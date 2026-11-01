/// The two printable sheets whose key decides which questions count: the
/// 20-question vocabulary quiz and the 50-question sheet with a 15-term
/// matching column. Their layouts mirror omr_final's `vocab_sheet_layout.py`
/// and `match_sheet_layout.py`; the PDFs in `app/assets/` are drawn from those.
///
/// A row left blank on the key is not scored, so neither sheet needs a
/// question count. The batch turns the key into a one-version test package
/// (see paper_batch.dart), and the parts become its sections.
library;

import 'dart:math' as math;

import '../gray_image.dart';
import 'answer_sheet_75.dart';
import 'omr.dart';

const String vocabFormName = 'vocab20';
const String matchFormName = 'match65';

/// One printable layout: where each bubble is, and what each question is.
class KeyDecidesLayout {
  const KeyDecidesLayout._(this.form, this.questionCount, this._part, this._bubbles);

  final String form;
  final int questionCount;
  final ({String section, String letters, bool several}) Function(int question) _part;
  final List<(double, double)> Function(int question) _bubbles;

  /// The section a question belongs to (its part of the sheet).
  String sectionOf(int question) => _part(question).section;

  /// Its answer letters, A-E, A-J or A-O.
  String lettersOf(int question) => _part(question).letters;

  /// Whether its key may hold several letters, all to be filled.
  bool allowsSeveral(int question) => _part(question).several;

  List<(double, double)> bubbles(int question) => _bubbles(question);
}

// ---------------------------------------------------------- vocabulary quiz

({String section, String letters, bool several}) _vocabPart(int q) {
  if (q >= 1 && q <= 8) return (section: 'Matching', letters: 'ABCDEFGHIJ', several: false);
  if (q >= 9 && q <= 16) return (section: 'Words in context', letters: 'ABCD', several: false);
  if (q >= 17 && q <= 20) return (section: 'Select all that apply', letters: 'ABCDE', several: true);
  throw RangeError.range(q, 1, 20, 'question');
}

List<(double, double)> _vocabBubbles(int q) {
  const rowPitch = 0.30, bubblePitch = 0.32, bubbleDx = 0.62;
  const columnX0 = [0.70, 4.45];
  final (first, last, columns, row0) = switch (q) {
    <= 8 => (1, 8, 1, 4.72),
    <= 16 => (9, 16, 2, 7.62),
    _ => (17, 20, 2, 9.32),
  };
  final rows = ((last - first + 1) / columns).ceil();
  final index = q - first;
  final column = index ~/ rows;
  final row = index % rows;
  final x0 = columnX0[column] + bubbleDx;
  final y = row0 + row * rowPitch;
  final letters = _vocabPart(q).letters;
  return [for (var i = 0; i < letters.length; i++) (x0 + i * bubblePitch, y)];
}

const KeyDecidesLayout vocabLayout = KeyDecidesLayout._(vocabFormName, 20, _vocabPart, _vocabBubbles);

// ------------------------------------------------- 50 questions + matching

({String section, String letters, bool several}) _matchPart(int q) {
  if (q >= 1 && q <= 50) return (section: 'Multiple choice', letters: 'ABCDE', several: true);
  if (q >= 51 && q <= 65) return (section: 'Matching', letters: 'ABCDEFGHIJKLMNO', several: false);
  throw RangeError.range(q, 1, 65, 'question');
}

List<(double, double)> _matchBubbles(int q) {
  if (q <= 50) {
    final block = (q - 1) ~/ 25;
    final row = (q - 1) % 25;
    final x0 = const [0.60, 2.55][block] + 0.62;
    final y = 4.32 + row * 0.235;
    return [for (var i = 0; i < 5; i++) (x0 + i * 0.30, y)];
  }
  final y = 4.80 + (q - 51) * 0.34;
  return [for (var i = 0; i < 15; i++) (4.62 + 0.55 + i * 0.19, y)];
}

const KeyDecidesLayout matchLayout = KeyDecidesLayout._(matchFormName, 65, _matchPart, _matchBubbles);

KeyDecidesLayout? keyDecidesLayout(String form) => switch (form) {
      vocabFormName => vocabLayout,
      matchFormName => matchLayout,
      _ => null,
    };

// --------------------------------------------------------------- reading

/// Select-all rows (vocabulary 17-20) are judged bubble by bubble against the
/// page's empty-bubble level, since several may be right: above this is a
/// mark, and anything in the band around it goes to review.
const double selectAllMark = 0.35;
const double selectAllReviewLow = 0.12;
const double selectAllReviewHigh = 0.60;

SheetExtraction extractKeyDecidesSheet(
  GrayImage canon,
  KeyDecidesLayout layout,
  int angle,
  double confidence, {
  bool scanStudentId = true,
}) {
  final raw = <int, List<double>>{
    for (var q = 1; q <= layout.questionCount; q++)
      q: [for (final (x, y) in layout.bubbles(q)) sampleCustomBubble(canon, x, y)],
  };
  // The page's empty-bubble level: most bubbles on any sheet are empty.
  final all = [for (final row in raw.values) ...row]..sort();
  final paper = all[all.length ~/ 2];
  // On the 50 + matching sheet, the A-E rows remove each letter's printed
  // level as the 75-question sheet does.
  final choiceRows = [for (var q = 1; q <= layout.questionCount; q++) if (layout.lettersOf(q) == 'ABCDE') raw[q]!];
  final baselines = [
    for (var j = 0; j < 5; j++) choiceRows.isEmpty ? 0.0 : choiceRows.map((r) => r[j]).reduce(math.min),
  ];

  final answers = <int, String>{};
  final marks = <int, String>{};
  final confidences = <int, Map<String, Object?>>{};
  for (final MapEntry(key: q, value: ratios) in raw.entries) {
    final letters = layout.lettersOf(q);
    if (layout.form == vocabFormName && layout.allowsSeveral(q)) {
      final adjusted = [for (final v in ratios) math.max(0.0, v - paper)];
      final marked = [for (var i = 0; i < letters.length; i++) if (adjusted[i] >= selectAllMark) letters[i]].join();
      final unclear = adjusted.any((v) => v >= selectAllReviewLow && v < selectAllReviewHigh);
      answers[q] = marked.isEmpty ? 'BLANK' : (marked.length == 1 ? marked : 'MULTIPLE');
      if (marked.length > 1) marks[q] = marked;
      confidences[q] = {'mark_strength': adjusted.reduce(math.max), 'needs_review': unclear};
    } else if (letters == 'ABCDE') {
      final answer = decideAnswer(ratios, baselines, minimumFill);
      answers[q] = answer;
      if (answer == 'MULTIPLE') marks[q] = markedOptions(ratios, baselines, minimumFill);
      confidences[q] = answerConfidence(ratios, baselines);
    } else {
      final read = decideLetterRow(ratios, letters);
      answers[q] = read.answer;
      if (read.marks != null) marks[q] = read.marks!;
      confidences[q] = {'needs_review': read.answer == 'MULTIPLE'};
    }
  }

  final header = readSheetHeader(canon, scanStudentId: scanStudentId);
  return SheetExtraction(
    studentId: header.studentId,
    answers: answers,
    rawDarkness: raw,
    optionBaselines: baselines,
    answerConfidence: confidences,
    calibration: <String, Object?>{
      'form': layout.form,
      'orientation_angle': angle,
      'form_code_confidence': confidence,
    },
    form: layout.form,
    isKey: header.isKey,
    version: header.version,
    versionRead: header.versionRead,
    marks: marks,
  );
}
