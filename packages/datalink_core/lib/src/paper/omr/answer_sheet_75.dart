/// The printable 75-question answer sheet: where everything on it is, and how
/// to read a scan of it.
///
/// The sheet is printed from `app/assets/answer_sheet_75.pdf`, made by
/// omr_final's `make_answer_sheet.py`; the positions below mirror its
/// `answer_sheet_layout.py`, and `test/answer_sheet_75_test.dart` reads marks
/// drawn onto a rendering of that PDF to keep the two together.
///
/// Unlike the AccuScan form, nothing here was measured from a scan. The four
/// solid corner squares are found, the page is warped onto the printed
/// layout, and every bubble is then at a known place.
library;

import 'dart:math' as math;

import '../gray_image.dart';
import 'omr.dart';

const String customFormName = 'custom75';
const int customQuestionCount = 75;
const int customIdDigits = 6;
const String customVersions = '1234';

// Inches from the top-left corner of a US Letter page.
const double _pageWidth = 8.5;
const double _pageHeight = 11.0;

const double _fiducialSize = 0.30;
const Map<String, (double, double)> _fiducials = {
  'tl': (0.60, 0.60),
  'tr': (7.90, 0.60),
  'bl': (0.60, 10.40),
  'br': (7.90, 10.40),
};

// The strip along the bottom edge that names the form and says which way up
// it was fed: '1' printed solid, '0' left empty.
const String _formCode = '11010011';
const double _formCodeX0 = 2.00;
const double _formCodePitch = 0.25;
const double _formCodeY = 10.40;
const double _formCodeSize = 0.14;

// Sample inside the outline, excluding the printed letter at the centre.
const double _sampleRadius = 0.065;

const double _versionX0 = 3.55;
const double _versionPitch = 0.32;
const double _versionY = 2.60;
const (double, double) _keyBubble = (0.90, 3.40);

const double _idX0 = 5.55;
const double _idPitch = 0.36;
const double _idRow0Y = 1.65;
const double _idRowPitch = 0.215;

const double _answerRow0Y = 4.32;
const double _answerRowPitch = 0.235;
const int _rowsPerColumn = 25;
const List<double> _answerBlockX0 = [0.70, 3.20, 5.70];
const double _answerBubbleDx = 0.62;
const double _answerBubblePitch = 0.32;

/// The page is straightened onto a grid at this resolution.
const int canonicalDpi = 200;
const int _canonWidth = 1700; // 8.5 in
const int _canonHeight = 2200; // 11 in

/// Scanned toner and pencil can be grey after copier/scanner resampling.
/// Pair this with a minimum filled area so printed detail is not a mark.
const int customDarkThreshold = 190;
const double _minimumFill = 0.18;
const int _registrationThreshold = 190;
const int _sampleInnerRadius = 7; // 0.035 inches at 200 dpi.

/// Fill fraction that marks the single ANSWER KEY bubble, which has no
/// neighbours in a row to be compared with.
const double keyMarkThreshold = 0.35;

/// Bubble centres in inches, for question 1-75: option index -> (x, y).
List<(double, double)> answerBubbles(int question) {
  if (question < 1 || question > customQuestionCount) {
    throw RangeError.range(question, 1, customQuestionCount, 'question');
  }
  final block = (question - 1) ~/ _rowsPerColumn;
  final row = (question - 1) % _rowsPerColumn;
  final x0 = _answerBlockX0[block] + _answerBubbleDx;
  final y = _answerRow0Y + row * _answerRowPitch;
  return [for (var i = 0; i < 5; i++) (x0 + i * _answerBubblePitch, y)];
}

/// Digit -> (x, y) for ID column 0-5.
List<(double, double)> idBubbles(int column) {
  final x = _idX0 + column * _idPitch;
  return [for (var d = 0; d < 10; d++) (x, _idRow0Y + d * _idRowPitch)];
}

List<(double, double)> versionBubbles() =>
    [for (var i = 0; i < customVersions.length; i++) (_versionX0 + i * _versionPitch, _versionY)];

(double, double) get keyBubble => _keyBubble;

List<(double, double)> formCodeCenters() =>
    [for (var i = 0; i < _formCode.length; i++) (_formCodeX0 + i * _formCodePitch, _formCodeY)];

String get formCode => _formCode;
double get formCodeSize => _formCodeSize;
double get fiducialSize => _fiducialSize;
Map<String, (double, double)> get fiducialCenters => _fiducials;

// ------------------------------------------------------------ finding it

