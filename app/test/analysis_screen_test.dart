import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

/// testWidgets with semantics switched on, so tests can query by the labels a
/// screen reader would read. The handle must be released inside the test body.
void screenTest(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      semantics.dispose();
    }
  });
}

Map<String, Object?> scan(int number, String role, List<String> responses, {String? id, String? name}) => {
      'number': number,
      'role': role,
      'student_id': id,
      'student_name': name,
      'received_at': '2026-09-16T18:00:00+00:00',
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
    };

/// Four students on a five-question test: one has no id (sheet 3), one has a
/// double mark (sheet 4), and questions 2, 4 and 5 are hard.
int seedTest(Store store) {
  store.saveClass('P4', [
    {'id': '900011', 'name': 'Ada'},
    {'id': '900012', 'name': 'Bo'},
    {'id': '900013', 'name': 'Cy'},
    {'id': '900014', 'name': 'Di'},
  ]);
  final id = store.createSession('Unit 1', 'P4', 5);
  store
    ..addScan(id, scan(1, 'key', ['A', 'B', 'C', 'D', 'E']))
    ..addScan(id, scan(2, 'student', ['A', 'B', 'C', 'D', 'E'], id: '900011', name: 'Ada'))
    ..addScan(id, scan(3, 'student', ['A', 'B', 'C', 'E', '']))
    ..addScan(id, scan(4, 'student', ['A', 'AB', 'C', 'D', 'E'], id: '900013', name: 'Cy'))
    ..addScan(id, scan(5, 'student', ['E', 'E', 'E', 'A', 'A'], id: '900014', name: 'Di'));
  return id;
}

Future<AppServices> open(
  WidgetTester tester, {
  bool seed = true,
  RecordingActions? actions,
  AppView tab = AppView.analysis,
  bool select = true,
}) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = Store.open(':memory:');
  final id = seed ? seedTest(store) : null;
  final services = testServices(store: store, actions: actions);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Sessions').first);
  await tester.pumpAndSettle();
  if (id != null && select) {
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Analysis').first);
  await tester.pumpAndSettle();
  return services;
}

Future<void> pane(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(SegmentedButton<AnalysisPane>), matching: find.text(label)));
  await tester.pumpAndSettle();
}

