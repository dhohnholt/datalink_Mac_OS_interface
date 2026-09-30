import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

Future<AppServices> open(WidgetTester tester, {void Function(AppServices)? seed}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final services = testServices();
  seed?.call(services);
  services.classBook.load();
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Classes').first);
  await tester.pumpAndSettle();
  return services;
}

void main() {
  testWidgets('an empty library invites you to add a class', (tester) async {
    await open(tester);
    expect(find.text('No classes yet'), findsOneWidget);
    expect(find.text('New class'), findsOneWidget);
  });

  testWidgets('adds a class from pasted lines, selects it, and says so', (tester) async {
    final services = await open(tester);
    await tester.tap(find.text('New class'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Class name'), 'Period 4');
    await tester.enterText(
      find.widgetWithText(TextField, 'Roster'),
      '900011, Ada Lovelace\n900012, Grace Hopper\n',
    );
    await tester.tap(find.text('Save class'));
    await tester.pumpAndSettle();

    expect(find.text('Saved Period 4 with 2 students'), findsOneWidget);
    expect(find.text('Add a class'), findsNothing, reason: 'the editor closes');
    expect(services.classBook.selectedName, 'Period 4', reason: 'the first class is selected');
    expect(services.store.getSetting('selected_class'), 'Period 4');
    expect(find.text('2 students'), findsOneWidget);
  });

  testWidgets('a bad roster line is named and nothing is saved', (tester) async {
    final services = await open(tester);
    await tester.tap(find.text('New class'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Class name'), 'Period 4');
    await tester.enterText(find.widgetWithText(TextField, 'Roster'), '900011, Ada\nabc, Nobody');
    await tester.tap(find.text('Save class'));
    await tester.pumpAndSettle();

    expect(find.text('Fix roster line: abc, Nobody'), findsOneWidget);
    expect(services.store.listClasses(), isEmpty);
    expect(find.text('Add a class'), findsOneWidget, reason: 'the editor stays open');
  });

  testWidgets('a duplicate name is refused in the store\'s own words', (tester) async {
    await open(tester, seed: (s) => s.store.saveClass('Period 4', [
          {'id': '1', 'name': 'Ada'},
        ]));
    await tester.tap(find.text('New class'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Class name'), 'period 4');
    await tester.tap(find.text('Save class'));
    await tester.pumpAndSettle();
    expect(find.text('A class with that name already exists'), findsOneWidget);
  });

  testWidgets('editing shows the roster as id, name lines and renames keep it in use', (tester) async {
    final services = await open(tester, seed: (s) {
      s.store
        ..saveClass('Old', [
          {'id': '900011', 'name': 'Ada'},
          {'id': '900012', 'name': 'Bo'},
        ])
        ..setSetting('selected_class', 'Old');
    });
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final roster = tester.widget<TextField>(find.widgetWithText(TextField, 'Roster'));
    expect(roster.controller!.text, '900011, Ada\n900012, Bo');

    await tester.enterText(find.widgetWithText(TextField, 'Class name'), 'New');
    await tester.tap(find.text('Save class'));
    await tester.pumpAndSettle();
    expect(services.classBook.selectedName, 'New');
    expect(services.store.listClasses().single['name'], 'New');
  });

  testWidgets('"Use for scanning" switches the roster and says which', (tester) async {
    final services = await open(tester, seed: (s) {
      s.store
        ..saveClass('A', [
          {'id': '1', 'name': 'Ada'},
        ])
        ..saveClass('B', [
          {'id': '2', 'name': 'Bo'},
        ])
        ..setSetting('selected_class', 'A');
    });
    await tester.tap(find.text('Use for scanning'));
    await tester.pumpAndSettle();
    expect(services.classBook.selectedName, 'B');
    expect(find.text('Scanning against B'), findsOneWidget);
  });

  testWidgets('deleting asks first, and clears the selection if it was in use', (tester) async {
    final services = await open(tester, seed: (s) {
      s.store
        ..saveClass('Gone', [
          {'id': '1', 'name': 'Ada'},
        ])
        ..setSetting('selected_class', 'Gone');
    });
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete class'));
    await tester.pumpAndSettle();
    expect(find.text('Delete the saved class “Gone”? Saved sessions are not affected.'), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(services.store.listClasses(), isNotEmpty, reason: 'cancel keeps it');

    await tester.tap(find.text('Delete class'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(services.store.listClasses(), isEmpty);
    expect(services.classBook.selectedName, '');
    expect(services.store.getSetting('selected_class'), '');
  });
}