/// Averages [factor] x [factor] blocks: a 400 dpi page becomes 200 dpi.
GrayImage _shrink(GrayImage gray, int factor) {
  if (factor <= 1) return gray;
  final w = gray.width ~/ factor;
  final h = gray.height ~/ factor;
  final out = GrayImage(w, h);
  final area = factor * factor;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var sum = 0;
      for (var dy = 0; dy < factor; dy++) {
        final base = (y * factor + dy) * gray.width + x * factor;
        for (var dx = 0; dx < factor; dx++) {
          sum += gray.pixels[base + dx];
        }
      }
      out.pixels[y * w + x] = sum ~/ area;
    }
  }
  return out;
}

/// Summed-area table of dark pixels, one row and column larger than the image.
class _DarkSums {
  _DarkSums(GrayImage gray, int threshold)
      : width = gray.width,
        height = gray.height,
        _sums = List<int>.filled((gray.width + 1) * (gray.height + 1), 0) {
    final stride = width + 1;
    for (var y = 0; y < height; y++) {
      var row = 0;
      for (var x = 0; x < width; x++) {
        if (gray.pixels[y * width + x] < threshold) row++;
        _sums[(y + 1) * stride + x + 1] = _sums[y * stride + x + 1] + row;
      }
    }
  }

  final int width;
  final int height;
  final List<int> _sums;

  /// Dark pixels in [x0, x1) x [y0, y1), clipped to the image.
  int count(int x0, int y0, int x1, int y1) {
    x0 = x0.clamp(0, width);
    x1 = x1.clamp(0, width);
    y0 = y0.clamp(0, height);
    y1 = y1.clamp(0, height);
    if (x1 <= x0 || y1 <= y0) return 0;
    final stride = width + 1;
    return _sums[y1 * stride + x1] - _sums[y0 * stride + x1] - _sums[y1 * stride + x0] + _sums[y0 * stride + x0];
  }
}

/// The centre of the solid square nearest each page corner, in pixels of
/// [gray]; null unless all four are found.
Map<String, (double, double)>? _findFiducials(GrayImage gray, double dpi) {
  final sums = _DarkSums(gray, _registrationThreshold);
  final side = (_fiducialSize * dpi).round();
  final ring = (0.50 * dpi).round();
  final reach = (1.6 * dpi).round();
  final found = <String, (double, double)>{};
  final windows = {
    'tl': (0, 0),
    'tr': (gray.width - reach, 0),
    'bl': (0, gray.height - reach),
    'br': (gray.width - reach, gray.height - reach),
  };
  for (final MapEntry(key: name, value: (wx, wy)) in windows.entries) {
    final margin = (ring - side) ~/ 2;
    var best = 0.0;
    var bestX = 0;
    var bestY = 0;
    for (var y = math.max(0, wy); y + side <= math.min(gray.height, wy + reach); y++) {
      for (var x = math.max(0, wx); x + side <= math.min(gray.width, wx + reach); x++) {
        final inner = sums.count(x, y, x + side, y + side);
        final fill = inner / (side * side);
        if (fill <= best || fill < 0.80) continue;
        // A square, not part of something larger such as the dark edge of
        // the scanner lid: the band around it is mostly paper.
        final outer = sums.count(x - margin, y - margin, x + side + margin, y + side + margin);
        if ((outer - inner) / (ring * ring - side * side) > 0.25) continue;
        best = fill;
        bestX = x;
        bestY = y;
      }
    }
    if (best == 0) return null;
    final rx0 = bestX - margin;
    final ry0 = bestY - margin;

    // Centroid of the dark pixels around it, for sub-pixel accuracy.
    var sx = 0.0;
    var sy = 0.0;
    var n = 0;
    for (var y = math.max(0, ry0); y < math.min(gray.height, ry0 + ring); y++) {
      for (var x = math.max(0, rx0); x < math.min(gray.width, rx0 + ring); x++) {
        if (gray.pixels[y * gray.width + x] < _registrationThreshold) {
          sx += x + 0.5;
          sy += y + 0.5;
          n++;
        }
      }
    }
    found[name] = (sx / n, sy / n);
  }
  return found;
}

/// The projective map taking each of [from] onto the matching [to].
List<double> _homography(List<(double, double)> from, List<(double, double)> to) {
  final a = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final (x, y) = from[i];
    final (u, v) = to[i];
    a[2 * i].setAll(0, [x, y, 1, 0, 0, 0, -u * x, -u * y, u]);
    a[2 * i + 1].setAll(0, [0, 0, 0, x, y, 1, -v * x, -v * y, v]);
  }
  for (var col = 0; col < 8; col++) {
    var pivot = col;
    for (var row = col + 1; row < 8; row++) {
      if (a[row][col].abs() > a[pivot][col].abs()) pivot = row;
    }
    final swap = a[col];
    a[col] = a[pivot];
    a[pivot] = swap;
    for (var row = 0; row < 8; row++) {
      if (row == col) continue;
      final factor = a[row][col] / a[col][col];
      for (var k = col; k < 9; k++) {
        a[row][k] -= factor * a[col][k];
      }
    }
  }
  return [for (var i = 0; i < 8; i++) a[i][8] / a[i][i], 1.0];
}

