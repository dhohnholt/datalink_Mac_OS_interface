/// Drawing a scanned page: find its picture and resample it onto the pixel
/// grid poppler would have produced at 400 dpi.
///
/// The OMR constants (bubble positions, thresholds) were measured on
/// poppler's output, so this does not use a general renderer. A system
/// renderer resamples the embedded 200 ppi picture differently, and on faint
/// marks that is enough to change an answer (measured against the real
/// batches: 18 answers changed without being flagged, against 4 with this).
///
/// How poppler resamples, as measured against `pdftoppm` output:
///
/// * Enlarging a picture is bilinear with the corners pinned: source
///   coordinate `x * (sw - 1) / (dw - 1)`, where `dw` is the page width
///   rounded down.
/// * Shrinking averages whole source pixels: each output pixel takes
///   `sw ~/ dw` of them, or one more when the running remainder overflows
///   (Bresenham), and divides with a fixed-point reciprocal.
///
/// A page that is more than one picture covering the sheet (visible text,
/// drawing, a picture placed in part of the page, a rotated one) is refused
/// with [PdfUnsupported] rather than drawn wrongly.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../gray_image.dart';
import 'pdf_document.dart';

/// Poppler's resolution when the OMR calibration was measured.
const int scanDpi = 400;

/// The picture that makes up a page, and where it sits.
class PageScan {
  const PageScan(this.image, this.ctm);
  final PdfStream image;
  final List<double> ctm;
}

List<double> _multiply(List<double> m, List<double> n) => [
      m[0] * n[0] + m[1] * n[2],
      m[0] * n[1] + m[1] * n[3],
      m[2] * n[0] + m[3] * n[2],
      m[2] * n[1] + m[3] * n[3],
      m[4] * n[0] + m[5] * n[2] + n[4],
      m[4] * n[1] + m[5] * n[3] + n[5],
    ];

/// Finds the single picture on [page], or says why the page is not a scan.
PageScan findPageScan(PdfPage page) {
  final doc = page.document;
  final lexer = PdfLexer(page.content());
  final stack = <(List<double>, int)>[];
  var ctm = <double>[1, 0, 0, 1, 0, 0];
  var renderMode = 0;
  final operands = <Object?>[];
  PdfStream? found;
  List<double>? foundCtm;

  final xobjects = doc.resolve(page.resources['XObject']);

  PdfUnsupported notAScan(String why) => PdfUnsupported(
        'Page contents are not a plain scan ($why), so this reader cannot '
        'read it. Scan the sheets again to a PDF with a document scanner.',
      );

  while (!lexer.atEnd) {
    final token = lexer.read(allowRefs: false);
    if (token is! PdfKeyword) {
      operands.add(token);
      continue;
    }
    final op = token.value;
    switch (op) {
      case 'q':
        stack.add((ctm, renderMode));
      case 'Q':
        if (stack.isNotEmpty) {
          final saved = stack.removeLast();
          ctm = saved.$1;
          renderMode = saved.$2;
        }
      case 'cm':
        if (operands.length >= 6) {
          final m = [for (final v in operands.sublist(operands.length - 6)) (v as num).toDouble()];
          ctm = _multiply(m, ctm);
        }
      case 'Tr':
        if (operands.isNotEmpty && operands.last is num) renderMode = (operands.last as num).toInt();
      case 'Do':
        final name = operands.isNotEmpty ? operands.last : null;
        if (name is! PdfName || xobjects is! Map<String, Object?>) throw notAScan('missing picture');
        final xobject = doc.resolve(xobjects[name.value]);
        if (xobject is! PdfStream) throw notAScan('missing picture');
        if (doc.resolve(xobject.dict['Subtype']) != const PdfName('Image')) {
          throw notAScan('it draws a form');
        }
        if (found != null) throw notAScan('more than one picture');
        found = xobject;
        foundCtm = ctm;
      case 'Tj' || 'TJ' || "'" || '"':
        if (renderMode != 3) throw notAScan('visible text');
      case 'f' || 'F' || 'f*' || 'S' || 's' || 'B' || 'B*' || 'b' || 'b*' || 'sh':
        throw notAScan('drawn shapes');
      case 'W' || 'W*':
        throw notAScan('clipping');
      case 'BI':
        throw notAScan('an inline picture');
    }
    operands.clear();
  }
  if (found == null || foundCtm == null) throw notAScan('no picture');
  return PageScan(found, foundCtm);
}

