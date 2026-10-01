/// Normalised cross-correlation of a template over a page, found
/// coarse-to-fine.
///
/// The Python reader asks OpenCV for `matchTemplate(..., TM_CCOEFF_NORMED)`
/// over the whole page, which OpenCV does with an FFT. Doing that directly
/// would cost about 10^12 operations a page here. What the reader uses is the
/// *best* score and where it is, so this finds the same peak by searching
/// every position on a picture reduced 16 times, then re-searching a few
/// pixels around each promising peak at each finer scale, ending at full
/// size. The final score is the exact full-size correlation at the peak, so
/// it agrees with OpenCV's to float precision whenever the peak is found.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../gray_image.dart';

/// Where the template fits best, and how well.
class TemplateMatch {
  const TemplateMatch(this.score, this.x, this.y);
  final double score;
  final int x;
  final int y;

  @override
  String toString() => 'TemplateMatch($score at $x,$y)';
}

class _Level {
  _Level(this.width, this.height, this.data);
  final int width;
  final int height;
  final Float32List data;
}

_Level _fromGray(GrayImage image) {
  final data = Float32List(image.pixels.length);
  for (var i = 0; i < data.length; i++) {
    data[i] = image.pixels[i].toDouble();
  }
  return _Level(image.width, image.height, data);
}

/// Halves a picture by averaging 2x2 blocks (an odd last row/column is dropped).
_Level _halve(_Level level) {
  final w = level.width ~/ 2;
  final h = level.height ~/ 2;
  final out = Float32List(w * h);
  final src = level.data;
  final sw = level.width;
  for (var y = 0; y < h; y++) {
    final r0 = 2 * y * sw;
    final r1 = r0 + sw;
    for (var x = 0; x < w; x++) {
      out[y * w + x] = (src[r0 + 2 * x] + src[r0 + 2 * x + 1] + src[r1 + 2 * x] + src[r1 + 2 * x + 1]) * 0.25;
    }
  }
  return _Level(w, h, out);
}

/// A picture at full size and each halving of it.
class ImagePyramid {
  ImagePyramid._(this._levels);
  final List<_Level> _levels;
}

/// A template, reduced and zero-meaned at each scale, ready to be searched for.
class TemplateMatcher {
  TemplateMatcher(GrayImage template, {this.levels = 4}) {
    var level = _fromGray(template);
    for (var i = 0; i <= levels; i++) {
      _templates.add(_Prepared(level));
      if (i < levels) level = _halve(level);
    }
  }

  /// How many halvings the coarse search is done after.
  final int levels;
  final List<_Prepared> _templates = [];

  int get width => _templates.first.level.width;
  int get height => _templates.first.level.height;

  /// A pyramid of [image], full size first.
  ImagePyramid pyramid(GrayImage image) {
    final out = <_Level>[_fromGray(image)];
    for (var i = 0; i < levels; i++) {
      out.add(_halve(out.last));
    }
    return ImagePyramid._(out);
  }

  /// The best match of the template in [image], or null if the template does
  /// not fit inside it. [candidates] peaks of the coarse search are followed
  /// down to full size.
  TemplateMatch? best(GrayImage image, {int candidates = 3}) {
    if (image.width < width || image.height < height) return null;
    return bestIn(pyramid(image), candidates: candidates);
  }