/// Draws [gray] onto the canonical page through the corner squares.
GrayImage _warp(GrayImage gray, Map<String, (double, double)> fiducials) {
  const order = ['tl', 'tr', 'bl', 'br'];
  // Canonical pixel -> source pixel, so each output pixel is looked up once.
  final h = _homography(
    [for (final k in order) (_fiducials[k]!.$1 * canonicalDpi, _fiducials[k]!.$2 * canonicalDpi)],
    [for (final k in order) fiducials[k]!],
  );
  final out = GrayImage(_canonWidth, _canonHeight)..pixels.fillRange(0, _canonWidth * _canonHeight, 255);
  final w = gray.width;
  final src = gray.pixels;
  for (var y = 0; y < _canonHeight; y++) {
    for (var x = 0; x < _canonWidth; x++) {
      final cx = x + 0.5;
      final cy = y + 0.5;
      final d = h[6] * cx + h[7] * cy + h[8];
      final sx = (h[0] * cx + h[1] * cy + h[2]) / d - 0.5;
      final sy = (h[3] * cx + h[4] * cy + h[5]) / d - 0.5;
      final x0 = sx.floor();
      final y0 = sy.floor();
      if (x0 < 0 || y0 < 0 || x0 + 1 >= w || y0 + 1 >= gray.height) continue;
      final fx = sx - x0;
      final fy = sy - y0;
      final i = y0 * w + x0;
      final top = src[i] + (src[i + 1] - src[i]) * fx;
      final bottom = src[i + w] + (src[i + w + 1] - src[i + w]) * fx;
      out.pixels[y * _canonWidth + x] = (top + (bottom - top) * fy).round();
    }
  }
  return out;
}

/// Every printable form shares the corner squares, header and code-strip
/// position; the strip's pattern says which form a page is.
const Map<String, String> printedFormCodes = {
  customFormName: _formCode,
  'vocab20': '10110011',
  'match65': '11001101',
};

double _formCodeScore(GrayImage canon, [String code = _formCode]) {
  final half = (_formCodeSize * canonicalDpi * 0.35).round();
  var hits = 0;
  final centers = formCodeCenters();
  for (var i = 0; i < code.length; i++) {
    final px = (centers[i].$1 * canonicalDpi).round();
    final py = (centers[i].$2 * canonicalDpi).round();
    var sum = 0;
    var n = 0;
    for (var y = py - half; y < py + half; y++) {
      for (var x = px - half; x < px + half; x++) {
        sum += canon.at(x, y);
        n++;
      }
    }
    final dark = sum / n < _registrationThreshold;
    if (dark == (code[i] == '1')) hits++;
  }
  return hits / code.length;
}

/// The page straightened onto the printed layout, the rotation that took,
/// and how well the form code matched (always 1.0: anything less is not
/// this form). Null when the page is not this form.
(GrayImage, int, double)? locateCustomSheet(GrayImage gray) {
  final found = locatePrintedSheet(gray);
  return found == null || found.$4 != customFormName ? null : (found.$1, found.$2, found.$3);
}

/// Any printable form: the page straightened onto its layout, the rotation
/// that took, the code-strip confidence, and which form it is.
(GrayImage, int, double, String)? locatePrintedSheet(GrayImage gray) {
  var angle = 0;
  if (gray.width > gray.height) {
    gray = gray.rotated90Clockwise();
    angle = 90;
  }
  final factor = math.max(1, (gray.height / _pageHeight / canonicalDpi).round());
  final small = _shrink(gray, factor);
  final dpi = small.height / _pageHeight;
  // A page that is not roughly Letter-shaped cannot be this form.
  if ((small.width / dpi - _pageWidth).abs() > 0.6) return null;
  final fiducials = _findFiducials(small, dpi);
  if (fiducials == null) return null;
  final canon = _warp(small, fiducials);
  final flipped = canon.rotated180();
  for (final MapEntry(key: form, value: code) in printedFormCodes.entries) {
    if (_formCodeScore(canon, code) == 1.0) return (canon, angle, 1.0, form);
    if (_formCodeScore(flipped, code) == 1.0) return (flipped, (angle + 180) % 360, 1.0, form);
  }
  return null;
}

// -------------------------------------------------------------- reading it

final int _sampleR = (_sampleRadius * canonicalDpi).round();

