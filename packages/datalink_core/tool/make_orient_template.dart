// Cuts the orientation template out of a scanned sheet of the form.
//
//   dart run tool/make_orient_template.dart <sheet.pdf> <page> <x> <y> <out.gray>
//
// The template is 840 x 620 grayscale pixels, one byte each, row by row. The
// sheet is drawn by the app's own renderer, so the template is in the same
// pixels as the pages it is matched against.
//
// (x, y) is where the form's student-ID grid and header start in that render.
// Row offsets are measured against the reference scan the bubble positions were
// calibrated on (the grid started at x 60, y 380 there), so the origin has to be
// the point that lines the two up. Find it by matching a crop of the old
// reference against the new render with cv2.matchTemplate, then check against
// real pages that the offsets agree: see docs/flutter-paper-measurements.md.
//
// Use a clean sheet. Nothing in the crop should identify a student.
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_core/src/paper/pdf/pdf_document.dart';
import 'package:datalink_core/src/paper/pdf/pdf_scan.dart';

void main(List<String> args) {
  final doc = PdfDocument.open(File(args[0]).readAsBytesSync());
  final page = renderScanPage(doc.pages[int.parse(args[1]) - 1]);
  final x0 = int.parse(args[2]);
  final y0 = int.parse(args[3]);
  final out = GrayImage(orientTemplateWidth, orientTemplateHeight);
  for (var y = 0; y < orientTemplateHeight; y++) {
    out.pixels.setRange(
      y * orientTemplateWidth,
      (y + 1) * orientTemplateWidth,
      page.pixels,
      (y0 + y) * page.width + x0,
    );
  }
  File(args[4]).writeAsBytesSync(out.pixels);
  stdout.writeln('wrote ${args[4]} (${out.pixels.length} bytes) from ${page.width}x${page.height}');
}
