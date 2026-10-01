import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_core/src/paper/omr/omr.dart' as omr;

/// A made-up orientation template: smooth random blobs, nothing to do with a
/// real sheet. The reader only needs *something* distinctive at the place the
/// real form's ID grid and header sit.
GrayImage syntheticTemplate() {
  final rng = math.Random(11);
  final image = GrayImage(orientTemplateWidth, orientTemplateHeight);
  image.pixels.fillRange(0, image.pixels.length, 240);
  for (var i = 0; i < 160; i++) {
    final cx = rng.nextInt(orientTemplateWidth);
    final cy = rng.nextInt(orientTemplateHeight);
    final r = 6 + rng.nextInt(30);
    final shade = 175 + rng.nextInt(50); // lighter than the ink threshold, so it never reads as a mark
    for (var y = math.max(0, cy - r); y < math.min(orientTemplateHeight, cy + r); y++) {
      for (var x = math.max(0, cx - r); x < math.min(orientTemplateWidth, cx + r); x++) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r) image.pixels[y * orientTemplateWidth + x] = shade;
      }
    }
  }
  return image;
}

const sheetWidth = 2384;
const sheetHeight = 4384;

void _disc(GrayImage page, double cx, double cy, int radius) {
  for (var y = (cy - radius).floor(); y <= (cy + radius).ceil(); y++) {
    for (var x = (cx - radius).floor(); x <= (cx + radius).ceil(); x++) {
      if (x < 0 || y < 0 || x >= page.width || y >= page.height) continue;
      if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius) page.pixels[y * page.width + x] = 20;
    }
  }
}

/// A 400 dpi sheet: the template where the reader looks for it, then a dark
/// mark for each answer in [answers] (`A`-`E`, `*` for two marks, empty for
/// none) and each digit of [studentId] (`_` for none).
///
/// [shiftY] moves the sheet down the page, as feed registration does.
GrayImage syntheticSheet(
  GrayImage template, {
  required List<String> answers,
  String? studentId,
  int shiftY = 0,
  bool upsideDown = false,
}) {
  final page = GrayImage(sheetWidth, sheetHeight);
  page.pixels.fillRange(0, page.pixels.length, 250);
  for (var y = 0; y < template.height; y++) {
    page.pixels.setRange(
      (y + orientTemplateY0 + shiftY) * sheetWidth + orientTemplateX0,
      (y + orientTemplateY0 + shiftY) * sheetWidth + orientTemplateX0 + template.width,
      template.pixels,
      y * template.width,
    );
  }
  // Printed ink down the margin, as the real form has, so that a sheet is not
  // mistaken for the blank back of a duplex scan.
  for (var row = 0; row < 25; row++) {
    final y = (omr.answerRow0Y + shiftY + row * omr.answerRowSpacing).round();
    for (var dy = -35; dy < 35; dy++) {
      for (var x = 10; x < 55; x++) {
        page.pixels[(y + dy) * sheetWidth + x] = 40;
        page.pixels[(y + dy) * sheetWidth + x + 2300] = 40;
      }
    }
  }
  for (var q = 1; q <= answers.length; q++) {
    final columns = q <= 25 ? omr.leftColumns : omr.rightColumns;
    final y = omr.answerRow0Y + shiftY + (q <= 25 ? q - 1 : q - 26) * omr.answerRowSpacing;
    final marks = answers[q - 1] == '*' ? ['A', 'B'] : [if (answers[q - 1].isNotEmpty) answers[q - 1]];
    for (final mark in marks) {
      _disc(page, columns[omr.options.indexOf(mark)], y, 20);
    }
  }
  if (studentId != null) {
    for (var i = 0; i < studentId.length; i++) {
      if (studentId[i] == '_') continue;
      _disc(page, omr.idColumns[i], omr.idRow0Y + shiftY + int.parse(studentId[i]) * omr.idRowSpacing, 16);
    }
  }
  return upsideDown ? page.rotated180() : page;
}

/// A scanner-style PDF: each page is one picture at 200 ppi covering the sheet.
Uint8List syntheticPdf(List<GrayImage> pages400dpi) {
  final objects = <Uint8List>[];
  int add(List<int> body) {
    objects.add(Uint8List.fromList(body));
    return objects.length;
  }

  Uint8List stream(String dictionary, List<int> data) => Uint8List.fromList([
        ...latin1.encode('<< $dictionary /Length ${data.length} >>\nstream\n'),
        ...data,
        ...latin1.encode('\nendstream'),
      ]);

  final pageNumbers = <int>[];
  final pagesObject = pages400dpi.length * 3 + 1;
  for (final full in pages400dpi) {
    // Halve to the 200 ppi a scanner would have stored.
    final w = full.width ~/ 2;
    final h = full.height ~/ 2;
    final half = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        half[y * w + x] = (full.at(2 * x, 2 * y) +
                full.at(2 * x + 1, 2 * y) +
                full.at(2 * x, 2 * y + 1) +
                full.at(2 * x + 1, 2 * y + 1)) ~/
            4;
      }
    }
    final image = add(stream(
      '/Type /XObject /Subtype /Image /Width $w /Height $h /ColorSpace /DeviceGray '
      '/BitsPerComponent 8 /Interpolate true /Filter /FlateDecode',
      ZLibCodec().encode(half),
    ));
    final widthPt = (full.width * 72 / 400).toStringAsFixed(2);
    final heightPt = (full.height * 72 / 400).toStringAsFixed(2);
    final content = add(stream('', latin1.encode('q $widthPt 0 0 $heightPt 0 0 cm /Im1 Do Q')));
    pageNumbers.add(add(latin1.encode(
      '<< /Type /Page /Parent $pagesObject 0 R /MediaBox [0 0 $widthPt $heightPt] '
      '/Contents $content 0 R /Resources << /XObject << /Im1 $image 0 R >> >> >>',
    )));
  }
  add(latin1.encode(
    '<< /Type /Pages /Kids [${pageNumbers.map((n) => '$n 0 R').join(' ')}] /Count ${pageNumbers.length} >>',
  ));
  final catalog = add(latin1.encode('<< /Type /Catalog /Pages $pagesObject 0 R >>'));

  final out = BytesBuilder();
  out.add(latin1.encode('%PDF-1.4\n'));
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.add(latin1.encode('${i + 1} 0 obj\n'));
    out.add(objects[i]);
    out.add(latin1.encode('\nendobj\n'));
  }
  final xref = out.length;
  out.add(latin1.encode('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n'));
  for (final offset in offsets) {
    out.add(latin1.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  out.add(latin1.encode(
    'trailer\n<< /Size ${objects.length + 1} /Root $catalog 0 R >>\nstartxref\n$xref\n%%EOF\n',
  ));
  return out.takeBytes();
}
