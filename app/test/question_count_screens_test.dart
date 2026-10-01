// A 30-question test scanned into a session set for 50: the screens notice from
// the answer key, ask once, and bring the count down on a yes.
import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_fake.dart';
import 'support/test_services.dart';

List<String> answered(int count, {int total = 50}) => [for (var i = 0; i < total; i++) i < count ? 'A' : ''];

Map<String, Object?> scan(int number, String role, List<String> responses, {String? id}) => {
      'number': number,
      'role': role,
      'student_id': id,
      'student_name': null,
      'received_at': '2026-09-16T18:00:00+00:00',
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
    };

void bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> settle(WidgetTester tester, {int ms = 700}) async {
  for (var elapsed = 0; elapsed < ms; elapsed += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<AppServices> openSaved(
  WidgetTester tester, {
  List<String>? student,
  ThemeMode mode = ThemeMode.light,
  double textScale = 1,
  Size size = const Size(1600, 1800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
  final store = Store.open(':memory:');
  final id = store.createSession('Unit 4', '', 50);
  store
    ..addScan(id, scan(1, 'key', answered(30)))
    ..addScan(id, scan(2, 'student', student ?? answered(30), id: '900011'));
  final services = testServices(store: store);
  services.appearance.set(mode);
  addTearDown(services.dispose);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Sessions').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('View'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Analysis').first);
  await tester.pumpAndSettle();
  return services;
}

void main() {
  group('while scanning', () {
    Future<({AppServices services, LiveFakeTransport device})> startAndFeedKey(
      WidgetTester tester,
      int answers,
    ) async {
      bigScreen(tester);
      final clock = TickClock();
      final device = LiveFakeTransport(clock: clock);
      final store = Store.open(':memory:');
      final services = testServices(store: store, transport: device, clock: clock);
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect and start session'));
      await settle(tester, ms: 4500);
      device.sendRecord(answered(answers, total: answers), studentId: '');
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

    testWidgets('a key marked for 30 questions in a session set for 50 asks, and yes lowers it', (tester) async {
      final rig = await startAndFeedKey(tester, 30);

      expect(find.text('This looks like a 30-question test'), findsOneWidget);
      expect(find.textContaining('questions 1 to 30 and none after that'), findsOneWidget);
      expect(find.textContaining('set to 50 questions'), findsOneWidget);

      await tester.tap(find.text('Use 30 questions'));
      await settle(tester);

      expect(find.text('This looks like a 30-question test'), findsNothing);
      expect(find.text('Scoring out of 30 questions'), findsOneWidget);
      expect(rig.services.scan.snapshot.questionCount, 30);
      expect(rig.services.store.getSetting('question_count'), '30', reason: 'the next session starts at 30');
      expect(rig.services.store.session(rig.services.scan.snapshot.sessionId!)!['question_count'], 30);
      expect(
        tester.widget<TextField>(find.widgetWithText(TextField, 'Questions per form')).controller!.text,
        '30',
        reason: 'the field shows the new count',
      );
      await disconnect(tester);
    });

    testWidgets('keeping the count is an answer, and is not asked again', (tester) async {
      final rig = await startAndFeedKey(tester, 30);
      expect(find.text('This looks like a 30-question test'), findsOneWidget);

      await tester.tap(find.text('Keep 50 questions'));
      await settle(tester);

      expect(find.text('This looks like a 30-question test'), findsNothing);
      expect(rig.services.scan.snapshot.questionCount, 50);
      expect(rig.services.scan.countSuggestion, isNull);
      await disconnect(tester);
    });

    testWidgets('a key that fills the count raises nothing', (tester) async {
      await startAndFeedKey(tester, 50);
      expect(find.textContaining('-question test'), findsNothing);
      await disconnect(tester);
    });
  });

  group('reading a PDF', () {
    Future<({AppServices services, List<PaperRequest> requests})> open(
      WidgetTester tester, {
      ThemeMode mode = ThemeMode.light,
    }) async {
      bigScreen(tester);
      final requests = <PaperRequest>[];
      final actions = RecordingActions()..nextPdfPath = '/scans/Unit 1 Exam.pdf';
      final services = testServices(
        store: Store.open(':memory:'),
        actions: actions,
        pageCounter: (_) => 12,
        paperReader: (request, progress) async {
          requests.add(request);
          if (requests.length == 1) {
            throw const QuestionCountException('The key stops at 30.', 30, 50, 1);
          }
          return {
            'created_at': '2026-09-30T12:00:00+00:00',
            'exam': {
              'name': 'x',
              'question_count': 3,
              'key_page': 1,
              'answer_key': [
                for (var q = 1; q <= 3; q++) {'question': q, 'answer': 'A'},
              ],
            },
            'students': [
              {
                'page': 2,
                'student_id': '900011',
                'student_id_read': '900011',
                'answers': [
                  for (var q = 1; q <= 3; q++)
                    {'question': q, 'response': 'A', 'confidence': {'mark_strength': 0.3, 'margin': 0.2}},
                ],
              },
            ],
            '_page_cache': '/nowhere',
          };
        },
      );
      services.appearance.set(mode);
      addTearDown(services.dispose);
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.tap(find.text('Paper').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose PDF…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read the sheets'));
      await tester.pumpAndSettle();
      return (services: services, requests: requests);
    }

    testWidgets('asks when the key stops short, and "read as 30" reads again at 30', (tester) async {
      final rig = await open(tester);
      expect(find.text('This looks like a 30-question test'), findsOneWidget);
      expect(find.textContaining('(page 1) has answers for questions 1 to 30'), findsOneWidget);
      expect(rig.requests, hasLength(1));
      expect(rig.requests.single.questionCount, 50);
      expect(rig.requests.single.checkQuestionCount, isTrue);

      await tester.tap(find.text('Read as 30 questions'));
      await tester.pumpAndSettle();

      expect(rig.requests, hasLength(2));
      expect(rig.requests.last.questionCount, 30);
      expect(find.text('This looks like a 30-question test'), findsNothing);
      expect(find.textContaining('Read 1 sheet'), findsOneWidget);
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('the question is readable and its buttons named, ${mode.name} mode', (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await open(tester, mode: mode);
          expect(find.text('Read as 30 questions'), findsOneWidget);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
        } finally {
          handle.dispose();
        }
      });
    }

    testWidgets('"keep 50" reads again at 50, without asking a second time', (tester) async {
      final rig = await open(tester);

      await tester.tap(find.text('Keep 50 questions'));
      await tester.pumpAndSettle();

      expect(rig.requests, hasLength(2));
      expect(rig.requests.last.questionCount, 50);
      expect(rig.requests.last.checkQuestionCount, isFalse);
      expect(find.text('This looks like a 30-question test'), findsNothing);
    });
  });

  group('on a saved test', () {
    Future<AppServices> open(WidgetTester tester, {List<String>? student}) => openSaved(tester, student: student);

    testWidgets('says so, and one press scores it out of 30', (tester) async {
      final services = await open(tester);
      expect(find.text('This test cannot be scored'), findsOneWidget, reason: 'a key with blanks cannot be scored');
      expect(find.text('This looks like a 30-question test'), findsOneWidget);

      await tester.tap(find.text('Score out of 30'));
      await tester.pumpAndSettle();

      expect(find.text('This looks like a 30-question test'), findsNothing);
      expect(find.text('This test cannot be scored'), findsNothing);
      expect(find.text('Now scored out of 30 questions'), findsOneWidget);
      expect(services.store.listSessions().single['question_count'], 30);
    });

    testWidgets('names what would be left out, and a no changes nothing', (tester) async {
      final services = await open(tester, student: [...answered(30), ...List.filled(20, '')]..[34] = 'B');

      await tester.tap(find.text('Score out of 30'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 mark on 1 sheet after question 30 would be left out'), findsOneWidget);

      await tester.tap(find.text('Keep 50 questions'));
      await tester.pumpAndSettle();

      expect(services.store.listSessions().single['question_count'], 50);
      expect(find.text('This looks like a 30-question test'), findsOneWidget, reason: 'still offered');
    });

    testWidgets('a yes to the warning goes ahead', (tester) async {
      final services = await open(tester, student: [...answered(30), ...List.filled(20, '')]..[34] = 'B');

      await tester.tap(find.text('Score out of 30'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use 30 questions'));
      await tester.pumpAndSettle();

      expect(services.store.listSessions().single['question_count'], 30);
      expect(find.text('This looks like a 30-question test'), findsNothing);
    });
  });

  group('readable and reachable', () {
    final marked = [...answered(30), ...List.filled(20, '')]..[34] = 'B';

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('the banner and the warning, ${mode.name} mode', (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await openSaved(tester, student: marked, mode: mode);
          expect(find.text('This looks like a 30-question test'), findsOneWidget);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));

          await tester.tap(find.text('Score out of 30'));
          await tester.pumpAndSettle();
          expect(find.text('Use 30 questions'), findsOneWidget);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
        } finally {
          handle.dispose();
        }
      });
    }

    testWidgets('the banner and the warning at 200% text still fit', (tester) async {
      await openSaved(tester, student: marked, textScale: 2, size: const Size(1100, 760));
      await tester.ensureVisible(find.text('Score out of 30'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Score out of 30'));
      await tester.pumpAndSettle();
      expect(find.text('Use 30 questions'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'a layout overflow is reported as an exception');
    });
  });
}
