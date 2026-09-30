import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/foundation.dart';

/// Whether this Mac is connected to the teacher's reporting site, and the tests
/// it offers. Settings and the upload pane both watch it, as the old page's two
/// tabs shared `connected` and `destinations`.
class TtessConnection extends ChangeNotifier {
  TtessConnection(this._client);

  final TtessClient _client;

  bool _connected = false;
  List<Map<String, Object?>> _destinations = const [];
  String? _error;
  bool _loaded = false;

  bool get connected => _connected;
  List<Map<String, Object?>> get destinations => _destinations;

  /// Set when the site could not be asked (or turned the token down).
  String? get error => _error;
  bool get loaded => _loaded;

  String get apiUrl => _client.apiUrl;
  String get siteUrl => _client.siteUrl;
  bool get hasEndpoint => apiUrl.isNotEmpty;

  int get courseCount => {for (final d in _destinations) d['course_title']}.length;

  /// The line under the section title.
  String get status {
    if (!hasEndpoint) return 'No upload address yet. Enter the address of your site below.';
    if (!_connected) return 'Not connected. Paste the connection token your site issued.';
    if (_error != null) return _error!;
    final tests = _destinations.length;
    return 'Connected · $tests test${tests == 1 ? '' : 's'} across '
        '$courseCount course${courseCount == 1 ? '' : 's'}';
  }

  String get destinationSummary => _destinations.isEmpty
      ? 'No tests are available to this account yet.'
      : {for (final d in _destinations) d['course_title']}.join(' · ');

  /// On launch: is there a token, and what does the site offer with it?
  Future<void> load() async {
    final token = await _client.token();
    _connected = token != null && token.isNotEmpty;
    _error = null;
    if (_connected && hasEndpoint) {
      try {
        _destinations = await _client.destinations(bearer: token);
      } on UploadError catch (error) {
        _error = error.message;
        // A token the site turned down was erased by the client.
        _connected = (await _client.token()) != null;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> connect(String token) async {
    try {
      await _client.saveToken(token);
      _destinations = await _client.destinations(force: true);
      _connected = true;
      _error = null;
    } on UploadError catch (error) {
      if (error.code != 'invalid_token') await _client.forgetToken();
      _connected = false;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _client.forgetToken();
    _connected = false;
    _destinations = const [];
    _error = null;
    notifyListeners();
  }

  /// Ask the site again, ignoring the 15-minute cache.
  Future<int> refresh() async {
    try {
      _destinations = await _client.destinations(force: true);
      _error = null;
      return _destinations.length;
    } on UploadError catch (error) {
      _error = error.message;
      _connected = (await _client.token()) != null;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// Save where reports go. Throws [UploadError] for an address that is not
  /// https.
  void saveAddress(String api, String site) {
    _client
      ..saveEndpoint(api)
      ..saveSite(site);
    _destinations = const [];
    notifyListeners();
  }

  /// Used by the upload pane after sending, to pick up a new draft run.
  Future<void> refreshQuietly() async {
    try {
      _destinations = await _client.destinations(force: true);
      notifyListeners();
    } on UploadError {
      // The upload already succeeded; a refresh failure should not hide that.
    }
  }

  /// Upload one scored run.
  Future<Map<String, Object?>> upload(
    String examId,
    Map<String, Object?> report,
    String testCode, {
    String? replaceRunId,
  }) async {
    try {
      return await _client.upload(examId, report, testCode, replaceRunId: replaceRunId);
    } on UploadError catch (error) {
      if (error.code == 'invalid_token') {
        _connected = false;
        _destinations = const [];
        notifyListeners();
      }
      rethrow;
    }
  }
}
