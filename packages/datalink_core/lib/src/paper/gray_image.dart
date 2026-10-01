library;

import 'dart:typed_data';

/// An 8-bit grayscale picture, row by row, top row first.
class GrayImage {
  GrayImage(this.width, this.height, [Uint8List? pixels])
      : pixels = pixels ?? Uint8List(width * height);

  final int width;
  final int height;
  final Uint8List pixels;

  int at(int x, int y) => pixels[y * width + x];

  /// `cv2.rotate(img, ROTATE_90_COUNTERCLOCKWISE)`.
  GrayImage rotated90CounterClockwise() {
    final out = GrayImage(height, width);
    final o = out.pixels;
    // dst[r][c] = src[c][w-1-r]
    for (var r = 0; r < width; r++) {
      final srcX = width - 1 - r;
      for (var c = 0; c < height; c++) {
        o[r * height + c] = pixels[c * width + srcX];
      }
    }
    return out;
  }

  /// `cv2.rotate(img, ROTATE_90_CLOCKWISE)`.
  GrayImage rotated90Clockwise() {
    final out = GrayImage(height, width);
    final o = out.pixels;
    // dst[r][c] = src[h-1-c][r]
    for (var r = 0; r < width; r++) {
      for (var c = 0; c < height; c++) {
        o[r * height + c] = pixels[(height - 1 - c) * width + r];
      }
    }
    return out;
  }

  /// `cv2.rotate(img, ROTATE_180)`.
  GrayImage rotated180() {
    final out = GrayImage(width, height);
    final n = width * height;
    for (var i = 0; i < n; i++) {
      out.pixels[i] = pixels[n - 1 - i];
    }
    return out;
  }
}
