/// Reading one answer sheet: find its orientation, line up the grid, measure
/// the ink in every bubble and decide what was marked. A port of
/// `vendor/omr/{calibrate_page,extract_template_a,analyze_exam}.py`, which are
/// verbatim copies from omr_final; the numbers must come out the same.
library;

import 'dart:math' as math;

import '../../protocol/py_math.dart';
import '../gray_image.dart';
import 'template_match.dart';

// --- Calibrated grid (400 dpi scan, portrait 2384x4384 reference page) ---
const double answerRow0Y = 1150.0;
const double answerRowSpacing = 109.3;
const List<double> leftColumns = [279.2, 398.4, 517.6, 636.8, 756.0];
const List<double> rightColumns = [1126.0, 1240.4, 1354.8, 1469.2, 1583.6];
const String options = 'ABCDE';

const List<double> idColumns = [294.2, 414.8, 535.1, 656.1, 776.0, 895.8];
const double idRow0Y = 465.8;
const double idRowSpacing = 63.13;

const int bubbleSampleRadius = 30;
const int darkPixelThreshold = 170;
const double adjBlankThreshold = 0.05;
const double adjMultiRatio = 0.85;

/// The part of the reference page matched to find orientation and offset:
/// rows 380-1000, columns 60-900.
const int orientTemplateX0 = 60;
const int orientTemplateY0 = 380;
const int orientTemplateWidth = 840;
const int orientTemplateHeight = 620;

const double minMatchConfidence = 0.55;

const double refRow0Y = 1150.0;
const double refRowSpacing = 109.3;

/// What `process_page` made of a page.
sealed class PageReading {
  const PageReading();
}

/// Almost no ink anywhere: the back of a duplex sheet.
class BlankPage extends PageReading {
  const BlankPage();
}

/// Not the form this reader knows.
class UnsupportedPage extends PageReading {
  const UnsupportedPage(this.confidence);

  /// Rounded to two places, as the reader reports it.
  final double confidence;
}

class ProcessedPage extends PageReading {
  const ProcessedPage(this.sheet);
  final SheetExtraction sheet;
}

class SheetExtraction {
  SheetExtraction({
    required this.studentId,
    required this.answers,
    required this.rawDarkness,
    required this.optionBaselines,
    required this.answerConfidence,
    required this.calibration,
  });

  /// Six characters of digits, `_` for an empty column and `?` for an unclear
  /// one; null when ID scanning was off.
  final String? studentId;
  final Map<int, String> answers;
  final Map<int, List<double>> rawDarkness;
  final List<double> optionBaselines;

  /// Question -> `{mark_strength, margin, needs_review}`.
  final Map<int, Map<String, Object?>> answerConfidence;
  final Map<String, Object?> calibration;
}

class SheetReader {
  SheetReader(GrayImage orientTemplate) : _matcher = TemplateMatcher(orientTemplate) {
    if (orientTemplate.width != orientTemplateWidth || orientTemplate.height != orientTemplateHeight) {
      throw ArgumentError('The orientation template must be $orientTemplateWidth x $orientTemplateHeight');
    }
  }

  final TemplateMatcher _matcher;

  /// `process_page`: classify a page and, if it is the form, read it.
  PageReading read(GrayImage gray, {double minMatch = minMatchConfidence, bool scanStudentId = true}) {
    if (isBlankPage(gray)) return const BlankPage();
    final (oriented, angle, confidence, location) = _fixOrientation(gray);
    if (confidence < minMatch) {
      return UnsupportedPage(pyRound(confidence, 2));
    }
    return ProcessedPage(_extract(oriented, angle, confidence, location, scanStudentId));
  }

  /// Tries the four rotations and keeps the one that matches best.
  (GrayImage, int, double, TemplateMatch?) _fixOrientation(GrayImage gray) {
    var bestImage = gray;
    var bestConfidence = -1.0;
    var bestAngle = 0;
    TemplateMatch? bestMatch;
    for (final angle in const [0, 90, 180, 270]) {
      final candidate = switch (angle) {
        90 => gray.rotated90CounterClockwise(),
        180 => gray.rotated180(),
        270 => gray.rotated90Clockwise(),
        _ => gray,
      };
      final match = _matcher.best(candidate);
      if (match == null) continue;
      if (match.score > bestConfidence) {
        bestImage = candidate;
        bestConfidence = match.score;
        bestAngle = angle;
        bestMatch = match;
      }
    }
    return (bestImage, bestAngle, bestConfidence, bestMatch);
  }

  SheetExtraction _extract(
    GrayImage gray,
    int angle,
    double orientationConfidence,
    TemplateMatch? location,
    bool scanStudentId,
  ) {
    // calibrate_page repeats the match on the already-oriented page and gets
    // the same answer; the match found while orienting is reused.
    final dy = location == null ? 0 : location.y - orientTemplateY0;
    final row0 = refRow0Y + dy;
    const spacing = refRowSpacing;
    final calibrationConfidence = orientationConfidence;

    final idRow0 = idRow0Y + (row0 - refRow0Y);
    final idSpacing = idRowSpacing * (spacing / refRowSpacing);
    final studentId = scanStudentId ? _extractId(gray, idRow0, idSpacing) : null;

    final raw = <int, List<double>>{};
    for (var q = 1; q <= 50; q++) {
      final columns = q <= 25 ? leftColumns : rightColumns;
      final y = row0 + (q <= 25 ? q - 1 : q - 26) * spacing;
      raw[q] = [for (var j = 0; j < 5; j++) sampleInkRatio(gray, columns[j], y)];
    }

    // The letters printed inside the bubbles do not carry equal ink; the
    // lightest reading of each option over the 50 rows is its unmarked level.
    final baselines = [
      for (var j = 0; j < 5; j++) raw.values.map((row) => row[j]).reduce(math.min),
    ];

    final answers = <int, String>{};
    final confidences = <int, Map<String, Object?>>{};
    for (final entry in raw.entries) {
      answers[entry.key] = decideAnswer(entry.value, baselines);
      confidences[entry.key] = answerConfidence(entry.value, baselines);
    }
    return SheetExtraction(
      studentId: studentId,
      answers: answers,
      rawDarkness: raw,
      optionBaselines: baselines,
      answerConfidence: confidences,
      calibration: <String, Object?>{
        'row0_y': row0,
        'row_spacing': spacing,
        'confidence': calibrationConfidence,
        'orientation_angle': angle,
        'orientation_confidence': orientationConfidence,
      },
    );
  }

