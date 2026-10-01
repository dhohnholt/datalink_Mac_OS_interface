// Ported from the API-level tests in tests/test_server.py (HttpApiTests): the
// same behaviours, called directly instead of over HTTP.
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

void main() {
  late Store store;
  late Workspace workspace;
  var ids = 0;

  setUp(() {
    store = Store.open(':memory:');
    ids = 0;
    workspace = Workspace(
      store: store,
      now: () => DateTime.utc(2026, 9, 30, 12),
      newId: () => 'run-${++ids}',
    );
  });

  tearDown(() => store.close());

  Map<String, Object?> scan(int number, String role, List<String> responses,
          {String? id, String? name}) =>
      {
        'number': number,
        'role': role,
        'student_id': id,
        'student_name': name,
        'received_at': 'x',
        'answered_count': responses.where((r) => r.isNotEmpty).length,
        'responses': responses,
      };

  int flaggedSession() {
    final id = store.createSession('Unit 7', 'P4', 3);
    store
      ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
      ..addScan(id, scan(2, 'student', ['A', 'AB', 'C']));
    return id;
  }

  group('corrections', () {
    test('a name can be corrected alongside an id', () {
      final id = store.createSession('Unit 3', 'P4', 3);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C']));
      final result = workspace.correct(id, [
        {'number': 2, 'student_id': '900011', 'student_name': 'Ada Lovelace'},
      ]);
      expect(result['applied'], 1);
      final saved = store.sessionScans(id).firstWhere((s) => s['number'] == 2);
      expect(saved['student_id'], '900011');
      expect(saved['student_name'], 'Ada Lovelace');
    });

    test('a correction rewrites the sheet and rescores', () {
      final id = store.createSession('Unit 9', 'P4', 5);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C', 'D', 'E']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C', 'D', 'E']));
      final result = workspace.correct(id, [
        {'number': 2, 'student_id': '900444'},
      ]);
      expect(result['applied'], 1);
      final analysis = result['analysis']! as Map<String, Object?>;
      expect(((analysis['students']! as List).first as Map)['student_id'], '900444');
      expect(analysis['review_items'], isEmpty);
    });

    test('the wrong number of responses is rejected', () {
      final id = store.createSession('Unit 9', 'P4', 5);
      store.addScan(id, scan(1, 'key', List.filled(5, 'A')));
      expect(
        () => workspace.correct(id, [
          {'number': 1, 'responses': ['A', 'B']},
        ]),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            'Sheet 1 needs exactly 5 responses',
          ),
        ),
      );
    });

    test('a non-letter response is rejected, with Python\'s quoting', () {
      final id = store.createSession('Unit 9', 'P4', 3);
      store.addScan(id, scan(1, 'key', ['A', 'B', 'C']));
      expect(
        () => workspace.correct(id, [
          {'number': 1, 'responses': ['A', 'B', 'Z']},
        ]),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            "'Z' is not a valid response",
          ),
        ),
      );
    });

    test('a non-numeric student id is rejected', () {
      final id = store.createSession('Unit 9', 'P4', 3);
      store.addScan(id, scan(1, 'student', ['A', 'B', 'C']));
      expect(
        () => workspace.correct(id, [
          {'number': 1, 'student_id': 'abc'},
        ]),
        throwsA(isA<DataLinkError>()),
      );
    });

    test('BLANK and MULTIPLE are accepted as words', () {
      final id = store.createSession('Unit 9', 'P4', 3);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      workspace.correct(id, [
        {'number': 2, 'responses': ['blank', ' Multiple ', 'c']},
      ]);
      expect(store.sessionScans(id).last['responses'], ['', '*', 'C']);
    });

    test('a correction with nothing to do is refused', () {
      final id = flaggedSession();
      expect(
        () => workspace.correct(id, const [], dismiss: const []),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            'No corrections were supplied',
          ),
        ),
      );
    });

    test('a sheet that does not exist is refused, and nothing is half-applied', () {
      final id = flaggedSession();
      expect(
        () => workspace.correct(id, [
          {'number': 2, 'student_id': '900001'},
          {'number': 99, 'student_id': '900002'},
        ]),
        throwsA(isA<StoreError>()),
      );
      expect(store.sessionScans(id).last['student_id'], isNull, reason: 'rolled back');
    });

    test('a session that is gone is not found', () {
      expect(
        () => workspace.correct(404, [
          {'number': 1},
        ]),
        throwsA(isA<NotFoundError>()),
      );
    });
  });

  group('review', () {
    test('the report names the class it was scanned against', () {
      final id = store.createSession('Unit 5', 'Period 4', 3);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      final inline = workspace.analysisReport(id);
      expect(inline['class_name'], 'Period 4');
      // The downloadable report keeps the schema the website expects.
      final download = workspace.scoredSession(id).report;
      expect(download.containsKey('class_name'), isFalse);
      expect(download.containsKey('has_pages'), isFalse);
    });

    test('opening a session names students the roster learned later', () {
      final id = store.createSession('Unit 6', 'Period 4', 3);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '566940'))
        ..saveClass('Period 4', [
          {'id': '566940', 'name': 'Ada Lovelace'},
        ]);
      final detail = workspace.sessionDetail(id);
      final sheet = (detail['scans']! as List).cast<Map<String, Object?>>().firstWhere(
            (s) => s['number'] == 2,
          );
      expect(sheet['student_name'], 'Ada Lovelace');
      final report = workspace.analysisReport(id);
      expect(((report['students']! as List).first as Map)['student_name'], 'Ada Lovelace');
    });

    test('a checked item stops being reported', () {
      final id = flaggedSession();
      final before = workspace.analysisReport(id);
      expect((before['review_items']! as List), hasLength(2));
      expect(before['dismissed_count'], 0);

      expect(workspace.dismissReviews(id, ['2:answer:2:multiple']), 1);

      final after = workspace.analysisReport(id);
      expect((after['review_items']! as List), hasLength(1));
      expect(after['dismissed_count'], 1);
    });

    test('checking items off is a complete answer on its own', () {
      final id = flaggedSession();
      final result = workspace.correct(
        id,
        const [],
        dismiss: ['2:answer:2:multiple', '2:student_id:0:'],
      );
      expect(result['applied'], 0);
      expect(result['dismissed'], 2);
      expect((result['analysis']! as Map)['review_items'], isEmpty);
    });

    test('the uploaded report leaves out checked items too', () {
      final id = flaggedSession();
      workspace.dismissReviews(id, ['2:answer:2:multiple']);
      final payload = workspace.scoredSession(id).report;
      expect((payload['review_items']! as List), hasLength(1));
      expect(payload.containsKey('dismissed_count'), isFalse);
    });

    test('they can all be brought back', () {
      final id = flaggedSession();
      workspace.dismissReviews(id, ['2:answer:2:multiple', '2:student_id:0:']);
      expect(workspace.restoreReviews(id), 2);
      expect((workspace.analysisReport(id)['review_items']! as List), hasLength(2));
    });

    test('checking off on a session that is gone is refused', () {
      expect(
        () => workspace.dismissReviews(99999, ['1:answer:1:faint']),
        throwsA(isA<NotFoundError>()),
      );
    });
  });

  group('sessions', () {
    test('a DataLink session offers no sheet images', () {
      final id = store.createSession('Unit 4', 'P4', 3);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      expect(workspace.sessionDetail(id)['has_pages'], isFalse);
      expect(workspace.analysisReport(id)['has_pages'], isFalse);
    });

    test('a paper session offers its pages while the cache exists', () {
      final cache = Directory.systemTemp.createTempSync('datalink-pages');
      addTearDown(() {
        if (cache.existsSync()) cache.deleteSync(recursive: true);
      });
      final id = store.createSession('Paper', 'P4', 3, source: 'paper', pageCache: cache.path);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      expect(workspace.sessionDetail(id)['has_pages'], isTrue);
      expect(workspace.sessionDetail(id).containsKey('page_cache'), isFalse,
          reason: 'where it lives on disk is not the screen\'s business');
      cache.deleteSync(recursive: true);
      expect(workspace.sessionDetail(id)['has_pages'], isFalse);
    });

    test('a session that cannot be scored says why, and is still viewable', () {
      final id = store.createSession('No key', 'P4', 3);
      store.addScan(id, scan(2, 'student', ['A', 'B', 'C']));
      final detail = workspace.sessionDetail(id);
      expect(detail['analysis_available'], isFalse);
      expect(
        detail['analysis_error'],
        'Scoring needs exactly one answer key in the session; this one has 0',
      );
      expect(() => workspace.analysisReport(id), throwsA(isA<AnalysisError>()));
    });

    test('a retry keeps its run id; a re-score after a change does not', () {
      final id = store.createSession('Unit 1', 'P4', 3);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      final first = workspace.scoredSession(id).report['run_id'];
      final retry = workspace.scoredSession(id).report['run_id'];
      expect(retry, first, reason: 'same inputs, same audit record');

      workspace.correct(id, [
        {'number': 2, 'student_id': '900022'},
      ]);
      final rescored = workspace.scoredSession(id).report['run_id'];
      expect(rescored, isNot(first), reason: 'the payload changed');
      expect(store.session(id)!['analysis_run_id'], rescored);
    });

    test('exports carry a safe filename', () {
      final id = store.createSession('Quiz: Ünï 1', 'P4', 3);
      store
        ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
        ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      expect(workspace.sessionCsv(id).filename, 'Quiz_ _n_ 1.csv');
      expect(workspace.analysisDownload(id).filename, 'Quiz_ _n_ 1.json');
      expect(workspace.analysisDownload(id).json, startsWith('{\n  "schema_version": "1.0"'));
    });

    test('a missing session is not found', () {
      expect(() => workspace.sessionDetail(1), throwsA(isA<NotFoundError>()));
      expect(() => workspace.sessionCsv(1), throwsA(isA<NotFoundError>()));
      expect(() => workspace.scoredSession(1), throwsA(isA<NotFoundError>()));
    });
  });

  group('settings', () {
    test('survive a reload, with the matching default', () {
      expect(workspace.settings()['student_matching'], 'id');
      workspace.updateSettings({
        'test_name': 'Unit 2',
        'selected_class': 'P4',
        'question_count': 30,
        'student_matching': 'roster',
      });
      expect(workspace.settings(), {
        'test_name': 'Unit 2',
        'selected_class': 'P4',
        'question_count': '30',
        'student_matching': 'roster',
      });
    });

    test('renaming the test keeps an open history row in step', () {
      final id = store.createSession('Old', 'P4', 3);
      workspace.updateSettings({'test_name': 'New', 'selected_class': 'P5'}, openSessionId: id);
      final session = store.session(id)!;
      expect(session['name'], 'New');
      expect(session['class_name'], 'P5');
    });

    test('unrelated keys are ignored and leave the row alone', () {
      final id = store.createSession('Keep', 'P4', 3);
      workspace.updateSettings({'question_count': 20}, openSessionId: id);
      expect(store.session(id)!['name'], 'Keep');
    });
  });

  test('a paper sheet\'s stored picture is served, and its absence is null', () {
    final cache = Directory.systemTemp.createTempSync('ws-pages-');
    addTearDown(() {
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });
    File('${cache.path}/${pagePictureName(2)}').writeAsBytesSync([1, 2, 3]);
    final withPages = store.createSession('Paper', '', 3, source: 'paper', pageCache: cache.path);
    final without = store.createSession('DataLink', '', 3);
    expect(workspace.sessionPage(withPages, 2), [1, 2, 3]);
    expect(workspace.sessionPage(withPages, 9), isNull);
    expect(workspace.sessionPage(without, 2), isNull);
    expect(workspace.sessionDetail(withPages)['has_pages'], isTrue);
    cache.deleteSync(recursive: true);
    expect(workspace.sessionDetail(withPages)['has_pages'], isFalse);
  });
}
