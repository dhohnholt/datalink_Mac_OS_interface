import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:datalink_scanner/features/settings/upload_specification.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_services.dart';

const site = 'https://example.org/datalink';

Map<String, Object?> destination(String exam, {String course = 'c1', String unit = 'u1'}) => {
      'exam_id': exam,
      'exam_title': 'Exam $exam',
      'test_code': 'T-$exam',
      'unit_id': unit,
      'unit_title': 'Unit $unit',
      'course_id': course,
      'course_title': 'Course $course',
      'sections': [
        {'section_id': 's1', 'section_name': 'Section 1'},
      ],
    };

class Rig {
  Rig(this.services, this.secrets, this.http, this.actions);

  final AppServices services;
  final MemorySecrets secrets;
  final ScriptedHttp http;
  final RecordingActions actions;
}

Future<Rig> open(
  WidgetTester tester, {
  String? endpoint,
  String? siteUrl,
  String? token,
  List<Object>? answers,
}) async {
  tester.view.physicalSize = const Size(1500, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final store = Store.open(':memory:');
  if (endpoint != null) store.setSetting(endpointSetting, endpoint);
  if (siteUrl != null) store.setSetting(siteSetting, siteUrl);
  final secrets = MemorySecrets();
  if (token != null) secrets.items[(keychainService, keychainAccount)] = token;
  final http = ScriptedHttp(answers);
  final actions = RecordingActions();
  final services = testServices(store: store, secrets: secrets, http: http, actions: actions);
  await services.connection.load();
  await tester.pumpWidget(DataLinkApp(services: services));
  await tester.tap(find.text('Settings').first);
  await tester.pumpAndSettle();
  return Rig(services, secrets, http, actions);
}

HttpReply twoTests() => reply(200, {
      'destinations': [destination('a'), destination('b', unit: 'u2')],
    });

Future<void> tap(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.ensureVisible(finder.first);
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('with no address, says so and offers nothing to connect to', (tester) async {
    await open(tester);
    expect(find.text('No upload address yet. Enter the address of your site below.'), findsOneWidget);
    expect(find.text('Enter and save an upload address before connecting.'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Open your site'), findsNothing);
    expect(find.textContaining('nothing can be sent'), findsOneWidget);
  });

  testWidgets('no address ships with the app', (tester) async {
    final rig = await open(tester);
    expect(rig.services.connection.apiUrl, '');
    expect(rig.services.connection.siteUrl, '');
    expect(rig.http.calls, isEmpty, reason: 'nothing contacted at launch');
  });

  testWidgets('saving an https address reveals the token box', (tester) async {
    final rig = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Upload address'), ' $site ');
    await tester.enterText(find.widgetWithText(TextField, 'Site address (optional)'), 'https://example.org/reports');
    await tap(tester, 'Save address');
    expect(find.text('Upload address saved'), findsOneWidget);
    expect(rig.services.store.getSetting(endpointSetting), site);
    expect(find.text('Not connected. Paste the connection token your site issued.'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Connection token'), findsOneWidget);
    expect(find.text('Open your site'), findsOneWidget);
    expect(find.textContaining('Sent over HTTPS to $site.'), findsOneWidget);
  });

  testWidgets('an http address is refused in words and not saved', (tester) async {
    final rig = await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Upload address'), 'http://example.org/api');
    await tap(tester, 'Save address');
    expect(
      find.text('The upload address must use https. Refusing to send student data over an unencrypted connection.'),
      findsOneWidget,
    );
    expect(rig.services.store.getSetting(endpointSetting), '');
  });

  testWidgets('clearing the address says so', (tester) async {
    await open(tester, endpoint: site);
    await tester.enterText(find.widgetWithText(TextField, 'Upload address'), '');
    await tap(tester, 'Save address');
    expect(find.text('Upload address cleared'), findsOneWidget);
  });

  group('connecting', () {
    testWidgets('a token that is not one is turned away before anything is sent', (tester) async {
      final rig = await open(tester, endpoint: site);
      await tester.enterText(find.widgetWithText(TextField, 'Connection token'), 'hunter2');
      await tap(tester, 'Connect');
      expect(
        find.text('That does not look like a DataLink connection token — they begin with dlk_live_'),
        findsOneWidget,
      );
      expect(rig.http.calls, isEmpty);
      expect(rig.secrets.items, isEmpty);
    });

    testWidgets('an empty token is asked for', (tester) async {
      await open(tester, endpoint: site);
      await tap(tester, 'Connect');
      expect(find.text('Paste the connection token first'), findsOneWidget);
    });

    testWidgets('a good token connects, lists the tests, and is kept only in the keychain', (tester) async {
      final rig = await open(tester, endpoint: site, answers: [twoTests()]);
      await tester.enterText(find.widgetWithText(TextField, 'Connection token'), ' dlk_live_abc ');
      await tap(tester, 'Connect');
      expect(find.text('Connected to your site'), findsOneWidget);
      expect(find.text('Connected · 2 tests across 1 course'), findsOneWidget);
      expect(find.text('Course c1'), findsOneWidget);
      expect(find.text('Refresh tests'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Connection token'), findsNothing);
      expect(rig.secrets.items, {(keychainService, keychainAccount): 'dlk_live_abc'});
      expect(rig.http.calls.single.headers['Authorization'], 'Bearer dlk_live_abc');
      expect(rig.http.calls.single.method, 'GET');
      expect(rig.services.store.getSetting('token'), '');
    });

    testWidgets('the token box does not keep the token after connecting', (tester) async {
      final rig = await open(tester, endpoint: site, answers: [twoTests()]);
      await tester.enterText(find.widgetWithText(TextField, 'Connection token'), 'dlk_live_abc');
      await tap(tester, 'Connect');
      await rig.services.connection.disconnect();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Connection token')).controller!.text, '');
    });

    testWidgets('a site that turns the token down says why, and keeps nothing', (tester) async {
      final rig = await open(tester, endpoint: site, answers: [
        reply(401, {'error': {'code': 'invalid_token', 'message': 'Token revoked'}}),
      ]);
      await tester.enterText(find.widgetWithText(TextField, 'Connection token'), 'dlk_live_abc');
      await tap(tester, 'Connect');
      expect(find.text('Token revoked'), findsOneWidget);
      expect(rig.secrets.items, isEmpty);
      expect(find.text('Disconnect'), findsNothing);
    });

    testWidgets('a site that cannot be reached leaves no token behind', (tester) async {
      final rig = await open(tester, endpoint: site);
      await tester.enterText(find.widgetWithText(TextField, 'Connection token'), 'dlk_live_abc');
      await tap(tester, 'Connect');
      expect(find.textContaining('Could not reach the site'), findsOneWidget);
      expect(rig.secrets.items, isEmpty, reason: 'an unverified token is not kept');
    });
  });

  group('connected', () {
    testWidgets('remembers the connection across launches and lists the tests', (tester) async {
      await open(tester, endpoint: site, token: 'dlk_live_abc', answers: [twoTests()]);
      expect(find.text('Connected · 2 tests across 1 course'), findsOneWidget);
    });

    testWidgets('refresh asks the site again and says how many tests there are', (tester) async {
      final rig = await open(tester, endpoint: site, token: 'dlk_live_abc', answers: [twoTests()]);
      final before = rig.http.calls.length;
      await tap(tester, 'Refresh tests');
      expect(rig.http.calls.length, before + 1);
      expect(find.text('2 test(s) available'), findsOneWidget);
    });

    testWidgets('disconnect asks, then removes the token', (tester) async {
      final rig = await open(tester, endpoint: site, token: 'dlk_live_abc', answers: [twoTests()]);
      await tap(tester, 'Disconnect');
      expect(
        find.text("Disconnect from your site? The connection token is removed from this Mac's Keychain."),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(rig.secrets.items, isNotEmpty, reason: 'cancel keeps it');

      await tap(tester, 'Disconnect');
      await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
      await tester.pumpAndSettle();
      expect(rig.secrets.items, isEmpty);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Connection token'), findsOneWidget);
    });

    testWidgets('a token the site withdraws is noticed at launch', (tester) async {
      final rig = await open(tester, endpoint: site, token: 'dlk_live_old', answers: [
        reply(401, {'error': {'code': 'invalid_token'}}),
      ]);
      expect(rig.secrets.items, isEmpty);
      expect(find.widgetWithText(TextField, 'Connection token'), findsOneWidget);
    });
  });

  group('the specification', () {
    testWidgets('copies to the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await open(tester);
      await tap(tester, 'Do not have a site yet?');
      await tap(tester, 'Copy the specification');
      expect(copied, uploadSpecification);
      expect(find.text('Specification copied'), findsOneWidget);
    });

    test('still describes what the client does', () {
      // The document is handed to whoever builds the site, so it must not drift
      // from the constants the client is built on.
      expect(uploadSpecification, contains(tokenPrefix));
      expect(uploadSpecification, contains('${maxAnalysisBytes ~/ 1048576} MB'));
      expect(uploadSpecification, contains('The app retries twice'));
      expect(uploadSpecification, contains('replace_run_id'));
      expect(uploadSpecification, contains('Authorization: Bearer'));
      expect(uploadSpecification, contains('https'));
      expect(maxRetries, 2);
    });
  });

  testWidgets('About: the privacy policy and support open in the browser', (tester) async {
    final rig = await open(tester);
    expect(find.text('DataLink Scanner 2.0.0'), findsOneWidget);
    await tap(tester, 'Privacy policy');
    await tap(tester, 'Support');
    expect(rig.actions.opened, [
      'https://dhohnholt.github.io/datalink_Mac_OS_interface/privacy.html',
      'https://dhohnholt.github.io/datalink_Mac_OS_interface/',
    ]);
  });

  testWidgets('Open your site uses the site address', (tester) async {
    final rig = await open(tester, endpoint: site, siteUrl: 'https://example.org/reports');
    await tap(tester, 'Open your site');
    expect(rig.actions.opened, ['https://example.org/reports']);
  });

  testWidgets('has no update controls: the store delivers updates', (tester) async {
    await open(tester);
    expect(find.textContaining('Check for a new version'), findsNothing);
    expect(find.text('Updates'), findsNothing);
  });
}