/// Output size at [dpi]: poppler rounds a page up to whole pixels.
(int, int) renderedSize(PdfPage page, int dpi) {
  var w = (page.width * dpi / 72).ceil();
  var h = (page.height * dpi / 72).ceil();
  // A tiny float error must not add a pixel: 433 * 400 / 72 is 2405.56, but
  // 432 * 400 / 72 is exactly 2400 and must stay so.
  final exactW = page.width * dpi / 72;
  final exactH = page.height * dpi / 72;
  if ((exactW - exactW.round()).abs() < 1e-9) w = exactW.round();
  if ((exactH - exactH.round()).abs() < 1e-9) h = exactH.round();
  return (w, h);
}

/// Draws [page] at [dpi], as poppler would, in grayscale.
GrayImage renderScanPage(PdfPage page, {int dpi = scanDpi}) {
  final scan = findPageScan(page);
  final m = scan.ctm;
  final width = page.width;
  final height = page.height;
  final upright = m[1].abs() < 1e-6 && m[2].abs() < 1e-6 && m[0] > 0 && m[3] > 0;
  final covers = (m[4] - page.mediaBox[0]).abs() < 2 &&
      (m[5] - page.mediaBox[1]).abs() < 2 &&
      (m[0] - width).abs() < 2 &&
      (m[3] - height).abs() < 2;
  if (!upright || !covers) {
    throw const PdfUnsupported(
      'The picture on this page does not fill the sheet the way a document '
      "scanner's does, so this reader cannot read it.",
    );
  }
  final picture = loadImageGray(page.document, scan.image);
  final (dw, dh) = renderedSize(page, dpi);
  // How big poppler draws the picture, which is not always the output size:
  // one being enlarged is scaled to the page's size rounded down, one being
  // reduced (or a black-and-white one) to that size plus one. The output is
  // then cut, or padded by repeating its last row and column, to fit.
  final bilevel = page.document.resolve(scan.image.dict['BitsPerComponent']) == 1;
  final floorW = (width * dpi / 72 + 1e-9).floor();
  final floorH = (height * dpi / 72 + 1e-9).floor();
  final sw = (bilevel || dw <= picture.width) ? floorW + 1 : floorW;
  final sh = (bilevel || dh <= picture.height) ? floorH + 1 : floorH;
  final scaled = resample(picture.pixels, picture.width, picture.height, sw, sh);
  final drawn = GrayImage(dw, dh);
  final copy = math.min(sw, dw);
  for (var y = 0; y < dh; y++) {
    final from = math.min(y, sh - 1) * sw;
    final to = y * dw;
    drawn.pixels.setRange(to, to + copy, scaled, from);
    for (var x = copy; x < dw; x++) {
      drawn.pixels[to + x] = scaled[from + sw - 1];
    }
  }
  return switch (page.rotate) {
    90 => drawn.rotated90Clockwise(),
    180 => drawn.rotated180(),
    270 => drawn.rotated90CounterClockwise(),
    _ => drawn,
  };
}

// ------------------------------------------------------------ resampling

/// Scales an 8-bit picture the way poppler's Splash does.
Uint8List resample(Uint8List src, int sw, int sh, int dw, int dh) {
  if (sw == dw && sh == dh) return Uint8List.fromList(src);
  if (dw <= sw && dh <= sh) return _boxDown(src, sw, sh, dw, dh);
  return _separable(src, sw, sh, dw, dh);
}