  String _extractId(GrayImage gray, double row0, double spacing) {
    final digits = StringBuffer();
    for (final x in idColumns) {
      final ratios = [
        for (var d = 0; d < 10; d++) sampleInkRatio(gray, x, row0 + d * spacing, radius: 25),
      ];
      final baseline = ratios.reduce(math.min);
      final adjusted = [for (final v in ratios) v - baseline];
      final order = _byValueDescending(adjusted);
      final topValue = adjusted[order[0]];
      final secondValue = adjusted[order[1]];
      if (topValue < adjBlankThreshold) {
        digits.write('_');
      } else if (secondValue >= adjMultiRatio * topValue) {
        digits.write('?');
      } else {
        digits.write(order[0]);
      }
    }
    return digits.toString();
  }
}

/// `is_blank_page`: under 1% of the page is dark.
bool isBlankPage(GrayImage gray, {int inkThreshold = darkPixelThreshold, double minInkFraction = 0.01}) {
  var dark = 0;
  final pixels = gray.pixels;
  for (var i = 0; i < pixels.length; i++) {
    if (pixels[i] < inkThreshold) dark++;
  }
  return dark / pixels.length < minInkFraction;
}

/// `sample_ink_ratio`: the fraction of a square around (x, y) that is darker
/// than [darkThreshold]. Bounds truncate toward zero, as Python's `int()` does.
double sampleInkRatio(
  GrayImage gray,
  double x,
  double y, {
  int radius = bubbleSampleRadius,
  int darkThreshold = darkPixelThreshold,
}) {
  final x0 = math.max(0, (x - radius).truncate());
  final x1 = math.min(gray.width, (x + radius).truncate());
  final y0 = math.max(0, (y - radius).truncate());
  final y1 = math.min(gray.height, (y + radius).truncate());
  if (x1 <= x0 || y1 <= y0) return 0.0;
  var dark = 0;
  for (var row = y0; row < y1; row++) {
    final base = row * gray.width;
    for (var col = x0; col < x1; col++) {
      if (gray.pixels[base + col] < darkThreshold) dark++;
    }
  }
  return dark / ((x1 - x0) * (y1 - y0));
}

/// Indices ordered by value, largest first, ties keeping their original order
/// (Python's `sorted(..., key=lambda kv: -kv[1])` is stable).
List<int> _byValueDescending(List<double> values) {
  final order = List<int>.generate(values.length, (i) => i);
  for (var i = 1; i < order.length; i++) {
    final item = order[i];
    var j = i - 1;
    while (j >= 0 && values[order[j]] < values[item]) {
      order[j + 1] = order[j];
      j--;
    }
    order[j + 1] = item;
  }
  return order;
}

List<double> _adjustedOptionRatios(List<double> ratios, List<double>? baselines) {
  final normalized = [
    for (var j = 0; j < ratios.length; j++) ratios[j] - (baselines?[j] ?? 0.0),
  ];
  final rowBaseline = normalized.reduce(math.min);
  return [for (final v in normalized) math.max(0.0, v - rowBaseline)];
}

/// `decide_answer`: the marked option, `BLANK`, or `MULTIPLE`.
String decideAnswer(
  List<double> ratios, [
  List<double>? baselines,
  double blank = adjBlankThreshold,
  double multi = adjMultiRatio,
]) {
  final adjusted = _adjustedOptionRatios(ratios, baselines);
  final order = _byValueDescending(adjusted);
  final topValue = adjusted[order[0]];
  final secondValue = adjusted[order[1]];

  if (topValue < blank) {
    // Option normalisation can subtract most of a very faint mark when the
    // whole row is darker than the rest of the page; keep one that the plain
    // within-row comparison finds unambiguously.
    if (baselines != null) {
      final legacy = decideAnswer(ratios, null, blank, multi);
      if (legacy.length == 1 && options.contains(legacy)) return legacy;
    }
    return 'BLANK';
  }
  if (secondValue >= blank && secondValue >= multi * topValue) return 'MULTIPLE';
  return options[order[0]];
}

/// `answer_confidence`: strength and separation, for deciding what to review.
Map<String, Object?> answerConfidence(List<double> ratios, List<double>? baselines) {
  var adjusted = _adjustedOptionRatios(ratios, baselines)..sort((a, b) => b.compareTo(a));
  if (adjusted[0] < adjBlankThreshold && baselines != null) {
    final legacy = _adjustedOptionRatios(ratios, null)..sort((a, b) => b.compareTo(a));
    if (legacy[0] >= adjBlankThreshold &&
        !(legacy[1] >= adjBlankThreshold && legacy[1] >= adjMultiRatio * legacy[0])) {
      adjusted = legacy;
    }
  }
  final top = adjusted[0];
  final second = adjusted[1];
  return <String, Object?>{
    'mark_strength': pyRound(top, 4),
    'margin': pyRound(top - second, 4),
    'needs_review': top < adjBlankThreshold || (top > 0 && second >= adjMultiRatio * top),
  };
}
