// The session lifecycle and CSV tests are ported from tests/test_server.py
// (SessionLifecycleTests, ExportCsvTests). The reader-path tests are new: the
// Python controller's reader loop was only ever exercised on hardware.
import 'dart:convert';
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

import 'support/live_fake.dart';

void main() {
  late Directory directory;
  late Store store;
  late YieldingClock clock;
  late LiveFakeTransport device;
  late ScannerController controller;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('datalink-controller');
    store = Store.open(':memory:');
    clock = YieldingClock();
    device = LiveFakeTransport(clock: clock);
    controller = ScannerController(
      captureRoot: directory,
      store: store,
      transport: device,
      clock: clock,
    );
  });

  tearDown(() async {
    await controller.dispose();
    store.close();
    directory.deleteSync(recursive: true);
  });

  Future<void> connect({Object count = 30}) async {
    await controller.connect(null, count);
  }

  /// Feed a key and one student sheet through the real reader path.
  Future<void> keyAndStudent() async {
    device.sendRecord(['A', 'B', 'C'], studentId: '', score: '003');
    await pumpUntil(() => controller.snapshot().recordCount == 1);
    device.sendRecord(['A', 'B', 'D'], studentId: '900011');
    await pumpUntil(() => controller.snapshot().pendingReview != null);
    controller.resolveReview(2, const {}, '900011', 'Ada');
  }

  group('session lifecycle (ported)', () {
    test('a fresh controller is not scanning', () {
      final snapshot = controller.snapshot();
      expect(snapshot.scanning, isFalse);
      expect(snapshot.sessionId, isNull);
    });

    test('starting opens a session with its own log', () async {
      store.setSetting('test_name', 'Unit 1');
      final id = await controller.startSession(questionCount: 30);
      final snapshot = controller.snapshot();
      expect(snapshot.scanning, isTrue);
      expect(snapshot.sessionId, id);
      expect(snapshot.sessionName, 'Unit 1');
      expect(snapshot.outputPath, endsWith('.jsonl'));
      expect(store.session(id)!['log_path'], snapshot.outputPath);
    });

    test('an explicit start resets a connected scanner', () async {
      await connect();
      device.written.clear();
      await controller.startSession(questionCount: 30, resetScanner: true);
      expect(device.written.first, 'V', reason: 'the handshake was re-sent');
      expect(device.written, contains('M6'));
    });

    test('a form length out of range is refused', () async {
      for (final count in <Object>[0, 101, 'abc']) {
        await expectLater(
          controller.startSession(questionCount: count),
          throwsA(isA<DataLinkError>()),
          reason: '$count',
        );
      }
      expect(controller.snapshot().scanning, isFalse);
    });

    test('two sessions cannot run at once', () async {
      await controller.startSession(questionCount: 30);
      await expectLater(
        controller.startSession(questionCount: 30),
        throwsA(isA<DataLinkError>()),
      );
    });

    test('ending files the session and reports what it held', () async {
      store.setSetting('test_name', 'Unit 1');
      await connect();
      final id = await controller.startSession(questionCount: 3);
      await keyAndStudent();
      final summary = controller.endSession();
      expect(summary.sessionId, id);
      expect(summary.sheets, 1);
      expect(summary.message, contains('1 student sheet'));
      expect(store.session(id)!['ended_at'], isNotNull);
      expect(controller.snapshot().scanning, isFalse);
    });

    test('ending without a session says so', () {
      expect(controller.endSession, throwsA(isA<DataLinkError>()));
    });

    test('the next session starts its numbering over', () async {
      await connect();
      await controller.startSession(questionCount: 3);
      await keyAndStudent();
      controller.endSession();
      await controller.startSession(questionCount: 3);
      expect(controller.snapshot().recordCount, 0);
    });

    test('a session with sheets survives the prune on ending', () async {
      await connect();
      final id = await controller.startSession(questionCount: 3);
      await keyAndStudent();
      controller.endSession();
      expect(store.session(id), isNotNull);
    });

    test('an empty session is pruned on ending', () async {
      final id = await controller.startSession(questionCount: 3);
      controller.endSession();
      expect(store.session(id), isNull);
    });

    test('clearing the view is refused while a session runs', () async {
      await controller.startSession(questionCount: 30);
      expect(controller.clear, throwsA(isA<DataLinkError>()));
      controller
        ..endSession()
        ..clear();
      expect(controller.snapshot().recordCount, 0);
    });

    test('ending a session leaves another being written alone', () async {
      final importing = store.createSession('Paper batch', 'P4', 3);
      await controller.startSession(questionCount: 30);
      controller.endSession();
      expect(store.session(importing), isNotNull);
    });

    test('resetting needs a connected scanner', () async {
      await expectLater(controller.resetScanner(), throwsA(isA<DataLinkError>()));
    });
  });

  group('connecting', () {
    test('runs the captured handshake and enters Data Collection', () async {
      await connect();
      expect(controller.snapshot().state, 'connected');
      expect(controller.snapshot().port, '/dev/cu.usbserial-1200');
      expect(device.written, [
        ...initializationCommands.map(String.fromCharCodes),
        ...dataCollectionCommands.map(String.fromCharCodes),
      ]);
      final messages = controller.snapshot().activity.map((a) => a.message);
      expect(messages, contains('Data Collection is active.'));
      expect(messages, contains('T4 → S32155'));
    });

    test('with no scanner plugged in, says so and is in error', () async {
      device = LiveFakeTransport(clock: clock, ports: const []);
      controller = ScannerController(
        captureRoot: directory,
        store: store,
        transport: device,
        clock: clock,
      );
      await expectLater(
        controller.connect(null, 30),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            'No /dev/cu.usbserial* DataLink port was found',
          ),
        ),
      );
      expect(controller.snapshot().state, 'error');
      expect(controller.snapshot().error, contains('No /dev/cu.usbserial'));
    });

    test('a second connect is refused', () async {
      await connect();
      await expectLater(controller.connect(null, 30), throwsA(isA<DataLinkError>()));
    });

    test('a scanner that never answers fails the connection, not the app', () async {
      device = LiveFakeTransport(clock: clock, replies: const {});
      controller = ScannerController(
        captureRoot: directory,
        store: store,
        transport: device,
        clock: clock,
      );
      await expectLater(
        controller.connect(null, 30),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            contains('did not identify itself after 4 tries'),
          ),
        ),
      );
      expect(controller.snapshot().state, 'error');
      expect(device.connection!.closed, isTrue, reason: 'the port is released on failure');
    });

    test('disconnecting ends the session and closes the port', () async {
      await connect();
      final id = await controller.startSession(questionCount: 3);
      await keyAndStudent();
      await controller.disconnect();
      expect(controller.snapshot().state, 'disconnected');
      expect(controller.snapshot().scanning, isFalse);
      expect(device.connection!.closed, isTrue);
      expect(store.session(id)!['ended_at'], isNotNull);
    });
  });

  group('reading sheets', () {
    setUp(() async {
      await connect(count: 3);
      await controller.startSession(questionCount: 3);
    });

    test('sheet 1 is the answer key and is saved at once', () async {
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      final key = controller.snapshot().records.single;
      expect(key['role'], 'key');
      expect(key['number'], 1);
      expect(key['responses'], ['A', 'B', 'C']);
      final saved = store.sessionScans(controller.snapshot().sessionId!);
      expect(saved.single['role'], 'key');
      expect(controller.snapshot().pendingReview, isNull);
      expect(
        controller.snapshot().activity.map((a) => a.message),
        contains('Captured answer key with 3/3 answered.'),
      );
    });

    test('a student sheet waits for review and is saved as pending', () async {
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      device.sendRecord(['A', 'B', 'D'], studentId: '900011', score: '002');
      await pumpUntil(() => controller.snapshot().pendingReview != null);

      final review = controller.snapshot().pendingReview!;
      expect(review['number'], 2);
      expect(review['role'], 'student');
      expect(review['student_id_required'], isTrue);
      expect(review['scanner_id'], '900011');
      expect(review['ambiguities'], isEmpty);

      final saved = store.sessionScans(controller.snapshot().sessionId!);
      expect(saved.last['pending_review'], 1, reason: 'saved before it is shown');
      expect(saved.last['student_id'], '900011');
      expect(saved.last['scanner_score'], 2);
    });

    test('a completed student scan can be removed without removing the key', () async {
      await keyAndStudent();
      final sessionId = controller.snapshot().sessionId!;
      final removed = controller.removeStudentScan(2);
      expect(removed['student_name'], 'Ada');
      expect(controller.snapshot().records, hasLength(1));
      expect(controller.snapshot().records.single['role'], 'key');
      expect(store.sessionScans(sessionId), hasLength(1));
      expect(() => controller.removeStudentScan(1), throwsA(isA<DataLinkError>()));
    });

    test('a scan after removal gets a new number instead of reusing one', () async {
      await keyAndStudent();
      device.sendRecord(['A', 'B', 'C'], studentId: '900012');
      await pumpUntil(() => controller.snapshot().pendingReview != null);
      controller.resolveReview(3, const {}, '900012', 'Bo');
      controller.removeStudentScan(2);
      device.sendRecord(['A', 'C', 'C'], studentId: '900013');
      await pumpUntil(() => controller.snapshot().pendingReview != null);
      expect(controller.snapshot().pendingReview!['number'], 4);
    });

    test('resolving a review files the sheet, keeps the scanner score, and logs it', () async {
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      device.sendRecord(['A', 'B', 'D'], studentId: '900011', score: '002');
      await pumpUntil(() => controller.snapshot().pendingReview != null);

      controller.resolveReview(2, const {}, ' 900011 ', ' Ada ');
      final snapshot = controller.snapshot();
      expect(snapshot.pendingReview, isNull);
      expect(snapshot.records.map((r) => r['number']), [1, 2]);
      expect(snapshot.records.last['student_name'], 'Ada');
      expect(snapshot.records.last['scanner_score'], 2);

      final saved = store.sessionScans(snapshot.sessionId!).last;
      expect(saved['pending_review'], 0);
      expect(saved['student_name'], 'Ada');

      final lines = File(snapshot.outputPath!).readAsLinesSync().map(jsonDecode).toList();
      expect(lines.length, 3, reason: 'key, pending student, reviewed student');
      expect((lines.last as Map)['student_name'], 'Ada');
      expect((lines.last as Map).containsKey('fields'), isFalse);
    });

    test('an erasure puts up each doubtful question, and each needs an answer', () async {
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      device.sendRecord(['AC', 'B', 'BD'], studentId: '900011');
      await pumpUntil(() => controller.snapshot().pendingReview != null);

      final review = controller.snapshot().pendingReview!;
      final ambiguities = (review['ambiguities']! as List).cast<Map<String, Object?>>();
      expect(ambiguities.map((a) => a['question']), [1, 3]);
      expect(ambiguities.first['options'], ['A', 'C']);

      expect(
        () => controller.resolveReview(2, const {'1': 'A'}, '900011', ''),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            'Choose a resolution for question 3',
          ),
        ),
      );
      expect(
        () => controller.resolveReview(2, const {'1': 'Z', '3': 'B'}, '900011', ''),
        throwsA(isA<DataLinkError>()),
      );

      controller.resolveReview(2, const {'1': 'C', '3': ''}, '900011', '');
      expect(controller.snapshot().records.last['responses'], ['C', 'B', '']);
      expect(controller.snapshot().records.last['answered_count'], 2);
    });

    test('a student needs an ID, and it must be digits', () async {
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      device.sendRecord(['A', 'B', 'C'], studentId: '');
      await pumpUntil(() => controller.snapshot().pendingReview != null);

      expect(
        () => controller.resolveReview(2, const {}, '  ', ''),
        throwsA(
          isA<DataLinkError>().having((e) => e.message, 'message', 'Enter the student ID'),
        ),
      );
      expect(
        () => controller.resolveReview(2, const {}, '90x11', ''),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            'Student ID must contain digits only',
          ),
        ),
      );
      expect(
        () => controller.resolveReview(99, const {}, '900011', ''),
        throwsA(
          isA<DataLinkError>().having(
            (e) => e.message,
            'message',
            'That review is no longer pending',
          ),
        ),
      );
    });

    test('a sheet with no session running gets one, and says so', () async {
      controller.endSession();
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().scanning);
      final messages = controller.snapshot().activity.map((a) => a.message);
      expect(
        messages,
        contains('A sheet arrived with no session running, so one was started for it.'),
      );
    });

    test('a scanner prompt is shown in plain words as a warning', () async {
      device.sendText('D2\r\n');
      await pumpUntil(
        () => controller.snapshot().activity.any((a) => a.message.contains('side 2')),
      );
      final entry = controller.snapshot().activity.firstWhere((a) => a.message.contains('side 2'));
      expect(entry.kind, 'warning');
    });

    test('an unreadable line does not cost the sheets around it', () async {
      device
        ..sendText('${List.filled(40, 'x').join(',')}\r\n')
        ..sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      expect(
        controller.snapshot().activity.any(
              (a) => a.message.startsWith('Unreadable form record skipped') && a.kind == 'error',
            ),
        isTrue,
      );
    });

    test('a line the scanner never finished is given up on', () async {
      device.sendText('D');
      await pumpUntil(() => clock.now > 0);
      clock.now += 3;
      await pumpUntil(
        () => controller.snapshot().activity.any((a) => a.message.contains('unexpected message: D')),
      );
    });

    test('re-sending the handshake does not interleave with reading', () async {
      device.written.clear();
      await controller.resetScanner();
      final expected = [
        ...initializationCommands.map(String.fromCharCodes),
        ...dataCollectionCommands.map(String.fromCharCodes),
      ];
      expect(device.written, expected, reason: 'one clean pass, nothing interleaved');
    });

    test('a device that vanishes puts the controller in error', () async {
      device.failReadsWith = const SerialException('Scanner read failed: Device not configured');
      await pumpUntil(() => controller.snapshot().state == 'error');
      expect(controller.snapshot().error, contains('Device not configured'));
    });

    test('the CSV export reflects what is on screen', () async {
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      final rows = const LineSplitter().convert(controller.exportCsv('P4'));
      expect(rows.first, startsWith('Scan,Role,Class,Student ID'));
      expect(rows.first, endsWith('Q3'));
      expect(rows[1], contains(',key,P4,'));
    });
  });

  group('export CSV (ported)', () {
    test('an empty session still produces a header', () {
      final rows = const LineSplitter().convert(controller.exportCsv());
      expect(rows, hasLength(1));
      expect(rows.first, startsWith('Scan,'));
    });

    test('the header follows the form length when nothing is on screen', () async {
      await connect(count: 64);
      expect(controller.exportCsv().split('\r\n').first, endsWith('Q64'));
    });
  });

  group('removing sessions', () {
    test('deletes the scans and the log file together', () async {
      await connect();
      final id = await controller.startSession(questionCount: 3);
      device.sendRecord(['A', 'B', 'C']);
      await pumpUntil(() => controller.snapshot().recordCount == 1);
      final log = File(controller.snapshot().outputPath!);
      expect(log.existsSync(), isTrue);
      controller.endSession();

      final result = controller.removeSessions([id]);
      expect(result.sessions, 1);
      expect(result.logs, 1);
      expect(log.existsSync(), isFalse);
      expect(store.session(id), isNull);
    });

    test('a log that is already gone is not an error', () async {
      final id = store.createSession('x', '', 3, logPath: '${directory.path}/missing.jsonl');
      store.addScan(id, {'number': 1, 'role': 'key', 'responses': ['A']});
      final result = controller.removeSessions([id]);
      expect(result.sessions, 1);
      expect(result.logs, 0);
    });
  });
}
