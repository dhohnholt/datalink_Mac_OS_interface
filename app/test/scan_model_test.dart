// The Scan tab's logic, driven against a scripted scanner. Every string asserted
// here is one a teacher reads; the expectations come from app.js.
import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:datalink_scanner/features/scan/scan_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_fake.dart';
import 'support/test_services.dart';

class Rig {
  Rig(this.services, this.device, this.model);

  final AppServices services;
  final LiveFakeTransport device;
  final ScanModel model;
  final List<String> messages = [];

  Store get store => services.store;
}

Future<Rig> rig({
  void Function(Store)? seed,
  List<String> ports = const ['/dev/cu.usbserial-1200'],
}) async {
  final clock = YieldingClock();
  final device = LiveFakeTransport(clock: clock, ports: ports);
  final store = Store.open(':memory:');
  seed?.call(store);
  final services = testServices(store: store, transport: device, clock: clock);
  final model = ScanModel(
    services,
    portPollInterval: null,
    debounce: const Duration(milliseconds: 20),
  );
  final r = Rig(services, device, model);
  model.onMessage = r.messages.add;
  addTearDown(() async {
    model.dispose();
    await services.dispose();
  });
  return r;
}

void seedClass(Store store) {
  store
    ..saveClass('P4', [
      {'id': '900011', 'name': 'Ada'},
      {'id': '900012', 'name': 'Bo'},
    ])
    ..setSetting('selected_class', 'P4');
}

Future<void> feedKey(Rig r, {List<String> answers = const ['A', 'B', 'C']}) async {
  r.device.sendRecord(answers, studentId: '');
  await pumpUntil(() => r.model.snapshot.records.any((x) => x['role'] == 'key'));
}

