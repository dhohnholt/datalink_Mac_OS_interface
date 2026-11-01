import 'dart:convert';

import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

const site = 'https://example.org/datalink';

Map<String, Object?> dest(
  String exam, {
  String unit = 'u1',
  Map<String, Object?>? draft,
}) =>
    {
      'exam_id': exam,
      'exam_title': 'Exam $exam',
      'test_code': 'CODE-$exam',
      'unit_id': unit,
      'unit_title': 'Unit $unit',
      'course_id': 'c1',
      'course_title': 'Course 1',
      'sections': [
        {'section_id': 's1', 'section_name': 'Section 1'},
      ],
      'draft_run': ?draft,
    };

Map<String, Object?> scan(int number, String role, List<String> responses, {String? id}) => {
      'number': number,
      'role': role,
      'student_id': id,
      'student_name': null,
      'received_at': '2026-09-16T18:00:00+00:00',
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
    };

class Rig {
  Rig(this.services, this.http, this.actions);

  final AppServices services;
  final ScriptedHttp http;
  final RecordingActions actions;
}

Future<Rig> open(
  WidgetTester tester, {
  required List<Object> answers,
  bool connected = true,
}) async {
  tester.view.physicalSize = const Size(1500, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = Store.open(':memory:')..setSetting(endpointSetting, site);
  final id = store.createSession('Unit 1', 'P4', 3);
  store
    ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
    ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
  final secrets = MemorySecrets();
  if (connected) secrets.items[(keychainService, keychainAccount)] = 'dlk_live_abc';
  final http = ScriptedHttp(answers);
  final actions = RecordingActions();
  // Production regenerates report timestamps on every read. A frozen clock
  // hides false "analysis changed" failures in the upload guard.
  var reportReads = 0;
  final services = testServices(
    store: store, secrets: secrets, http: http, actions: actions,
    now: () => DateTime.utc(2026, 10, 20, 12).add(Duration(seconds: reportReads++)),
  );
  await services.connection.load();
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Sessions').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('View'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Analysis').first);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(
    of: find.byType(SegmentedButton<AnalysisPane>),
    matching: find.text('Send to your site'),
  ));
  await tester.pumpAndSettle();
  return Rig(services, http, actions);
}

HttpReply tests(List<Map<String, Object?>> list) => reply(200, {'destinations': list});

