/// Client for a teacher's own reporting site. A port of `ttess.py`.
///
/// Two rules shape everything here. The connection token is a credential, so
/// it lives in the Keychain and never reaches a log line or an error message.
/// And an upload is an audit record, so a retry of one request keeps its run
/// id while a corrected re-score gets a new one.
///
/// Unlike the Python module this holds no global state and ships **no default
/// address**: the teacher says where their own reports go, in Settings, and
/// until they do there is nowhere to send anything.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/py_json.dart';
import '../store/store.dart';

/// Where the token is kept. These coordinates are part of the specification
/// the website was built against.
const String keychainService = 'org.tmechs.datalink';
const String keychainAccount = 'scantron-upload-token';

const String tokenPrefix = 'dlk_live_';
const int maxAnalysisBytes = 5242880;
const Duration requestTimeout = Duration(seconds: 30);
const Duration destinationCacheWindow = Duration(minutes: 15);
const int maxRetries = 2;

const String endpointSetting = 'ttess_api_url';
const String siteSetting = 'ttess_site_url';

/// A failure worth showing the teacher, with the server's own wording.
class UploadError implements Exception {
  const UploadError(this.message, {this.code = 'error', this.retryable = false});

  final String message;
  final String code;
  final bool retryable;

  @override
  String toString() => message;
}

/// One HTTP exchange: the status and the decoded JSON body (empty if none).
typedef HttpReply = ({int status, Map<String, Object?> body});

abstract interface class HttpTransport {
  /// Throws [SocketException], [HandshakeException] or [TimeoutException] when
  /// the site cannot be reached; returns any status the server answers with.
  Future<HttpReply> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  });
}

/// The Keychain, as far as this client needs it.
abstract interface class SecretStore {
  Future<String?> read(String service, String account);
  Future<void> write(String service, String account, String secret);

  /// True if something was removed.
  Future<bool> delete(String service, String account);
}

/// `dart:io` over TLS. Needs the network.client entitlement in the sandbox.
class IoHttpTransport implements HttpTransport {
  @override
  Future<HttpReply> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, url).timeout(timeout);
      headers.forEach(request.headers.set);
      if (body != null) request.add(body);
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      Map<String, Object?> decoded = const {};
      if (text.isNotEmpty) {
        try {
          final value = jsonDecode(text);
          if (value is Map) decoded = value.cast<String, Object?>();
        } on FormatException {
          // A non-JSON body is treated as no body.
        }
      }
      return (status: response.statusCode, body: decoded);
    } finally {
      client.close(force: true);
    }
  }
}

void requireHttps(String url) {
  if (!url.toLowerCase().startsWith('https://')) {
    throw const UploadError(
      'The upload address must use https. Refusing to send student data '
      'over an unencrypted connection.',
      code: 'insecure_url',
    );
  }
}

/// Stamp the destination onto the report and check it against the limit.
///
/// `schema_version` and `run_id` are left exactly as scored: the run id is what
/// makes a retry the same audit record rather than a second one. The caller's
/// report is not modified.
({Map<String, Object?> payload, List<int> bytes}) prepareAnalysis(
  Map<String, Object?> analysis,
  String testCode,
) {
  final payload = (jsonDecode(pyJsonEncode(analysis)) as Map).cast<String, Object?>();
  final exam = (payload.putIfAbsent('exam', () => <String, Object?>{}) as Map).cast<String, Object?>();
  exam['test_code'] = testCode;
  // source_type says how it reached the site, which is the same either way.
  // capture_method keeps how the sheets were actually read, so a batch off a
  // document scanner is not recorded as having come from the device.
  exam.putIfAbsent(
    'capture_method',
    () => exam['source_type'] == 'pdf_scan' ? 'paper_scan' : 'datalink',
  );
  exam['source_type'] = 'datalink_direct';
  final bytes = utf8.encode(pyJsonEncode(payload));
  if (bytes.length > maxAnalysisBytes) {
    final mb = (bytes.length / 1048576).toStringAsFixed(1);
    throw UploadError(
      'The analysis is $mb MB, over the ${(maxAnalysisBytes / 1048576).round()} MB upload limit.',
      code: 'payload_too_large',
    );
  }
  return (payload: payload, bytes: bytes);
}

