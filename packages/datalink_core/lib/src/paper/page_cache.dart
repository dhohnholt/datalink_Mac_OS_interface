/// Page pictures kept so a sheet can be looked at later, when its ID or a
/// name has to be corrected by eye.
///
/// The Python app cached every page at 400 dpi (about 6 MB each) so that a
/// second run would not re-render. Here rendering is quick and the PDF is
/// still in hand for a retry, so only a reduced picture of each page is kept,
/// about 150 KB, and the cache stays small enough to forget about.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import 'gray_image.dart';

/// The widest a page is shown. A 400 dpi page is far more than a person needs
/// to read a name off the top of a sheet.
const int pageViewWidth = 1100;

/// Roughly a term of 40-page batches before anyone is asked anything.
const int cacheWarnBytes = 500 * 1024 * 1024;

class PageCache {
  PageCache(this.root, {this.warnBytes = cacheWarnBytes});

  /// The size past which the teacher is offered the chance to empty it.
  final int warnBytes;

  /// Holds one folder per PDF.
  final Directory root;

  /// Where the pages of [pdf] are kept: a name made from the file's path, size
  /// and modification time, so an edited file gets a fresh folder.
  Directory directoryFor(File pdf, {int dpi = 400}) {
    final stat = pdf.statSync();
    final identity = '${pdf.absolute.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:$dpi';
    final digest = sha256.convert(identity.codeUnits).toString().substring(0, 16);
    return Directory('${root.path}/$digest');
  }

  Map<String, Object?> report() {
    var bytes = 0;
    var batches = 0;
    if (root.existsSync()) {
      for (final entry in root.listSync(followLinks: false)) {
        if (entry is Directory) batches++;
        if (entry is File) {
          bytes += entry.lengthSync();
        } else if (entry is Directory) {
          for (final inner in entry.listSync(recursive: true, followLinks: false)) {
            if (inner is File) bytes += inner.lengthSync();
          }
        }
      }
    }
    return <String, Object?>{
      'cache_dir': root.path,
      'cache_bytes': bytes,
      'batches': batches,
      'warn_bytes': warnBytes,
      'over_limit': bytes >= warnBytes,
    };
  }

  /// Deletes the pictures. Scores and sessions are untouched.
  Map<String, Object?> purge() {
    final before = report();
    var removed = 0;
    if (root.existsSync()) {
      for (final entry in root.listSync(followLinks: false)) {
        try {
          entry.deleteSync(recursive: true);
          removed++;
        } on FileSystemException {
          continue;
        }
      }
    }
    return <String, Object?>{'freed_bytes': before['cache_bytes'], 'removed': removed, ...report()};
  }
}

String pagePictureName(int page) => 'page-${page.toString().padLeft(6, '0')}.jpg';

/// Writes the reduced picture of [page] into [directory].
void writePagePicture(Directory directory, int page, GrayImage gray) {
  directory.createSync(recursive: true);
  var image = img.Image.fromBytes(
    width: gray.width,
    height: gray.height,
    bytes: gray.pixels.buffer,
    numChannels: 1,
  );
  if (image.width > pageViewWidth) {
    image = img.copyResize(image, width: pageViewWidth, interpolation: img.Interpolation.average);
  }
  File('${directory.path}/${pagePictureName(page)}').writeAsBytesSync(img.encodeJpg(image, quality: 82));
}

/// The stored picture of [page], or null if it is not (any more) in the cache.
Uint8List? readPagePicture(String directory, int page) {
  final file = File('$directory/${pagePictureName(page)}');
  return file.existsSync() ? file.readAsBytesSync() : null;
}
