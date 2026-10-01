import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/src/paper/pdf/pdf_document.dart';
import 'package:datalink_core/src/paper/pdf/pdf_scan.dart';
import 'package:test/test.dart';

/// Drawn by `tools/goldens/make_render_goldens.py` and rendered by poppler.
void main() {
  final directory = Directory('test/goldens/render');
  final manifest = (jsonDecode(File('${directory.path}/manifest.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  group('page rendering matches poppler', () {
    for (final entry in manifest) {
      final name = entry['name']! as String;
      for (final MapEntry(key: dpi, value: rendered) in (entry['renders']! as Map<String, Object?>).entries) {
        final info = rendered! as Map<String, Object?>;
        test('$name at $dpi dpi', () {
          final doc = PdfDocument.open(File('${directory.path}/$name.pdf').readAsBytesSync());
          expect(doc.pageCount, 1);
          final ours = renderScanPage(doc.pages.single, dpi: int.parse(dpi));
          final golden = gzip.decode(File('${directory.path}/${info['file']}').readAsBytesSync());
          expect([ours.width, ours.height], [info['width'], info['height']], reason: 'page size');
          var sum = 0;
          var worst = 0;
          for (var i = 0; i < golden.length; i++) {
            final d = (golden[i] - ours.pixels[i]).abs();
            sum += d;
            if (d > worst) worst = d;
          }
          final mean = sum / golden.length;
          // Print so a drift is visible before it fails.
          // ignore: avoid_print
          print('$name@$dpi mean ${mean.toStringAsFixed(3)} max $worst');
          // A /Rotate page is drawn by poppler in the rotated frame, which puts
          // the resampling grid up to a pixel off ours; the OMR finds the sheet
          // by correlation, so that is tolerated, but not hidden.
          final rotated = name.startsWith('rotated');
          expect(mean, lessThan(rotated ? 1.5 : 0.25), reason: 'mean absolute difference');
          expect(worst, lessThan(rotated ? 255 : 12), reason: 'largest single difference');
        });
      }
    }
  });

  group('resampling', () {
    test('a shrink averages whole pixels, with the remainder spread by Bresenham', () {
      final src = Uint8List.fromList([for (var i = 0; i < 18; i++) i * 10]);
      expect(resample(src, 6, 3, 4, 2), [0, 15, 30, 45, 90, 105, 120, 135]);
    });

    test('an enlargement pins the corners', () {
      final src = Uint8List.fromList([0, 100, 200, 100, 200, 250]);
      final out = resample(src, 3, 2, 5, 2);
      expect([out[0], out[4]], [0, 200]);
      expect([out[5], out[9]], [100, 250]);
    });
  });

  group('repair and refusal', () {
    test('a PDF whose cross-reference table is wrong is rebuilt', () {
      final doc = PdfDocument.open(File('${directory.path}/broken_xref.pdf').readAsBytesSync());
      expect(doc.pageCount, 1);
    });

    test('something that is not a PDF is refused in plain words', () {
      expect(
        () => PdfDocument.open(Uint8List.fromList(utf8.encode('hello'))),
        throwsA(isA<PdfException>().having((e) => e.message, 'message', contains('does not look like a PDF'))),
      );
    });

    test('a page with visible text is not mistaken for a plain scan', () {
      final bytes = File('${directory.path}/rgb_jpeg_up.pdf').readAsBytesSync();
      final text = latin1.decode(bytes).replaceFirst('BT 3 Tr', 'BT 0 Tr');
      expect(text.length, bytes.length);
      final doc = PdfDocument.open(Uint8List.fromList(latin1.encode(text)));
      expect(
        () => renderScanPage(doc.pages.single),
        throwsA(isA<PdfUnsupported>().having((e) => e.message, 'message', contains('visible text'))),
      );
    });
  });
}
