import 'package:datalink_core/datalink_core.dart';
import 'package:datalink_scanner/app/app.dart';
import 'package:datalink_scanner/app/commands.dart';
import 'package:datalink_scanner/app/menu.dart';
import 'package:datalink_scanner/app/navigation.dart';
import 'package:datalink_scanner/app/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/live_fake.dart';
import 'support/test_services.dart';

/// Every leaf item in a menu tree, in order.
Iterable<PlatformMenuItem> leaves(Iterable<PlatformMenuItem> items) sync* {
  for (final item in items) {
    if (item is PlatformMenu) {
      yield* leaves(item.menus);
    } else if (item is PlatformMenuItemGroup) {
      yield* leaves(item.members);
    } else {
      yield item;
    }
  }
}

PlatformMenuItem menuItem(Iterable<PlatformMenuItem> menus, String label) =>
    leaves(menus).firstWhere((i) => i.label == label, orElse: () => throw StateError('no "$label"'));

class Rig {
  Rig(this.services, this.nav, this.commands, this.toasts, this.confirms, this.actions, this.device);

  final AppServices services;
  final AppNavigation nav;
  final Commands commands;
  final List<String> toasts;
  final List<String> confirms;
  final RecordingActions actions;
  final LiveFakeTransport device;
  bool answer = true;

  List<PlatformMenuItem> menus() =>
      buildMenus(commands: commands, services: services, navigation: nav);
}

Rig rig({void Function(Store)? seed}) {
  final clock = YieldingClock();
  final device = LiveFakeTransport(clock: clock);
  final store = Store.open(':memory:');
  seed?.call(store);
  final actions = RecordingActions();
  final services = testServices(store: store, transport: device, clock: clock, actions: actions);
  final nav = AppNavigation();
  final toasts = <String>[];
  final confirms = <String>[];
  late Rig r;
  final commands = Commands(
    services: services,
    navigation: nav,
    toast: toasts.add,
    confirm: ({required title, required message, confirmLabel = 'OK', destructive = false}) async {
      confirms.add(message);
      return r.answer;
    },
  );
  services.scan.onMessage = toasts.add; // the shell does this in the app
  r = Rig(services, nav, commands, toasts, confirms, actions, device);
  addTearDown(() async {
    await services.dispose();
  });
  return r;
}

Map<String, Object?> scan(int n, String role, List<String> responses, {String? id}) => {
      'number': n,
      'role': role,
      'student_id': id,
      'student_name': null,
      'received_at': 'x',
      'answered_count': responses.where((r) => r.isNotEmpty).length,
      'responses': responses,
    };