class TtessClient {
  TtessClient({
    required this.store,
    required this.secrets,
    required this.http,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  })  : _sleep = sleep ?? Future<void>.delayed,
        _now = now ?? DateTime.now;

  final Store store;
  final SecretStore secrets;
  final HttpTransport http;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  // ---------------------------------------------------------------- addresses

  /// Where reports are sent, or '' when the teacher has not said.
  String get apiUrl => store.getSetting(endpointSetting).trim();

  /// Where the teacher reads those reports, for a link in Settings.
  String get siteUrl => store.getSetting(siteSetting).trim();

  /// Remember where this copy uploads to. Refused unless it is https: the
  /// token travels on the request as a bearer header and student data travels
  /// in the body. An empty string clears it.
  void saveEndpoint(String url) {
    url = url.trim();
    if (url.isNotEmpty) requireHttps(url);
    store.setSetting(endpointSetting, url);
    _destinations = const [];
    _fetchedAt = null;
  }

  void saveSite(String url) {
    url = url.trim();
    if (url.isNotEmpty) requireHttps(url);
    store.setSetting(siteSetting, url);
  }

  // -------------------------------------------------------------------- token

  Future<String?> token() => secrets.read(keychainService, keychainAccount);

  Future<void> saveToken(String value) async {
    value = value.trim();
    if (value.isEmpty) {
      throw const UploadError('Paste the connection token first', code: 'empty_token');
    }
    if (!value.startsWith(tokenPrefix)) {
      throw const UploadError(
        'That does not look like a DataLink connection token — they begin '
        'with $tokenPrefix',
        code: 'malformed_token',
      );
    }
    await secrets.write(keychainService, keychainAccount, value);
  }

  Future<bool> forgetToken() {
    _destinations = const [];
    _fetchedAt = null;
    return secrets.delete(keychainService, keychainAccount);
  }

  // ------------------------------------------------------------------ requests

