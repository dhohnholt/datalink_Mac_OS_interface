import 'package:datalink_core/datalink_core.dart';
import 'package:flutter/services.dart';

/// Where the form's orientation template is bundled: the 840 x 620 grayscale
/// crop of the printed ID grid and header, one byte per pixel, row by row.
/// Made by `tools/omr/make_orient_template.py`.
const String orientTemplateAsset = 'assets/orient_template.gray';

Future<GrayImage> loadOrientTemplate([AssetBundle? bundle]) async {
  final data = await (bundle ?? rootBundle).load(orientTemplateAsset);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  if (bytes.length != orientTemplateWidth * orientTemplateHeight) {
    throw StateError('The orientation template is the wrong size (${bytes.length} bytes).');
  }
  return GrayImage(orientTemplateWidth, orientTemplateHeight, Uint8List.fromList(bytes));
}
