import 'dart:async';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/features/paper/paper_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'paper_screen_test.dart' as fixture;

int seed(Store store) {
  final id = store.createSession('Unit 1', 'Period 4', 3, source: 'paper');
  store.addScan(id, {
    'number': 1,
    'role': 'key',
    'responses': ['A', 'B', 'C'],
  });
  store.addScan(id, {
    'number': 2,
    'role': 'student',
    'student_id': '123456',
    'responses': ['A', 'B', 'C'],
  });
  return id;
}

Map<String, Object?> singleReport() {
  final report = fixture.report();
  report['students'] = [
    {
      'page': 1,
      'student_id': '654321',
      'answers': [
        for (var q = 1; q <= 3; q++) {'question': q, 'response': 'ABC'[q - 1]},
      ],
    },
  ];
  return report;
}

void main() {
  testWidgets(
    'Sessions Add sheets opens Paper with the saved key, and adds one page to the same test',
    (tester) async {
      late int id;
      final app = await fixture.open(
        tester,
        pages: 1,
        seed: (store) => id = seed(store),
        reader: (_, _, _) async => singleReport(),
      );
      await tester.tap(find.text('Sessions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add sheets'));
      await tester.pumpAndSettle();
      expect(app.services.paper.targetSessionId, id);
      await fixture.choose(tester);
      expect(find.text('Answer key page'), findsNothing);
      expect(find.text('Questions per form'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Unit 1'))
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Add sheets to session'));
      await tester.pumpAndSettle();
      final request = app.calls.requests.single;
      expect(request.savedKey, ['A', 'B', 'C']);
      expect(request.keyPage, isNull);
      expect(request.questionCount, 3);
      expect(request.checkQuestionCount, isFalse);
      expect(app.services.paper.sessionId, id);
      expect(app.services.store.listSessions(), hasLength(1));
      final scans = app.services.store.sessionScans(id);
      expect(scans, hasLength(3));
      expect(scans.where((s) => s['role'] == 'key'), hasLength(1));
      expect(scans.last['student_id'], '654321');
      await tester.tap(find.text('Open the item analysis'));
      await tester.pumpAndSettle();
      expect(find.text('Average'), findsOneWidget);
      expect(
        app.services.workspace.analysisReport(id)['students'],
        hasLength(2),
      );
    },
  );

  testWidgets('Paper destination can switch back to a normal new session', (
    tester,
  ) async {
    late int id;
    final app = await fixture.open(tester, seed: (store) => id = seed(store));
    await fixture.choose(tester);
    await tester.tap(find.text('New session'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Unit 1 · Period 4').last);
    await tester.pumpAndSettle();
    expect(app.services.paper.targetSessionId, id);
    expect(find.text('Add sheets to session'), findsOneWidget);
    await tester.tap(find.textContaining('Unit 1 · Period 4').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New session').last);
    await tester.pumpAndSettle();
    expect(app.services.paper.targetSessionId, isNull);
    expect(find.text('Answer key page'), findsOneWidget);
    expect(find.text('Read the sheets'), findsOneWidget);
  });

  testWidgets(
    'a saved key corrected while the PDF reads prevents a stale append',
    (tester) async {
      late int id;
      final completed = Completer<Map<String, Object?>>();
      final app = await fixture.open(
        tester,
        seed: (store) => id = seed(store),
        reader: (_, _, _) => completed.future,
      );
      final model = app.services.paper;
      model.addToSession(id);
      model.setPdf('/makeup.pdf');
      final run = model.run();
      app.services.store.updateScan(id, 1, responses: ['B', 'B', 'C']);
      completed.complete(singleReport());
      await run;
      expect(model.phase, PaperPhase.failed);
      expect(model.error, contains('saved session changed'));
      expect(app.services.store.sessionScans(id), hasLength(2));
      expect(app.services.store.listSessions(), hasLength(1));
    },
  );

  testWidgets(
    'a deleted target and a reader failure leave saved results untouched',
    (tester) async {
      late int id;
      final app = await fixture.open(
        tester,
        seed: (store) => id = seed(store),
        reader: (_, _, _) async => throw const PaperException('Unreadable PDF'),
      );
      final model = app.services.paper;
      model.addToSession(id);
      model.setPdf('/makeup.pdf');
      final original = app.services.store.sessionScans(id);
      await model.run();
      expect(model.error, 'Unreadable PDF');
      expect(app.services.store.sessionScans(id), original);
      app.services.store.deleteSessions([id]);
      await model.run();
      expect(model.error, contains('no longer exists'));
      expect(app.services.store.listSessions(), isEmpty);
    },
  );
}