  Future<HttpReply> _request(String method, List<int>? body, String bearer) async {
    final url = apiUrl;
    if (url.isEmpty) {
      throw const UploadError(
        'No upload address is set. Open Settings and enter the address of '
        'your own site before connecting.',
        code: 'no_endpoint',
      );
    }
    requireHttps(url);
    try {
      return await http.send(
        method,
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $bearer',
          'Accept': 'application/json',
          if (body != null) 'Content-Type': 'application/json',
        },
        body: body,
        timeout: requestTimeout,
      );
    } on TimeoutException {
      throw UploadError(
        'The site did not respond within ${requestTimeout.inSeconds} seconds.',
        code: 'service_unavailable',
        retryable: true,
      );
    } on IOException catch (error) {
      // The reason can carry a host name but never the token, which is only
      // ever sent as a header.
      final reason = error is SocketException ? error.message : error.toString();
      throw UploadError(
        'Could not reach the site ($reason). Check the internet connection and try again.',
        code: 'service_unavailable',
        retryable: true,
      );
    }
  }

  Future<UploadError> _serverError(int status, Map<String, Object?> payload) async {
    final error = (payload['error'] as Map?)?.cast<String, Object?>() ?? const {};
    final code = '${error['code'] ?? ''}';
    final message = '${error['message'] ?? ''}'.trim();

    if (status == 401 || code == 'invalid_token') {
      await forgetToken();
      return UploadError(
        message.isNotEmpty
            ? message
            : 'The connection token is no longer valid. Open Settings and paste a new one.',
        code: 'invalid_token',
      );
    }
    if (status == 403 || code == 'exam_forbidden') {
      return UploadError(
        message.isNotEmpty ? message : 'That test is not available to this account. Choose another.',
        code: 'exam_forbidden',
      );
    }
    if (code == 'run_not_replaceable') {
      return UploadError(
        message.isNotEmpty ? message : 'Those results are already finalized and cannot be replaced.',
        code: 'run_not_replaceable',
      );
    }
    if (status == 409 || code == 'duplicate_run') {
      return UploadError(
        message.isNotEmpty ? message : 'This scoring run has already been uploaded.',
        code: 'duplicate_run',
      );
    }
    if (status == 413 || code == 'payload_too_large') {
      return UploadError(
        message.isNotEmpty ? message : 'The analysis is larger than the 5 MB upload limit.',
        code: 'payload_too_large',
      );
    }
    if (status == 422 || code == 'validation_failed') {
      return UploadError(
        message.isNotEmpty ? message : 'The site rejected the analysis.',
        code: 'validation_failed',
      );
    }
    if (status == 503 || code == 'service_unavailable') {
      return UploadError(
        message.isNotEmpty ? message : 'The site is temporarily unavailable.',
        code: 'service_unavailable',
        retryable: true,
      );
    }
    return UploadError(
      message.isNotEmpty ? message : 'The site returned an unexpected response ($status).',
      code: code.isNotEmpty ? code : 'unexpected',
      retryable: status >= 500,
    );
  }

  // -------------------------------------------------------------- destinations

  List<Map<String, Object?>> _destinations = const [];
  DateTime? _fetchedAt;

  bool get _stale {
    final at = _fetchedAt;
    return at == null || _now().difference(at) > destinationCacheWindow;
  }

  /// The tests this account can upload to.
  Future<List<Map<String, Object?>>> fetchDestinations([String? bearer]) async {
    bearer ??= await token();
    if (bearer == null || bearer.isEmpty) {
      throw const UploadError('Connect DataLink to your site first', code: 'not_connected');
    }
    final reply = await _request('GET', null, bearer);
    if (reply.status != 200) throw await _serverError(reply.status, reply.body);
    return [
      for (final d in (reply.body['destinations'] as List?) ?? const <Object?>[])
        (d! as Map).cast<String, Object?>(),
    ];
  }

  /// Kept for 15 minutes, and refreshed on connect, on launch and before an
  /// upload once stale.
  Future<List<Map<String, Object?>>> destinations({bool force = false, String? bearer}) async {
    if (force || _stale || _destinations.isEmpty) {
      _destinations = await fetchDestinations(bearer);
      _fetchedAt = _now();
    }
    return _destinations;
  }

  // ------------------------------------------------------------------- upload

  /// Send one scored run. Retries only what is safe to retry, with the same
  /// body each time so a retry is the same audit record.
  Future<Map<String, Object?>> upload(
    String examId,
    Map<String, Object?> analysis,
    String testCode, {
    String? replaceRunId,
    String? bearer,
  }) async {
    bearer ??= await token();
    if (bearer == null || bearer.isEmpty) {
      throw const UploadError('Connect DataLink to your site first', code: 'not_connected');
    }
    if (examId.isEmpty) {
      throw const UploadError('Choose which test to upload to', code: 'no_destination');
    }

    final prepared = prepareAnalysis(analysis, testCode);
    final body = utf8.encode(
      pyJsonEncode({
        'exam_id': examId,
        'analysis': prepared.payload,
        if (replaceRunId != null && replaceRunId.isNotEmpty) 'replace_run_id': replaceRunId,
      }),
    );

    var attempt = 0;
    while (true) {
      UploadError failure;
      try {
        final reply = await _request('POST', body, bearer);
        if (reply.status == 200 || reply.status == 201) {
          final payload = reply.body;
          final review = payload['review_url'];
          return <String, Object?>{
            'run_id': payload['run_id'],
            'status': payload['status'] ?? 'imported',
            'replaced_run_id': payload['replaced_run_id'],
            'review_url': (review is String && review.isNotEmpty) ? review : siteUrl,
          };
        }
        failure = await _serverError(reply.status, reply.body);
      } on UploadError catch (error) {
        failure = error;
      }
      if (!failure.retryable || attempt >= maxRetries) throw failure;
      // Same body, so the same run id: a retry must not become a second audit
      // record.
      await _sleep(Duration(seconds: 1 << attempt));
      attempt++;
    }
  }
}
