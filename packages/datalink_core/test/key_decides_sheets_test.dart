import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_core/src/paper/omr/answer_sheet_75.dart' as sheet;
import 'package:datalink_core/src/paper/omr/key_decides_sheets.dart';
import 'package:datalink_core/src/paper/omr/omr.dart' as omr;
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'support/synthetic_sheets.dart';

/// The vocabulary quiz and the 50-question + matching sheet, read from marks
/// drawn onto renderings of the PDFs the app hands out. If a PDF and its
/// layout here drift apart, these stop passing.
void main() {
  final blanks = <String, GrayImage>{};
  late Directory work;
  late PageCache cache;
  final template = syntheticTemplate();

  GrayImage load(String name) {
    final decoded = img.decodePng(File('test/goldens/${name}_200dpi.png').readAsBytesSync())!;
    final image = GrayImage(decoded.width, decoded.height);
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        image.pixels[y * decoded.width + x] = decoded.getPixel(x, y).r.toInt();
      }
    }
    return image;
  }

  setUpAll(() {
    blanks[vocabFormName] = load('vocabulary_quiz_sheet');
    blanks[matchFormName] = load('answer_sheet_50_matching');
  });
  setUp(() {
    work = Directory.systemTemp.createTempSync('key-decides-test-');
    cache = PageCache(Directory('${work.path}/cache'));
  });
  tearDown(() => work.deleteSync(recursive: true));

  /// A sheet filled in and scanned: [answers] maps question -> letters (two
  /// letters fill two bubbles), tilted and shifted a little, at 400 dpi.
  GrayImage filled(
    KeyDecidesLayout layout, {
    Map<int, String> answers = const {},
    String studentId = '',
    String? version,
    bool key = false,
    int shade = 60,
    double degrees = 0,
    bool upsideDown = false,
  }) {
    final blank = blanks[layout.form]!;
    final page = GrayImage(blank.width, blank.height, Uint8List.fromList(blank.pixels));
    void dot((double, double) at, double radius) {
      const dpi = 200;
      final r = radius * 0.85 * dpi;
      final cx = at.$1 * dpi;
      final cy = at.$2 * dpi;
      for (var y = (cy - r).floor(); y <= (cy + r).ceil(); y++) {
        for (var x = (cx - r).floor(); x <= (cx + r).ceil(); x++) {
          if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) page.pixels[y * page.width + x] = shade;
        }
      }
    }

    answers.forEach((q, letters) {
      final radius = layout.lettersOf(q).length == 15 ? 0.075 : 0.085;
      for (final letter in letters.split('')) {
        dot(layout.bubbles(q)[layout.lettersOf(q).indexOf(letter)], radius);
      }
    });
    for (var i = 0; i < studentId.length; i++) {
      dot(sheet.idBubbles(i)[int.parse(studentId[i])], 0.085);
    }
    if (version != null) dot(sheet.versionBubbles()[sheet.customVersions.indexOf(version)], 0.085);
    if (key) dot(sheet.keyBubble, 0.085);

    final out = GrayImage(blank.width * 2, blank.height * 2)..pixels.fillRange(0, blank.width * blank.height * 4, 255);
    final a = degrees * math.pi / 180;
    final cx = out.width / 2;
    final cy = out.height / 2;
    for (var y = 0; y < out.height; y++) {
      for (var x = 0; x < out.width; x++) {
        final dx = x - cx - 30;
        final dy = y - cy + 20;
        final sx = ((math.cos(a) * dx + math.sin(a) * dy + cx) / 2).round();
        final sy = ((-math.sin(a) * dx + math.cos(a) * dy + cy) / 2).round();
        if (sx < 0 || sy < 0 || sx >= page.width || sy >= page.height) continue;
        out.pixels[y * out.width + x] = page.pixels[sy * page.width + sx];
      }
    }
    return upsideDown ? out.rotated180() : out;
  }

  File pdfOf(List<GrayImage> pages) => File('${work.path}/batch.pdf')..writeAsBytesSync(syntheticPdf(pages));

  Map<String, Object?> scoresOf(Map<String, Object?> report) => {
        for (final s in (report['students']! as List).cast<Map<String, Object?>>())
          s['student_id']! as String: (s['score']! as Map)['correct'],
      };

  for (final layout in [vocabLayout, matchLayout]) {
    test('a single makeup ${layout.form} sheet reuses the saved package', () async {
      final key = layout.form == vocabFormName ? {1: 'J', 9: 'B', 17: 'ACE'} : {1: 'AC', 51: 'O', 52: 'N'};
      final items = [for (final q in key.keys) 'q$q'];
      final package = TestPackage(
        items: items, versions: ['1'],
        numbers: {'1': {for (final q in key.keys) 'q$q': q}},
        answers: {'1': {for (final e in key.entries) 'q${e.key}': e.value}},
        sections: {for (final item in items) item: 'Test'},
        standards: const {}, form: layout.form,
      );
      final store = Store.open(':memory:');
      addTearDown(store.close);
      final id = store.createSession('Makeup', '', package.questionCount, package: pyJsonEncode(package.toJson()));
      final saved = savedPaperKey(store, id);
      final report = await readBatch(
        request: PaperRequest(pdf: pdfOf([filled(layout, answers: key, studentId: '654321')]), package: saved.package),
        orientTemplate: template, cache: cache, workers: 1,
      );
      appendReportToSession(store, cache, id, report);
      expect(store.listSessions(), hasLength(1));
      final scan = store.sessionScans(id).single;
      expect(scan['role'], 'student');
      expect(scan['student_id'], '654321');
      for (final e in key.entries) {
        expect((scan['responses']! as List)[e.key - 1], e.value);
      }
      expect(scoresOf(Workspace(store: store).analysisReport(id)), {'654321': 3});
    });
  }

  test('each sheet is told apart by its code strip and read in its own layout', () {
    final reader = omr.SheetReader(template);
    final vocab = (reader.read(filled(vocabLayout,
            answers: {1: 'J', 9: 'D', 17: 'ACE', 18: 'B'}, studentId: '042517', version: '3', key: true, degrees: 1))
        as omr.ProcessedPage).sheet;
    expect(vocab.form, vocabFormName);
    expect([vocab.answers[1], vocab.answers[9], vocab.answers[17], vocab.marks[17], vocab.answers[18]],
        ['J', 'D', 'MULTIPLE', 'ACE', 'B']);
    expect(vocab.answers[2], 'BLANK');
    expect((vocab.studentId, vocab.version, vocab.isKey), ('042517', '3', true));

    final match = (reader.read(filled(matchLayout, answers: {1: 'B', 26: 'AC', 50: 'E', 51: 'O', 60: 'N'}, upsideDown: true))
        as omr.ProcessedPage).sheet;
    expect(match.form, matchFormName);
    expect([match.answers[1], match.marks[26], match.answers[50], match.answers[51], match.answers[60]],
        ['B', 'AC', 'E', 'O', 'N']);
    expect(match.calibration['orientation_angle'], 180);
  });

  test('an unmarked student sheet cannot silently become the matching key', () async {
    await expectLater(readBatch(
      request: PaperRequest(pdf: pdfOf([filled(matchLayout, answers: {1: 'A'}, version: '1')]), keyPage: 1),
      orientTemplate: template, cache: cache, workers: 1,
    ), throwsA(isA<PaperException>().having((e) => e.message, 'message', contains('Choose the answer map CSV'))));
  });

  test('matching detects two filled marks even when one is darker', () {
    final read = sheet.decideLetterRow([.174,.180,.195,.195,.201,.867,.188,.182,.174,.169,.172,.180,.198,.992,.174], 'ABCDEFGHIJKLMNO');
    expect(read.answer, 'MULTIPLE');
    expect(read.marks, 'FN');
  });

  test('uploaded two-version CSV scores matching sheets with skipped rows', () async {
    final package = TestPackage.parse(
      'Stable item ID,Section,Version 1,Version 1 answer,Version 2,Version 2 answer\n'
      'mc,Media,40,A,40,B\n'
      'term,Vocabulary,51,G,60,O\n',
    );
    final report = await readBatch(
      request: PaperRequest(pdf: pdfOf([
        filled(matchLayout, answers: {40: 'A', 41: 'D', 51: 'G'}, studentId: '200001', version: '1'),
        filled(matchLayout, answers: {40: 'B', 50: 'C', 60: 'O'}, studentId: '200002', version: '2'),
        filled(matchLayout, answers: {40: 'B', 60: 'O'}, studentId: '200003'),
      ]), package: package),
      orientTemplate: template,
      cache: cache,
      workers: 2,
    );
    expect(scoresOf(report), {'200001': 2, '200002': 2});
    final store = Store.open(':memory:');
    addTearDown(store.close);
    final id = sessionFromReport(store, report);
    final saved = Workspace(store: store, now: () => DateTime.utc(2026), newId: () => 'r').analysisReport(id);
    expect(scoresOf(saved), scoresOf(report));
    final firstStudent = (saved['students'] as List).first as Map;
    final matchingAnswer = (firstStudent['answers'] as List).firstWhere((a) => a['question'] == 51);
    expect(matchingAnswer['options'], 'ABCDEFGHIJKLMNO');
    final row = ReviewRow(sheet: 1, student: firstStudent.cast<String, Object?>(), key: 'answer:1:51', kind: ReviewKind.answer, question: 51, problem: '', read: 'MULTIPLE');
    expect(row.answerLetters, 'ABCDEFGHIJKLMNO');
    expect(saved['not_scored'], [{'page': 3, 'reason': 'no version bubbled'}]);
    final workspace = Workspace(store: store, now: () => DateTime.utc(2026), newId: () => 'version-change');
    workspace.correct(id, [{'number': 3, 'version': '2'}]);
    expect(scoresOf(workspace.analysisReport(id))['200003'], 2);
    expect(workspace.analysisReport(id)['not_scored'], isEmpty);
    expect(() => workspace.correct(id, [{'number': 3, 'version': '4'}]), throwsA(isA<DataLinkError>()));
    workspace.correct(id, [{'number': 3, 'version': ''}]);
    expect(workspace.analysisReport(id)['not_scored'], [{'page': 3, 'reason': 'no version bubbled'}]);
  });

  test('a vocabulary quiz: only the rows the key marks count, select-all all or nothing', () async {
    // 6 matching, 8 context, 3 select-all on the key; 7, 8 and 20 left blank.
    final key = {1: 'F', 2: 'B', 3: 'H', 4: 'A', 5: 'I', 6: 'G', 9: 'B', 10: 'A', 11: 'C', 12: 'D', 13: 'A', 14: 'B', 15: 'C',
      16: 'D', 17: 'ABDE', 18: 'ACE', 19: 'C'};
    final pages = [
      filled(vocabLayout, answers: key, studentId: '200001', version: '1'),
      filled(vocabLayout, answers: key, key: true, version: '1', degrees: -0.6),
      filled(vocabLayout, answers: {...key, 1: 'J', 17: 'AB', 18: 'ACDE'}, studentId: '200002', upsideDown: true, shade: 120),
      filled(vocabLayout, answers: {...key, 7: 'A'}, studentId: '200003'), // an unused row is ignored
      filled(matchLayout, answers: {1: 'A'}, studentId: '300001'), // another form: not scored
    ];
    final report = await readBatch(
      request: PaperRequest(pdf: pdfOf(pages), keyPage: 2, examName: 'Vocab 3'),
      orientTemplate: template,
      cache: cache,
      workers: 2,
    );
    expect(scoresOf(report), {'200001': 17, '200002': 14, '200003': 17});
    expect((report['summary']! as Map)['student_count'], 3);
    expect(report['not_scored'], [
      {'page': 5, 'reason': 'a different answer sheet from the key'},
    ]);
    expect((report['sections']! as Map).keys, ['Matching', 'Words in context', 'Select all that apply']);

    final store = Store.open(':memory:');
    addTearDown(store.close);
    final id = sessionFromReport(store, report);
    final workspace = Workspace(store: store, now: () => DateTime.utc(2026, 10, 31), newId: () => 'run-1');
    final rescored = workspace.analysisReport(id);
    expect(scoresOf(rescored), scoresOf(report));
    // Matching runs to J: a correction can use it.
    workspace.correct(id, [
      {'number': 3, 'responses': [for (var q = 1; q <= 19; q++) q == 1 ? 'F' : ((key[q] ?? '').length > 1 ? key[q]! : key[q] ?? '')]},
    ]);
    expect(scoresOf(workspace.analysisReport(id))['200002'], 17);
  });

  test('the 50 + matching sheet: multiple-answer A-E rows and matching to O', () async {
    final key = {1: 'B', 2: 'AC', 3: 'D', 4: 'ABE', 51: 'O', 52: 'N', 53: 'A', 54: 'H'};
    final pages = [
      filled(matchLayout, answers: key, key: true),
      filled(matchLayout, answers: key, studentId: '300001', degrees: 0.7),
      filled(matchLayout, answers: {...key, 2: 'A', 4: 'ABDE', 52: 'M'}, studentId: '300002', upsideDown: true),
      filled(matchLayout, answers: {...key, 1: 'BD', 53: 'B'}, studentId: '300003', shade: 135),
    ];
    final report = await readBatch(
      request: PaperRequest(pdf: pdfOf(pages), examName: 'Unit 4'),
      orientTemplate: template,
      cache: cache,
      workers: 2,
    );
    expect(scoresOf(report), {'300001': 8, '300002': 5, '300003': 6});
    final review = (report['review_items']! as List).cast<Map<String, Object?>>();
    expect(review.where((i) => i['field'] == 'answer').map((i) => (i['page'], i['question'])), [(4, 1)],
        reason: 'two marks where the key has one are worth a look; two where it has two are the answer');
    final items = {for (final i in (report['items']! as List).cast<Map<String, Object?>>()) i['item']: i};
    expect((items['Q2']!['answers']! as Map).values.single, 'AC');
    expect(items['Q52']!['percent_correct'], 66.7);
  });

  test('a key mark that cannot be a key is sent back to be settled', () async {
    final pages = [
      filled(vocabLayout, answers: {1: 'AB', 2: 'C'}, key: true), // matching takes one letter
      filled(vocabLayout, answers: {1: 'A', 2: 'C'}, studentId: '111111'),
    ];
    await expectLater(
      readBatch(request: PaperRequest(pdf: pdfOf(pages)), orientTemplate: template, cache: cache),
      throwsA(isA<AnswerKeyException>().having((e) => e.message, 'message', contains('question 1'))),
    );
    final report = await readBatch(
      request: PaperRequest(pdf: pdfOf(pages), keyOverrides: {1: 'A'}),
      orientTemplate: template,
      cache: cache,
    );
    expect(scoresOf(report), {'111111': 2});
  });
}
