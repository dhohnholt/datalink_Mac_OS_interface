import 'dart:io';
import 'dart:math' as math;

import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';

import 'support/synthetic_sheets.dart';

/// The whole paper path on made-up sheets: PDF -> pages -> marks -> scores ->
/// a session in the library.
void main() {
  late Directory work;
  late GrayImage template;
  late PageCache cache;

  setUp(() {
    work = Directory.systemTemp.createTempSync('paper-test-');
    template = syntheticTemplate();
    cache = PageCache(Directory('${work.path}/cache'));
  });
  tearDown(() => work.deleteSync(recursive: true));

  List<String> cycle(int shift) => [for (var q = 0; q < 50; q++) 'ABCDE'[(q + shift) % 5]];

  File pdfOf(List<GrayImage> pages) {
    final file = File('${work.path}/batch.pdf');
    file.writeAsBytesSync(syntheticPdf(pages));
    return file;
  }

  test('reads a batch, scores it and files it as a session', () async {
    final key = cycle(0);
    final first = [...key]..[0] = 'B'..[1] = 'C'; // two wrong
    final second = [...key]..[4] = ''..[5] = '*'; // one blank, one double mark
    final pages = [
      syntheticSheet(template, answers: key),
      syntheticSheet(template, answers: first, studentId: '123456', shiftY: 17),
      GrayImage(sheetWidth, sheetHeight)..pixels.fillRange(0, sheetWidth * sheetHeight, 255), // blank back
      syntheticSheet(template, answers: second, studentId: '654_21', upsideDown: true),
    ];
    final progress = <double>[];
    final report = await readBatch(
      request: PaperRequest(pdf: pdfOf(pages), keyPage: 1, examName: 'Unit 1', questionCount: 50),
      orientTemplate: template,
      cache: cache,
      onProgress: (fraction, _) => progress.add(fraction),
      workers: 2,
      now: () => DateTime.utc(2026, 9, 30, 12),
    );

    final exam = report['exam']! as Map<String, Object?>;
    expect(exam['processed_pages'], [1, 2, 4]);
    expect(report['warnings'], contains(isA<Map<String, Object?>>().having((w) => w['code'], 'code', 'blank_pages_skipped')));
    final students = (report['students']! as List).cast<Map<String, Object?>>();
    expect(students.map((s) => s['page']), [2, 4]);
    expect(students[0]['student_id'], '123456');
    expect((students[0]['score']! as Map)['correct'], 48);
    // Read upside down, and with a missing digit.
    expect(students[1]['student_id'], isNull);
    expect(students[1]['student_id_read'], '654_21');
    final score = students[1]['score']! as Map;
    expect([score['correct'], score['blank'], score['multiple']], [48, 1, 1]);
    final items = (report['items']! as List).cast<Map<String, Object?>>();
    expect(items.first['correct_answer'], 'A');
    expect(progress, isNotEmpty);
    expect(progress.every((p) => p >= 0 && p <= 1), isTrue);
    expect(progress, equals([...progress]..sort()));

    // A reduced picture of each page was kept for the Review dialog.
    final directory = Directory(report['_page_cache']! as String);
    expect(directory.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toList()..sort(),
        ['page-000001.jpg', 'page-000002.jpg', 'page-000003.jpg', 'page-000004.jpg']);
    expect(readPagePicture(directory.path, 2)!.length, lessThan(400 * 1024));
    expect((cache.report()['batches']! as int), 1);

    // Filed as an ordinary session.
    final store = Store.open(':memory:');
    addTearDown(store.close);
    final id = sessionFromReport(store, report, name: 'Period 4');
    final session = store.session(id)!;
    expect([session['name'], session['source'], session['question_count']], ['Period 4', 'paper', 50]);
    final scans = store.sessionScans(id);
    expect(scans.map((s) => [s['number'], s['role']]), [
      [1, 'key'],
      [2, 'student'],
      [4, 'student'],
    ]);
    expect(scans[2]['responses'], hasLength(50));
    expect((scans[2]['responses']! as List)[4], '');
    // A double mark is kept as its letters, as the DataLink reports one.
    expect((scans[2]['responses']! as List)[5], 'AB');
  });

  test('a key that cannot be read comes back with what was seen, and overrides settle it', () async {
    final key = cycle(0);
    key[2] = ''; // nothing marked
    final pages = [
      syntheticSheet(template, answers: key),
      syntheticSheet(template, answers: cycle(0), studentId: '111111'),
    ];
    final request = PaperRequest(pdf: pdfOf(pages), keyPage: 1);
    await expectLater(
      readBatch(request: request, orientTemplate: template, cache: cache, workers: 1),
      throwsA(isA<AnswerKeyException>()
          .having((e) => e.message, 'message', 'The answer key could not be read on question 3.')
          .having((e) => (e.review['unresolved']! as Map)['3'], 'question 3 seen', 'BLANK')
          .having((e) => e.review['key_page'], 'key page', 1)),
    );

    final report = await readBatch(
      request: PaperRequest(pdf: request.pdf, keyPage: 1, keyOverrides: {3: 'C', 10: 'a'}),
      orientTemplate: template,
      cache: cache,
      workers: 1,
    );
    final answers = ((report['exam']! as Map)['answer_key']! as List).cast<Map<String, Object?>>();
    expect([answers[2]['answer'], answers[9]['answer']], ['C', 'A']);
  });

  test('a key row with two marks is a multiple-answer question, right only when matched exactly', () async {
    final key = cycle(0)..[9] = '*'; // A and B filled on question 10
    final pages = [
      syntheticSheet(template, answers: key),
      syntheticSheet(template, answers: key, studentId: '111111'),
      syntheticSheet(template, answers: cycle(0), studentId: '222222'), // A only on 10
    ];
    final report = await readBatch(
      request: PaperRequest(pdf: pdfOf(pages), keyPage: 1),
      orientTemplate: template,
      cache: cache,
      workers: 1,
    );
    final keyRows = ((report['exam']! as Map)['answer_key']! as List).cast<Map<String, Object?>>();
    expect(keyRows[9]['answer'], 'AB');
    final students = (report['students']! as List).cast<Map<String, Object?>>();
    expect([for (final s in students) (s['score']! as Map)['correct']], [50, 49]);
    final tenth = ((students[0]['answers']! as List)[9] as Map);
    expect([tenth['response'], tenth['marks'], tenth['correct']], ['MULTIPLE', 'AB', true]);
    expect((report['review_items']! as List).where((i) => (i as Map)['question'] == 10), isEmpty,
        reason: 'two marks are the expected answer there');
  });

  group('a key marked for fewer questions than the batch is set to', () {
    // A 30-question test, with the count left at the form's 50.
    List<String> shortKey() => [...cycle(0).take(30), ...List.filled(20, '')];

    File thirtyQuestionBatch() => pdfOf([
          syntheticSheet(template, answers: shortKey()),
          syntheticSheet(template, answers: shortKey(), studentId: '111111'),
        ]);

    test('is caught on the key sheet alone, before the class is read', () async {
      var reads = 0;
      await expectLater(
        readBatch(
          request: PaperRequest(pdf: thirtyQuestionBatch(), keyPage: 1),
          orientTemplate: template,
          cache: cache,
          workers: 1,
          onProgress: (_, _) => reads++,
        ),
        throwsA(isA<QuestionCountException>()
            .having((e) => e.suggested, 'suggested', 30)
            .having((e) => e.current, 'current', 50)
            .having((e) => e.keyPage, 'key page', 1)
            .having((e) => e.message, 'message', contains('questions 1 to 30'))),
      );
      expect(reads, 0, reason: 'no progress is reported, because the sheets were never read');
    });

    test('reads as normal once the count is brought down', () async {
      final report = await readBatch(
        request: PaperRequest(pdf: thirtyQuestionBatch(), keyPage: 1, questionCount: 30),
        orientTemplate: template,
        cache: cache,
        workers: 1,
      );
      expect(((report['exam']! as Map)['answer_key']! as List), hasLength(30));
      expect((report['students']! as List), hasLength(1));
    });

    test('keeping the count goes on to the usual key review', () async {
      await expectLater(
        readBatch(
          request: PaperRequest(pdf: thirtyQuestionBatch(), keyPage: 1, checkQuestionCount: false),
          orientTemplate: template,
          cache: cache,
          workers: 1,
        ),
        throwsA(isA<AnswerKeyException>()),
      );
    });

    test('answers supplied for the rest of the key mean the count was meant', () async {
      final report = await readBatch(
        request: PaperRequest(
          pdf: thirtyQuestionBatch(),
          keyPage: 1,
          keyOverrides: {for (var q = 31; q <= 50; q++) q: 'A'},
        ),
        orientTemplate: template,
        cache: cache,
        workers: 1,
      );
      expect(((report['exam']! as Map)['answer_key']! as List), hasLength(50));
    });

    test('a complete key is read without a word', () async {
      final report = await readBatch(
        request: PaperRequest(
          pdf: pdfOf([syntheticSheet(template, answers: cycle(0)), syntheticSheet(template, answers: cycle(0), studentId: '111111')]),
          keyPage: 1,
        ),
        orientTemplate: template,
        cache: cache,
        workers: 1,
      );
      expect((report['students']! as List), hasLength(1));
    });
  });

  group('refusals', () {
    test('a key page outside the selection', () async {
      final file = pdfOf([syntheticSheet(template, answers: cycle(0))]);
      await expectLater(
        readBatch(request: PaperRequest(pdf: file, keyPage: 1, skipPages: '1'), orientTemplate: template, cache: cache),
        throwsA(isA<PaperException>().having((e) => e.message, 'message', contains('contains no pages'))),
      );
    });

    test('a key page that is not a sheet of this form', () async {
      final rng = math.Random(3);
      final noise = GrayImage(sheetWidth, sheetHeight);
      for (var i = 0; i < noise.pixels.length; i++) {
        noise.pixels[i] = rng.nextInt(2) == 0 ? 20 : 240;
      }
      final file = pdfOf([noise]);
      await expectLater(
        readBatch(request: PaperRequest(pdf: file, keyPage: 1), orientTemplate: template, cache: cache, workers: 1),
        throwsA(isA<PaperException>().having((e) => e.message, 'message', contains('was not processed'))),
      );
    });

    test('missing key page, bad question count, bad page list', () async {
      final file = pdfOf([syntheticSheet(template, answers: cycle(0))]);
      Future<void> refuses(PaperRequest request, String text) => expectLater(
            readBatch(request: request, orientTemplate: template, cache: cache),
            throwsA(isA<PaperException>().having((e) => e.message, 'message', contains(text))),
          );
      await refuses(PaperRequest(pdf: file, keyPage: 0), 'Choose which page');
      await refuses(PaperRequest(pdf: file, keyPage: 1, questionCount: 76), 'from 1 to 75');
      await refuses(
        PaperRequest(pdf: file, keyPage: 1, questionCount: 51, checkQuestionCount: false),
        'holds 50 questions',
      );
      await refuses(PaperRequest(pdf: file, keyPage: 1, version: '5'), 'no version 5');
      await refuses(PaperRequest(pdf: file, keyPage: 1, pages: '1,x'), 'invalid page entry');
      await refuses(PaperRequest(pdf: file, keyPage: 1, pages: '9'), 'outside this PDF');
    });
  });

  test('page lists follow the reader\'s rules', () {
    expect(parsePageSpec('odd', 5), {1, 3, 5});
    expect(parsePageSpec('1,3,7-9', 12), {1, 3, 7, 8, 9});
    expect(parsePageSpec('', 5), isEmpty);
    expect(() => parsePageSpec('4-2', 5), throwsFormatException);
  });

  test('emptying the cache removes the pictures and reports the space freed', () async {
    final file = pdfOf([syntheticSheet(template, answers: cycle(0)), syntheticSheet(template, answers: cycle(1), studentId: '000000')]);
    await readBatch(request: PaperRequest(pdf: file, keyPage: 1), orientTemplate: template, cache: cache, workers: 1);
    expect(cache.report()['cache_bytes'], greaterThan(0));
    final result = cache.purge();
    expect(result['removed'], 1);
    expect(result['freed_bytes'], greaterThan(0));
    expect(cache.report()['cache_bytes'], 0);
  });
}