/// `Splash::scaleImageYdXd`: whole-pixel boxes, Bresenham spans.
Uint8List _boxDown(Uint8List src, int sw, int sh, int dw, int dh) {
  final out = Uint8List(dw * dh);
  final xp = sw ~/ dw;
  final xq = sw % dw;
  final yp = sh ~/ dh;
  final yq = sh % dh;
  // Column spans are the same for every row, so work them out once.
  final xStart = Int32List(dw);
  final xCount = Int32List(dw);
  var xt = 0;
  var xs = 0;
  for (var x = 0; x < dw; x++) {
    var step = xp;
    xt += xq;
    if (xt >= dw) {
      xt -= dw;
      step++;
    }
    xStart[x] = xs;
    xCount[x] = step;
    xs += step;
  }
  var yt = 0;
  var ys = 0;
  for (var y = 0; y < dh; y++) {
    var yStep = yp;
    yt += yq;
    if (yt >= dh) {
      yt -= dh;
      yStep++;
    }
    for (var x = 0; x < dw; x++) {
      final count = xCount[x] * yStep;
      var sum = 0;
      for (var row = ys; row < ys + yStep; row++) {
        final base = row * sw + xStart[x];
        for (var i = 0; i < xCount[x]; i++) {
          sum += src[base + i];
        }
      }
      final d = (1 << 23) ~/ count;
      out[y * dw + x] = (sum * d) >> 23;
    }
    ys += yStep;
  }
  return out;
}

/// Bilinear where a side grows, box average where it shrinks.
Uint8List _separable(Uint8List src, int sw, int sh, int dw, int dh) {
  final across = _Axis(sw, dw);
  final down = _Axis(sh, dh);
  final tmp = Float32List(sh * dw);
  for (var y = 0; y < sh; y++) {
    final row = y * sw;
    final outRow = y * dw;
    if (across.grow) {
      for (var x = 0; x < dw; x++) {
        final a = src[row + across.first[x]];
        final b = src[row + across.second[x]];
        tmp[outRow + x] = (a + (b - a) * across.fraction[x]).floorToDouble();
      }
    } else {
      for (var x = 0; x < dw; x++) {
        var sum = 0;
        final n = across.second[x];
        for (var i = 0; i < n; i++) {
          sum += src[row + across.first[x] + i];
        }
        tmp[outRow + x] = sum / n;
      }
    }
  }
  final out = Uint8List(dw * dh);
  for (var y = 0; y < dh; y++) {
    final outRow = y * dw;
    if (down.grow) {
      final r0 = down.first[y] * dw;
      final r1 = down.second[y] * dw;
      final f = down.fraction[y];
      for (var x = 0; x < dw; x++) {
        final a = tmp[r0 + x];
        final b = tmp[r1 + x];
        out[outRow + x] = (a + (b - a) * f).floor().clamp(0, 255);
      }
    } else {
      final n = down.second[y];
      for (var x = 0; x < dw; x++) {
        var sum = 0.0;
        for (var i = 0; i < n; i++) {
          sum += tmp[(down.first[y] + i) * dw + x];
        }
        out[outRow + x] = (sum / n).floor().clamp(0, 255);
      }
    }
  }
  return out;
}

/// How each output position along one axis draws on the source: two taps and
/// a fraction when the axis grows, or a start and a count when it shrinks.
class _Axis {
  _Axis(int length, int target)
      : grow = target > length,
        first = Int32List(target),
        second = Int32List(target),
        fraction = Float64List(target > length ? target : 0) {
    if (grow) {
      for (var x = 0; x < target; x++) {
        final position = target > 1 ? x * (length - 1) / (target - 1) : 0.0;
        final i = position.floor();
        first[x] = i;
        second[x] = math.min(i + 1, length - 1);
        fraction[x] = position - i;
      }
    } else {
      final p = length ~/ target;
      final q = length % target;
      var t = 0;
      var s = 0;
      for (var x = 0; x < target; x++) {
        var step = p;
        t += q;
        if (t >= target) {
          t -= target;
          step++;
        }
        first[x] = s;
        second[x] = step;
        s += step;
      }
    }
  }

