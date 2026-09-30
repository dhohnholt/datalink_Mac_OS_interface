// Ported from tests/test_ttess.py. Nothing here touches a real service or the
// real Keychain: what matters is the handling around the call -- which failures
// may be retried, which must not, that a retry keeps its run id, and that the
// token never leaks.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

Map<String, Object?> analysis({String runId = 'run-1', int size = 1}) => {
      'schema_version': '1.0',
      'run_id': runId,
      'exam': {'name': 'Unit 4', 'source_type': 'datalink_csv', 'padding': 'x' * size},
      'students': <Object?>[],
      'items': <Object?>[],
    };

class MemorySecrets implements SecretStore {
  final Map<(String, String), String> items = {};

  @override
  Future<String?> read(String service, String account) async => items[(service, account)];

  @override
  Future<void> write(String service, String account, String secret) async =>
      items[(service, account)] = secret;

  @override
  Future<bool> delete(String service, String account) async =>
      items.remove((service, account)) != null;
}

class ScriptedHttp implements HttpTransport {
  ScriptedHttp(this.outcomes);

  /// Each is an [HttpReply] (status, body) or an exception to throw. The last
  /// one repeats.
  final List<Object> outcomes;
  final List<({String method, Uri url, Map<String, String> headers, List<int>? body})> calls = [];

  @override
  Future<HttpReply> send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    List<int>? body,
    required Duration timeout,
  }) async {
    calls.add((method: method, url: url, headers: headers, body: body));
    final outcome = outcomes[calls.length - 1 < outcomes.length ? calls.length - 1 : outcomes.length - 1];
    if (outcome is Exception) throw outcome;
    return outcome as HttpReply;
  }
}

HttpReply reply(int status, [Map<String, Object?> body = const {}]) => (status: status, body: body);

