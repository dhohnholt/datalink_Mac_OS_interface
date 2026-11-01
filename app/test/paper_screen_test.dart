import 'dart:async';
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

/// A report as the reader would return it: a key and two students on a
/// three-question test.
Map<String, Object?> report({String cache = '/nowhere'}) => {
      'created_at': '2026-09-30T12:00:00+00:00',
      'exam': {
        'name': 'From the report',
        'question_count': 3,
        'key_page': 1,
        'answer_key': [
          {'question': 1, 'answer': 'A'},
          {'question': 2, 'answer': 'B'},
          {'question': 3, 'answer': 'C'},
        ],
      },
      'students': [
        for (final (page, id, responses) in [
          (2, '900011', ['A', 'B', 'C']),
          (3, '900012', ['A', 'BLANK', 'MULTIPLE']),
        ])
          {
            'page': page,
            'student_id': id,
            'student_id_read': id,
            'answers': [
              for (var q = 1; q <= 3; q++)
                {'question': q, 'response': responses[q - 1], 'confidence': {'mark_strength': 0.3, 'margin': 0.2}},
            ],
          },
      ],
      '_page_cache': cache,
    };

class Calls {
  final List<PaperRequest> requests = [];
}

Future<({AppServices services, RecordingActions actions, Calls calls})> open(
  WidgetTester tester, {
  Future<Map<String, Object?>> Function(PaperRequest request, PaperProgress progress, int call)? reader,
  int pages = 12,
  void Function(Store)? seed,
}) async {
  tester.view.physicalSize = const Size(1500, 1300);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final actions = RecordingActions()..nextPdfPath = '/scans/Unit 1 Exam.pdf';
  final calls = Calls();
  final store = Store.open(':memory:');
  seed?.call(store);
  final services = testServices(
    store: store,
    actions: actions,
    pageCounter: (file) {
      if (file.path.endsWith('bad.pdf')) throw const PaperException('Could not inspect the PDF: damaged');
      return pages;
    },
    paperReader: (request, progress) async {
      calls.requests.add(request);
      return reader != null ? reader(request, progress, calls.requests.length) : report();
    },
  );
  addTearDown(services.dispose);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Paper').first);
  await tester.pumpAndSettle();
  return (services: services, actions: actions, calls: calls);
}

