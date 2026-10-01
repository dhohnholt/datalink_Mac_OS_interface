import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

/// Reading the Keychain can make macOS ask for a password (when another app
/// made the entry), so it must only happen when a screen needs the answer.
void main() {
  Future<MemorySecrets> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final secrets = MemorySecrets();
    final services = testServices(store: Store.open(':memory:'), secrets: secrets);
    addTearDown(services.dispose);
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.pumpAndSettle();
    return secrets;
  }

  testWidgets('launching, scanning and visiting the other tabs never touch the Keychain', (tester) async {
    final secrets = await start(tester);
    for (final tab in ['Paper', 'Sessions', 'Analysis', 'Classes', 'Scan']) {
      await tester.tap(find.text(tab).first);
      await tester.pumpAndSettle();
    }
    expect(secrets.reads, 0);
  });

  testWidgets('Settings reads it once, on first view, and says it is checking until then', (tester) async {
    final secrets = await start(tester);
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(secrets.reads, 1);
    // Back and forth does not ask again.
    await tester.tap(find.text('Scan').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(secrets.reads, 1);
    expect(find.text('Checking your connection…'), findsNothing);
  });
}