  final bool grow;
  final Int32List first;

  /// The second tap when growing; the span length when shrinking.
  final Int32List second;
  final Float64List fraction;
}

// ---------------------------------------------------------- image decoding

/// cv2's gray: `(R*4899 + G*9617 + B*1868 + 8192) >> 14`.
int _luma(int r, int g, int b) => (r * 4899 + g * 9617 + b * 1868 + 8192) >> 14;

/// The picture in [stream], as grayscale the way `cv2.imread(..., GRAYSCALE)`
/// would have it from the rendered page.
GrayImage loadImageGray(PdfDocument doc, PdfStream stream) {
  final width = doc.resolve(stream.dict['Width']) as int;
  final height = doc.resolve(stream.dict['Height']) as int;
  if (width < 1 || height < 1 || width * height > 400000000) {
    throw const PdfUnsupported('The picture on this page has an unusable size.');
  }
  if (doc.resolve(stream.dict['ImageMask']) == true) {
    throw const PdfUnsupported('This PDF stores its pages as stencil masks, which are not supported.');
  }
  final decodeArray = doc.resolve(stream.dict['Decode']);
  final invert = decodeArray is List && decodeArray.length >= 2 &&
      (doc.resolve(decodeArray[0]) as num) > (doc.resolve(decodeArray[1]) as num);

  final (data, leftover) = doc.decodeStreamUpTo(stream);
  Uint8List gray;
  if (leftover == 'DCTDecode' || leftover == 'DCT') {
    gray = _jpegGray(data, width, height);
  } else if (leftover != null) {
    throw PdfUnsupported(
      'This PDF stores its pages with $leftover compression, which is not '
      'supported yet.',
    );
  } else {
    final bits = doc.resolve(stream.dict['BitsPerComponent']) as int? ?? 8;
    final space = _colorSpace(doc, doc.resolve(stream.dict['ColorSpace']));
    gray = _rawGray(data, width, height, bits, space);
  }
  if (invert) {
    for (var i = 0; i < gray.length; i++) {
      gray[i] = 255 - gray[i];
    }
  }
  return GrayImage(width, height, gray);
}

Uint8List _jpegGray(Uint8List data, int width, int height) {
  final decoded = img.decodeJpg(data);
  if (decoded == null) throw const PdfException('A page in this PDF has a damaged picture.');
  if (decoded.width != width || decoded.height != height) {
    throw const PdfException('A page in this PDF has a picture of the wrong size.');
  }
  final bytes = decoded.getBytes();
  final channels = decoded.numChannels;
  final out = Uint8List(width * height);
  switch (channels) {
    case 1:
      out.setRange(0, out.length, bytes);
    case 3:
      for (var i = 0, j = 0; i < out.length; i++, j += 3) {
        out[i] = _luma(bytes[j], bytes[j + 1], bytes[j + 2]);
      }
    case 4:
      for (var i = 0, j = 0; i < out.length; i++, j += 4) {
        out[i] = _luma(bytes[j], bytes[j + 1], bytes[j + 2]);
      }
    default:
      throw const PdfUnsupported('This PDF has a picture with an unsupported colour layout.');
  }
  return out;
}

class _Space {
  const _Space(this.components, [this.palette]);
  final int components;

  /// For Indexed: RGB triples, one per index.
  final Uint8List? palette;
}

