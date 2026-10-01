// Renders one page of a PDF to a grayscale PNG with the app's own renderer.
//
//   dart run tool/render_page.dart <file.pdf> <page> <out.png>
import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/src/paper/pdf/pdf_document.dart';
import 'package:datalink_core/src/paper/pdf/pdf_scan.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final doc = PdfDocument.open(File(args[0]).readAsBytesSync());
  final gray = renderScanPage(doc.pages[int.parse(args[1]) - 1]);
  final image = img.Image.fromBytes(
    width: gray.width,
    height: gray.height,
    bytes: Uint8List.fromList(gray.pixels).buffer,
    numChannels: 1,
  );
  File(args[2]).writeAsBytesSync(img.encodePng(image));
  stdout.writeln('${gray.width}x${gray.height}');
}