  /// As [best], on a pyramid already built by [pyramid].
  TemplateMatch? bestIn(ImagePyramid built, {int candidates = 3}) {
    final pyr = built._levels;
    final top = pyr[levels];
    final topTemplate = _templates[levels];
    final tw = topTemplate.level.width;
    final th = topTemplate.level.height;
    if (top.width < tw || top.height < th || tw < 4 || th < 4) {
      // Too small to reduce: search the full-size picture, slowly but correctly.
      return _exhaustive(pyr.first, _templates.first);
    }
    final rangeX = top.width - tw + 1;
    final rangeY = top.height - th + 1;
    final scores = Float32List(rangeX * rangeY);
    final sums = _WindowSums(top);
    for (var y = 0; y < rangeY; y++) {
      for (var x = 0; x < rangeX; x++) {
        scores[y * rangeX + x] = _score(top, topTemplate, x, y, sums);
      }
    }
    final peaks = _topPeaks(scores, rangeX, rangeY, candidates, 3);
    TemplateMatch? best;
    for (final (px, py) in peaks) {
      var x = px;
      var y = py;
      var score = scores[py * rangeX + px].toDouble();
      for (var level = levels - 1; level >= 0; level--) {
        final image = pyr[level];
        final template = _templates[level];
        final maxX = image.width - template.level.width;
        final maxY = image.height - template.level.height;
        var bestScore = -2.0;
        var bx = math.min(math.max(2 * x, 0), maxX);
        var by = math.min(math.max(2 * y, 0), maxY);
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            final cx = 2 * x + dx;
            final cy = 2 * y + dy;
            if (cx < 0 || cy < 0 || cx > maxX || cy > maxY) continue;
            final s = _score(image, template, cx, cy, null);
            if (s > bestScore) {
              bestScore = s;
              bx = cx;
              by = cy;
            }
          }
        }
        x = bx;
        y = by;
        score = bestScore;
      }
      if (best == null || score > best.score) best = TemplateMatch(score, x, y);
    }
    return best;
  }

  TemplateMatch? _exhaustive(_Level image, _Prepared template) {
    TemplateMatch? best;
    for (var y = 0; y <= image.height - template.level.height; y++) {
      for (var x = 0; x <= image.width - template.level.width; x++) {
        final s = _score(image, template, x, y, null);
        if (best == null || s > best.score) best = TemplateMatch(s, x, y);
      }
    }
    return best;
  }

  /// `TM_CCOEFF_NORMED` of [template] placed with its corner at (x, y).
  double _score(_Level image, _Prepared template, int x, int y, _WindowSums? sums) {
    final tw = template.level.width;
    final th = template.level.height;
    final t = template.centred;
    final data = image.data;
    final stride = image.width;
    var dot = 0.0;
    var sum = 0.0;
    var sumSquares = 0.0;
    if (sums != null) {
      sum = sums.sum(x, y, tw, th);
      sumSquares = sums.sumSquares(x, y, tw, th);
      for (var ty = 0; ty < th; ty++) {
        var p = (y + ty) * stride + x;
        var q = ty * tw;
        final end = q + tw;
        while (q < end) {
          dot += data[p++] * t[q++];
        }
      }
    } else {
      for (var ty = 0; ty < th; ty++) {
        var p = (y + ty) * stride + x;
        var q = ty * tw;
        final end = q + tw;
        while (q < end) {
          final v = data[p++];
          dot += v * t[q++];
          sum += v;
          sumSquares += v * v;
        }
      }
    }
    final n = tw * th;
    final variance = sumSquares - sum * sum / n;
    final denominator = math.sqrt(math.max(variance, 0) * template.energy);
    if (denominator < 1e-7) return 0;
    return dot / denominator;
  }

  static List<(int, int)> _topPeaks(Float32List scores, int w, int h, int count, int radius) {
    final order = List<int>.generate(scores.length, (i) => i)
      ..sort((a, b) => scores[b].compareTo(scores[a]));
    final chosen = <(int, int)>[];
    for (final index in order) {
      final x = index % w;
      final y = index ~/ w;
      var near = false;
      for (final (cx, cy) in chosen) {
        if ((cx - x).abs() <= radius && (cy - y).abs() <= radius) {
          near = true;
          break;
        }
      }
      if (near) continue;
      chosen.add((x, y));
      if (chosen.length == count) break;
    }
    return chosen;
  }
}

class _Prepared {
  _Prepared(this.level) {
    final n = level.data.length;
    var sum = 0.0;
    for (final v in level.data) {
      sum += v;
    }
    final mean = sum / n;
    centred = Float32List(n);
    var energy = 0.0;
    for (var i = 0; i < n; i++) {
      final v = level.data[i] - mean;
      centred[i] = v;
      energy += v * v;
    }
    this.energy = energy;
  }

  final _Level level;
  late final Float32List centred;
  late final double energy;
}

/// Integral images, for the sum and sum of squares of any window.
class _WindowSums {
  _WindowSums(_Level level)
      : _stride = level.width + 1,
        _sums = Float64List((level.width + 1) * (level.height + 1)),
        _squares = Float64List((level.width + 1) * (level.height + 1)) {
    final w = level.width;
    for (var y = 0; y < level.height; y++) {
      var rowSum = 0.0;
      var rowSquares = 0.0;
      for (var x = 0; x < w; x++) {
        final v = level.data[y * w + x];
        rowSum += v;
        rowSquares += v * v;
        _sums[(y + 1) * _stride + x + 1] = _sums[y * _stride + x + 1] + rowSum;
        _squares[(y + 1) * _stride + x + 1] = _squares[y * _stride + x + 1] + rowSquares;
      }
    }
  }

  final int _stride;
  final Float64List _sums;
  final Float64List _squares;

  double _window(Float64List table, int x, int y, int w, int h) =>
      table[(y + h) * _stride + x + w] - table[y * _stride + x + w] - table[(y + h) * _stride + x] + table[y * _stride + x];

  double sum(int x, int y, int w, int h) => _window(_sums, x, y, w, h);
  double sumSquares(int x, int y, int w, int h) => _window(_squares, x, y, w, h);
}
