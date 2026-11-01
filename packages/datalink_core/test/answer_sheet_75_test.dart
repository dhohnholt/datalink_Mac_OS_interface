import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_core/src/paper/omr/answer_sheet_75.dart' as sheet;
import 'package:datalink_core/src/paper/omr/omr.dart' as omr;
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'support/synthetic_sheets.dart';

/// The printable 75-question sheet, read from marks drawn onto a rendering of
/// the PDF the app hands out (`app/assets/answer_sheet_75.pdf` at 200 dpi).
/// If the PDF and the reader's layout drift apart, these stop passing.
void main() {
  late GrayImage blank;
  late Directory work;
  late PageCache cache;

  setUpAll(() {
    final decoded = img.decodePng(File('test/goldens/answer_sheet_75_200dpi.png').readAsBytesSync())!;
    blank = GrayImage(decoded.width, decoded.height);
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        blank.pixels[y * decoded.width + x] = decoded.getPixel(x, y).r.toInt();
      }
    }
  });
  setUp(() {
    work = Directory.systemTemp.createTempSync('sheet75-test-');
    cache = PageCache(Directory('${work.path}/cache'));
  });
  tearDown(() => work.deleteSync(recursive: true));

  /// A filled bubble at (x, y) inches on a 200 dpi page, in [shade].
  void fill(GrayImage page, (double, double) at, int shade) {
    const dpi = 200;
    final r = 0.085 * 0.85 * dpi;
    final cx = at.$1 * dpi;
    final cy = at.$2 * dpi;
    for (var y = (cy - r).floor(); y <= (cy + r).ceil(); y++) {
      for (var x = (cx - r).floor(); x <= (cx + r).ceil(); x++) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) page.pixels[y * page.width + x] = shade;
      }
    }
  }

  /// A filled-in sheet as a scanner would store it: tilted by [degrees],
  /// scaled, shifted, perhaps fed upside down, at 400 dpi for [syntheticPdf].
  GrayImage filled({
    Map<int, String> answers = const {},
    String studentId = '',
    String? version,
    bool key = false,
    int shade = 60,
    double degrees = 0,
    double scale = 1,
    (double, double) shift = (0, 0),
    bool upsideDown = false,
  }) {
    final page = GrayImage(blank.width, blank.height, Uint8List.fromList(blank.pixels));
    answers.forEach((q, letters) {
      for (final letter in letters.split('')) {
        fill(page, sheet.answerBubbles(q)['ABCDE'.indexOf(letter)], shade);
      }
    });
    for (var i = 0; i < studentId.length; i++) {
      fill(page, sheet.idBubbles(i)[int.parse(studentId[i])], shade);
    }
    if (version != null) fill(page, sheet.versionBubbles()[sheet.customVersions.indexOf(version)], shade);
    if (key) fill(page, sheet.keyBubble, shade);

    // Resample at 400 dpi through the inverse of the tilt, scale and shift.
    final out = GrayImage(blank.width * 2, blank.height * 2)..pixels.fillRange(0, blank.width * blank.height * 4, 255);
    final a = degrees * math.pi / 180;
    final cx = out.width / 2;
    final cy = out.height / 2;
    for (var y = 0; y < out.height; y++) {
      for (var x = 0; x < out.width; x++) {
        final dx = (x - cx - shift.$1) / scale;
        final dy = (y - cy - shift.$2) / scale;
        final sx = ((math.cos(a) * dx + math.sin(a) * dy + cx) / 2).round();
        final sy = ((-math.sin(a) * dx + math.cos(a) * dy + cy) / 2).round();
        if (sx < 0 || sy < 0 || sx >= page.width || sy >= page.height) continue;
        out.pixels[y * out.width + x] = page.pixels[sy * page.width + sx];
      }
    }
    return upsideDown ? out.rotated180() : out;
  }

  File pdfOf(List<GrayImage> pages) => File('${work.path}/batch.pdf')..writeAsBytesSync(syntheticPdf(pages));

  Map<int, String> cycle(int shift, [int count = 75]) =>
      {for (var q = 1; q <= count; q++) q: 'ABCDE'[(q + shift) % 5]};

  final unusedTemplate = syntheticTemplate();

  group('reading one sheet', () {
    test('answers, ID, version and the key bubble', () {
      final answers = {1: 'A', 25: 'E', 26: 'C', 50: 'B', 51: 'D', 75: 'B', 40: 'AC'};
      final page = filled(answers: answers, studentId: '042517', version: '3', key: true, degrees: 1.2, shift: (40, -30));
      final reading = omr.SheetReader(unusedTemplate).read(page);
      final extraction = (reading as omr.ProcessedPage).sheet;
      expect(extraction.form, sheet.customFormName);
      for (final MapEntry(key: q, value: letters) in answers.entries) {
        expect(extraction.answers[q], letters.length == 1 ? letters : 'MULTIPLE', reason: 'question $q');
      }
      expect(extraction.answers[2], 'BLANK');
      expect(extraction.studentId, '042517');
      expect(extraction.version, '3');
      expect(extraction.isKey, isTrue);
    });

    test('upside down, scaled, and in light pencil', () {
      final page = filled(answers: {10: 'D'}, studentId: '9', shade: 135, upsideDown: true, scale: 0.97, degrees: -1);
      final extraction = (omr.SheetReader(unusedTemplate).read(page) as omr.ProcessedPage).sheet;
      expect(extraction.answers[10], 'D');
      expect(extraction.studentId, '9_____');
      expect(extraction.calibration['orientation_angle'], 180);
      expect(extraction.isKey, isFalse);
      expect(extraction.version, isNull);
      expect(extraction.versionRead, '_');
    });

    test('an unmarked sheet reads as blank everywhere, not as a blank page', () {
      final extraction = (omr.SheetReader(unusedTemplate).read(filled()) as omr.ProcessedPage).sheet;
      expect(extraction.answers.values.toSet(), {'BLANK'});
      expect(extraction.studentId, '______');
      expect(extraction.isKey, isFalse);
    });

    test('grey scanned registration marks and pencil retain IDs and answers', () {
      final page = filled(answers: cycle(0, 33), studentId: '562440', version: '1', shade: 175, degrees: 0.7);
      // A scanner can turn solid black toner into grey, as in the first
      // classroom batch. Keep this synthetic so student scans stay private.
      for (var i = 0; i < page.pixels.length; i++) {
        final x = i % page.width;
        final y = i ~/ page.width;
        if ((x < 400 || x > page.width - 400) &&
            (y < 400 || y > page.height - 400) && page.pixels[i] < 170) {
          page.pixels[i] = 170;
        }
      }
      final extraction = (omr.SheetReader(unusedTemplate).read(page) as omr.ProcessedPage).sheet;
      expect(extraction.studentId, '562440');
      expect(extraction.version, '1');
      for (var q = 1; q <= 75; q++) {
        expect(extraction.answers[q], q <= 33 ? cycle(0, 33)[q] : 'BLANK', reason: 'question $q');
      }
      expect(extraction.isKey, isFalse);
    });

    test('an AccuScan sheet is not taken for this form', () {
      final accuscan = syntheticSheet(unusedTemplate, answers: [for (var q = 0; q < 50; q++) 'A']);
      expect(sheet.locateCustomSheet(accuscan), isNull);
    });
  });

  group('a batch', () {
    test('several versions in one run, from a test package, filed and rescored', () async {
      // Item i is question i on version 1 and question 21 - i on version 2,
      // with the answers moved round too.
      final rows = StringBuffer('Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer\n');
      final v1 = <int, String>{};
      final v2 = <int, String>{};
      for (var i = 1; i <= 20; i++) {
        final a1 = i == 20 ? 'AC' : 'ABCDE'[i % 5];
        final a2 = i == 20 ? 'BD' : 'ABCDE'[(i + 2) % 5];
        v1[i] = a1;
        v2[21 - i] = a2;
        rows.writeln('item-$i,${i <= 10 ? 'Part 1' : 'Part 2'},${i.isEven ? 'S.2' : 'S.1'},$i,$a1,${21 - i},$a2');
      }
      final package = TestPackage.parse(rows.toString());
      Map<int, String> withWrong(Map<int, String> key, List<int> wrong) =>
          {...key, for (final q in wrong) q: key[q] == 'A' ? 'B' : 'A'};
      final pages = [
        filled(answers: v2, studentId: '200002', version: '2', degrees: 0.6),
        filled(answers: withWrong(v1, [1, 2]), studentId: '100001', version: '1'),
        filled(answers: withWrong(v2, [20]), studentId: '200003', version: '2', upsideDown: true),
        filled(answers: v1, studentId: '999999'), // no version: not scored
        filled(answers: v1, version: '1', key: true), // agrees with the package
      ];
      final report = await readBatch(
        request: PaperRequest(pdf: pdfOf(pages), package: package, examName: 'Presidency'),
        orientTemplate: unusedTemplate,
        cache: cache,
        workers: 2,
      );
      final scores = {
        for (final s in (report['students']! as List).cast<Map<String, Object?>>())
          s['student_id']: (s['score']! as Map)['correct'],
      };
      expect(scores, {'200002': 20, '100001': 18, '200003': 19});
      expect(report['not_scored'], [
        {'page': 4, 'reason': 'no version bubbled'},
      ]);
      expect(report['key_mismatches'], isEmpty);
      expect((report['standards']! as Map)['S.1'], {'items': 10, 'class_pct': 93.3});

      final store = Store.open(':memory:');
      addTearDown(store.close);
      final id = sessionFromReport(store, report, name: 'Presidency');
      final scans = store.sessionScans(id);
      expect([for (final s in scans) (s['role'], s['version'])],
          [('student', '2'), ('student', '1'), ('student', '2'), ('key', '1')]);
      // Question 20 on version 1 is the multiple-answer item, kept as letters.
      expect((scans[1]['responses']! as List)[19], 'AC');

      final workspace = Workspace(store: store, now: () => DateTime.utc(2026, 10, 31), newId: () => 'run-1');
      final rescored = workspace.analysisReport(id);
      expect(
        {for (final s in (rescored['students']! as List).cast<Map<String, Object?>>()) s['student_id']: (s['score']! as Map)['correct']},
        scores,
      );
      expect((rescored['exam']! as Map)['form'], 'package');
    });

    test('finds the key by its bubble and scores one version', () async {
      final key = cycle(0);
      Map<int, String> wrong(int n) => {...key, for (var q = 1; q <= n; q++) q: 'ABCDE'[('ABCDE'.indexOf(key[q]!) + 1) % 5]};
      final pages = [
        filled(answers: wrong(10), studentId: '100002', version: '1', degrees: 0.8),
        filled(answers: key, version: '1', key: true),
        filled(answers: wrong(0), studentId: '100001', version: '1', upsideDown: true),
        filled(answers: wrong(20), studentId: '100003'), // version left blank
        filled(answers: wrong(5), studentId: '100004', version: '2'),
      ];
      final report = await readBatch(
        request: PaperRequest(pdf: pdfOf(pages), questionCount: 75),
        orientTemplate: unusedTemplate,
        cache: cache,
        workers: 2,
      );
      final exam = report['exam']! as Map<String, Object?>;
      expect(exam['key_page'], 2);
      expect(exam['version'], '1');
      final students = (report['students']! as List).cast<Map<String, Object?>>();
      expect({for (final s in students) s['student_id']: (s['score']! as Map)['correct']},
          {'100002': 65, '100001': 75, '100003': 55});
      expect(report['_not_scored'], [
        {'page': 5, 'reason': 'version 2'},
      ]);
      expect((report['review_items']! as List).where((i) => (i as Map)['field'] == 'version').map((i) => (i as Map)['page']), [4]);
    });

    test('keys for two versions need a version chosen', () async {
      final pages = [
        filled(answers: cycle(0), version: '1', key: true),
        filled(answers: cycle(1), version: '2', key: true),
        filled(answers: cycle(0), studentId: '111111', version: '1'),
        filled(answers: cycle(1), studentId: '222222', version: '2'),
      ];
      final file = pdfOf(pages);
      await expectLater(
        readBatch(request: PaperRequest(pdf: file, questionCount: 75), orientTemplate: unusedTemplate, cache: cache),
        throwsA(isA<PaperException>().having((e) => e.message, 'message', contains('versions 1, 2'))),
      );
      final report = await readBatch(
        request: PaperRequest(pdf: file, questionCount: 75, version: '2'),
        orientTemplate: unusedTemplate,
        cache: cache,
      );
      final students = (report['students']! as List).cast<Map<String, Object?>>();
      expect(students.map((s) => s['student_id']), ['222222']);
      expect((students.single['score']! as Map)['correct'], 75);
    });

    test('no key bubble and no key page is refused', () async {
      final file = pdfOf([filled(answers: cycle(0), studentId: '111111')]);
      await expectLater(
        readBatch(request: PaperRequest(pdf: file), orientTemplate: unusedTemplate, cache: cache),
        throwsA(isA<PaperException>().having((e) => e.message, 'message', contains('ANSWER KEY bubble'))),
      );
    });

    test('a key with more answers than the count suggests the higher count', () async {
      final file = pdfOf([filled(answers: cycle(0, 60), key: true), filled(answers: cycle(0, 60), studentId: '1')]);
      await expectLater(
        readBatch(request: PaperRequest(pdf: file, questionCount: 50), orientTemplate: unusedTemplate, cache: cache),
        throwsA(isA<QuestionCountException>().having((e) => e.suggested, 'suggested', 60)),
      );
      await expectLater(
        readBatch(request: PaperRequest(pdf: file, questionCount: 75), orientTemplate: unusedTemplate, cache: cache),
        throwsA(isA<QuestionCountException>().having((e) => e.suggested, 'suggested', 60)),
      );
    });
  });
}
