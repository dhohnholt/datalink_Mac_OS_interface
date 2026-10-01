// Compares this package's page renderer with pdftoppm output, page by page.
//
//   dart run tool/check_render.dart <file.pdf> <dir with page-000001.png ...> [dpi]
//
// For development against local PDFs; prints numbers only.
import 'dart:io';

import 'package:datalink_core/src/paper/pdf/pdf_document.dart';
import 'package:datalink_core/src/paper/pdf/pdf_scan.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final doc = PdfDocument.open(File(args[0]).readAsBytesSync());
  final dpi = args.length > 2 ? int.parse(args[2]) : 400;
  final watch = Stopwatch();
  var worstMean = 0.0;
  var worstMax = 0;
  for (var i = 0; i < doc.pageCount; i++) {
    final name = 'page-${(i + 1).toString().padLeft(6, '0')}.png';
    final file = File('${args[1]}/$name');
    if (!file.existsSync()) continue;
    watch.start();
    final ours = renderScanPage(doc.pages[i], dpi: dpi);
    watch.stop();
    final ref = img.decodePng(file.readAsBytesSync())!;
    if (ref.width != ours.width || ref.height != ours.height) {
      stdout.writeln('page ${i + 1}: size ${ours.width}x${ours.height} vs ${ref.width}x${ref.height}');
      continue;
    }
    final bytes = ref.getBytes();
    final channels = ref.numChannels;
    var sum = 0;
    var max = 0;
    for (var p = 0; p < ours.pixels.length; p++) {
      final o = p * channels;
      final gray = channels == 1
          ? bytes[o]
          : (bytes[o] * 4899 + bytes[o + 1] * 9617 + bytes[o + 2] * 1868 + 8192) >> 14;
      final d = (gray - ours.pixels[p]).abs();
      sum += d;
      if (d > max) max = d;
    }
    final mean = sum / ours.pixels.length;
    if (args.contains('-v')) stdout.writeln('page ${i + 1}: mean ${mean.toStringAsFixed(3)} max $max');
    if (mean > worstMean) worstMean = mean;
    if (max > worstMax) worstMax = max;
  }
  stdout.writeln('${doc.pageCount} pages · worst mean ${worstMean.toStringAsFixed(3)} · worst max $worstMax · '
      'render ${(watch.elapsedMilliseconds / doc.pageCount).round()} ms/page');
}
