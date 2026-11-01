import 'dart:io';
import 'dart:typed_data';

import 'package:datalink_core/datalink_core.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

void main() {
  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('preview-test-'));
  tearDown(() => cache.deleteSync(recursive: true));

  GrayImage scan() {
    final gray = GrayImage(80, 100)..pixels.fillRange(0, 8000, 255);
    for (var y = 24; y < 56; y++) {
      for (var x = 24; x < 56; x++) {
        gray.pixels[y * 80 + x] = 0;
      }
    }
    return gray;
  }

  void expectReadable(Uint8List bytes) {
    final image = img.decodeImage(bytes)!;
    final paper = image.getPixel(8, 8);
    expect(paper.r, greaterThan(240));
    expect(paper.g, greaterThan(240));
    expect(paper.b, greaterThan(240));
    final mark = image.getPixel(40, 40);
    expect(mark.r, lessThan(20));
    expect(mark.g, lessThan(20));
    expect(mark.b, lessThan(20));
  }

  test('new JPEG previews keep paper white and marks black', () {
    writePagePicture(cache, 1, scan());
    expectReadable(File('${cache.path}/${pagePictureName(1)}').readAsBytesSync());
    expectReadable(readPagePicture(cache.path, 1)!);
  });

  test('old red previews display correctly without changing cached bytes', () {
    final gray = scan();
    final old = img.Image.fromBytes(width: gray.width, height: gray.height,
        bytes: gray.pixels.buffer, numChannels: 1);
    final file = File('${cache.path}/${pagePictureName(1)}');
    final encoded = Uint8List.fromList(img.encodeJpg(old, quality: 82));
    file.writeAsBytesSync(encoded);
    expect(img.decodeJpg(encoded)!.getPixel(8, 8).g, lessThan(20));
    expectReadable(readPagePicture(cache.path, 1)!);
    expect(file.readAsBytesSync(), encoded);
  });

  test('legacy PNG diagnostic images remain unchanged', () {
    final image = img.Image(width: 40, height: 60)..clear(img.ColorRgb8(255, 0, 0));
    final bytes = Uint8List.fromList(img.encodePng(image));
    File('${cache.path}/page-000001.png').writeAsBytesSync(bytes);
    expect(readPagePicture(cache.path, 1), bytes);
  });
}
