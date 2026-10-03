// A sheet with no ID bubbled, with a class roster: the dialog asks which
// student it is, and the ID follows from the choice. Nothing is typed.
import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_fake.dart';
import 'support/test_services.dart';

Future<void> settle(WidgetTester tester, {int ms = 700}) async {
  for (var elapsed = 0; elapsed < ms; elapsed += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A session of three-question sheets against class P4, with the key scanned.
Future<({AppServices services, LiveFakeTransport device})> start(
  WidgetTester tester, {
  String matching = 'manual',
  bool roster = true,
}) async {
  tester.view.physicalSize = const Size(1600, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final clock = TickClock();
  final device = LiveFakeTransport(clock: clock);
  final store = Store.open(':memory:')
    ..setSetting('question_count', '3')
    ..setSetting('student_matching', matching);
  if (roster) {
    store
      ..saveClass('P4', [
        {'id': '900011', 'name': 'Ada'},
        {'id': '900012', 'name': 'Bo'},
      ])
      ..setSetting('selected_class', 'P4');
  }
  final services = testServices(store: store, transport: device, clock: clock);
  addTearDown(services.dispose);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Connect and start session'));
  await settle(tester, ms: 4500);
  device.sendRecord(['A', 'B', 'C'], studentId: '');
  await settle(tester);
  return (services: services, device: device);
}

Future<void> disconnect(WidgetTester tester) async {
  final button = find.widgetWithText(TextButton, 'Disconnect');
  if (button.evaluate().isNotEmpty) {
    await tester.tap(button);
    await settle(tester);
  }
}

List<Map<String, Object?>> students(AppServices services) {
  final id = services.scan.snapshot.sessionId!;
  return services.store.sessionScans(id).where((s) => s['role'] == 'student' && s['pending_review'] == 0).toList();
}

void main() {
  testWidgets('"Ask for every sheet": the next student is chosen, the ID is not typed', (tester) async {
    final rig = await start(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);

    expect(find.text('Which student is this?'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Student ID'), findsNothing, reason: 'no ID box to fill in');
    expect(find.text('Ada · 900011'), findsOneWidget, reason: 'the student the screen said was next');

    await tester.tap(find.text('Save correction'));
    await settle(tester);

    expect(find.text('Which student is this?'), findsNothing);
    final saved = students(rig.services).single;
    expect([saved['student_id'], saved['student_name']], ['900011', 'Ada']);
    expect(find.text('Next: Bo'), findsOneWidget);
    await disconnect(tester);
  });

  testWidgets('a sheet out of order: pick the student, and the roster carries on after them', (tester) async {
    final rig = await start(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await settle(tester, ms: 400);
    await tester.tap(find.text('Bo · 900012').last);
    await settle(tester, ms: 400);
    await tester.tap(find.text('Save correction'));
    await settle(tester);

    final saved = students(rig.services).single;
    expect([saved['student_id'], saved['student_name']], ['900012', 'Bo']);
    expect(find.text('Roster complete'), findsOneWidget, reason: 'Bo was the last on the list');
    await disconnect(tester);
  });

  testWidgets('a student not on the roster can still be typed', (tester) async {
    final rig = await start(tester);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await settle(tester, ms: 400);
    await tester.tap(find.text('Not on the roster — type an ID').last);
    await settle(tester, ms: 400);
    await tester.enterText(find.widgetWithText(TextField, 'Student ID'), '555555');
    await tester.tap(find.text('Save correction'));
    await settle(tester);

    expect(students(rig.services).single['student_id'], '555555');
    await disconnect(tester);
  });

  testWidgets('with the roster used up there is nothing to assume, and it says so', (tester) async {
    final rig = await start(tester);
    for (final _ in [0, 1]) {
      rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
      await settle(tester);
      await tester.tap(find.text('Save correction'));
      await settle(tester);
    }
    expect(students(rig.services), hasLength(2));

    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);
    await tester.tap(find.text('Save correction'));
    await settle(tester);

    expect(find.text('Choose the student, or "Not on the roster" to type an ID.'), findsOneWidget);
    expect(students(rig.services), hasLength(2), reason: 'nothing was saved');

    // Choosing someone gets past it, and the dialog is out of the way.
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await settle(tester, ms: 400);
    await tester.tap(find.text('Bo · 900012').last);
    await settle(tester, ms: 400);
    await tester.tap(find.text('Save correction'));
    await settle(tester);
    await disconnect(tester);
  });

  testWidgets('without a roster the dialog still asks for the ID, as before', (tester) async {
    final rig = await start(tester, roster: false);
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);

    expect(find.text('Enter the student ID'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Student ID'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Student ID'), '900099');
    await tester.tap(find.text('Save correction'));
    await settle(tester);
    expect(students(rig.services).single['student_id'], '900099');
    await disconnect(tester);
  });

  testWidgets('by ID with no ID read: confirms the next student, picker ready to change it', (tester) async {
    final rig = await start(tester, matching: 'id');
    rig.device.sendRecord(['A', 'B', 'C'], studentId: '');
    await settle(tester);

    expect(find.text('Confirm Ada'), findsOneWidget);
    expect(find.text('Ada · 900011'), findsOneWidget);
    await tester.tap(find.text('Save correction'));
    await settle(tester);
    expect(students(rig.services).single['student_id'], '900011');
    await disconnect(tester);
  });
}
