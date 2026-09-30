import 'package:datalink_scanner/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('hardware check shows the report the runner produces', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HardwareCheckPage(
          saver: (_) async => '/tmp/report.txt',
          runner: (listenFor, onProgress) async {
            onProgress('working');
            return 'usbserial ports: (none)';
          },
        ),
      ),
    );
    expect(find.text('No report yet.'), findsOneWidget);

    await tester.tap(find.text('Run check'));
    await tester.pumpAndSettle();

    expect(find.textContaining('usbserial ports: (none)', findRichText: true), findsOneWidget);
  });

  testWidgets('copy is disabled until there is a report', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HardwareCheckPage(runner: (_, _) async => '')),
    );
    final copy = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Copy report'));
    expect(copy.onPressed, isNull);
  });
}