void main() {
  late Store store;
  late MemorySecrets secrets;
  late List<Duration> slept;

  TtessClient client(ScriptedHttp http, {DateTime Function()? now}) => TtessClient(
        store: store,
        secrets: secrets,
        http: http,
        sleep: (d) async => slept.add(d),
        now: now,
      );

  setUp(() {
    store = Store.open(':memory:')..setSetting(endpointSetting, 'https://example.org/datalink');
    secrets = MemorySecrets();
    slept = [];
  });

  tearDown(() => store.close());

  group('token', () {
    test('rejects a token without the expected prefix, and stores nothing', () async {
      await expectLater(
        client(ScriptedHttp([])).saveToken('not-a-real-token'),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'malformed_token')),
      );
      expect(secrets.items, isEmpty);
    });

    test('rejects an empty token', () async {
      await expectLater(
        client(ScriptedHttp([])).saveToken('   '),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'empty_token')),
      );
    });

    test('stores a valid token in the keychain only, trimmed', () async {
      await client(ScriptedHttp([])).saveToken('  dlk_live_abc123  ');
      expect(secrets.items, {(keychainService, keychainAccount): 'dlk_live_abc123'});
      expect(store.getSetting('token'), '', reason: 'nothing in the database');
    });

    test('the keychain coordinates match the specification', () {
      expect(keychainService, 'org.tmechs.datalink');
      expect(keychainAccount, 'scantron-upload-token');
    });
  });

  group('preparation', () {
    test('stamps the destination and marks the source', () {
      final prepared = prepareAnalysis(analysis(), 'ECON-U2-5-5WT').payload;
      final exam = prepared['exam']! as Map;
      expect(exam['test_code'], 'ECON-U2-5-5WT');
      expect(exam['source_type'], 'datalink_direct');
      expect(exam['capture_method'], 'datalink');
    });

    test('a paper batch is recorded as read from paper', () {
      final report = analysis();
      (report['exam']! as Map)['source_type'] = 'pdf_scan';
      expect(((prepareAnalysis(report, 'T').payload)['exam']! as Map)['capture_method'], 'paper_scan');
    });

    test('an existing capture method is kept', () {
      final report = analysis();
      (report['exam']! as Map)['capture_method'] = 'custom';
      expect(((prepareAnalysis(report, 'T').payload)['exam']! as Map)['capture_method'], 'custom');
    });

    test('keeps schema version and run id', () {
      final prepared = prepareAnalysis(analysis(runId: 'keep-me'), 'T').payload;
      expect(prepared['schema_version'], '1.0');
      expect(prepared['run_id'], 'keep-me');
    });

    test("does not mutate the caller's report", () {
      final original = analysis();
      prepareAnalysis(original, 'T');
      expect((original['exam']! as Map)['source_type'], 'datalink_csv');
      expect((original['exam']! as Map).containsKey('test_code'), isFalse);
    });

    test('refuses an oversized analysis before sending', () {
      expect(
        () => prepareAnalysis(analysis(size: maxAnalysisBytes + 1), 'T'),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'payload_too_large')),
      );
    });

    test('the limit matches the specification', () => expect(maxAnalysisBytes, 5242880));
  });

  group('upload', () {
    Future<({Map<String, Object?>? result, ScriptedHttp http, UploadError? error})> send(
      List<Object> outcomes, {
      String? replaceRunId,
    }) async {
      final http = ScriptedHttp(outcomes);
      try {
        final result = await client(http).upload(
          'exam-1',
          analysis(),
          'CODE',
          bearer: 'dlk_live_x',
          replaceRunId: replaceRunId,
        );
        return (result: result, http: http, error: null);
      } on UploadError catch (error) {
        return (result: null, http: http, error: error);
      }
    }

    test('a created response returns the review url', () async {
      final r = await send([
        reply(201, {'run_id': 'db-run', 'status': 'imported', 'review_url': 'https://x.example/?run=1'}),
      ]);
      expect(r.error, isNull);
      expect(r.result!['run_id'], 'db-run');
      expect(r.result!['status'], 'imported');
      expect(r.result!['review_url'], contains('run=1'));
      expect(r.http.calls, hasLength(1));
    });

    test('with no review url the site address is offered', () async {
      store.setSetting(siteSetting, 'https://example.org/reports');
      final r = await send([reply(201, {'run_id': 'r'})]);
      expect(r.result!['review_url'], 'https://example.org/reports');
      expect(r.result!['status'], 'imported');
    });

    test('the token travels as a bearer and not in the body', () async {
      final r = await send([reply(201, {'run_id': 'r'})]);
      final call = r.http.calls.single;
      expect(call.headers['Authorization'], 'Bearer dlk_live_x');
      expect(utf8.decode(call.body!), isNot(contains('dlk_live_x')));
      expect(call.method, 'POST');
      expect(call.url.toString(), 'https://example.org/datalink');
      expect(call.headers['Content-Type'], 'application/json');
    });

    test('the body is raw JSON with exam_id and analysis', () async {
      final r = await send([reply(201, {'run_id': 'r'})]);
      final body = jsonDecode(utf8.decode(r.http.calls.single.body!)) as Map;
      expect(body.keys.toList()..sort(), ['analysis', 'exam_id']);
      expect(body['exam_id'], 'exam-1');
      expect(((body['analysis'] as Map)['exam'] as Map)['source_type'], 'datalink_direct');
    });

    test('a draft replacement is explicit in the body and the result', () async {
      final r = await send(
        [reply(200, {'run_id': 'new-db-run', 'status': 'updated', 'replaced_run_id': 'old-db-run'})],
        replaceRunId: 'old-db-run',
      );
      expect(r.error, isNull);
      final body = jsonDecode(utf8.decode(r.http.calls.single.body!)) as Map;
      expect(body['replace_run_id'], 'old-db-run');
      expect(r.result!['status'], 'updated');
      expect(r.result!['replaced_run_id'], 'old-db-run');
    });

    test('an unavailable service is retried twice with back-off, then reported', () async {
      final r = await send([reply(503, {'error': {'code': 'service_unavailable'}})]);
      expect(r.error!.code, 'service_unavailable');
      expect(r.http.calls, hasLength(3), reason: 'first attempt plus two retries');
      expect(slept, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    test('a retry sends the identical body, so the run id is unchanged', () async {
      final r = await send([
        reply(503, {'error': {'code': 'service_unavailable'}}),
        reply(201, {'run_id': 'db-run'}),
      ]);
      expect(r.http.calls, hasLength(2));
      expect(r.http.calls[0].body, r.http.calls[1].body);
      final body = jsonDecode(utf8.decode(r.http.calls[0].body!)) as Map;
      expect((body['analysis'] as Map)['run_id'], 'run-1');
    });

    test('a network failure is retried, and is worded for a person', () async {
      final r = await send([const SocketException('Connection refused')]);
      expect(r.error!.code, 'service_unavailable');
      expect(r.error!.message, 'Could not reach the site (Connection refused). Check the internet connection and try again.');
      expect(r.http.calls, hasLength(3));
    });

    test('a timeout says how long it waited', () async {
      final r = await send([TimeoutException('slow')]);
      expect(r.error!.message, 'The site did not respond within 30 seconds.');
    });

    test('a duplicate run is never retried', () async {
      final r = await send([reply(409, {'error': {'code': 'duplicate_run', 'message': 'Already uploaded'}})]);
      expect(r.error!.code, 'duplicate_run');
      expect(r.error!.message, 'Already uploaded');
      expect(r.http.calls, hasLength(1));
      expect(slept, isEmpty);
    });

    test('finalized results are not reported as duplicate runs', () async {
      final r = await send([
        reply(409, {'error': {'code': 'run_not_replaceable', 'message': 'Finalized results cannot be replaced'}}),
      ]);
      expect(r.error!.code, 'run_not_replaceable');
      expect(r.error!.message, 'Finalized results cannot be replaced');
      expect(r.http.calls, hasLength(1));
    });

    test('payload too large is never retried', () async {
      final r = await send([reply(413, {'error': {'code': 'payload_too_large'}})]);
      expect(r.error!.code, 'payload_too_large');
      expect(r.error!.message, 'The analysis is larger than the 5 MB upload limit.');
      expect(r.http.calls, hasLength(1));
    });

    test('a validation failure shows the server message and stops', () async {
      final r = await send([
        reply(422, {'error': {'code': 'validation_failed', 'message': 'answer_key must have 50 entries'}}),
      ]);
      expect(r.error!.code, 'validation_failed');
      expect(r.error!.message, 'answer_key must have 50 entries');
      expect(r.http.calls, hasLength(1));
    });

    test('a forbidden exam is not retried', () async {
      final r = await send([reply(403, {'error': {'code': 'exam_forbidden'}})]);
      expect(r.error!.code, 'exam_forbidden');
      expect(r.error!.message, 'That test is not available to this account. Choose another.');
      expect(r.http.calls, hasLength(1));
    });

    test('an invalid token is removed from the keychain', () async {
      secrets.items[(keychainService, keychainAccount)] = 'dlk_live_x';
      final r = await send([reply(401, {'error': {'code': 'invalid_token'}})]);
      expect(r.error!.code, 'invalid_token');
      expect(r.http.calls, hasLength(1));
      expect(secrets.items, isEmpty);
    });

    test('an unexpected status falls back to words and retries only a server fault', () async {
      final r = await send([reply(418)]);
      expect(r.error!.message, 'The site returned an unexpected response (418).');
      expect(r.http.calls, hasLength(1));
      final r500 = await send([reply(500)]);
      expect(r500.http.calls, hasLength(3));
    });

    test('uploading without a destination is refused locally', () async {
      await expectLater(
        client(ScriptedHttp([])).upload('', analysis(), 'CODE', bearer: 'dlk_live_x'),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'no_destination')),
      );
    });

    test('uploading without a token is refused locally', () async {
      final http = ScriptedHttp([]);
      await expectLater(
        client(http).upload('exam-1', analysis(), 'CODE'),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'not_connected')),
      );
      expect(http.calls, isEmpty);
    });

    test('with a token in the keychain and none passed, that token is used', () async {
      secrets.items[(keychainService, keychainAccount)] = 'dlk_live_stored';
      final http = ScriptedHttp([reply(201, {'run_id': 'r'})]);
      await client(http).upload('exam-1', analysis(), 'CODE');
      expect(http.calls.single.headers['Authorization'], 'Bearer dlk_live_stored');
    });
  });

  group('addresses', () {
    test('an http address is refused and not stored', () {
      final c = client(ScriptedHttp([]));
      expect(
        () => c.saveEndpoint('http://example.com/api'),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'insecure_url')),
      );
      expect(c.apiUrl, 'https://example.org/datalink');
      expect(() => c.saveSite('http://example.com'), throwsA(isA<UploadError>()));
    });

    test('an https address is saved, and clearing is allowed', () {
      final c = client(ScriptedHttp([]))..saveEndpoint(' https://new.example/api ');
      expect(c.apiUrl, 'https://new.example/api');
      c.saveEndpoint('');
      expect(c.apiUrl, '');
    });

    test('with nothing set there is nowhere to send, and nothing ships by default', () async {
      store.setSetting(endpointSetting, '');
      final http = ScriptedHttp([]);
      expect(client(http).apiUrl, '');
      await expectLater(
        client(http).fetchDestinations('dlk_live_x'),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'no_endpoint')),
      );
      expect(http.calls, isEmpty);
    });

    test('an insecure address that got into the settings is still refused at send time', () async {
      store.setSetting(endpointSetting, 'http://example.com/api');
      await expectLater(
        client(ScriptedHttp([])).fetchDestinations('dlk_live_x'),
        throwsA(isA<UploadError>().having((e) => e.code, 'code', 'insecure_url')),
      );
    });
  });

  group('destinations', () {
    test('are cached for fifteen minutes', () async {
      var now = DateTime.utc(2026, 9, 30, 12);
      final http = ScriptedHttp([
        reply(200, {'destinations': [{'exam_id': 'a'}]}),
      ]);
      final c = client(http, now: () => now);
      await c.destinations(bearer: 'dlk_live_x');
      await c.destinations(bearer: 'dlk_live_x');
      expect(http.calls, hasLength(1));
      now = now.add(const Duration(minutes: 15, seconds: 1));
      await c.destinations(bearer: 'dlk_live_x');
      expect(http.calls, hasLength(2));
    });

    test('force refetches at once', () async {
      final http = ScriptedHttp([reply(200, {'destinations': [{'exam_id': 'a'}]})]);
      final c = client(http);
      await c.destinations(bearer: 'dlk_live_x');
      await c.destinations(bearer: 'dlk_live_x', force: true);
      expect(http.calls, hasLength(2));
    });

    test('an empty list is asked for again rather than trusted', () async {
      final http = ScriptedHttp([reply(200, {'destinations': <Object?>[]})]);
      final c = client(http);
      await c.destinations(bearer: 'dlk_live_x');
      await c.destinations(bearer: 'dlk_live_x');
      expect(http.calls, hasLength(2));
    });

    test('changing the address drops what was cached from the old one', () async {
      final http = ScriptedHttp([reply(200, {'destinations': [{'exam_id': 'a'}]})]);
      final c = client(http);
      await c.destinations(bearer: 'dlk_live_x');
      c.saveEndpoint('https://other.example/api');
      await c.destinations(bearer: 'dlk_live_x');
      expect(http.calls.last.url.toString(), 'https://other.example/api');
    });

    test('the window matches the specification', () {
      expect(destinationCacheWindow, const Duration(minutes: 15));
    });
  });
}
