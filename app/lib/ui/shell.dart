import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../app/commands.dart';
import '../app/menu.dart';
import '../app/palette.dart';
import '../app/navigation.dart';
import '../app/scope.dart';
import '../features/analysis/analysis_screen.dart';
import '../features/classes/classes_screen.dart';
import '../features/paper/paper_screen.dart';
import '../features/scan/review_dialog.dart';
import '../features/scan/scan_model.dart';
import '../features/scan/scan_screen.dart';
import '../features/sessions/sessions_screen.dart';
import '../features/settings/settings_screen.dart';
import 'widgets.dart';

/// Builds the screen for a tab.
typedef ScreenBuilder = Widget Function(BuildContext context);

/// The window: a tab rail, the current screen, and three things that belong to
/// the whole app rather than to a tab.
///
/// * Toasts show on every tab.
/// * The review dialog opens over whichever tab is showing. The old page kept
///   every tab alive at once, so a sheet that needed a person interrupted
///   wherever they were; this keeps that.
/// * The menu bar, whose commands work from any tab.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.screens = const {}});

  /// Overrides, used by tests to stand in for screens that need hardware.
  final Map<AppView, ScreenBuilder> screens;

  static const labels = <AppView, (String, IconData)>{
    AppView.scan: ('Scan', Icons.document_scanner_outlined),
    AppView.paper: ('Paper', Icons.description_outlined),
    AppView.sessions: ('Sessions', Icons.history),
    AppView.analysis: ('Analysis', Icons.insights_outlined),
    AppView.classes: ('Classes', Icons.groups_outlined),
    AppView.settings: ('Settings', Icons.settings_outlined),
  };

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  Commands? _commands;
  bool _reviewOpen = false;
  final MenuCache _menuCache = MenuCache();
  ScanModel? _scan;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_commands != null) return;
    final services = Services.of(context);
    final nav = Nav.read(context);
    _commands = Commands(
      services: services,
      navigation: nav,
      toast: (message) {
        if (mounted) showToast(context, message);
      },
      confirm: ({required title, required message, confirmLabel = 'OK', destructive = false}) =>
          confirmDialog(
            context,
            title: title,
            message: message,
            confirmLabel: confirmLabel,
            destructive: destructive,
          ),
    );
    _scan = services.scan;
    services.scan
      ..onMessage = _commands!.toast
      ..addListener(_maybeReview);
  }

  @override
  void dispose() {
    _scan?.removeListener(_maybeReview);
    super.dispose();
  }

  /// Open the review dialog when a sheet needs a person. The dialog closes
  /// itself, including when the sheet is dealt with some other way.
  void _maybeReview() {
    final scan = Services.of(context).scan;
    if (scan.pendingPlan == null || _reviewOpen) return;
    _reviewOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || scan.pendingPlan == null) {
        _reviewOpen = false;
        return;
      }
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ReviewDialog(model: scan),
      ).whenComplete(() => _reviewOpen = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final nav = Nav.of(context);
    final services = Services.of(context);
    final views = AppView.values;
    final commands = _commands!;
    return ListenableBuilder(
      // The menu reflects what is possible right now, so it is rebuilt when
      // the scanner or the navigation changes.
      listenable: Listenable.merge([services.scan, nav, services.appearance]),
      builder: (context, _) => _withMenuBar(
        menus: () => _menuCache.stable(buildMenus(commands: commands, services: services, navigation: nav)),
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
                    child: Text(
                      'DataLink',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Palette.of(Theme.of(context).brightness).railSelected,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                destinations: [
                  for (final view in views)
                    NavigationRailDestination(
                      icon: Icon(AppShell.labels[view]!.$2),
                      label: Text(AppShell.labels[view]!.$1),
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

  /// The native menu bar exists on macOS only; elsewhere (including widget
  /// tests) there is nothing to install. Its structure is tested through
  /// [buildMenus] directly.
  Widget _withMenuBar({required List<PlatformMenuItem> Function() menus, required Widget child}) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;
    return PlatformMenuBar(menus: menus(), child: child);
  }

  Widget _screenFor(BuildContext context, AppView view) {
    final override = widget.screens[view];
    if (override != null) return override(context);
    return switch (view) {
      AppView.scan => const ScanScreen(),
      AppView.paper => const PaperScreen(),
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
