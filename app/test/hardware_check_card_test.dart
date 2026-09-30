import 'package:datalink_scanner/hardware_check/hardware_check_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget card) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: card)));

void main() {
  testWidgets('shows the report the runner produces', (tester) async {
    await tester.pumpWidget(
      host(
        HardwareCheckCard(
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
    expect(find.textContaining('Saved to /tmp/report.txt', findRichText: true), findsOneWidget);
  });

  testWidgets('copy is disabled until there is a report', (tester) async {
    await tester.pumpWidget(host(HardwareCheckCard(runner: (_, _) async => '')));
    final copy = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Copy report'));
    expect(copy.onPressed, isNull);
  });
}