/// Fraction of dark pixels in the inner annulus at (x, y) inches.
double sampleCustomBubble(GrayImage canon, double xIn, double yIn) {
  final px = (xIn * canonicalDpi).round();
  final py = (yIn * canonicalDpi).round();
  final r = _sampleR;
  var dark = 0;
  var n = 0;
  for (var dy = -r; dy <= r; dy++) {
    for (var dx = -r; dx <= r; dx++) {
      final distance = dx * dx + dy * dy;
      if (distance > r * r || distance < _sampleInnerRadius * _sampleInnerRadius) continue;
      final x = px + dx;
      final y = py + dy;
      if (x < 0 || y < 0 || x >= canon.width || y >= canon.height) return 0.0;
      if (canon.pixels[y * canon.width + x] < customDarkThreshold) dark++;
      n++;
    }
  }
  return dark / n;
}

/// One choice from a row of bubbles: its index, -1 for none, -2 for several.
/// `decide_answer` without per-option baselines.
int _decideGroup(List<double> ratios) {
  final baseline = ratios.reduce(math.min);
  final adjusted = [for (final v in ratios) v - baseline];
  var top = 0;
  for (var i = 1; i < adjusted.length; i++) {
    if (adjusted[i] > adjusted[top]) top = i;
  }
  var second = -1.0;
  for (var i = 0; i < adjusted.length; i++) {
    if (i != top && adjusted[i] > second) second = adjusted[i];
  }
  if (adjusted[top] < _minimumFill) return -1;
  if (second >= _minimumFill && second >= adjMultiRatio * adjusted[top]) return -2;
  return top;
}

String _groupLetter(int choice, String names) => switch (choice) {
      -1 => '_',
      -2 => '?',
      _ => names[choice],
    };

SheetExtraction extractCustomSheet(GrayImage canon, int angle, double confidence, {bool scanStudentId = true}) {
  final raw = <int, List<double>>{
    for (var q = 1; q <= customQuestionCount; q++)
      q: [for (final (x, y) in answerBubbles(q)) sampleCustomBubble(canon, x, y)],
  };
  final baselines = [
    for (var j = 0; j < 5; j++) raw.values.map((row) => row[j]).reduce(math.min),
  ];
  final answers = <int, String>{};
  final confidences = <int, Map<String, Object?>>{};
  final marks = <int, String>{};
  for (final entry in raw.entries) {
    answers[entry.key] = decideAnswer(entry.value, baselines, _minimumFill);
    confidences[entry.key] = answerConfidence(entry.value, baselines);
    if (answers[entry.key] == 'MULTIPLE') {
      marks[entry.key] = markedOptions(entry.value, baselines, _minimumFill);
    }
    if (answers[entry.key] == 'BLANK' || answers[entry.key] == 'MULTIPLE') {
      confidences[entry.key]!['needs_review'] = true;
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
      'form': customFormName,
      'orientation_angle': angle,
      'form_code_confidence': confidence,
    },
    form: customFormName,
    isKey: header.isKey,
    version: header.version,
    versionRead: header.versionRead,
    marks: marks,
  );
}

/// The student ID, version and ANSWER KEY bubble, which every printable form
/// carries in the same place.
({String? studentId, bool isKey, String? version, String versionRead}) readSheetHeader(
  GrayImage canon, {
  bool scanStudentId = true,
}) {
  String? studentId;
  if (scanStudentId) {
    final digits = StringBuffer();
    for (var column = 0; column < customIdDigits; column++) {
      final ratios = [for (final (x, y) in idBubbles(column)) sampleCustomBubble(canon, x, y)];
      digits.write(_groupLetter(_decideGroup(ratios), '0123456789'));
    }
    studentId = digits.toString();
  }
  final versionRatios = [for (final (x, y) in versionBubbles()) sampleCustomBubble(canon, x, y)];
  final versionRead = _groupLetter(_decideGroup(versionRatios), customVersions);
  final keyMark = sampleCustomBubble(canon, _keyBubble.$1, _keyBubble.$2);
  return (
    studentId: studentId,
    isKey: keyMark >= keyMarkThreshold,
    version: customVersions.contains(versionRead) ? versionRead : null,
    versionRead: versionRead,
  );
}

/// One row of [letters] bubbles, judged against itself: the marked letter,
/// `BLANK`, or `MULTIPLE` with the letters behind it.
({String answer, String? marks}) decideLetterRow(List<double> ratios, String letters) {
  final baseline = ratios.reduce(math.min);
  final adjusted = [for (final v in ratios) v - baseline];
  final choice = _decideGroup(ratios);
  if (choice == -1) return (answer: 'BLANK', marks: null);
  if (choice >= 0) return (answer: letters[choice], marks: null);
  final top = adjusted.reduce(math.max);
  final floor = math.max(_minimumFill, adjMultiRatio * top);
  return (
    answer: 'MULTIPLE',
    marks: [for (var i = 0; i < adjusted.length; i++) if (adjusted[i] >= floor) letters[i]].join(),
  );
}

/// The fill a bubble needs before it counts as a mark, in this reader.
double get minimumFill => _minimumFill;
