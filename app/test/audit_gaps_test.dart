import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_fake.dart';
import 'support/test_services.dart';

/// Checks added while auditing the UI checklist, for behaviour that had no
/// test: the live table and metrics, the locked controls, the connecting badge,
/// the session bar, and the offer to empty the page cache.

Future<void> settle(WidgetTester tester, {int ms = 700}) async {
  for (var elapsed = 0; elapsed < ms; elapsed += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('Scan', () {
    Future<({AppServices services, LiveFakeTransport device})> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1700, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final clock = TickClock();
      final device = LiveFakeTransport(clock: clock);
      final store = Store.open(':memory:');
      store
        ..saveClass('P4', [
          {'id': '900011', 'name': 'Ada'},
          {'id': '900012', 'name': 'Bo'},
        ])
        ..setSetting('selected_class', 'P4')
        ..setSetting('test_name', 'Unit 1')
        ..setSetting('question_count', '4');
      final services = testServices(store: store, transport: device, clock: clock);
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.pumpAndSettle();
      return (services: services, device: device);
    }

    testWidgets('the badge says Connecting… on the way, and the form locks once connected', (tester) async {
      final app = await open(tester);
      DropdownButtonFormField<String> port() =>
          tester.widget(find.widgetWithText(DropdownButtonFormField<String>, 'Serial port'));
      TextField count() => tester.widget(find.widgetWithText(TextField, 'Questions per form'));
      expect(port().onChanged, isNotNull);
      expect(count().enabled, isTrue);

      await tester.tap(find.text('Connect and start session'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Connecting…'), findsOneWidget);
      await settle(tester, ms: 4500);

      expect(find.text('Ready to scan'), findsOneWidget);
      expect(port().onChanged, isNull, reason: 'the port cannot change while connected');
      expect(count().enabled, isFalse, reason: 'nor the form length during a session');

      await tester.tap(find.text('Disconnect'));
      await settle(tester);
      expect(app.services.scan.connected, isFalse);
    });

    testWidgets('Re-send handshake explains what it does not do', (tester) async {
      await open(tester);
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: find.text('Re-send handshake'), matching: find.byType(Tooltip)).first,
      );
      expect(tooltip.message, contains('does not change the mode the scanner is in'));
      expect(tooltip.message, contains('Reset button on the device'));
    });

    testWidgets('the live table lists the newest sheet first, with names, blanks and double marks', (tester) async {
      final app = await open(tester);
      await tester.tap(find.text('Connect and start session'));
      await settle(tester, ms: 4500);

      app.device.sendRecord(['A', 'B', 'C', 'D'], studentId: '');
      await settle(tester);
      app.device.sendRecord(['A', '', 'C', 'D'], studentId: '900011');
      await settle(tester);
      app.device.sendRecord(['A', 'B', 'AB', 'D'], studentId: '900012');
      await settle(tester);
      // A double mark stops for a person; keep it as read.
      await tester.tap(find.text('Keep AB'));
      await tester.tap(find.text('Save correction'));
      await settle(tester);

      // The metrics.
      expect(find.text('Sheets captured'), findsOneWidget);
      expect(find.text('3'), findsWidgets);
      expect(find.text('Latest response count'), findsOneWidget);
      expect(find.text('4 / 4'), findsOneWidget);

      // One column per question, no more.
      for (var q = 1; q <= 4; q++) {
        expect(find.text('Q$q'), findsOneWidget);
      }
      expect(find.text('Q5'), findsNothing);

      // Newest first: Bo (sheet 2) above Ada (sheet 1) above the key.
      double top(String text) => tester.getTopLeft(find.text(text).first).dy;
      expect(top('Bo'), lessThan(top('Ada')));
      expect(top('Ada'), lessThan(top('Key')));
      expect(find.text('Student 2'), findsOneWidget);
      expect(find.text('900011'), findsOneWidget, reason: 'the id sits under the name');

      // A blank is a dash, a double mark is shown as read and in bold.
      expect(find.text('—'), findsWidgets);
      final both = tester.widget<Text>(find.text('AB'));
      expect(both.style?.fontWeight, FontWeight.w700);

      await tester.tap(find.text('Disconnect'));
      await settle(tester);
    });
  });

  group('the session bar', () {
    testWidgets('names the test on every tab, switches views, and clears', (tester) async {
      tester.view.physicalSize = const Size(1500, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = Store.open(':memory:');
      final id = store.createSession('Unit 1', 'P4', 2);
      store
        ..addScan(id, {'number': 1, 'role': 'key', 'responses': ['A', 'B'], 'answered_count': 2})
        ..addScan(id, {'number': 2, 'role': 'student', 'student_id': '1', 'responses': ['A', 'C'], 'answered_count': 2});
      final services = testServices(store: store);
      addTearDown(services.dispose);
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 sheets'), findsNothing, reason: 'no test is selected yet');

      await tester.tap(find.text('Sessions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.textContaining('P4 · 2 sheets'), findsWidgets);

      // Still there on another tab.
      await tester.tap(find.text('Classes').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('P4 · 2 sheets'), findsWidgets);

      // The two views of it, and clearing.
      final views = find.byType(SegmentedButton<AppView>);
      await tester.tap(find.descendant(of: views, matching: find.text('Analysis')));
      await tester.pumpAndSettle();
      expect(services.scan.connected, isFalse);
      expect(find.text('Item analysis'), findsWidgets);
      await tester.tap(find.descendant(of: views, matching: find.text('Sheets')));
      await tester.pumpAndSettle();
      expect(find.text('Saved sessions'), findsOneWidget, reason: 'back on Sessions, with the test still open');

      await tester.tap(find.widgetWithText(TextButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Clear'), findsNothing, reason: 'the bar is gone with the test');
      expect(find.byType(SegmentedButton<AppView>), findsNothing);
    });
  });

  group('Settings', () {
    testWidgets('says plainly what is sent, and that nothing is sent until asked', (tester) async {
      tester.view.physicalSize = const Size(1500, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = testServices();
      addTearDown(services.dispose);
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      expect(find.text('What is sent'), findsOneWidget);
      expect(find.textContaining('Student IDs, names, per-question responses and scores for that test.'), findsOneWidget);
      expect(find.textContaining('No password, email, or other account credential is requested or transmitted.'), findsOneWidget);
      expect(find.textContaining('Nothing leaves this Mac until you ask it to'), findsOneWidget);
    });
  });

  group('the page cache', () {
    testWidgets('over its limit, it is offered once, and declining leaves it', (tester) async {
      tester.view.physicalSize = const Size(1500, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = Directory.systemTemp.createTempSync('cache-offer-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${(Directory('${root.path}/abc')..createSync()).path}/page-000001.jpg').writeAsBytesSync(List.filled(500, 1));
      final services = testServices(
        pageCache: PageCache(root, warnBytes: 100),
        pageCounter: (_) => 5,
        paperReader: (request, progress) async => {
          'created_at': '2026-09-30T12:00:00+00:00',
          'exam': {
            'name': 'x',
            'question_count': 1,
            'key_page': 1,
            'answer_key': [
              {'question': 1, 'answer': 'A'},
            ],
          },
          'students': [
            {
              'page': 2,
              'student_id': '1',
              'student_id_read': '1',
              'answers': [
                {'question': 1, 'response': 'A', 'confidence': <String, Object?>{}},
              ],
            },
          ],
          '_page_cache': '/nowhere',
        },
      );
      addTearDown(services.dispose);
      (services.actions as RecordingActions).nextPdfPath = '/scans/a.pdf';
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.tap(find.text('Paper').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose PDF…'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Read the sheets'));
      await tester.pumpAndSettle();
      expect(find.text('Empty the page cache?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(Directory('${root.path}/abc').existsSync(), isTrue);

      // Another batch while it is still over: not asked again.
      await tester.tap(find.text('Read another batch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read the sheets'));
      await tester.pumpAndSettle();
      expect(find.text('Empty the page cache?'), findsNothing);
    });

    testWidgets('accepting the offer empties it and says how much was freed', (tester) async {
      tester.view.physicalSize = const Size(1500, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = Directory.systemTemp.createTempSync('cache-offer-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${(Directory('${root.path}/abc')..createSync()).path}/page-000001.jpg').writeAsBytesSync(List.filled(500, 1));
      final services = testServices(
        pageCache: PageCache(root, warnBytes: 100),
        pageCounter: (_) => 5,
        paperReader: (request, progress) async => {
          'created_at': '2026-09-30T12:00:00+00:00',
          'exam': {
            'name': 'x',
            'question_count': 1,
            'key_page': 1,
            'answer_key': [
              {'question': 1, 'answer': 'A'},
            ],
          },
          'students': [
            {
              'page': 2,
              'student_id': '1',
              'student_id_read': '1',
              'answers': [
                {'question': 1, 'response': 'A', 'confidence': <String, Object?>{}},
              ],
            },
          ],
          '_page_cache': '/nowhere',
        },
      );
      addTearDown(services.dispose);
      (services.actions as RecordingActions).nextPdfPath = '/scans/a.pdf';
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.tap(find.text('Paper').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose PDF…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read the sheets'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty it'));
      await tester.pumpAndSettle();
      expect(Directory('${root.path}/abc').existsSync(), isFalse);
      expect(find.textContaining('Freed'), findsOneWidget);
    });
  });
}
