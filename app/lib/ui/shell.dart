import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/navigation.dart';
import '../app/scope.dart';
import '../features/analysis/analysis_screen.dart';
import '../features/classes/classes_screen.dart';
import '../features/scan/scan_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/sessions/sessions_screen.dart';
import 'widgets.dart';

/// Builds the screen for a tab.
typedef ScreenBuilder = Widget Function(BuildContext context);

class AppShell extends StatelessWidget {
  const AppShell({super.key, this.screens = const {}});

  /// Overrides, used by tests to stand in for screens that need hardware.
  final Map<AppView, ScreenBuilder> screens;

  static const _labels = <AppView, (String, IconData)>{
    AppView.scan: ('Scan', Icons.document_scanner_outlined),
    AppView.sessions: ('Sessions', Icons.history),
    AppView.analysis: ('Analysis', Icons.insights_outlined),
    AppView.classes: ('Classes', Icons.groups_outlined),
    AppView.settings: ('Settings', Icons.settings_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final nav = Nav.of(context);
    final views = AppView.values;
    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < views.length; i++)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: true):
              () => nav.show(views[i]),
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true): nav.back,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: views.indexOf(nav.view),
                onDestinationSelected: (index) => nav.show(views[index]),
                labelType: NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Semantics(
                    header: true,
                    child: Text('DataLink', style: Theme.of(context).textTheme.titleSmall),
                  ),
                ),
                destinations: [
                  for (final view in views)
                    NavigationRailDestination(
                      icon: Icon(_labels[view]!.$2),
                      label: Text(_labels[view]!.$1),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    const _ContextBar(),
                    Expanded(child: _screenFor(context, nav.view)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _screenFor(BuildContext context, AppView view) {
    final override = screens[view];
    if (override != null) return override(context);
    return switch (view) {
      AppView.scan => const ScanScreen(),
      AppView.sessions => const SessionsScreen(),
      AppView.analysis => const AnalysisScreen(),
      AppView.classes => const ClassesScreen(),
      AppView.settings => const SettingsScreen(),
    };
  }
}

/// The test being worked on, shown on every tab with shortcuts to its two
/// views. Hidden when no test is selected.
class _ContextBar extends StatelessWidget {
  const _ContextBar();

  @override
  Widget build(BuildContext context) {
    final nav = Nav.of(context);
    final id = nav.sessionId;
    if (id == null) return const SizedBox.shrink();
    final store = Services.of(context).store;
    final session = store.session(id);
    final scanCount = store.sessionScans(id).length;
    final name = (session?['name'] as String?)?.isNotEmpty == true
        ? session!['name']! as String
        : 'Untitled session';
    final meta = [
      if ((session?['class_name'] as String?)?.isNotEmpty == true) session!['class_name']! as String,
      '$scanCount sheets',
      formatTimestamp(session?['started_at'] as String?),
    ].join(' · ');
    return Semantics(
      container: true,
      label: 'Working on $name. $meta',
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: Theme.of(context).textTheme.titleSmall),
                    Text(meta, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              SegmentedButton<AppView>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: AppView.sessions, label: Text('Sheets')),
                  ButtonSegment(value: AppView.analysis, label: Text('Analysis')),
                ],
                emptySelectionAllowed: true,
                selected: {if (nav.view == AppView.sessions || nav.view == AppView.analysis) nav.view},
                onSelectionChanged: (selection) {
                  if (selection.isNotEmpty) nav.show(selection.first);
                },
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: nav.clearSession,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
