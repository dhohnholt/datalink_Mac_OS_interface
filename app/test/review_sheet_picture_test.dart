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
