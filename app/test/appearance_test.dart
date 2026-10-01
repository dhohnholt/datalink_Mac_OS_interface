import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

void main() {
  test('the choice is remembered, and anything unrecognised means follow the Mac', () {
    final store = Store.open(':memory:');
    addTearDown(store.close);
    expect(Appearance(store).mode, ThemeMode.system);
    Appearance(store).set(ThemeMode.dark);
    expect(Appearance(store).mode, ThemeMode.dark);
    store.setSetting(Appearance.setting, 'purple');
    expect(Appearance(store).mode, ThemeMode.system);
  });

  testWidgets('Settings switches the whole app between light and dark', (tester) async {
    tester.view.physicalSize = const Size(1500, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = testServices();
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();

    Brightness shown() => Theme.of(tester.element(find.text('Appearance').first)).brightness;
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(shown(), Brightness.dark);
    expect(services.appearance.mode, ThemeMode.dark);

    await tester.tap(find.text('Light').last);
    await tester.pumpAndSettle();
    expect(shown(), Brightness.light);
  });
}