void main() {
  testWidgets('not connected: says so and leads to Settings', (tester) async {
    await open(tester, answers: [], connected: false);
    expect(find.text('DataLink is not connected to a site yet.'), findsOneWidget);
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Send scored reports to your own site'), findsOneWidget);
  });

  testWidgets('offers the tests and says where it would upload', (tester) async {
    await open(tester, answers: [
      tests([dest('a'), dest('b', unit: 'u2')]),
    ]);
    expect(find.text('Uploads to Course 1 · Unit u1 · Exam a · code CODE-a'), findsOneWidget);
    expect(find.text('Add results'), findsOneWidget);
    expect(find.text('Upload another scan to add missing student scores or update existing scores for matching students.'), findsNothing);
  });

  testWidgets('choosing another unit changes the test on offer', (tester) async {
    await open(tester, answers: [
      tests([dest('a'), dest('b', unit: 'u2')]),
    ]);
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Unit u1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unit u2').last);
    await tester.pumpAndSettle();
    expect(find.text('Uploads to Course 1 · Unit u2 · Exam b · code CODE-b'), findsOneWidget);
  });

  testWidgets('uploading sends the scored run to the chosen test and reports the run', (tester) async {
    final rig = await open(tester, answers: [
      tests([dest('a')]),
      reply(201, {'run_id': 'db-run-9', 'status': 'imported', 'review_url': 'https://example.org/r/9'}),
      tests([dest('a')]),
    ]);
    await tester.tap(find.text('Add results'));
    await tester.pumpAndSettle();

    expect(find.text('Uploaded to your site'), findsOneWidget);
    expect(find.text('Sent. Run db-run-9'), findsOneWidget);

    final post = rig.http.calls.firstWhere((c) => c.method == 'POST');
    expect(post.url.toString(), site);
    expect(post.headers['Authorization'], 'Bearer dlk_live_abc');
    final body = jsonDecode(utf8.decode(post.body!)) as Map;
    expect(body['exam_id'], 'a');
    expect((body['analysis'] as Map)['exam']['test_code'], 'CODE-a');
    expect((body['analysis'] as Map)['exam']['source_type'], 'datalink_direct');
    expect(body.containsKey('replace_run_id'), isFalse);
    expect(utf8.decode(post.body!), isNot(contains('dlk_live_abc')));

    await tester.tap(find.text('Open on your site'));
    expect(rig.actions.opened, ['https://example.org/r/9']);
  });

  testWidgets('a retry of the same session reuses the run id', (tester) async {
    final rig = await open(tester, answers: [
      tests([dest('a')]),
      reply(201, {'run_id': 'r'}),
    ]);
    await tester.tap(find.text('Add results'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add results'));
    await tester.pumpAndSettle();
    final posts = rig.http.calls.where((c) => c.method == 'POST').toList();
    expect(posts, hasLength(2));
    String runId(List<int> body) => ((jsonDecode(utf8.decode(body)) as Map)['analysis'] as Map)['run_id'] as String;
    expect(runId(posts[0].body!), runId(posts[1].body!), reason: 'unchanged inputs, same audit record');
  });

  testWidgets('replacement refreshes and confirms the selected draft', (tester) async {
    final rig = await open(tester, answers: [
      tests([
        dest('a', draft: {'run_id': 'old-run', 'created_at': '2026-09-16T18:00:00+00:00', 'student_count': 3, 'question_count': 3}),
      ]),
      tests([dest('a', draft: {'run_id': 'old-run'})]),
      tests([dest('a', draft: {'run_id': 'old-run'})]),
      reply(200, {'run_id': 'new-run', 'status': 'updated', 'replaced_run_id': 'old-run'}),
      tests([dest('a')]),
    ]);
    expect(find.text('Upload another scan to add missing student scores or update existing scores for matching students.'), findsOneWidget);
    expect(find.text('Replace draft results'), findsOneWidget);

    await tester.tap(find.text('Replace draft results'));
    await tester.pumpAndSettle();
    expect(
      find.text("Replace the current unfinalized results for Exam a? The corrected scan becomes the test's current draft."),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(rig.http.calls.where((c) => c.method == 'POST'), isEmpty);

    await tester.tap(find.text('Replace draft results'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();
    final post = rig.http.calls.firstWhere((c) => c.method == 'POST');
    expect((jsonDecode(utf8.decode(post.body!)) as Map)['replace_run_id'], 'old-run');
    expect(find.text('Updated draft results on your site'), findsOneWidget);
  });

  testWidgets('a real answer change while confirming still blocks replacement', (tester) async {
    final rig = await open(tester, answers: [
      tests([dest('a', draft: {'run_id': 'old-run'})]),
      tests([dest('a', draft: {'run_id': 'old-run'})]),
    ]);
    await tester.tap(find.text('Replace draft results'));
    await tester.pumpAndSettle();
    rig.services.store.updateScan(1, 2, responses: ['C', 'B', 'C']);
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();
    expect(rig.http.calls.where((c) => c.method == 'POST'), isEmpty);
    expect(find.text('The selected test or analysis changed. Choose an action again.'), findsOneWidget);
  });

  testWidgets('a draft finalized elsewhere blocks replacement and allows adding', (tester) async {
    final rig = await open(tester, answers: [
      tests([dest('a', draft: {'run_id': 'old-run'})]),
      tests([dest('a')]),
      reply(201, {'run_id': 'added'}),
      tests([dest('a')]),
    ]);
    await tester.tap(find.text('Replace draft results'));
    await tester.pumpAndSettle();
    expect(rig.http.calls.where((c) => c.method == 'POST'), isEmpty);
    expect(find.text('The draft is no longer available for replacement. Use Add results to upload additional students.'), findsOneWidget);
    await tester.tap(find.text('Add results'));
    await tester.pumpAndSettle();
    final post = rig.http.calls.firstWhere((c) => c.method == 'POST');
    expect((jsonDecode(utf8.decode(post.body!)) as Map).containsKey('replace_run_id'), isFalse);
  });

  testWidgets('Add results omits replacement even with an existing draft', (tester) async {
    final rig = await open(tester, answers: [
      tests([dest('a', draft: {'run_id': 'earlier-draft'})]),
      reply(201, {'run_id': 'additional-student'}),
      tests([dest('a')]),
    ]);
    await tester.tap(find.text('Add results'));
    await tester.pumpAndSettle();
    final posts = rig.http.calls.where((c) => c.method == 'POST').toList();
    expect(posts, hasLength(1));
    expect((jsonDecode(utf8.decode(posts.single.body!)) as Map).containsKey('replace_run_id'), isFalse);
  });

  testWidgets('rejected replacement never falls back to adding', (tester) async {
    final rig = await open(tester, answers: [
      tests([dest('a', draft: {'run_id': 'old-run'})]),
      tests([dest('a', draft: {'run_id': 'old-run'})]),
      reply(409, {'error': {'code': 'run_not_replaceable', 'message': 'Finalized results cannot be replaced from DataLink.'}}),
    ]);
    await tester.tap(find.text('Replace draft results'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();
    expect(rig.http.calls.where((c) => c.method == 'POST'), hasLength(1));
    expect(find.text('Finalized results cannot be replaced from DataLink.'), findsOneWidget);
  });

  testWidgets("the site's own words are shown when it refuses", (tester) async {
    await open(tester, answers: [
      tests([dest('a')]),
      reply(409, {'error': {'code': 'duplicate_run', 'message': 'Already uploaded'}}),
    ]);
    await tester.tap(find.text('Add results'));
    await tester.pumpAndSettle();
    expect(find.text('Already uploaded'), findsOneWidget);
    expect(find.text('Uploaded to your site'), findsNothing);
  });

  testWidgets('a withdrawn token drops the connection', (tester) async {
    await open(tester, answers: [
      tests([dest('a')]),
      reply(401, {'error': {'code': 'invalid_token'}}),
    ]);
    await tester.tap(find.text('Add results'));
    await tester.pumpAndSettle();
    expect(find.text('The connection token is no longer valid. Open Settings and paste a new one.'), findsOneWidget);
    expect(find.text('DataLink is not connected to a site yet.'), findsOneWidget);
  });

  testWidgets('with no tests to upload to, nothing can be sent', (tester) async {
    await open(tester, answers: [tests([])]);
    expect(find.text('No test matches this combination.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add results')).onPressed, isNull);
  });

  testWidgets('Refresh tests asks the site again', (tester) async {
    final rig = await open(tester, answers: [
      tests([dest('a')]),
    ]);
    final before = rig.http.calls.length;
    await tester.tap(find.text('Refresh tests'));
    await tester.pumpAndSettle();
    expect(rig.http.calls.length, before + 1);
    expect(find.text('1 test(s) available'), findsOneWidget);
  });
}
