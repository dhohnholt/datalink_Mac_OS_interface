import 'dart:io';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

/// A test given in two versions, scored from a test package: the Paper tab
/// takes the package, Analysis shows standards and the package's key, and a
/// double mark on a multiple-answer item survives a Review edit.
const _package = 'Stable item ID,Section,Standard,Version 1,Version 1 answer,Version 2,Version 2 answer\n'
    'veto,Presidency,USG.7B,1,A,3,C\n'
    'cabinet,Presidency,USG.7B,2,B,1,A\n'
    'judicial-review,CBA review,USG.7C,3,AC,2,BD\n';

int seedPackageTest(Store store) {
  store.saveClass('P4', [
    {'id': '100001', 'name': 'Ada'},
    {'id': '200002', 'name': 'Bo'},
  ]);
  final package = TestPackage.parse(_package);
  final id = store.createSession('Presidency', 'P4', package.questionCount,
      source: 'paper', package: pyJsonEncode(package.toJson()));
  Map<String, Object?> sheet(int number, String version, String sid, List<String> responses) => {
        'number': number,
        'role': 'student',
        'version': version,
        'student_id': sid,
        'received_at': '2026-10-31T12:00:00+00:00',
        'answered_count': responses.where((r) => r.isNotEmpty).length,
        'responses': responses,
      };
  store
    ..addScan(id, sheet(1, '1', '100001', ['A', 'B', 'AC'])) // 3 of 3
    ..addScan(id, sheet(2, '2', '200002', ['A', 'BD', 'B'])); // 2 of 3: veto wrong
  return id;
}

Future<AppServicesRig> openAnalysis(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = Store.open(':memory:');
  final id = seedPackageTest(store);
  final services = testServices(store: store);
  addTearDown(services.dispose);
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Sessions').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('View'));
  await tester.pumpAndSettle();
  return (services: services, id: id);
}

typedef AppServicesRig = ({dynamic services, int id});

Future<void> pane(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(SegmentedButton<AnalysisPane>), matching: find.text(label)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Student scores shows missing roster students and absence toggle', (tester) async {
    final rig = await openAnalysis(tester);
    final roster = (rig.services.store.getClass('P4')['students'] as List).cast<Map<String, Object?>>();
    rig.services.store.saveClass('P4', [...roster, {'id': '300003', 'name': 'Missing student'}]);
    await pane(tester, 'Student scores');
    expect(find.text('Missing student'), findsOneWidget);
    expect(find.text('Missing score'), findsOneWidget);
    final checkbox = find.byKey(const ValueKey('roster-absent-300003'));
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(rig.services.workspace.missingRosterStudents(rig.id).single['absent'], true);
    expect(tester.widget<Checkbox>(checkbox).value, true);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(rig.services.workspace.missingRosterStudents(rig.id).single['absent'], false);
    expect(find.text('Missing score'), findsOneWidget);
  });

  testWidgets('missing roster student can be explicitly marked absent in Review', (tester) async {
    final rig = await openAnalysis(tester);
    final roster = (rig.services.store.getClass('P4')['students'] as List).cast<Map<String, Object?>>();
    rig.services.store.saveClass('P4', [...roster, {'id': '300003', 'name': 'Absent student'}]);
    await pane(tester, 'Review');
    final absent = find.widgetWithText(CheckboxListTile, 'Absent student · ID 300003');
    await tester.ensureVisible(absent);
    await tester.tap(absent);
    await tester.pumpAndSettle();
    expect(rig.services.workspace.missingRosterStudents(rig.id).single['absent'], true);
    expect(find.text('Absent for this exam'), findsOneWidget);
  });

  testWidgets('Review changes a sheet version and can mark it unassigned', (tester) async {
    final rig = await openAnalysis(tester);
    await pane(tester, 'Review');
    final selector = find.byKey(const ValueKey('sheet-version-2'));
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Version 1').last);
    await tester.pumpAndSettle();
    expect(rig.services.store.sessionScans(rig.id).last['version'], '1');
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Version not assigned').last);
    await tester.pumpAndSettle();
    expect(rig.services.store.sessionScans(rig.id).last['version'], isNull);
    expect(rig.services.workspace.analysisReport(rig.id)['not_scored'], isNotEmpty);
  });

  testWidgets('scores each student on their own version, with a Standards pane', (tester) async {
    await openAnalysis(tester);
    await pane(tester, 'Student scores');
    expect(find.text('Ada'), findsOneWidget);
    await pane(tester, 'Standards');
    expect(find.text('By standard'), findsOneWidget);
    expect(find.text('USG.7B'), findsWidgets);
    // Bo missed the veto item (USG.7B): 1 of 2 there.
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the package key and multi-version send pane are available', (tester) async {
    await openAnalysis(tester);
    await pane(tester, 'Answer key');
    expect(find.textContaining('From the test package'), findsOneWidget);
    expect(find.text('judicial-review'), findsOneWidget);
    expect(find.text('BD'), findsOneWidget);
    // Multi-version tests retain the send action alongside Standards.
    expect(
      find.descendant(of: find.byType(SegmentedButton<AnalysisPane>), matching: find.text('Send to your site')),
      findsOneWidget,
    );
    final last = tester.getRect(find.descendant(
        of: find.byType(SegmentedButton<AnalysisPane>), matching: find.text('Answer key')));
    expect(last.right, lessThan(1600), reason: 'every pane stays in the window');
    await tester.ensureVisible(find.text('Send scores'));
    await tester.tap(find.text('Send scores'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('cannot be sent'), findsNothing);
    await pane(tester, 'Item analysis');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Paper tab takes a PDF and its package together, and copies the prompt', (tester) async {
    tester.view.physicalSize = const Size(1500, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final work = Directory.systemTemp.createTempSync('package-ui-');
    addTearDown(() => work.deleteSync(recursive: true));
    final csv = File('${work.path}/test-package.csv')..writeAsStringSync(_package);
    final actions = RecordingActions()
      ..nextPdfPath = '/scans/Presidency.pdf'
      ..nextPackagePath = csv.path;
    final requests = <PaperRequest>[];
    final services = testServices(
      store: Store.open(':memory:'),
      actions: actions,
      pageCounter: (_) => 6,
      paperReader: (request, progress) async {
        requests.add(request);
        throw const PaperException('stop here');
      },
    );
    addTearDown(services.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.pumpWidget(DataLinkApp(services: services));
    await tester.tap(find.text('Paper').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Copy prompt'));
    await tester.pumpAndSettle();
    expect(copied, testPackagePrompt);
    expect(find.text('Prompt copied'), findsOneWidget);

    await tester.tap(find.text('Choose answer map CSV…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('test-package.csv'), findsOneWidget);
    actions.nextPackagePath = null;
    await tester.tap(find.text('Choose PDF…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('test-package.csv · 3 items, versions 1, 2'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Answer key page'), findsNothing, reason: 'the package says where every item is');
    await tester.tap(find.text('Read the sheets'));
    await tester.pumpAndSettle();
    expect(requests.single.package!.items, ['veto', 'cabinet', 'judicial-review']);
    expect(requests.single.keyPage, isNull);
  });

  testWidgets('a double mark keeps its letters when the sheet is saved in Review', (tester) async {
    final rig = await openAnalysis(tester);
    await pane(tester, 'Review');
    await tester.tap(find.text('Review all scans'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-scan-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Student name').last, 'Ada L.');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    final store = (rig.services as dynamic).store as Store;
    expect(store.sessionScans(rig.id).first['responses'], ['A', 'B', 'AC']);
  });
}
