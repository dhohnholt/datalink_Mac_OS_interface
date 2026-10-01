// Reads page images with the Dart reader and prints one JSON line per page,
// for comparison with tool/realdata-style Python output.
//
//   dart run tool/check_omr.dart <reference_page.png> <dir of page-NNNNNN.png>
//
// Prints numbers and answer letters only.
import 'dart:convert';
import 'dart:io';

import 'package:datalink_core/src/paper/gray_image.dart';
import 'package:datalink_core/src/paper/omr/omr.dart';
import 'package:image/image.dart' as img;

GrayImage load(String path) {
  final image = img.decodePng(File(path).readAsBytesSync())!;
  final bytes = image.getBytes();
  final channels = image.numChannels;
  final out = GrayImage(image.width, image.height);
  for (var i = 0; i < out.pixels.length; i++) {
    final o = i * channels;
    out.pixels[i] = channels == 1
        ? bytes[o]
        : (bytes[o] * 4899 + bytes[o + 1] * 9617 + bytes[o + 2] * 1868 + 8192) >> 14;
  }
  return out;
}

void main(List<String> args) {
  final reference = load(args[0]);
  final template = GrayImage(orientTemplateWidth, orientTemplateHeight);
  for (var y = 0; y < orientTemplateHeight; y++) {
    for (var x = 0; x < orientTemplateWidth; x++) {
      template.pixels[y * orientTemplateWidth + x] =
          reference.pixels[(y + orientTemplateY0) * reference.width + x + orientTemplateX0];
    }
  }
  final reader = SheetReader(template);
  final files = Directory(args[1]).listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final watch = Stopwatch()..start();
    final result = reader.read(load(file.path));
    final name = file.uri.pathSegments.last;
    final Map<String, Object?> row = switch (result) {
      BlankPage() => {'page': name, 'status': 'blank'},
      UnsupportedPage(:final confidence) => {'page': name, 'status': 'unsupported', 'confidence': confidence},
      ProcessedPage(:final sheet) => {
          'page': name,
          'status': 'processed',
          'id': sheet.studentId,
          'answers': [for (var q = 1; q <= 50; q++) sheet.answers[q]!.substring(0, 1)].join(),
          'review': [for (var q = 1; q <= 50; q++) if (sheet.answerConfidence[q]!['needs_review']! as bool) q],
          'row0': sheet.calibration['row0_y'],
          'angle': sheet.calibration['orientation_angle'],
          'conf': sheet.calibration['orientation_confidence'],
        },
    };
    row['ms'] = watch.elapsedMilliseconds;
    stdout.writeln(jsonEncode(row));
  }
}
