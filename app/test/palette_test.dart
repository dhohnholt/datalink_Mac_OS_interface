import 'dart:math' as math;

import 'package:datalink_scanner/app/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2 contrast ratio.
double contrast(Color a, Color b) {
  double lum(Color c) {
    double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  }

  final l1 = lum(a);
  final l2 = lum(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

void main() {
  for (final palette in [Palette.light, Palette.dark]) {
    group('${palette.brightness.name} palette', () {
      void reads(String what, Color foreground, Color background, {double ratio = 4.5}) {
        test('$what reads (at least $ratio:1)', () {
          expect(contrast(foreground, background), greaterThanOrEqualTo(ratio));
        });
      }

      reads('text on the page', palette.text, palette.page);
      reads('text on a card', palette.text, palette.card);
      reads('secondary text on the page', palette.textSecondary, palette.page);
      reads('secondary text on a card', palette.textSecondary, palette.card);
      reads('button text on the primary colour', palette.onPrimary, palette.primary);
      reads('the primary colour as text on a card', palette.primary, palette.card);
      reads('text on a primary tint', palette.onPrimaryContainer, palette.primaryContainer);
      reads('rail labels on the rail', palette.railText, palette.rail);
      reads('the selected rail item on its indicator', palette.railSelected, palette.railIndicator);
      reads('the selected rail item on the rail', palette.railSelected, palette.rail);
      reads('error text on a card', palette.error, palette.card);
      reads('the rail indicator against the rail (a graphic)', palette.railIndicator, palette.rail, ratio: 1.5);
      reads('a card edge against the page (a graphic)', palette.line, palette.page, ratio: 1.0);
    });
  }
}
