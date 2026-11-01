import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

Map<String, Object?> scan(int number, String role, List<String> responses, {String? id, String? name}) => {
      'number': number,
      'role': role,
      'student_id': id,
      'student_name': name,
      'received_at': '2026-09-16T18:00:00+00:00',
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
    };

/// A scored test with something to review, a class, and a paper session whose
/// key could not be read, so every screen has real content.
int seed(Store store) {
  store.saveClass('P4', [
    {'id': '900011', 'name': 'Ada'},
    {'id': '900012', 'name': 'Bo'},
    {'id': '900013', 'name': 'Cy'},
  ]);
  final id = store.createSession('Unit 1', 'P4', 5);
  store
    ..addScan(id, scan(1, 'key', ['A', 'B', 'C', 'D', 'E']))
    ..addScan(id, scan(2, 'student', ['A', 'B', 'C', 'D', 'E'], id: '900011', name: 'Ada'))
    ..addScan(id, scan(3, 'student', ['A', 'B', 'C', 'E', '']))
    ..addScan(id, scan(4, 'student', ['A', 'AB', 'C', 'D', 'E'], id: '900013', name: 'Cy'));
  return id;
}

/// Every screen worth checking, as a way to get to it.
typedef Visit = Future<void> Function(WidgetTester tester, AppServices services, int session);

Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pumpAndSettle();
}

Future<void> pane(WidgetTester tester, String label) async {
  final target = find.descendant(of: find.byType(SegmentedButton<AnalysisPane>), matching: find.text(label));
  // At large text the panes sit below the fold, or past the edge: scroll to them.
  await tester.scrollUntilVisible(target, 120, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

final Map<String, Visit> screens = {
  'Scan': (tester, services, session) async {},
  'Paper': (tester, services, session) async {
    await tapTab(tester, 'Paper');
    (services.actions as RecordingActions).nextPdfPath = '/scans/Unit 1.pdf';
    await tester.tap(find.text('Choose PDF…'));
    await tester.pumpAndSettle();
  },
  'Sessions': (tester, services, session) async {
    await tapTab(tester, 'Sessions');
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    // View opens the analysis; come back to the session's response table.
    await tapTab(tester, 'Sessions');
  },
  'Analysis · items': (tester, services, session) async {
    services; // ignore: unnecessary_statements
    await tapTab(tester, 'Sessions');
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Analysis');
  },
  'Analysis · students': (tester, services, session) async {
    await tapTab(tester, 'Sessions');
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Analysis');
    await pane(tester, 'Student scores');
  },
  'Analysis · review': (tester, services, session) async {
    await tapTab(tester, 'Sessions');
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Analysis');
    await pane(tester, 'Review');
  },
  'Analysis · key': (tester, services, session) async {
    await tapTab(tester, 'Sessions');
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Analysis');
    await pane(tester, 'Answer key');
  },
  'Analysis · send': (tester, services, session) async {
    await tapTab(tester, 'Sessions');
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    await tapTab(tester, 'Analysis');
    await pane(tester, 'Send to your site');
  },
  'Classes': (tester, services, session) async => tapTab(tester, 'Classes'),
  'Settings': (tester, services, session) async => tapTab(tester, 'Settings'),
};

Future<AppServices> open(
  WidgetTester tester, {
  ThemeMode mode = ThemeMode.light,
  double textScale = 1,
  Size size = const Size(1400, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearAllTestValues();
  });
  final store = Store.open(':memory:');
  seed(store);
  final services = testServices(store: store, pageCounter: (_) => 12);
  services.appearance.set(mode);
  addTearDown(services.dispose);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.pumpAndSettle();
  return services;
}

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    group('${mode.name} mode: every control that can be pressed has a name', () {
      for (final entry in screens.entries) {
        testWidgets(entry.key, (tester) async {
          final handle = tester.ensureSemantics();
          try {
            final services = await open(tester, mode: mode);
            await entry.value(tester, services, 1);
            await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          } finally {
            handle.dispose();
          }
        });
      }
    });

    group('${mode.name} mode: text contrast as drawn', () {
      for (final entry in screens.entries) {
        testWidgets(entry.key, (tester) async {
          final handle = tester.ensureSemantics();
          try {
            final services = await open(tester, mode: mode);
            await entry.value(tester, services, 1);
            await expectLater(tester, meetsGuideline(textContrastGuideline));
          } finally {
            handle.dispose();
          }
        });
      }
    });
  }

  for (final scale in [1.5, 2.0]) {
    group('text at ${(scale * 100).round()}% still fits', () {
      for (final entry in screens.entries) {
        testWidgets(entry.key, (tester) async {
          final services = await open(tester, textScale: scale, size: const Size(1100, 760));
          await entry.value(tester, services, 1);
          expect(tester.takeException(), isNull, reason: 'a layout overflow is reported as an exception');
        });
      }
    });
  }
}
