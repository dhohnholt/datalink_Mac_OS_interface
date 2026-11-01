import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_fake.dart';
import 'support/test_services.dart';

class Rig {
  Rig(this.services, this.device, this.actions);

  final AppServices services;
  final LiveFakeTransport device;
  final RecordingActions actions;
}

Future<Rig> open(WidgetTester tester, {void Function(Store)? seed}) async {
  tester.view.physicalSize = const Size(1600, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final clock = TickClock();
  final device = LiveFakeTransport(clock: clock);
  final store = Store.open(':memory:')
    // The keys these tests feed are three answers long.
    ..setSetting('question_count', '3');
  seed?.call(store);
  final actions = RecordingActions();
  final services = testServices(store: store, transport: device, clock: clock, actions: actions);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.pumpAndSettle();
  return Rig(services, device, actions);
}

/// Let the scanner's background work run for a while on the test clock, then
/// redraw. The handshake alone takes a couple of virtual seconds.
Future<void> settle(WidgetTester tester, {int ms = 700}) async {
  for (var elapsed = 0; elapsed < ms; elapsed += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Long enough for connect + handshake + starting a session.
Future<void> connect(WidgetTester tester) async {
  await tester.tap(find.text('Connect and start session'));
  await settle(tester, ms: 4500);
}

Future<void> disconnect(WidgetTester tester) async {
  final button = find.widgetWithText(TextButton, 'Disconnect');
  if (button.evaluate().isNotEmpty && tester.widget<TextButton>(button).onPressed != null) {
    await tester.tap(button);
    await settle(tester);
  }
}

void main() {
  testWidgets('before connecting: disconnected, nothing captured, only Start is live', (tester) async {
    await open(tester);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect and start session'), findsOneWidget);
    expect(find.text('No sheets captured yet'), findsOneWidget);
    expect(find.text('Not started'), findsOneWidget);
    expect(find.text('Start a session'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'End session')).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Re-send handshake')).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Disconnect')).onPressed, isNull);
    expect(find.textContaining('Press Reset on the scanner until its display reads Scan Mode Ready'), findsOneWidget);
  });

  testWidgets('the test name is saved shortly after typing stops', (tester) async {
    final rig = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Test name'), 'Unit 9 Exam');
    await tester.pump(const Duration(milliseconds: 500));
    expect(rig.services.store.getSetting('test_name'), 'Unit 9 Exam');
  });

  testWidgets('a question count out of range is pulled back, with the reason', (tester) async {
    final rig = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Questions per form'), '500');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Questions per form must be between 1 and 100'), findsOneWidget);
    expect(rig.services.store.getSetting('question_count'), '100');
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Questions per form')).controller!.text, '100');
  });

  testWidgets('picking a class shows its roster summary', (tester) async {
    await open(tester, seed: (s) {
      s.saveClass('P4', [
        {'id': '1', 'name': 'Ada'},
        {'id': '2', 'name': 'Bo'},
      ]);
    });
    expect(find.text('P4 · 2 students · 0 handled · 2 remaining'), findsNothing, reason: 'none selected yet');
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'No roster'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('P4').last);
    await tester.pumpAndSettle();
    expect(find.text('P4 · 2 students · 0 handled · 2 remaining'), findsOneWidget);
    expect(find.text('Scanning against P4'), findsOneWidget);
  });

  testWidgets('the help next to a field is reachable by a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await open(tester);
      expect(find.bySemanticsLabel(RegExp('About student matching')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('About questions per form')), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a whole session: connect, key, an unknown student, the dialog, end', (tester) async {
    final rig = await open(tester, seed: (s) {
      s.saveClass('P4', [
        {'id': '900011', 'name': 'Ada'},
      ]);
      s.setSetting('selected_class', 'P4');
      s.setSetting('test_name', 'Unit 1');
    });
    await connect(tester);
    expect(find.text('Session started · feed the answer key first'), findsOneWidget);
    expect(find.text('Ready to scan'), findsOneWidget);
    expect(find.text('Scan the answer key first'), findsOneWidget);
    expect(find.text('Unit 1'), findsWidgets);

    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    expect(find.text('Key'), findsOneWidget);
    expect(find.text('Next: Ada'), findsOneWidget);

    // A student the roster does not know: the dialog opens.
    rig.device.sendRecord(['A', 'B', 'D'], studentId: '900099');
    await settle(tester);
    expect(find.text('Enter the student ID'), findsOneWidget);
    expect(
      find.text('ID 900099 is not in P4. Check the sheet or save it as an unlisted student.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Student ID').last).controller!.text, '900099');

    await tester.enterText(find.widgetWithText(TextField, 'Student name (optional)'), 'Visitor');
    await tester.tap(find.text('Save correction'));
    await settle(tester);
    expect(find.text('Enter the student ID'), findsNothing, reason: 'the dialog closed');
    expect(find.text('Visitor'), findsOneWidget);
    expect(find.text('Student 1'), findsOneWidget);

    await tester.tap(find.text('End session'));
    await tester.pumpAndSettle();
    expect(find.text('End this session? The sheets already captured stay saved under Sessions.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'End session'));
    await settle(tester);
    expect(find.text('“Unit 1” ended with 1 student sheet.'), findsWidgets, reason: 'the toast, and the activity log');

    await disconnect(tester);
  });

  testWidgets('a student the roster knows is saved without a dialog', (tester) async {
    final rig = await open(tester, seed: (s) {
      s.saveClass('P4', [
        {'id': '900011', 'name': 'Ada'},
      ]);
      s.setSetting('selected_class', 'P4');
    });
    await connect(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '900011');
    await settle(tester);
    expect(find.text('Captured Ada · 900011'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Roster complete'), findsOneWidget);
    await disconnect(tester);
  });

  testWidgets('a live student scan can be removed or queued for rescan', (tester) async {
    final rig = await open(tester, seed: (s) {
      s.saveClass('P4', [
        {'id': '900011', 'name': 'Ada'},
      ]);
      s.setSetting('selected_class', 'P4');
    });
    await connect(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '900011');
    await settle(tester);
    expect(find.text('Rescan'), findsOneWidget);
    expect(find.byTooltip('Remove bad scan'), findsOneWidget);
    await tester.tap(find.text('Rescan'));
    await tester.pumpAndSettle();
    expect(find.text("Remove Ada's current scan, then feed their sheet again."), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove and rescan'));
    await settle(tester);
    expect(find.text('Rescan: Ada'), findsOneWidget);
    expect(find.text("The old scan was removed. Feed this student's replacement sheet now."), findsOneWidget);
    expect(find.text('Ada'), findsNothing);
    expect(rig.services.store.sessionScans(rig.services.scanner.currentSessionId!), hasLength(1));
    await disconnect(tester);
  });

  testWidgets('a doubtful mark opens a dialog with a choice per question', (tester) async {
    final rig = await open(tester);
    await connect(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    rig.device.sendRecord(['A', 'AC', 'C'], studentId: '900011');
    await settle(tester);

    expect(find.text('Check the scan'), findsOneWidget);
    expect(find.textContaining('Question 2 was read as'), findsOneWidget);
    expect(find.text('Keep AC'), findsOneWidget);
    expect(find.text('Blank'), findsOneWidget);

    await tester.tap(find.text('C').last);
    await tester.tap(find.text('Save correction'));
    await settle(tester);
    expect(find.text('Check the scan'), findsNothing);
    await disconnect(tester);
  });

  testWidgets('a dialog error stays on screen in words', (tester) async {
    final rig = await open(tester);
    await connect(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    expect(find.text('Enter the student ID'), findsOneWidget);
    await tester.tap(find.text('Save correction'));
    await settle(tester);
    expect(find.text('Enter the student ID'), findsNWidgets(2), reason: 'title and the error');
    await tester.enterText(find.widgetWithText(TextField, 'Student ID'), '900011');
    await tester.tap(find.text('Save correction'));
    await settle(tester);
    expect(find.text('Enter the student ID'), findsNothing);
    await disconnect(tester);
  });

  testWidgets('protocol details are hidden until asked for', (tester) async {
    final rig = await open(tester);
    await connect(tester);
    expect(find.text('V → ADV 1200OK'), findsNothing);
    expect(find.text('Data Collection is active.'), findsOneWidget);
    await tester.tap(find.text('Show protocol details'));
    await tester.pump();
    expect(find.text('V → ADV 1200OK'), findsOneWidget);
    expect(find.text('Hide protocol details'), findsOneWidget);
    expect(rig.device.written, contains('M6'));
    await disconnect(tester);
  });

  testWidgets('with no scanner plugged in the failure is shown where the teacher is looking', (tester) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = TickClock();
    final device = LiveFakeTransport(clock: clock, ports: const []);
    final services = testServices(transport: device, clock: clock);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.pumpAndSettle();
    await connect(tester);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('No /dev/cu.usbserial* DataLink port was found'), findsWidgets);
  });

  testWidgets('export CSV hands the sheets on screen to the Save panel', (tester) async {
    final rig = await open(tester, seed: (s) => s.setSetting('test_name', 'Unit 1'));
    await connect(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    await tester.tap(find.text('Export CSV'));
    await settle(tester);
    expect(rig.actions.saved.single.name, 'Unit 1.csv');
    expect(rig.actions.saved.single.text, contains(',key,'));
    await disconnect(tester);
  });

  testWidgets('clearing asks first, and is not offered mid-session', (tester) async {
    final rig = await open(tester);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Clear view')).onPressed, isNotNull);
    await connect(tester);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Clear view')).onPressed, isNull);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    await tester.tap(find.text('End session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'End session'));
    await settle(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Clear view'));
    await tester.pumpAndSettle();
    expect(find.text('Clear the scans shown here? The saved session is not deleted.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await settle(tester);
    expect(find.text('No sheets captured yet'), findsOneWidget);
    await disconnect(tester);
  });
}
