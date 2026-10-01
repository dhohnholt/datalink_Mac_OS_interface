// Runs a whole PDF batch through the Dart pipeline and writes the report JSON.
//
//   dart run tool/check_paper.dart <reference_page.png> <file.pdf> <key page> <out.json> [questions]
//
// For development against local PDFs; the report holds real student data, so
// write it somewhere untracked.
import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:image/image.dart' as img;

Future<void> main(List<String> args) async {
  final reference = img.decodePng(File(args[0]).readAsBytesSync())!;
  final bytes = reference.getBytes();
  final channels = reference.numChannels;
  final template = GrayImage(orientTemplateWidth, orientTemplateHeight);
  for (var y = 0; y < orientTemplateHeight; y++) {
    for (var x = 0; x < orientTemplateWidth; x++) {
      final o = ((y + orientTemplateY0) * reference.width + x + orientTemplateX0) * channels;
      template.pixels[y * orientTemplateWidth + x] =
          channels == 1 ? bytes[o] : (bytes[o] * 4899 + bytes[o + 1] * 9617 + bytes[o + 2] * 1868 + 8192) >> 14;
    }
  }
  final cache = PageCache(Directory.systemTemp.createTempSync('paper-cache-'));
  final watch = Stopwatch()..start();
  try {
    final report = await readBatch(
      request: PaperRequest(
        pdf: File(args[1]),
        keyPage: int.parse(args[2]),
        questionCount: args.length > 4 ? int.parse(args[4]) : 50,
      ),
      orientTemplate: template,
      cache: cache,
    );
    File(args[3]).writeAsStringSync(pyJsonEncode(report));
    stdout.writeln('ok ${(report['students']! as List).length} students in ${watch.elapsedMilliseconds} ms');
  } on AnswerKeyException catch (error) {
    stdout.writeln('key: ${error.message}');
  } on PaperException catch (error) {
    stdout.writeln('error: ${error.message}');
  } finally {
    cache.root.deleteSync(recursive: true);
  }
  exit(0);
}
