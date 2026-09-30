import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:datalink_scanner/features/sessions/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

Map<String, Object?> scan(int number, String role, List<String> responses, {String? id, String? name}) => {
      'number': number,
      'role': role,
      'student_id': id,
      'student_name': name,
      'received_at': '2026-09-16T18:00:00+00:00',
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
    };

Future<AppServices> open(
  WidgetTester tester, {
  void Function(Store)? seed,
  RecordingActions? actions,
  Store? store,
}) async {
  tester.view.physicalSize = const Size(1500, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = store ?? Store.open(':memory:');
  seed?.call(db);
  final services = testServices(store: db, actions: actions);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Sessions').first);
  await tester.pumpAndSettle();
  return services;
}

void two(Store store) {
  final a = store.createSession('Unit 1', 'P4', 3);
  store
    ..addScan(a, scan(1, 'key', ['A', 'B', 'C']))
    ..addScan(a, scan(2, 'student', ['A', 'B', 'D'], id: '900011', name: 'Ada'));
  final b = store.createSession('', '', 3);
  store.addScan(b, scan(1, 'key', ['A', 'B', 'C']));
}

void main() {
  group('formatting', () {
    test('bytes, as the old page wrote them', () {
      expect(formatBytes(0), '0 KB');
      expect(formatBytes(512), '512 bytes');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(10 * 1024), '10 KB');
      expect(formatBytes(5 * 1024 * 1024 + 300000), '5.3 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('the storage line', () {
      expect(
        storageSummary({
          'total_bytes': 2048,
          'scans': 18,
          'sessions': 3,
          'log_files': 2,
          'oldest': '2026-09-16T18:00:00+00:00',
        }),
        '2.0 KB in total — 18 sheets across 3 sessions, plus 2 plain-text logs · oldest Sep 2026.',
      );
      expect(
        storageSummary({'total_bytes': 0, 'scans': 0, 'sessions': 0, 'log_files': 0, 'oldest': null}),
        '0 KB in total — 0 sheets across 0 sessions, plus 0 plain-text logs.',
      );
    });
  });

  testWidgets('an empty library says so', (tester) async {
    await open(tester);
    expect(find.text('No saved sessions yet'), findsOneWidget);
  });

  testWidgets('lists sessions with sheet counts, untitled ones too', (tester) async {
    await open(tester, seed: two);
    expect(find.text('Unit 1'), findsOneWidget);
    expect(find.text('Untitled'), findsOneWidget);
    expect(find.textContaining('P4 · 2 sheets'), findsOneWidget);
    expect(find.textContaining('2 sheets'), findsWidgets);
    expect(find.textContaining('plain-text logs'), findsOneWidget);
  });

  testWidgets('View shows the sheets with every question column', (tester) async {
    await open(tester, seed: two);
    await tester.tap(find.text('View').first);
    await tester.pumpAndSettle();
    // Two sessions are listed newest first, so the first View is the untitled one.
    expect(find.text('Untitled session'), findsNWidgets(2), reason: 'context bar and card title');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
    expect(find.text('Key'), findsOneWidget);
    expect(find.text('Student 1'), findsOneWidget, reason: 'the row label, as the old page had it');
    expect(find.text('Ada'), findsOneWidget, reason: 'and the name in the Student column');
    expect(find.text('900011'), findsOneWidget);
    for (final q in ['Q1', 'Q2', 'Q3']) {
      expect(find.text(q), findsOneWidget);
    }
    expect(find.text('Q4'), findsNothing);
  });

  testWidgets('clicking a response corrects it, rescoring on the way', (tester) async {
    final services = await open(tester, seed: two);
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('D'));
    await tester.pumpAndSettle();
    expect(find.text('Question 3'), findsOneWidget);
    expect(find.textContaining('read as D'), findsOneWidget);

    await tester.tap(find.text('C').last);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Question 3 saved as C'), findsOneWidget);
    final saved = services.store.sessionScans(1).last;
    expect(saved['responses'], ['A', 'B', 'C']);
  });

  testWidgets('choosing what is already recorded changes nothing and says so', (tester) async {
    final services = await open(tester, seed: two);
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('D'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('That is already what is recorded'), findsOneWidget);
    expect(services.store.sessionScans(1).last['responses'], ['A', 'B', 'D']);
  });

  testWidgets('a blank can be recorded as blank', (tester) async {
    final services = await open(tester, seed: two);
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('D'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blank'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Question 3 saved as blank'), findsOneWidget);
    expect(services.store.sessionScans(1).last['responses'], ['A', 'B', '']);
  });

  testWidgets('rename asks for a name', (tester) async {
    final services = await open(tester, seed: two);
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Final exam');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(services.store.session(1)!['name'], 'Final exam');
    expect(find.text('Final exam'), findsOneWidget);
  });

  testWidgets('delete asks first; cancelling keeps it', (tester) async {
    final services = await open(tester, seed: two);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Delete this saved session and all of its scans? This cannot be undone.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(services.store.listSessions(), hasLength(2));

    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(services.store.listSessions(), hasLength(1));
    expect(find.text('Session deleted'), findsOneWidget);
  });

  testWidgets('deleting the open session closes it', (tester) async {
    await open(tester, seed: two);
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
    expect(find.text('Key'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Key'), findsNothing);
  });

  testWidgets('export CSV hands the file to the Save panel with a safe name', (tester) async {
    final actions = RecordingActions();
    await open(tester, seed: two, actions: actions);
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(actions.saved.single.name, 'Unit 1.csv');
    expect(actions.saved.single.extension, 'csv');
    expect(actions.saved.single.text, startsWith('Scan,Role,Class,Student ID,Student Name'));
    expect(find.text('Saved Unit 1.csv'), findsOneWidget);
  });

  testWidgets('cancelling the Save panel is silent', (tester) async {
    final actions = RecordingActions()..nextSavePath = null;
    await open(tester, seed: two, actions: actions);
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved Unit'), findsNothing);
  });

  testWidgets('item analysis export is offered only when the session can be scored', (tester) async {
    final actions = RecordingActions();
    await open(tester, seed: two, actions: actions);
    // The untitled session has a key and no students: not scoreable.
    await tester.tap(find.text('View').first);
    await tester.pumpAndSettle();
    var button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Export item analysis'));
    expect(button.onPressed, isNull);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View').last);
    await tester.pumpAndSettle();
    button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Export item analysis'));
    expect(button.onPressed, isNotNull);
    await tester.tap(find.text('Export item analysis'));
    await tester.pumpAndSettle();
    expect(actions.saved.single.name, 'Unit 1.json');
    expect(actions.saved.single.text, contains('"schema_version": "1.0"'));
  });

  testWidgets('deleting old sessions previews, asks, and reports', (tester) async {
    var when = DateTime.utc(2020, 1, 1);
    final store = Store.open(':memory:', now: () => when);
    two(store);
    when = DateTime.now().toUtc();
    store.createSession('Recent', '', 3);

    final services = await open(tester, store: store);
    await tester.tap(find.text('Delete old sessions'));
    await tester.pumpAndSettle();
    expect(
      find.text('Delete 2 session(s) older than 1 year? Their scans and log files are removed for good.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted 2 session(s) and 0 log file(s)'), findsOneWidget);
    expect(services.store.listSessions().map((s) => s['name']), ['Recent']);
  });

  testWidgets('with nothing old enough it says so and asks nothing', (tester) async {
    await open(tester, seed: (s) => s.createSession('New', '', 3));
    await tester.tap(find.text('Delete old sessions'));
    await tester.pumpAndSettle();
    expect(find.text('No sessions are older than 1 year'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Show in Finder reveals the data folder', (tester) async {
    final actions = RecordingActions();
    final services = await open(tester, actions: actions);
    await tester.tap(find.text('Show in Finder'));
    expect(actions.revealed, [services.dataDirectory.path]);
  });

  testWidgets('Refresh confirms', (tester) async {
    await open(tester);
    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(find.text('Sessions refreshed'), findsOneWidget);
  });
}
