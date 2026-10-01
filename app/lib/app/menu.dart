import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'commands.dart';
import 'navigation.dart';
import 'services.dart';

/// The menu bar, as the old app had it (app.py `_build_menu`), minus what no
/// longer exists: Check for Updates (the store delivers updates), Reload, and
/// Open in Browser (there is no page).
///
/// Built from the current state, so a disabled item is disabled for the same
/// reason its button is.
List<PlatformMenuItem> buildMenus({
  required Commands commands,
  required AppServices services,
  required AppNavigation navigation,
}) {
  final scan = services.scan;
  SingleActivator cmd(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: true, shift: shift);

  PlatformMenuItem item(
    String label,
    VoidCallback? onSelected, {
    MenuSerializableShortcut? shortcut,
  }) =>
      PlatformMenuItem(label: label, onSelected: onSelected, shortcut: shortcut);

  // Text-editing commands go to whatever text box has focus, through the same
  // intents its own keyboard shortcuts use.
  void toFocus(Intent intent) {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context != null) Actions.maybeInvoke(context, intent);
  }

  return [
    PlatformMenu(label: 'DataLink Scanner', menus: [
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
      PlatformMenuItemGroup(members: [
        item('Open Session Folder', commands.openSessionFolder),
      ]),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
      ]),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
      ]),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
      ]),
    ]),
    PlatformMenu(label: 'File', menus: [
      PlatformMenuItemGroup(members: [
        item('Read Paper Batch…', commands.readPaperBatch, shortcut: cmd(LogicalKeyboardKey.keyO)),
      ]),
      PlatformMenuItemGroup(members: [
        item('New Class…', commands.newClass, shortcut: cmd(LogicalKeyboardKey.keyN)),
        item('Edit Selected Class…', commands.editClass),
      ]),
      PlatformMenuItemGroup(members: [
        item('Export CSV…', commands.exportCsv, shortcut: cmd(LogicalKeyboardKey.keyE)),
        item(
          'Export Item Analysis…',
          commands.exportAnalysis,
          shortcut: cmd(LogicalKeyboardKey.keyE, shift: true),
        ),
      ]),
      PlatformMenuItemGroup(members: [
        item('Close Window', SystemNavigator.pop, shortcut: cmd(LogicalKeyboardKey.keyW)),
      ]),
    ]),
    PlatformMenu(label: 'Edit', menus: [
      PlatformMenuItemGroup(members: [
        item('Undo', () => toFocus(const UndoTextIntent(SelectionChangedCause.keyboard)),
            shortcut: cmd(LogicalKeyboardKey.keyZ)),
        item('Redo', () => toFocus(const RedoTextIntent(SelectionChangedCause.keyboard)),
            shortcut: cmd(LogicalKeyboardKey.keyZ, shift: true)),
      ]),
      PlatformMenuItemGroup(members: [
        item('Cut', () => toFocus(CopySelectionTextIntent.cut(SelectionChangedCause.keyboard)),
            shortcut: cmd(LogicalKeyboardKey.keyX)),
        item('Copy', () => toFocus(CopySelectionTextIntent.copy), shortcut: cmd(LogicalKeyboardKey.keyC)),
        item('Paste', () => toFocus(const PasteTextIntent(SelectionChangedCause.keyboard)),
            shortcut: cmd(LogicalKeyboardKey.keyV)),
        item('Select All', () => toFocus(const SelectAllTextIntent(SelectionChangedCause.keyboard)),
            shortcut: cmd(LogicalKeyboardKey.keyA)),
      ]),
    ]),
    PlatformMenu(label: 'Scanner', menus: [
      PlatformMenuItemGroup(members: [
        item('Start Scanning Session', scan.canStart ? commands.startSession : null,
            shortcut: cmd(LogicalKeyboardKey.keyK)),
        item('End Session', scan.canEnd ? commands.endSession : null,
            shortcut: cmd(LogicalKeyboardKey.keyK, shift: true)),
      ]),
      PlatformMenuItemGroup(members: [
        item('Re-send Handshake', scan.canReset ? commands.resetScanner : null),
        item('Disconnect', scan.canDisconnect ? commands.disconnect : null),
      ]),
      PlatformMenuItemGroup(members: [
        item('Skip Absent Student', scan.canSkip ? commands.skipStudent : null),
        item('Start at First Student', scan.canStartAtFirst ? commands.startAtFirstStudent : null),
      ]),
      PlatformMenuItemGroup(members: [
        item('Clear View', scan.canClear ? commands.clearView : null),
      ]),
    ]),
    PlatformMenu(label: 'View', menus: [
      PlatformMenuItemGroup(members: [
        item('Scan', () => commands.show(AppView.scan), shortcut: cmd(LogicalKeyboardKey.digit1)),
        item('Paper', () => commands.show(AppView.paper), shortcut: cmd(LogicalKeyboardKey.digit2)),
        item('Classes', () => commands.show(AppView.classes), shortcut: cmd(LogicalKeyboardKey.digit3)),
        item('Sessions', () => commands.show(AppView.sessions), shortcut: cmd(LogicalKeyboardKey.digit4)),
        item('Analysis', () => commands.show(AppView.analysis), shortcut: cmd(LogicalKeyboardKey.digit5)),
        item('Settings', () => commands.show(AppView.settings), shortcut: cmd(LogicalKeyboardKey.digit6)),
      ]),
      PlatformMenuItemGroup(members: [
        item('Back', navigation.canGoBack ? navigation.back : null,
            shortcut: cmd(LogicalKeyboardKey.bracketLeft)),
      ]),
      PlatformMenuItemGroup(members: [
        item(
          scan.showProtocol ? 'Hide Protocol Details' : 'Show Protocol Details',
          commands.toggleProtocol,
        ),
      ]),
    ]),
    const PlatformMenu(label: 'Window', menus: [
      PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
      ]),
      PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
      ]),
    ]),
    PlatformMenu(label: 'Help', menus: [
      PlatformMenuItemGroup(members: [
        item('DataLink Scanner Help', commands.openHelp, shortcut: const CharacterActivator('?', meta: true)),
        item('Protocol Notes', commands.openProtocolNotes),
      ]),
      PlatformMenuItemGroup(members: [
        item('Report an Issue', commands.reportIssue),
      ]),
    ]),
  ];
}