void main() {
  group('the menu bar', () {
    test('has the old menus, without the ones that no longer apply', () {
      final r = rig();
      final menus = r.menus();
      expect(menus.whereType<PlatformMenu>().map((m) => m.label),
          ['DataLink Scanner', 'File', 'Edit', 'Scanner', 'View', 'Window', 'Help']);
      final labels = leaves(menus).map((i) => i.label).toList();
      expect(labels, isNot(contains('Check for Updates…')));
      expect(labels, isNot(contains('Reload')));
      expect(labels, isNot(contains('Open in Browser')));
      expect(labels, containsAll(['Open Session Folder', 'New Class…', 'Edit Selected Class…',
          'Export CSV…', 'Export Item Analysis…', 'Protocol Notes', 'Report an Issue']));
    });

    test('keeps the old shortcuts', () {
      final r = rig();
      String? keys(String label) {
        final s = menuItem(r.menus(), label).shortcut;
        if (s is! SingleActivator) return null;
        return '${s.meta ? '⌘' : ''}${s.shift ? '⇧' : ''}${s.trigger.keyLabel.toUpperCase()}';
      }

      expect({
        for (final l in [
          'New Class…', 'Export CSV…', 'Export Item Analysis…', 'Start Scanning Session', 'End Session',
          'Scan', 'Classes', 'Sessions', 'Analysis', 'Settings', 'Back',
        ])
          l: keys(l),
      }, {
        'New Class…': '⌘N',
        'Export CSV…': '⌘E',
        'Export Item Analysis…': '⌘⇧E',
        'Start Scanning Session': '⌘K',
        'End Session': '⌘⇧K',
        'Scan': '⌘1',
        'Classes': '⌘3',
        'Sessions': '⌘4',
        'Analysis': '⌘5',
        'Settings': '⌘6',
        'Back': '⌘[',
      });
    });

    test('scanner items are enabled for the same reasons their buttons are', () async {
      final r = rig();
      bool on(String label) => menuItem(r.menus(), label).onSelected != null;
      expect(on('Start Scanning Session'), isTrue);
      expect(on('End Session'), isFalse);
      expect(on('Re-send Handshake'), isFalse);
      expect(on('Disconnect'), isFalse);
      expect(on('Skip Absent Student'), isFalse);
      expect(on('Clear View'), isTrue);

      await r.services.scan.start();
      expect(on('Start Scanning Session'), isFalse);
      expect(on('End Session'), isTrue);
      expect(on('Re-send Handshake'), isTrue);
      expect(on('Disconnect'), isTrue);
      expect(on('Clear View'), isFalse, reason: 'not while a session is running');
      await r.services.scan.disconnect();
    });

    test('Back is offered only when there is somewhere to go back to', () {
      final r = rig();
      expect(menuItem(r.menus(), 'Back').onSelected, isNull);
      r.nav.show(AppView.classes);
      expect(menuItem(r.menus(), 'Back').onSelected, isNotNull);
    });

    test('Appearance offers system, light and dark, and marks the current one', () {
      final r = rig();
      String? current() => [
            for (final item in leaves(r.menus()))
              if (item.label.startsWith('✓ ')) item.label.substring(2),
          ].singleOrNull;
      expect(current(), 'Match System');
      menuItem(r.menus(), '    Dark').onSelected!();
      expect(r.services.appearance.mode, ThemeMode.dark);
      expect(current(), 'Dark');
      menuItem(r.menus(), '    Light').onSelected!();
      expect(current(), 'Light');
    });

    test('the protocol item says what it would do', () {
      final r = rig();
      expect(leaves(r.menus()).any((i) => i.label == 'Show Protocol Details'), isTrue);
      r.services.scan.toggleProtocol();
      expect(leaves(r.menus()).any((i) => i.label == 'Hide Protocol Details'), isTrue);
    });
  });

  group('the menu bar is only replaced when what it shows changes', () {
    test('the same list comes back while nothing has changed, even though menus are rebuilt', () {
      final r = rig();
      final cache = MenuCache();
      final first = cache.stable(r.menus());
      expect(identical(cache.stable(r.menus()), first), isTrue, reason: 'an open menu would close otherwise');
      r.services.scan.notifyListeners();
      expect(identical(cache.stable(r.menus()), first), isTrue);
    });

    test('a change a person can see replaces it', () {
      final r = rig();
      final cache = MenuCache();
      final first = cache.stable(r.menus());
      r.services.scan.toggleProtocol();
      expect(identical(cache.stable(r.menus()), first), isFalse);
      final second = cache.stable(r.menus());
      r.nav.show(AppView.classes);
      expect(identical(cache.stable(r.menus()), second), isFalse, reason: 'Back became available');
    });
  });

  group('commands', () {
    test('New Class opens an empty editor on the Classes tab', () {
      final r = rig();
      r.commands.newClass();
      expect(r.nav.view, AppView.classes);
      expect(r.services.classBook.editorRequest.value, isNotNull);
      expect(r.services.classBook.editorRequest.value!.name, isNull);
    });

    test('Edit Selected Class opens the selected class, or an empty one when there is none', () {
      final r = rig(seed: (s) {
        s
          ..saveClass('P4', [
            {'id': '1', 'name': 'Ada'},
          ])
          ..setSetting('selected_class', 'P4');
      });
      r.services.classBook.load();
      r.commands.editClass();
      expect(r.services.classBook.editorRequest.value!.name, 'P4');
      r.services.classBook.select('');
      r.commands.editClass();
      expect(r.services.classBook.editorRequest.value!.name, isNull);
    });

    test('two menu requests in a row are both seen', () {
      final r = rig();
      r.commands.newClass();
      final first = r.services.classBook.editorRequest.value;
      r.commands.newClass();
      expect(r.services.classBook.editorRequest.value, isNot(first));
    });

    test('Export CSV takes the sheets on screen, or the open session on Sessions', () async {
      final r = rig(seed: (s) {
        final id = s.createSession('Unit 1', 'P4', 3);
        s
          ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
          ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      });
      await r.commands.exportCsv();
      expect(r.actions.saved.single.name, 'datalink-session.csv');
      expect(r.actions.saved.single.text.split('\r\n').where((l) => l.isNotEmpty), hasLength(1),
          reason: 'just the header: nothing is on the Scan tab');

      r.nav.openSession(1);
      await r.commands.exportCsv();
      expect(r.actions.saved.last.name, 'Unit 1.csv');
      expect(r.actions.saved.last.text, contains('900011'));
      expect(r.toasts.last, 'Saved Unit 1.csv');
    });

    test('Export Item Analysis needs a session open on Sessions', () async {
      final r = rig(seed: (s) {
        final id = s.createSession('Unit 1', 'P4', 3);
        s
          ..addScan(id, scan(1, 'key', ['A', 'B', 'C']))
          ..addScan(id, scan(2, 'student', ['A', 'B', 'C'], id: '900011'));
      });
      await r.commands.exportAnalysis();
      expect(r.toasts.last, 'Open a saved session first, then export its item analysis');
      expect(r.actions.saved, isEmpty);

      r.nav.openSession(1);
      await r.commands.exportAnalysis();
      expect(r.actions.saved.single.name, 'Unit 1.json');
    });

    test('Export Item Analysis on a session that cannot be scored says why', () async {
      final r = rig(seed: (s) => s.createSession('Empty', '', 3));
      r.nav.openSession(1);
      await r.commands.exportAnalysis();
      expect(r.toasts.last, 'Scoring needs exactly one answer key in the session; this one has 0');
    });

    test('End Session asks first, and cancelling ends nothing', () async {
      final r = rig();
      await r.services.scan.start();
      r.answer = false;
      await r.commands.endSession();
      expect(r.confirms.single, 'End this session? The sheets already captured stay saved under Sessions.');
      expect(r.services.scan.scanning, isTrue);
      r.answer = true;
      await r.commands.endSession();
      expect(r.services.scan.scanning, isFalse);
      await r.services.scan.disconnect();
    });

    test('End Session with no session does nothing, and does not ask', () async {
      final r = rig();
      await r.commands.endSession();
      expect(r.confirms, isEmpty);
    });

    test('Clear View asks; during a session it explains instead', () async {
      final r = rig();
      await r.commands.clearView();
      expect(r.confirms.single, 'Clear the scans shown here? The saved session is not deleted.');

      await r.services.scan.start();
      r.confirms.clear();
      await r.commands.clearView();
      expect(r.confirms, isEmpty);
      expect(r.toasts.last, startsWith('A session is running, so the sheets on screen'));
      await r.services.scan.disconnect();
    });

    test('Read Paper Batch shows Paper and offers the Open panel', () async {
      final r = rig();
      r.actions.nextPdfPath = '/no/such/scan.pdf';
      await r.commands.readPaperBatch();
      expect(r.nav.view, AppView.paper);
      expect(r.actions.pdfPicks, 1);
      // The file is not there, so the model says so rather than offering a form.
      expect(r.services.paper.file, isNull);
      expect(r.services.paper.error, contains('Could not open the PDF'));
    });

    test('Open Session Folder shows the data folder in Finder', () async {
      final r = rig();
      await r.commands.openSessionFolder();
      expect(r.actions.revealed, [r.services.dataDirectory.path]);
    });

    test('Help opens the repository pages in the browser', () async {
      final r = rig();
      await r.commands.openHelp();
      await r.commands.openProtocolNotes();
      await r.commands.reportIssue();
      expect(r.actions.opened, [
        '$repoUrl#use',
        '$repoUrl/blob/main/docs/PROTOCOL.md',
        '$repoUrl/issues',
      ]);
    });

    test('view commands navigate', () {
      final r = rig();
      r.commands.show(AppView.settings);
      expect(r.nav.view, AppView.settings);
    });
  });

  group('the window as a whole', () {
    testWidgets('a sheet that needs a person interrupts on any tab, not just Scan', (tester) async {
      tester.view.physicalSize = const Size(1600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final clock = TickClock();
      final device = LiveFakeTransport(clock: clock);
      final store = Store.open(':memory:')..setSetting('question_count', '3');
      final services = testServices(store: store, transport: device, clock: clock);
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect and start session'));
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      device.sendRecord(['A', 'B', 'C'], studentId: '');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Key'), findsOneWidget);

      // Leave the Scan tab, then feed a sheet with nobody to match it to.
      await tester.tap(find.text('Classes').first);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Key'), findsNothing, reason: 'we are on Classes now');
      device.sendRecord(['A', 'B', 'C'], studentId: '');
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Enter the student ID'), findsOneWidget, reason: 'the dialog opens over Classes');
      expect(find.text('New class'), findsOneWidget, reason: 'and Classes is still behind it');

      await tester.enterText(find.widgetWithText(TextField, 'Student ID'), '900011');
      await tester.tap(find.text('Save correction'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Enter the student ID'), findsNothing);
      expect(services.store.sessionScans(services.scan.snapshot.sessionId!).last['student_id'], '900011');

      await services.scan.disconnect();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    });

    testWidgets('the roster position survives leaving the Scan tab', (tester) async {
      tester.view.physicalSize = const Size(1600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = Store.open(':memory:')
        ..saveClass('P4', [
          {'id': '1', 'name': 'Ada'},
          {'id': '2', 'name': 'Bo'},
        ])
        ..setSetting('selected_class', 'P4');
      final services = testServices(store: store);
      services.classBook.load();
      services.scan.skipStudent();
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.pumpAndSettle();
      expect(find.text('P4 · 2 students · 1 handled · 1 remaining'), findsOneWidget);
      await tester.tap(find.text('Sessions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan').first);
      await tester.pumpAndSettle();
      expect(find.text('P4 · 2 students · 1 handled · 1 remaining'), findsOneWidget);
    });

    testWidgets('a menu request to add a class opens the editor even from another tab', (tester) async {
      tester.view.physicalSize = const Size(1600, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = testServices();
      await tester.pumpWidget(DataLinkApp(services: services));
      await tester.pumpAndSettle();
      // What File > New Class… does, from the Scan tab:
      services.classBook.requestEditor(null);
      await tester.tap(find.text('Classes').first);
      await tester.pumpAndSettle();
      expect(find.text('Add a class'), findsOneWidget);
    });
  });
}
