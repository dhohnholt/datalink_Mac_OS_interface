import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/features/paper/orient_template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled orientation template has the size the reader expects', () async {
    final template = await loadOrientTemplate();
    expect([template.width, template.height], [orientTemplateWidth, orientTemplateHeight]);
    var dark = 0;
    for (final v in template.pixels) {
      if (v < 170) dark++;
    }
    // Printed form, not a blank or a solid fill.
    expect(dark, inInclusiveRange(1000, template.pixels.length ~/ 2));
  });
}
