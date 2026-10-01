import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:datalink_scanner/app/scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_fake.dart';
import 'support/test_services.dart';

/// What a person using only the keyboard (or switch control) can reach and do.
void main() {
  Future<void> key(WidgetTester tester, LogicalKeyboardKey logical) async {
    await tester.sendKeyEvent(logical);
    await tester.pumpAndSettle();
  }

  bool focusIsIn<T extends Widget>() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<T>() != null;

  testWidgets('the navigation rail is reached with Tab and a tab is chosen with Space', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = testServices();
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.pumpAndSettle();
    final nav = Nav.read(tester.element(find.byType(NavigationRail)));
    expect(nav.view, AppView.scan);

    // Tab until focus lands on the rail.
    var steps = 0;
    while (!focusIsIn<NavigationRail>() && steps++ < 60) {
      await key(tester, LogicalKeyboardKey.tab);
    }
    expect(focusIsIn<NavigationRail>(), isTrue, reason: 'the rail can be reached by Tab');

    // Tab walks all six destinations before it leaves the rail, rather than
    // weaving between the rail and the page by screen position.
    var inRail = 1;
    while (true) {
      await key(tester, LogicalKeyboardKey.tab);
      if (!focusIsIn<NavigationRail>()) break;
      inRail++;
    }
    expect(inRail, AppView.values.length);

    // Back to the second destination, and Space chooses it.
    while (!focusIsIn<NavigationRail>()) {
      await key(tester, LogicalKeyboardKey.tab);
    }
    await key(tester, LogicalKeyboardKey.tab);
    await key(tester, LogicalKeyboardKey.space);
    expect(nav.view, AppView.paper);
  });

  testWidgets('Escape backs out of a question without answering it', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.open(':memory:');
    store.createSession('Unit 1', '', 2);
    final services = testServices(store: store);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete session'), findsWidgets);

    await key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.listSessions(), hasLength(1), reason: 'Escape is Cancel');
  });

  testWidgets('Return does not delete: a destructive choice is never the default', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.open(':memory:');
    store.createSession('Unit 1', '', 2);
    final services = testServices(store: store);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    await key(tester, LogicalKeyboardKey.enter);
    expect(store.listSessions(), hasLength(1));
  });

  testWidgets('a harmless confirmation is answered with Return', (tester) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = TickClock();
    final device = LiveFakeTransport(clock: clock);
    final store = Store.open(':memory:')..setSetting('question_count', '2');
    final services = testServices(store: store, transport: device, clock: clock);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect and start session'));
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    device.sendRecord(['A', 'B'], studentId: '');
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('End session'));
    await tester.pumpAndSettle();
    expect(find.text('End this session? The sheets already captured stay saved under Sessions.'), findsOneWidget);

    await key(tester, LogicalKeyboardKey.enter);
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('End this session? The sheets already captured stay saved under Sessions.'), findsNothing);
    expect(services.scan.scanning, isFalse, reason: 'Return confirmed it');
    await tester.tap(find.text('Disconnect'));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  });

  testWidgets('the sheet that needs a person opens with the cursor in the ID box, and Return saves', (tester) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = TickClock();
    final device = LiveFakeTransport(clock: clock);
    final store = Store.open(':memory:')..setSetting('question_count', '2');
    final services = testServices(store: store, transport: device, clock: clock);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect and start session'));
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    device.sendRecord(['A', 'B'], studentId: '');
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // A student with no ID: the dialog opens.
    device.sendRecord(['A', 'C'], studentId: '');
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Enter the student ID'), findsOneWidget);
    final field = FocusManager.instance.primaryFocus!.context!;
    expect(field.findAncestorWidgetOfExactType<TextField>(), isNotNull, reason: 'focus starts in a text box');
    await tester.enterText(find.widgetWithText(TextField, 'Student ID').last, '900011');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Enter the student ID'), findsNothing, reason: 'Return in the box saves and closes');
    await tester.tap(find.text('Disconnect'));
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  });

  testWidgets('a pop-up menu opens and chooses with the keyboard alone', (tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.open(':memory:');
    store.saveClass('P4', [
      {'id': '1', 'name': 'Ada'},
    ]);
    final services = testServices(store: store);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.pumpAndSettle();

    var steps = 0;
    while (!focusIsIn<DropdownButton<String>>() && steps++ < 40) {
      await key(tester, LogicalKeyboardKey.tab);
    }
    expect(focusIsIn<DropdownButton<String>>(), isTrue, reason: 'a drop-down can be reached by Tab');
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.text('P4'), findsWidgets, reason: 'the menu is open');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.enter);
    expect(services.classBook.selectedName, 'P4');
  });

  testWidgets('a table cell is pressed with the keyboard', (tester) async {
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = Store.open(':memory:');
    final id = store.createSession('Unit 1', '', 2);
    store
      ..addScan(id, {'number': 1, 'role': 'key', 'responses': ['A', 'B'], 'answered_count': 2})
      ..addScan(id, {'number': 2, 'role': 'student', 'student_id': '9', 'responses': ['A', 'C'], 'answered_count': 2});
    final services = testServices(store: store);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();

    Focus.of(tester.element(find.text('C').first)).requestFocus();
    await tester.pump();
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.textContaining('Choose what the sheet actually shows'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
  });
}
