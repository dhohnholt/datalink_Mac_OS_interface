import 'package:flutter/foundation.dart';

/// The tabs, in the order they appear.
enum AppView { scan, sessions, analysis, classes, settings }

/// The panes inside Analysis.
enum AnalysisPane { items, students, review, key, upload }

/// Where the teacher is, and the history Back walks through.
///
/// The old page kept this in the address bar, so Back worked, a reload did not
/// drop you on the Scan tab, and "the review list for this test" could be
/// pointed at. This is the same behaviour without a browser:
///
/// * the **selected test** persists across every tab, and choosing one in
///   Sessions or in Analysis selects it in both;
/// * Back steps through tabs and tests, but the Analysis sub-panes replace one
///   another in place, so Back leaves Analysis rather than stepping through
///   each pane.
class AppNavigation extends ChangeNotifier {
  AppNavigation();

  static const int _historyLimit = 50;

  AppView _view = AppView.scan;
  int? _sessionId;
  AnalysisPane _pane = AnalysisPane.items;
  final List<_Place> _history = [];

  AppView get view => _view;
  int? get sessionId => _sessionId;
  AnalysisPane get pane => _pane;
  bool get canGoBack => _history.isNotEmpty;

  /// Go to a tab, keeping the selected test.
  void show(AppView view) => _go(view: view);

  /// Select a test and show it in Sessions (the default) or Analysis.
  void openSession(int id, {AppView view = AppView.sessions, AnalysisPane? pane}) =>
      _go(view: view, sessionId: id, pane: pane ?? AnalysisPane.items);

  /// Stop working on the selected test.
  void clearSession() {
    if (_sessionId == null) return;
    _sessionId = null;
    _pane = AnalysisPane.items;
    notifyListeners();
  }

  void showPane(AnalysisPane pane) {
    if (_pane == pane) return;
    _pane = pane;
    notifyListeners();
  }

  void back() {
    if (_history.isEmpty) return;
    final place = _history.removeLast();
    _view = place.view;
    _sessionId = place.sessionId;
    _pane = place.pane;
    notifyListeners();
  }

  void _go({required AppView view, int? sessionId, AnalysisPane? pane}) {
    final next = _Place(view, sessionId ?? _sessionId, pane ?? _pane);
    final here = _Place(_view, _sessionId, _pane);
    if (next == here) return;
    _history.add(here);
    if (_history.length > _historyLimit) _history.removeAt(0);
    _view = next.view;
    _sessionId = next.sessionId;
    _pane = next.pane;
    notifyListeners();
  }
}

class _Place {
  const _Place(this.view, this.sessionId, this.pane);

  final AppView view;
  final int? sessionId;
  final AnalysisPane pane;

  @override
  bool operator ==(Object other) =>
      other is _Place &&
      other.view == view &&
      other.sessionId == sessionId &&
      other.pane == pane;

  @override
  int get hashCode => Object.hash(view, sessionId, pane);
}