Future<void> choose(WidgetTester tester) async {
  await tester.tap(find.text('Choose PDF…'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('nothing is offered until a PDF is chosen', (tester) async {
    await open(tester);
    expect(find.text('Read a paper batch'), findsOneWidget);
    expect(find.text('Read the sheets'), findsNothing);
    expect(find.text('Nothing cached yet.'), findsOneWidget);
  });

  testWidgets('choosing a PDF shows its name and pages, and fills in the test name', (tester) async {
    final app = await open(tester);
    await choose(tester);
    expect(app.actions.pdfPicks, 1);
    expect(find.text('Unit 1 Exam.pdf · 12 pages'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Unit 1 Exam'), findsOneWidget);
    expect(find.text('Read the sheets'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Read the sheets')).onPressed, isNotNull);
  });

  testWidgets('a key page outside the PDF is refused before anything runs', (tester) async {
    await open(tester);
    await choose(tester);
    await tester.enterText(find.widgetWithText(TextField, '1').first, '13');
    await tester.pump();
    expect(find.text('Choose a page from 1 to 12'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Read the sheets')).onPressed, isNull);
  });

  testWidgets('the printable answer sheet is saved from the Paper tab', (tester) async {
    final app = await open(tester);
    await tester.tap(find.text('Save answer sheet…'));
    await tester.pumpAndSettle();
    final saved = app.actions.savedBytes.single;
    expect(saved.name, 'Answer Sheet (75 questions).pdf');
    expect(saved.extension, 'pdf');
    expect(String.fromCharCodes(saved.bytes.take(5)), '%PDF-');
    expect(saved.bytes, File('assets/answer_sheet_75.pdf').readAsBytesSync());
    expect(find.text('Saved the answer sheet'), findsOneWidget);
  });

  testWidgets('the vocabulary sheet, its guide and the matching sheet are saved too', (tester) async {
    final app = await open(tester);
    for (final (button, name, asset) in [
      ('Save 50 + matching sheet…', 'Answer Sheet (50 questions + matching).pdf', 'answer_sheet_50_matching.pdf'),
      ('Save vocabulary quiz sheet…', 'Vocabulary Quiz Sheet.pdf', 'vocabulary_quiz_sheet.pdf'),
      ('Save vocabulary teacher guide…', 'Vocabulary Quiz Teacher Guide.pdf', 'vocabulary_quiz_teacher_guide.pdf'),
    ]) {
      await tester.ensureVisible(find.text(button));
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      final saved = app.actions.savedBytes.last;
      expect(saved.name, name);
      expect(saved.bytes, File('assets/$asset').readAsBytesSync());
    }
    expect(app.actions.savedBytes, hasLength(3));
  });

  testWidgets('the key can be found by its bubble, and a version chosen', (tester) async {
    final app = await open(tester);
    await choose(tester);
    await tester.tap(find.text('Find the key sheet by its ANSWER KEY bubble'));
    await tester.pump();
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Answer key page')).enabled, isFalse);
    await tester.enterText(find.widgetWithText(TextField, '50'), '75');
    await tester.tap(find.text('Any'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Version 2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read the sheets'));
    await tester.pumpAndSettle();

    final request = app.calls.requests.single;
    expect([request.keyPage, request.version, request.questionCount], [null, '2', 75]);
  });

  testWidgets('a PDF that cannot be read says why, and offers nothing else', (tester) async {
    final app = await open(tester);
    app.actions.nextPdfPath = '/scans/bad.pdf';
    await choose(tester);
    expect(find.text('Could not inspect the PDF: damaged'), findsOneWidget);
    expect(find.text('Read the sheets'), findsNothing);
  });

  testWidgets('reading a batch files a session and offers the item analysis', (tester) async {
    final app = await open(tester);
    await choose(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Unit 1 Exam'), 'Unit 1 — 4th');
    await tester.enterText(find.widgetWithText(TextField, '50'), '3');
    await tester.pump();
    await tester.tap(find.text('Read the sheets'));
    await tester.pumpAndSettle();

    final request = app.calls.requests.single;
    expect([request.keyPage, request.questionCount, request.examName], [1, 3, 'Unit 1 — 4th']);
    expect(request.pdf.path, '/scans/Unit 1 Exam.pdf');
    expect(find.textContaining('Read 2 sheets. They are saved as a session'), findsOneWidget);
    expect(find.text('Read the sheets'), findsNothing, reason: 'the form is out of the way once it is done');

    final sessions = app.services.store.listSessions();
    expect(sessions.single['name'], 'Unit 1 — 4th');
    expect(sessions.single['source'], 'paper');
    final scans = app.services.store.sessionScans(sessions.single['id']! as int);
    expect(scans.map((s) => s['role']), ['key', 'student', 'student']);
    expect((scans[2]['responses']! as List), ['A', '', '*']);

    await tester.tap(find.text('Open the item analysis'));
    await tester.pumpAndSettle();
    expect(find.text('Item analysis'), findsWidgets);
  });

  testWidgets('read another batch brings the form back', (tester) async {
    await open(tester);
    await choose(tester);
    await tester.tap(find.text('Read the sheets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read another batch'));
    await tester.pumpAndSettle();
    expect(find.text('Read the sheets'), findsOneWidget);
  });

  testWidgets('progress is shown while reading', (tester) async {
    final gate = Completer<void>();
    await open(tester, reader: (request, progress, call) async {
      progress(0.4, 'Reading the sheets…');
      await gate.future;
      return report();
    });
    await choose(tester);
    await tester.tap(find.text('Read the sheets'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.4);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Choose PDF…')).onPressed, isNull);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a refusal from the reader is shown in its words', (tester) async {
    await open(tester, reader: (r, p, c) async => throw const PaperException('page 1 was not processed as a valid Template A sheet.'));
    await choose(tester);
    await tester.tap(find.text('Read the sheets'));
    await tester.pumpAndSettle();
    expect(find.textContaining('was not processed as a valid Template A sheet'), findsOneWidget);
    expect(find.text('Read the sheets'), findsOneWidget, reason: 'the form stays, to try again');
  });

  group('an answer key that could not be read', () {
    Future<Map<String, Object?>> stuck(PaperRequest request, PaperProgress progress, int call) async {
      if (call == 1) {
        throw const AnswerKeyException(
          'The answer key could not be read on question 2, question 3.',
          {
            'key_page': 1,
            'unresolved': {'2': 'BLANK', '3': 'MULTIPLE'},
            'pages': '/nowhere',
          },
        );
      }
      return report();
    }

    testWidgets('asks for each answer and reads again with them', (tester) async {
      final app = await open(tester, reader: stuck);
      await choose(tester);
      await tester.tap(find.text('Read the sheets'));
      await tester.pumpAndSettle();

      expect(find.text('The answer key needs a hand'), findsOneWidget);
      expect(find.textContaining('2 questions could not be made out'), findsOneWidget);
      expect(find.textContaining('nothing marked on the key', findRichText: true), findsOneWidget);
      expect(find.textContaining('two or more marks on the key', findRichText: true), findsOneWidget);
      final retry = find.widgetWithText(FilledButton, 'Use these and read the batch');
      expect(tester.widget<FilledButton>(retry).onPressed, isNull);

      // One answered is not enough: a partial set would be refused again.
      await tester.tap(find.descendant(of: find.byType(SegmentedButton<String>).first, matching: find.text('B')));
      await tester.pump();
      expect(tester.widget<FilledButton>(retry).onPressed, isNull);
      await tester.tap(find.descendant(of: find.byType(SegmentedButton<String>).last, matching: find.text('C')));
      await tester.pump();
      expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);

      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(app.calls.requests, hasLength(2));
      expect(app.calls.requests.last.keyOverrides, {2: 'B', 3: 'C'});
      expect(find.text('The answer key needs a hand'), findsNothing);
      expect(find.textContaining('Read 2 sheets'), findsOneWidget);
    });

    testWidgets('Start over drops the panel and keeps the file', (tester) async {
      await open(tester, reader: stuck);
      await choose(tester);
      await tester.tap(find.text('Read the sheets'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start over'));
      await tester.pumpAndSettle();
      expect(find.text('The answer key needs a hand'), findsNothing);
      expect(find.text('Unit 1 Exam.pdf · 12 pages'), findsOneWidget);
    });

    testWidgets('the key sheet can be looked at, or its absence explained', (tester) async {
      await open(tester, reader: stuck);
      await choose(tester);
      await tester.tap(find.text('Read the sheets'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Look at the key sheet'));
      await tester.pumpAndSettle();
      expect(find.text('Answer key — page 1'), findsOneWidget);
      expect(find.textContaining('not in the cache any more'), findsOneWidget);
    });
  });

  testWidgets('the cache card reports its size and empties on confirmation', (tester) async {
    final app = await open(tester);
    final directory = Directory('${app.services.dataDirectory.path}/paper-cache/abc')..createSync(recursive: true);
    File('${directory.path}/page-000001.jpg').writeAsBytesSync(List.filled(300 * 1024, 7));
    app.services.paper.refreshStorage();
    await tester.pumpAndSettle();
    expect(find.textContaining('300 KB of page pictures from 1 batch'), findsOneWidget);

    await tester.tap(find.text('Empty the cache'));
    await tester.pumpAndSettle();
    expect(find.text('Empty the page cache?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Empty the cache'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing cached yet.'), findsOneWidget);
    expect(directory.existsSync(), isFalse);
  });
}
