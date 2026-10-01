import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

/// With Reduce Motion on, dialogs and toasts are fully there on the first
/// frame; without it they fade in over a fraction of a second.
void main() {
  Future<void> open(WidgetTester tester, {required bool reduce}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: reduce);
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearAllTestValues();
    });
    final store = Store.open(':memory:');
    store.createSession('Unit 1', '', 2);
    final services = testServices(store: store);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.tap(find.text('Sessions').first);
    await tester.pumpAndSettle();
  }

  double dialogOpacity(WidgetTester tester) {
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(of: find.byType(AlertDialog), matching: find.byType(FadeTransition)),
    );
    return fades.map((f) => f.opacity.value).reduce((a, b) => a < b ? a : b);
  }

  testWidgets('without Reduce Motion a dialog fades in', (tester) async {
    await open(tester, reduce: false);
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(dialogOpacity(tester), lessThan(1));
    await tester.pumpAndSettle();
    expect(dialogOpacity(tester), 1);
  });

  testWidgets('with Reduce Motion a dialog is fully shown at once', (tester) async {
    await open(tester, reduce: true);
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(dialogOpacity(tester), 1);
  });
}
