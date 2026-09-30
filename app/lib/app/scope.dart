import 'package:flutter/widgets.dart';

import 'navigation.dart';
import 'services.dart';

/// Hands [AppServices] to every screen below it.
class Services extends InheritedWidget {
  const Services({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<Services>();
    assert(scope != null, 'No Services above this widget');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(Services oldWidget) => services != oldWidget.services;
}

/// Hands the [AppNavigation] to every screen below it, and rebuilds them when
/// it changes.
class Nav extends InheritedNotifier<AppNavigation> {
  const Nav({super.key, required AppNavigation navigation, required super.child})
      : super(notifier: navigation);

  static AppNavigation of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<Nav>();
    assert(scope != null, 'No Nav above this widget');
    return scope!.notifier!;
  }

  /// Read without rebuilding when it changes (for event handlers).
  static AppNavigation read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<Nav>();
    assert(scope != null, 'No Nav above this widget');
    return scope!.notifier!;
  }
}