_Space _colorSpace(PdfDocument doc, Object? space) {
  if (space is PdfName) {
    return switch (space.value) {
      'DeviceGray' || 'G' || 'CalGray' => const _Space(1),
      'DeviceRGB' || 'RGB' || 'CalRGB' => const _Space(3),
      'DeviceCMYK' || 'CMYK' => const _Space(4),
      _ => throw PdfUnsupported('This PDF uses the colour space ${space.value}, which is not supported.'),
    };
  }
  if (space is List && space.isNotEmpty) {
    final head = doc.resolve(space[0]);
    final name = head is PdfName ? head.value : '';
    switch (name) {
      case 'ICCBased':
        final profile = doc.resolve(space[1]);
        final n = profile is PdfStream ? doc.resolve(profile.dict['N']) : null;
        if (n is int && (n == 1 || n == 3 || n == 4)) return _Space(n);
        throw const PdfUnsupported('This PDF has an unusable colour profile.');
      case 'CalGray':
        return const _Space(1);
      case 'CalRGB':
        return const _Space(3);
      case 'Indexed' || 'I':
        final base = _colorSpace(doc, doc.resolve(space[1]));
        final hival = doc.resolve(space[2]) as int;
        final table = doc.resolve(space[3]);
        final raw = table is PdfString
            ? table.bytes
            : table is PdfStream
                ? doc.decodeStream(table)
                : Uint8List(0);
        final palette = Uint8List((hival + 1) * 3);
        for (var i = 0; i <= hival; i++) {
          final o = i * base.components;
          int at(int k) => o + k < raw.length ? raw[o + k] : 0;
          switch (base.components) {
            case 1:
              palette[i * 3] = palette[i * 3 + 1] = palette[i * 3 + 2] = at(0);
            case 3:
              palette[i * 3] = at(0);
              palette[i * 3 + 1] = at(1);
              palette[i * 3 + 2] = at(2);
            default:
              throw const PdfUnsupported('This PDF has an unsupported palette.');
          }
        }
        return _Space(1, palette);
    }
    throw PdfUnsupported('This PDF uses the colour space $name, which is not supported.');
  }
  throw const PdfUnsupported('This PDF has a picture without a colour space.');
}

Uint8List _rawGray(Uint8List data, int width, int height, int bits, _Space space) {
  final comps = space.components;
  if (bits != 1 && bits != 2 && bits != 4 && bits != 8) {
    throw PdfUnsupported('This PDF uses $bits-bit pictures, which are not supported.');
  }
  final rowBytes = (width * comps * bits + 7) ~/ 8;
  final out = Uint8List(width * height);
  final maxValue = (1 << bits) - 1;
  for (var y = 0; y < height; y++) {
    final base = y * rowBytes;
    int sample(int index) {
      if (bits == 8) {
        final at = base + index;
        return at < data.length ? data[at] : 255;
      }
      final bit = index * bits;
      final at = base + (bit >> 3);
      if (at >= data.length) return maxValue;
      return (data[at] >> (8 - bits - (bit & 7))) & maxValue;
    }

    for (var x = 0; x < width; x++) {
      int value;
      if (space.palette != null) {
        final index = math.min(sample(x), space.palette!.length ~/ 3 - 1);
        value = _luma(space.palette![index * 3], space.palette![index * 3 + 1], space.palette![index * 3 + 2]);
      } else if (comps == 1) {
        final s = sample(x);
        value = bits == 8 ? s : (s * 255 / maxValue).round();
      } else if (comps == 3) {
        int channel(int k) => bits == 8 ? sample(x * 3 + k) : (sample(x * 3 + k) * 255 / maxValue).round();
        value = _luma(channel(0), channel(1), channel(2));
      } else {
        int channel(int k) => bits == 8 ? sample(x * 4 + k) : (sample(x * 4 + k) * 255 / maxValue).round();
        final k = channel(3);
        value = _luma(
          (255 - channel(0)) * (255 - k) ~/ 255,
          (255 - channel(1)) * (255 - k) ~/ 255,
          (255 - channel(2)) * (255 - k) ~/ 255,
        );
      }
      out[y * width + x] = value;
    }
  }
  return out;
}
