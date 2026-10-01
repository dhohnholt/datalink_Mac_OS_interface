// A session set up for 50 questions whose test has 30: the key sheet shows it
// (answers through 30, nothing after), and the count can be brought down to
// match, before or after the class has been scanned. Never up.
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

import 'support/live_fake.dart';

List<String> _responses(int answered, int total, {String letter = 'A'}) =>
    [for (var i = 0; i < total; i++) i < answered ? letter : ''];

void main() {
  group('questionCountFromKey', () {
    test('a key that stops short of the count says where', () {
      expect(questionCountFromKey(_responses(30, 50), 50), 30);
    });

    test('a key that fills the count suggests nothing', () {
      expect(questionCountFromKey(_responses(50, 50), 50), isNull);
    });

    test('an empty key has nothing to go on', () {
      expect(questionCountFromKey(_responses(0, 50), 50), isNull);
    });

    test('a blank in the middle does not hide where the key ends', () {
      final key = _responses(30, 50)..[11] = '';
      expect(questionCountFromKey(key, 50), 30);
    });

    test('several marks on the last question still count as an answer', () {
      final key = _responses(29, 50)..[29] = '*';
      expect(questionCountFromKey(key, 50), 30);
    });

    test('a count the key already fills, or exceeds, is left alone', () {
      expect(questionCountFromKey(_responses(30, 50), 30), isNull);
      expect(questionCountFromKey(_responses(30, 50), 20), isNull);
    });

    test('answers are read only up to the count', () {
      // 40 answered, session set to 35: nothing past 35 is considered.
      expect(questionCountFromKey(_responses(40, 50), 35), isNull);
    });
  });

  group('a saved session', () {
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

    Map<String, Object?> scan(int number, String role, List<String> responses, {String? id}) => {
          'number': number,
          'role': role,
          'student_id': id,
          'student_name': null,
          'received_at': 'x',
          'answered_count': responses.where((r) => r.isNotEmpty).length,
          'responses': responses,
        };

    /// The mistake: a 30-question test scanned into a session counting 50.
    int mistakenSession({List<String>? student}) {
      final id = store.createSession('Unit 4', 'P4', 50);
      store
        ..addScan(id, scan(1, 'key', _responses(30, 50)))
        ..addScan(id, scan(2, 'student', student ?? _responses(30, 50), id: '900011'));
      return id;
    }

    test('is noticed from its key', () {
      final id = mistakenSession();
      expect(workspace.questionCountSuggestion(id), {
        'current': 50,
        'suggested': 30,
        'sheets': 0,
        'marks': 0,
      });
    });

    test('says how many marks would be left out if a student marked past the end', () {
      final id = mistakenSession(student: [..._responses(30, 50), ...[]]..[34] = 'B'..[40] = 'C');
      final suggestion = workspace.questionCountSuggestion(id)!;
      expect([suggestion['sheets'], suggestion['marks']], [1, 2]);
    });

    test('a session whose key is complete is left alone', () {
      final id = store.createSession('Unit 5', 'P4', 50);
      store.addScan(id, scan(1, 'key', _responses(50, 50)));
      expect(workspace.questionCountSuggestion(id), isNull);
    });

    test('a session with no key is left alone', () {
      final id = store.createSession('Unit 6', 'P4', 50);
      store.addScan(id, scan(1, 'student', _responses(30, 50), id: '900011'));
      expect(workspace.questionCountSuggestion(id), isNull);
    });

    test('taking it up lowers the count and trims every sheet', () {
      final id = mistakenSession(student: [..._responses(30, 50)]..[34] = 'B');
      final result = workspace.useFewerQuestions(id, 30);
      expect(result, {'question_count': 30, 'sheets': 1, 'marks': 1});

      expect(store.session(id)!['question_count'], 30);
      final scans = store.sessionScans(id);
      expect(scans.map((s) => (s['responses']! as List).length), [30, 30]);
      expect(scans.map((s) => s['answered_count']), [30, 30]);
      expect(workspace.questionCountSuggestion(id), isNull);
    });

    test('a test that could not be scored before can be afterwards', () {
      final id = mistakenSession();
      expect(() => workspace.analysisReport(id), throwsA(isA<AnalysisError>()));

      workspace.useFewerQuestions(id, 30);

      final report = workspace.analysisReport(id);
      expect((report['students']! as List), hasLength(1));
      expect(((report['exam']! as Map)['answer_key']! as List), hasLength(30));
    });

    test('scoring after the change is a new run, as after any correction', () {
      final id = store.createSession('Unit 7', 'P4', 50);
      store
        ..addScan(id, scan(1, 'key', [..._responses(30, 50)]))
        ..addScan(id, scan(2, 'student', _responses(30, 50), id: '900011'));
      workspace.useFewerQuestions(id, 30);
      final first = workspace.analysisReport(id)['run_id'];
      expect(workspace.analysisReport(id)['run_id'], first, reason: 'unchanged inputs keep their run');
      store.updateScan(id, 2, responses: [..._responses(30, 30)]..[0] = 'B');
      expect(workspace.analysisReport(id)['run_id'], isNot(first));
    });

    test('a count cannot be raised, or left as it is', () {
      final id = mistakenSession();
      expect(() => workspace.useFewerQuestions(id, 50), throwsA(isA<DataLinkError>()));
      expect(() => workspace.useFewerQuestions(id, 60), throwsA(isA<DataLinkError>()));
      expect(() => workspace.useFewerQuestions(id, 0), throwsA(isA<DataLinkError>()));
      expect(store.session(id)!['question_count'], 50);
      expect((store.sessionScans(id).first['responses']! as List).length, 50);
    });

    test('a session that is not there is reported as such', () {
      expect(() => workspace.useFewerQuestions(999, 30), throwsA(isA<NotFoundError>()));
      expect(() => workspace.questionCountSuggestion(999), throwsA(isA<NotFoundError>()));
    });
  });

  group('a session being scanned', () {
    late Directory directory;
    late Store store;
    late LiveFakeTransport device;
    late ScannerController controller;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('datalink-count');
      store = Store.open(':memory:');
      final clock = YieldingClock();
      device = LiveFakeTransport(clock: clock);
      controller = ScannerController(captureRoot: directory, store: store, transport: device, clock: clock);
    });
    tearDown(() async {
      await controller.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    });

    Future<int> startAt50AndFeedKey() async {
      await controller.connect(null, 50);
      final id = await controller.startSession(questionCount: 50);
      device.sendRecord(_responses(30, 30), studentId: '');
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      return id;
    }

    test('lowering the count after the key trims the key and what is stored', () async {
      final id = await startAt50AndFeedKey();
      expect(controller.snapshot().questionCount, 50);

      final loss = controller.changeQuestionCount(30);

      expect(loss, (sheets: 0, marks: 0));
      final snapshot = controller.snapshot();
      expect(snapshot.questionCount, 30);
      expect((snapshot.records.single['responses']! as List), hasLength(30));
      expect(snapshot.records.single['answered_count'], 30);
      expect(store.session(id)!['question_count'], 30);
      expect((store.sessionScans(id).single['responses']! as List), hasLength(30));
    });

    test('the sheets that follow are read at the new count', () async {
      final id = await startAt50AndFeedKey();
      controller.changeQuestionCount(30);

      // A student sheet with a stray mark at question 35: past the test's end.
      device.sendRecord([..._responses(30, 40)]..[34] = 'C', studentId: '900011');
      await pumpUntil(() => controller.snapshot().pendingReview != null);
      controller.resolveReview(2, const {}, '900011', 'Ada');

      final student = store.sessionScans(id).last;
      expect((student['responses']! as List), hasLength(30));
      expect(student['answered_count'], 30);
    });

    test('it can only be lowered', () async {
      await startAt50AndFeedKey();
      expect(() => controller.changeQuestionCount(50), throwsA(isA<DataLinkError>()));
      expect(() => controller.changeQuestionCount(70), throwsA(isA<DataLinkError>()));
      expect(() => controller.changeQuestionCount(0), throwsA(isA<DataLinkError>()));
      expect(controller.snapshot().questionCount, 50);
    });

    test('it waits while a sheet is waiting for review', () async {
      await startAt50AndFeedKey();
      device.sendRecord(_responses(30, 30), studentId: '900011');
      await pumpUntil(() => controller.snapshot().pendingReview != null);
      expect(
        () => controller.changeQuestionCount(30),
        throwsA(isA<DataLinkError>().having((e) => e.message, 'message', contains('waiting for review'))),
      );
      expect(controller.snapshot().questionCount, 50);
    });

    test('there has to be a session', () async {
      await controller.connect(null, 50);
      expect(
        () => controller.changeQuestionCount(30),
        throwsA(isA<DataLinkError>().having((e) => e.message, 'message', 'No session is running')),
      );
    });
  });
}