void main() {
  group('before anything', () {
    test('is disconnected, offers to connect and start, and nothing else', () async {
      final r = await rig();
      final m = r.model;
      expect(m.badgeLabel, 'Disconnected');
      expect(m.connectLabel, 'Connect and start session');
      expect(m.canStart, isTrue);
      expect(m.canEnd, isFalse);
      expect(m.canReset, isFalse);
      expect(m.canDisconnect, isFalse);
      expect(m.canClear, isTrue);
      expect(m.connectionDetail, 'Connect the scanner by USB, then select its serial port.');
      expect(m.workflow.title, 'Start a session');
      expect(m.workflow.step, '1');
      expect(m.sessionLabel, 'Not started');
      expect(m.latestAnswered, '—');
      expect(m.rosterSummary, 'No saved roster. Student IDs will be entered manually.');
    });

    test('loads the saved test name, form length and matching', () async {
      final r = await rig(seed: (s) {
        s
          ..setSetting('test_name', 'Unit 4')
          ..setSetting('question_count', '30')
          ..setSetting('student_matching', 'roster');
      });
      expect(r.model.testName, 'Unit 4');
      expect(r.model.questionCount, 30);
      expect(r.model.matching, StudentMatching.roster);
    });

    test('a saved form length out of range is clamped rather than trusted', () async {
      final r = await rig(seed: (s) => s.setSetting('question_count', '900'));
      expect(r.model.questionCount, 100);
    });

    test('finds the ports to offer', () async {
      final r = await rig();
      await pumpUntil(() => r.model.snapshot.ports.isNotEmpty);
      expect(r.model.snapshot.ports, ['/dev/cu.usbserial-1200']);
    });
  });

  group('starting', () {
    test('connects and opens a session in one press', () async {
      final r = await rig();
      await r.model.start();
      final m = r.model;
      expect(r.messages, ['Session started · feed the answer key first']);
      expect(m.badgeLabel, 'Ready to scan');
      expect(m.connectLabel, 'Start scanning session');
      expect(m.connectionDetail, 'Session running on /dev/cu.usbserial-1200. Feed one sheet at a time.');
      expect((m.canStart, m.canEnd, m.canReset, m.canDisconnect, m.canClear), (false, true, true, true, false));
      expect((m.portLocked, m.countLocked), (true, true));
      expect(m.workflow.title, 'Scan the answer key first');
      expect(m.workflow.step, '2');
      expect(m.workflow.detail, startsWith("Check the scanner's own display reads Scan Mode Ready"));
      await m.disconnect();
    });

    test('with no scanner plugged in, says so and needs attention', () async {
      final r = await rig(ports: const []);
      await r.model.start();
      expect(r.messages, ['No /dev/cu.usbserial* DataLink port was found']);
      expect(r.model.badgeLabel, 'Needs attention');
      expect(r.model.connectionDetail, 'No /dev/cu.usbserial* DataLink port was found');
      expect(r.model.canStart, isTrue, reason: 'and can try again');
    });

    test('with the scanner already connected it only starts a session', () async {
      final r = await rig();
      await r.services.scanner.connect(null, 50);
      await pumpUntil(() => r.model.badgeLabel == 'Connected · no session');
      expect(r.model.connectionDetail, 'Scanner ready on /dev/cu.usbserial-1200. No session is running.');
      r.device.written.clear();
      await r.model.start();
      expect(r.device.written.first, 'V', reason: 'the handshake is re-sent when a session starts');
      expect(r.model.badgeLabel, 'Ready to scan');
      await r.model.disconnect();
    });

    test('a chosen port is used instead of auto-detect', () async {
      final r = await rig(ports: const ['/dev/cu.usbserial-1200', '/dev/cu.usbserial-9']);
      r.model.port = '/dev/cu.usbserial-9';
      await r.model.start();
      expect(r.model.snapshot.port, '/dev/cu.usbserial-9');
      await r.model.disconnect();
    });
  });

  group('sheets and the roster', () {
    test('the key with no roster: nothing to walk', () async {
      final r = await rig();
      await r.model.start();
      await feedKey(r);
      expect(r.model.hasKey, isTrue);
      expect(r.model.workflow, (
        step: '✓',
        title: 'Answer key captured',
        detail: 'The session is ready for student sheets. Feed them one at a time.',
      ));
      expect(r.model.latestAnswered, '3 / 50', reason: 'answers marked / the form length, blanks included');
      expect(r.model.recordsNewestFirst.single['role'], 'key');
      await r.model.disconnect();
    });

    test('after the key it names the next student', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      expect(r.model.workflow.title, 'Next: Ada');
      expect(r.model.workflow.detail, "Roster #900011 · Feed Ada's sheet now.");
      expect(r.model.rosterSummary, 'P4 · 2 students · 0 handled · 2 remaining');
      expect(r.model.canSkip, isTrue);
      await r.model.disconnect();
    });

    test('an id on the roster is saved without asking, and the roster moves past it', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '900012');
      await pumpUntil(() => r.messages.any((m) => m.startsWith('Captured')));
      expect(r.messages.last, 'Captured Bo · 900012');
      expect(r.model.pendingPlan, isNull, reason: 'no dialog');
      expect(r.model.walk.index, 2);
      expect(r.model.workflow.title, 'Roster complete');
      expect(r.model.workflow.detail, 'Every student on the roster has been handled.');
      final saved = r.store.sessionScans(r.model.snapshot.sessionId!).last;
      expect(saved['student_name'], 'Bo');
      expect(saved['pending_review'], 0);
      await r.model.disconnect();
    });

    test('an id with leading zeros still finds the student', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '0900011');
      await pumpUntil(() => r.messages.any((m) => m.startsWith('Captured')));
      expect(r.messages.last, 'Captured Ada · 0900011');
      await r.model.disconnect();
    });

    test('with no roster an id is simply captured', () async {
      final r = await rig();
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '900099');
      await pumpUntil(() => r.messages.any((m) => m.startsWith('Captured')));
      expect(r.messages.last, 'Captured ID 900099');
      await r.model.disconnect();
    });

    test('an id that is not on the roster asks, in words', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '900099');
      await pumpUntil(() => r.model.pendingPlan != null);
      final plan = r.model.pendingPlan!;
      expect(plan.title, 'Enter the student ID');
      expect(plan.intro, 'ID 900099 is not in P4. Check the sheet or save it as an unlisted student.');
      expect(plan.idPrefill, '900099');

      expect(r.model.resolve(const {}, '900099', 'Visitor'), isNull);
      await pumpUntil(() => r.model.pendingPlan == null);
      expect(r.model.walk.index, 0, reason: 'nobody on the roster was handled');
      await r.model.disconnect();
    });

    test('a sheet with no id offers the next student in roster order, and confirming moves on', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '');
      await pumpUntil(() => r.model.pendingPlan != null);
      expect(r.model.pendingPlan!.title, 'Confirm Ada');
      expect(r.model.pendingPlan!.idPrefill, '900011');
      expect(r.model.pendingPlan!.namePrefill, 'Ada');
      expect(r.model.resolve(const {}, '900011', 'Ada'), isNull);
      expect(r.model.walk.index, 1);
      expect(r.model.workflow.title, 'Next: Bo');
      await r.model.disconnect();
    });

    test('roster order ignores the bubbled id', () async {
      final r = await rig(seed: seedClass);
      r.model.setMatching(StudentMatching.roster);
      expect(r.messages.last, 'Sheets are taken in roster order');
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '900012');
      await pumpUntil(() => r.model.pendingPlan != null);
      expect(r.model.pendingPlan!.title, 'Confirm Ada', reason: 'roster order, not the id');
      await r.model.disconnect();
    });

    test('manual matching asks about every sheet and offers nobody', () async {
      final r = await rig(seed: seedClass);
      r.model.setMatching(StudentMatching.manual);
      expect(r.messages.last, 'Every sheet will ask');
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '900011');
      await pumpUntil(() => r.model.pendingPlan != null);
      expect(r.model.pendingPlan!.title, 'Enter the student ID');
      expect(r.model.pendingPlan!.namePrefill, '');
      await r.model.disconnect();
    });

    test('matching choices are remembered and worded', () async {
      final r = await rig();
      r.model.setMatching(StudentMatching.id);
      expect(r.messages.last, 'Sheets can be fed in any order');
      r.model.setMatching(StudentMatching.roster);
      expect(r.store.getSetting('student_matching'), 'roster');
    });

    test('a doubtful mark stops for review even with a good id, and errors come back as text', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'AC', 'C'], studentId: '900011');
      await pumpUntil(() => r.model.pendingPlan != null);
      expect(r.model.pendingPlan!.title, 'Confirm Ada');
      expect(r.model.pendingPlan!.intro, startsWith('The scanner found more than one mark'));
      expect(r.model.resolve(const {}, '900011', 'Ada'), 'Choose a resolution for question 2');
      expect(r.model.pendingPlan, isNotNull, reason: 'the dialog stays open');
      expect(r.model.resolve(const {'2': 'C'}, '900011', 'Ada'), isNull);
      await r.model.disconnect();
    });

    test('skipping an absent student moves the roster on, and Start at first goes back', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      expect(r.model.canStartAtFirst, isFalse);
      r.model.skipStudent();
      expect(r.messages.last, 'Skipped Ada');
      expect(r.model.workflow.title, 'Next: Bo');
      expect(r.model.canStartAtFirst, isTrue);
      r.model.startAtFirst();
      expect(r.model.workflow.title, 'Next: Ada');
      await r.model.disconnect();
    });

    test('progress is kept per class', () async {
      final r = await rig(seed: (s) {
        seedClass(s);
        s.saveClass('P5', [
          {'id': '1', 'name': 'Zed'},
        ]);
      });
      await r.model.start();
      await feedKey(r);
      r.model.skipStudent();
      expect(r.model.walk.index, 1);
      r.model.selectClass('P5');
      expect(r.model.walk.index, 0);
      expect(r.messages.last, 'Scanning against P5');
      r.model.selectClass('P4');
      expect(r.model.walk.index, 1, reason: 'P4 remembers where it was');
      r.model.selectClass('');
      expect(r.messages.last, 'Roster turned off');
      await r.model.disconnect();
    });

    test('starting a new session starts the roster over', () async {
      final r = await rig(seed: seedClass);
      await r.model.start();
      await feedKey(r);
      r.model.skipStudent();
      r.model.end();
      await r.model.start();
      expect(r.model.walk.index, 0);
      await r.model.disconnect();
    });
  });

  group('ending', () {
    test('reports what the session held, and frees the view to be cleared', () async {
      final r = await rig();
      r.model.setTestName('Unit 1');
      await r.model.start();
      await feedKey(r);
      r.device.sendRecord(['A', 'B', 'C'], studentId: '900011');
      await pumpUntil(() => r.messages.any((m) => m.startsWith('Captured')));
      final summary = r.model.end()!;
      expect(summary.sheets, 1);
      expect(r.messages.last, '“Unit 1” ended with 1 student sheet.');
      expect(r.model.canClear, isTrue);
      expect(r.model.canEnd, isFalse);
      r.model.clearView();
      expect(r.model.snapshot.recordCount, 0);
      await r.model.disconnect();
    });

    test('says so when there was no answer key, and drops the empty session', () async {
      final r = await rig();
      await r.model.start();
      final id = r.model.snapshot.sessionId!;
      r.model.end();
      expect(r.messages.last, 'The session ended with 0 student sheets and no answer key.');
      expect(r.model.snapshot.activity.first.kind, 'warning');
      expect(r.store.session(id), isNull, reason: 'connecting to check the scanner must not litter the history');
    });

    test('a name typed just before Start is the name the session gets', () async {
      final r = await rig();
      r.model.setTestName('Typed a moment ago');
      await r.model.start();
      expect(r.model.snapshot.sessionName, 'Typed a moment ago');
      await r.model.disconnect();
    });

    test('clearing is refused while scanning, with the reason', () async {
      final r = await rig();
      await r.model.start();
      r.model.clearView();
      expect(r.messages.last, startsWith('A session is running, so the sheets on screen'));
      await r.model.disconnect();
    });
  });

  group('the form on the left', () {
    test('the question count is clamped on the way out, with the reason', () async {
      final r = await rig();
      r.model.commitQuestionCount('0');
      expect((r.model.questionCount, r.messages.last), (1, 'Questions per form must be between 1 and 100'));
      r.model.commitQuestionCount('500');
      expect(r.model.questionCount, 100);
      r.messages.clear();
      r.model.commitQuestionCount('abc');
      expect(r.model.questionCount, 50, reason: 'nonsense falls back to the default');
      r.model.commitQuestionCount('30');
      expect(r.model.questionCount, 30);
      expect(r.messages.where((m) => m.contains('between')), hasLength(1), reason: 'only abc complained');
      expect(r.store.getSetting('question_count'), '30');
    });

    test('the test name is saved a moment after typing stops, and renames the open session', () async {
      final r = await rig();
      await r.model.start();
      r.model
        ..setTestName('U')
        ..setTestName('Un')
        ..setTestName('Unit 7 ');
      expect(r.store.getSetting('test_name'), '', reason: 'not yet');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(r.store.getSetting('test_name'), 'Unit 7');
      expect(r.store.session(r.model.snapshot.sessionId!)!['name'], 'Unit 7');
      await r.model.disconnect();
    });

    test('the export is named for the class and the test', () async {
      final r = await rig(seed: seedClass);
      expect(r.model.exportFilename, 'P4.csv');
      r.model.setTestName('Unit 1 Exam');
      expect(r.model.exportFilename, 'P4 - Unit 1 Exam.csv');
      r.model.selectClass('');
      expect(r.model.exportFilename, 'Unit 1 Exam.csv');
      r.model.setTestName('');
      expect(r.model.exportFilename, 'datalink-session.csv');
    });
  });

  group('activity and the scanner', () {
    test('protocol lines are hidden until asked for', () async {
      final r = await rig();
      await r.model.start();
      expect(r.model.activity.any((e) => e.kind == 'protocol'), isFalse);
      expect(r.model.activity.any((e) => e.message == 'Data Collection is active.'), isTrue);
      r.model.toggleProtocol();
      expect(r.model.showProtocol, isTrue);
      expect(r.model.activity.any((e) => e.message == 'V → ADV 1200OK'), isTrue);
      await r.model.disconnect();
    });

    test('a scanner prompt is a warning the teacher sees without protocol details', () async {
      final r = await rig();
      await r.model.start();
      r.device.sendText('D2\r\n');
      await pumpUntil(() => r.model.activity.any((e) => e.kind == 'warning' && e.message.contains('side 2')));
      await r.model.disconnect();
    });

    test('Re-send handshake says what it did and did not do', () async {
      final r = await rig();
      await r.model.start();
      await r.model.resetScanner();
      expect(r.messages.last, 'Handshake re-sent · for a held sheet, press Reset on the device');
      await r.model.disconnect();
    });

    test('disconnecting returns to the start, ending any session', () async {
      final r = await rig();
      await r.model.start();
      await r.model.disconnect();
      expect(r.model.badgeLabel, 'Disconnected');
      expect(r.model.scanning, isFalse);
      expect(r.model.canStart, isTrue);
    });

    test('a scanner that vanishes needs attention', () async {
      final r = await rig();
      await r.model.start();
      r.device.failReadsWith = const SerialException('Scanner read failed: Device not configured');
      await pumpUntil(() => r.model.snapshot.state == 'error');
      expect(r.model.badgeLabel, 'Needs attention');
      expect(r.model.connectionDetail, 'Scanner read failed: Device not configured');
      await r.model.disconnect();
    });
  });
}