void main() {
  screenTest('nothing selected says so', (tester) async {
    await open(tester, seed: false);
    expect(find.text('No test selected'), findsOneWidget);
  });

  screenTest('the test chosen in Sessions is the one shown here', (tester) async {
    await open(tester);
    expect(find.text('Students'), findsOneWidget);
    expect(find.text('4'), findsWidgets);
    expect(find.text('No test selected'), findsNothing);
  });

  screenTest('choosing a test from the picker loads it', (tester) async {
    await open(tester, select: false);
    expect(find.text('No test selected'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<int?>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Unit 1 ·').last);
    await tester.pumpAndSettle();
    expect(find.text('Students'), findsOneWidget);
  });

  screenTest('shows the figures, the buckets and the focus callout', (tester) async {
    await open(tester);
    expect(find.text('Average'), findsOneWidget);
    expect(find.text('KR-20'), findsOneWidget);
    expect(find.text('To review'), findsOneWidget);
    expect(find.text('3 Priority'), findsOneWidget);
    expect(find.text('0 Developing'), findsOneWidget);
    expect(find.text('2 Secure'), findsOneWidget);
    expect(
      find.text('Focus first on items 2, 4, 5. Fewer than 60% of students answered each correctly.'),
      findsOneWidget,
    );
  });

  screenTest('a session that cannot be scored explains why', (tester) async {
    final services = await open(tester, seed: false);
    final id = services.store.createSession('No key', '', 3);
    services.store.addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analysis').first);
    await tester.pumpAndSettle();
    expect(find.text('This test cannot be scored'), findsOneWidget);
    expect(
      find.text('Scoring needs exactly one answer key in the session; this one has 0'),
      findsOneWidget,
    );
  });

  group('item analysis', () {
    screenTest('lists every item, with status in words', (tester) async {
      await open(tester);
      expect(find.text('Priority'), findsWidgets);
      expect(find.text('Secure'), findsWidgets);
      expect(find.text('50.0%'), findsWidgets);
      expect(find.text('75.0%'), findsWidgets);
    });

    screenTest('filters to the priority items', (tester) async {
      await open(tester);
      await tester.tap(find.descendant(of: find.byType(SegmentedButton<ItemFilter>), matching: find.text('Secure')));
      await tester.pumpAndSettle();
      expect(find.text('75.0%'), findsNWidgets(2));
      expect(find.text('50.0%'), findsNothing);
      await tester.tap(find.descendant(of: find.byType(SegmentedButton<ItemFilter>), matching: find.text('Flagged')));
      await tester.pumpAndSettle();
      expect(find.text('No items match this filter'), findsNothing,
          reason: 'with 50% correct every item is over the 25% missed mark');
    });

    screenTest('diagnostics are hidden until asked for', (tester) async {
      await open(tester);
      expect(find.text('Point biserial'), findsNothing);
      await tester.tap(find.text('Show diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('Point biserial'), findsOneWidget);
      expect(find.text('Upper−lower'), findsOneWidget);
      await tester.tap(find.text('Hide diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('Point biserial'), findsNothing);
    });
  });

  screenTest('student scores list the best first with what they missed', (tester) async {
    await open(tester);
    await pane(tester, 'Student scores');
    final names = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList();
    expect(names.indexOf('Ada'), lessThan(names.indexOf('Cy')), reason: '100% before 80%');
    expect(names.indexOf('Cy'), lessThan(names.indexOf('Di')));
    expect(find.text('5 / 5'), findsOneWidget);
    expect(find.text('100.0%'), findsOneWidget);
  });

  group('review', () {
    screenTest('names each problem in words, and counts them on the tab', (tester) async {
      await open(tester);
      await pane(tester, 'Review');
      expect(find.text('No student ID was read'), findsOneWidget);
      expect(find.text('Question 2 has more than one mark'), findsOneWidget);
      expect(find.bySemanticsLabel('Review, 2 items to review'), findsOneWidget);
    });

    screenTest('applying with nothing changed says what to do', (tester) async {
      await open(tester);
      await pane(tester, 'Review');
      await tester.tap(find.text('Apply corrections'));
      await tester.pumpAndSettle();
      expect(find.text('Change something, or tick what you have checked'), findsOneWidget);
    });

    screenTest('ticking a row and applying settles it, and Show them again brings it back', (tester) async {
      final services = await open(tester);
      await pane(tester, 'Review');
      await tester.tap(find.byType(Checkbox).first);
      await tester.tap(find.text('Apply corrections'));
      await tester.pumpAndSettle();
      expect(find.text('Applied 1 checked off'), findsOneWidget);
      expect(find.text('1 item checked off and hidden. '), findsOneWidget);
      expect(services.store.dismissedReviews(1), hasLength(1));

      await tester.tap(find.text('Show them again'));
      await tester.pumpAndSettle();
      expect(find.text('Brought back 1 item(s)'), findsOneWidget);
      expect(find.text('1 item checked off and hidden. '), findsNothing);
    });

    screenTest('Mark all checked ticks every row and then offers to untick', (tester) async {
      await open(tester);
      await pane(tester, 'Review');
      await tester.tap(find.text('Mark all checked'));
      await tester.pumpAndSettle();
      expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).every((c) => c.value == true), isTrue);
      expect(find.text('Untick all'), findsOneWidget);
      await tester.tap(find.text('Apply corrections'));
      await tester.pumpAndSettle();
      expect(find.text('Applied 2 checked off'), findsOneWidget);
      expect(find.text('Nothing to review'), findsOneWidget);
    });

    screenTest('fixing a doubtful answer rewrites the sheet and settles the row', (tester) async {
      final services = await open(tester);
      await pane(tester, 'Review');
      await tester.tap(find.widgetWithText(DropdownButton<String>, 'Keep as read'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply corrections'));
      await tester.pumpAndSettle();
      expect(find.text('Applied 1 correction(s) · 1 checked off'), findsOneWidget);
      final sheet4 = services.store.sessionScans(1).firstWhere((s) => s['number'] == 4);
      expect(sheet4['responses'], ['A', 'B', 'C', 'D', 'E']);
    });

    screenTest('typing an id brings its name from the class roster', (tester) async {
      final services = await open(tester);
      await pane(tester, 'Review');
      await tester.enterText(find.widgetWithText(TextField, 'Student ID').first, '900012');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply corrections'));
      await tester.pumpAndSettle();
      expect(find.text('Applied 1 correction(s)'), findsOneWidget);
      final sheet3 = services.store.sessionScans(1).firstWhere((s) => s['number'] == 3);
      expect(sheet3['student_id'], '900012');
      expect(sheet3['student_name'], 'Bo');
    });

    screenTest('a non-numeric id is refused with the sheet named', (tester) async {
      await open(tester);
      await pane(tester, 'Review');
      await tester.enterText(find.widgetWithText(TextField, 'Student ID').first, '90x12');
      await tester.tap(find.text('Apply corrections'));
      await tester.pumpAndSettle();
      expect(find.text('Student ID for sheet 3 must be digits only'), findsOneWidget);
    });
  });

  group('answer key', () {
    screenTest('changing an answer is marked, and can be undone', (tester) async {
      await open(tester);
      await pane(tester, 'Answer key');
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save answer key')).onPressed, isNull);
      await tester.tap(find.bySemanticsLabel('Question 1, answer C'));
      await tester.pumpAndSettle();
      expect(find.text('1 answer changed. Saving rescores every sheet in this test.'), findsOneWidget);
      await tester.tap(find.text('Undo changes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('changed. Saving rescores'), findsNothing);
    });

    screenTest('saving asks first, then rescores every sheet', (tester) async {
      final services = await open(tester);
      await pane(tester, 'Answer key');
      await tester.tap(find.bySemanticsLabel('Question 4, answer E'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save answer key'));
      await tester.pumpAndSettle();
      expect(find.text('Save this answer key? Every sheet in the test is rescored against it.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Answer key saved and sheets rescored'), findsOneWidget);
      expect(services.store.sessionScans(1).first['responses'], ['A', 'B', 'C', 'E', 'E']);
    });

    screenTest('cancelling the confirmation saves nothing', (tester) async {
      final services = await open(tester);
      await pane(tester, 'Answer key');
      await tester.tap(find.bySemanticsLabel('Question 4, answer E'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save answer key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(services.store.sessionScans(1).first['responses'], ['A', 'B', 'C', 'D', 'E']);
    });
  });

  screenTest('Download JSON hands the report to the Save panel', (tester) async {
    final actions = RecordingActions();
    await open(tester, actions: actions);
    await tester.tap(find.text('Download JSON'));
    await tester.pumpAndSettle();
    expect(actions.saved.single.name, 'Unit 1.json');
    expect(actions.saved.single.text, contains('"schema_version": "1.0"'));
    expect(find.text('Saved Unit 1.json'), findsOneWidget);
  });
}
