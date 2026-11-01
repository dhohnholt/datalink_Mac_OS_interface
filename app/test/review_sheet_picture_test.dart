import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/test_services.dart';

Map<String, Object?> scan(int number, String role, List<String> responses, {String? id}) => {
      'number': number,
      'role': role,
      'student_id': id,
      'student_name': null,
      'received_at': '2026-09-16T18:00:00+00:00',
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
    };

/// A paper session with two sheets that need a person (no ID), and a picture
/// stored for sheet 3 only.
Future<void> open(WidgetTester tester, {required bool cached}) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final cache = Directory.systemTemp.createTempSync('review-pages-');
  addTearDown(() => cache.deleteSync(recursive: true));
  if (cached) {
    final picture = img.Image(width: 40, height: 60)..clear(img.ColorRgb8(200, 200, 200));
    File('${cache.path}/${pagePictureName(3)}').writeAsBytesSync(img.encodeJpg(picture));
    File('${cache.path}/${pagePictureName(2)}').writeAsBytesSync(img.encodeJpg(picture));
  }
  final store = Store.open(':memory:');
  final id = store.createSession('Unit 1', '', 2, source: 'paper', pageCache: cache.path);
  store
    ..addScan(id, scan(1, 'key', ['A', 'B']))
    ..addScan(id, scan(2, 'student', ['A', 'B'], id: '900011'))
    ..addScan(id, scan(3, 'student', ['A', 'C']))
    ..addScan(id, scan(4, 'student', ['B', 'B']));
  final services = testServices(store: store);
  addTearDown(services.dispose);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Sessions').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('View'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Analysis').first);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: find.byType(SegmentedButton<AnalysisPane>), matching: find.text('Review')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('side by side review fits a smaller desktop window', (tester) async {
    await open(tester, cached: true);
    tester.view.physicalSize = const Size(1100, 760);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review all scans'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('review-scan-2')));
    await tester.tap(find.byKey(const ValueKey('review-scan-2')));
    await tester.pumpAndSettle();
    final scanPane = tester.getRect(find.byKey(const ValueKey('scan-pane')));
    final corrections = tester.getRect(find.byKey(const ValueKey('correction-pane')));
    expect(scanPane.right, lessThan(corrections.left));
    expect(scanPane.width, greaterThan(300));
    expect(corrections.width, greaterThan(300));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('scan image viewer navigates between pages without closing', (tester) async {
    await open(tester, cached: true);
    await tester.tap(find.widgetWithText(TextButton, 'Sheet 3'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet 4'), findsWidgets);
    expect(find.textContaining('not in the cache any more'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Next')).onPressed, isNull);
    await tester.tap(find.text('Previous'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Previous')).onPressed, isNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('an unflagged sheet opens its image and all recorded answers', (tester) async {
    await open(tester, cached: true);
    final toolbar = tester.getRect(find.byType(SegmentedButton<AnalysisPane>));
    final browse = tester.getRect(find.widgetWithText(OutlinedButton, 'Review all scans'));
    // Beside the panes when there is room, below them when not; never over
    // one, so "Send to your site" stays in view.
    expect(browse.overlaps(toolbar), isFalse);
    final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    final lastPane = tester.getRect(find.text('Send to your site'));
    expect(screen.contains(lastPane.bottomRight), isTrue);
    expect(lastPane.overlaps(browse), isFalse);
    await tester.tap(find.text('Review all scans'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-scan-2')));
    await tester.pumpAndSettle();
    expect(find.text('Review scan · Sheet 2'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
    final scanPane = tester.getRect(find.byKey(const ValueKey('scan-pane')));
    final corrections = tester.getRect(find.byKey(const ValueKey('correction-pane')));
    expect(scanPane.right, lessThan(corrections.left));
    expect(scanPane.top, closeTo(corrections.top, 1));
    expect(find.ancestor(of: find.byType(Image), matching: find.byType(SingleChildScrollView)), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('a sheet of a paper batch opens its scan', (tester) async {
    await open(tester, cached: true);
    await tester.tap(find.widgetWithText(TextButton, 'Sheet 3'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet 3'), findsWidgets);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('not in the cache'), findsNothing);
  });

  testWidgets('a sheet whose picture has been emptied from the cache says so', (tester) async {
    await open(tester, cached: false);
    await tester.tap(find.widgetWithText(TextButton, 'Sheet 3'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not in the cache any more'), findsOneWidget);
  });
}
