import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/src/paper/gray_image.dart';
import 'package:datalink_core/src/paper/omr/omr.dart';
import 'package:datalink_core/src/paper/omr/template_match.dart';
import 'package:test/test.dart';

/// `tools/goldens/make_omr_goldens.py`: Python's bubble decisions and
/// OpenCV's template matching on synthetic inputs.
void main() {
  final data = jsonDecode(utf8.decode(gzip.decode(File('test/goldens/omr.json.gz').readAsBytesSync())))
      as Map<String, Object?>;

  test('bubble decisions and confidences match Python', () {
    final rows = (data['decisions']! as List).cast<Map<String, Object?>>();
    expect(rows.length, 4000);
    for (final row in rows) {
      final ratios = (row['ratios']! as List).cast<num>().map((v) => v.toDouble()).toList();
      final baselines = (row['baselines'] as List?)?.cast<num>().map((v) => v.toDouble()).toList();
      expect(decideAnswer(ratios, baselines), row['answer'], reason: '$row');
      expect(answerConfidence(ratios, baselines), row['confidence'], reason: '$row');
    }
  });

  group('template matching finds the peak OpenCV does', () {
    final cases = (data['matches']! as List).cast<Map<String, Object?>>();
    GrayImage picture(Map<String, Object?> map) => GrayImage(
          map['width']! as int,
          map['height']! as int,
          Uint8List.fromList((map['data']! as List).cast<int>()),
        );
    for (var i = 0; i < cases.length; i++) {
      test('case $i', () {
        final c = cases[i];
        final matcher = TemplateMatcher(picture(c['template']! as Map<String, Object?>), levels: 2);
        final match = matcher.best(picture(c['image']! as Map<String, Object?>))!;
        expect([match.x, match.y], [c['x'], c['y']]);
        expect(match.score, closeTo((c['score']! as num).toDouble(), 1e-4)); // OpenCV works in float32 via an FFT
      });
    }

    test('a template larger than the picture does not match', () {
      final matcher = TemplateMatcher(GrayImage(40, 40), levels: 1);
      expect(matcher.best(GrayImage(30, 80)), isNull);
    });
  });

  group('page helpers', () {
    test('a nearly white page is blank, a busy one is not', () {
      expect(isBlankPage(GrayImage(100, 100, Uint8List(10000)..fillRange(0, 10000, 255))), isTrue);
      final busy = GrayImage(100, 100, Uint8List(10000)..fillRange(0, 10000, 255));
      for (var i = 0; i < 300; i++) {
        busy.pixels[i] = 0;
      }
      expect(isBlankPage(busy), isFalse);
    });

    test('ink ratio counts pixels under the threshold and clips at the edges', () {
      final page = GrayImage(40, 40, Uint8List(1600)..fillRange(0, 1600, 255));
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 10; x++) {
          page.pixels[y * 40 + x] = 100;
        }
      }
      // A 20x20 window at (5,5) reaches (-5..15): clipped to 0..15, so 15x15 with 10x10 dark.
      expect(sampleInkRatio(page, 5, 5, radius: 10), closeTo(100 / 225, 1e-12));
      expect(sampleInkRatio(page, -100, -100, radius: 5), 0.0);
    });

    test('rotations are the OpenCV ones', () {
      final page = GrayImage(3, 2, Uint8List.fromList([1, 2, 3, 4, 5, 6]));
      expect(page.rotated90CounterClockwise().pixels, [3, 6, 2, 5, 1, 4]);
      expect(page.rotated90Clockwise().pixels, [4, 1, 5, 2, 6, 3]);
      expect(page.rotated180().pixels, [6, 5, 4, 3, 2, 1]);
    });
  });
}
