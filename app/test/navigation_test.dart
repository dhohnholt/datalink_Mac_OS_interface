import 'package:datalink_scanner/app/navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts on Scan with nothing selected', () {
    final nav = AppNavigation();
    expect(nav.view, AppView.scan);
    expect(nav.sessionId, isNull);
    expect(nav.canGoBack, isFalse);
  });

  test('the selected test follows you across tabs', () {
    final nav = AppNavigation()
      ..openSession(5)
      ..show(AppView.analysis);
    expect(nav.sessionId, 5, reason: 'choosing in Sessions selects it in Analysis');
    nav.show(AppView.classes);
    expect(nav.sessionId, 5);
    nav.show(AppView.sessions);
    expect(nav.sessionId, 5);
  });

  test('Back retraces tabs and tests', () {
    final nav = AppNavigation()
      ..show(AppView.classes)
      ..openSession(3)
      ..openSession(4, view: AppView.analysis);
    expect((nav.view, nav.sessionId), (AppView.analysis, 4));
    nav.back();
    expect((nav.view, nav.sessionId), (AppView.sessions, 3));
    nav.back();
    expect((nav.view, nav.sessionId), (AppView.classes, null));
    nav.back();
    expect(nav.view, AppView.scan);
    expect(nav.canGoBack, isFalse);
    nav.back(); // nothing left: harmless
    expect(nav.view, AppView.scan);
  });

  test('switching Analysis panes does not fill the history', () {
    final nav = AppNavigation()..openSession(1, view: AppView.analysis);
    nav
      ..showPane(AnalysisPane.review)
      ..showPane(AnalysisPane.key)
      ..showPane(AnalysisPane.students);
    nav.back();
    expect(nav.view, AppView.scan, reason: 'one Back leaves Analysis');
  });

  test('going where you already are adds nothing', () {
    final nav = AppNavigation()
      ..show(AppView.scan)
      ..show(AppView.scan);
    expect(nav.canGoBack, isFalse);
  });

  test('clearing the test forgets it and the pane', () {
    final nav = AppNavigation()
      ..openSession(2, view: AppView.analysis, pane: AnalysisPane.review)
      ..clearSession();
    expect(nav.sessionId, isNull);
    expect(nav.pane, AnalysisPane.items);
    expect(nav.view, AppView.analysis, reason: 'you stay on the tab');
  });

  test('notifies listeners only when something changed', () {
    final nav = AppNavigation();
    var calls = 0;
    nav.addListener(() => calls++);
    nav
      ..show(AppView.scan)
      ..showPane(AnalysisPane.items)
      ..clearSession();
    expect(calls, 0);
    nav.show(AppView.classes);
    expect(calls, 1);
  });

  test('history is bounded', () {
    final nav = AppNavigation();
    for (var i = 0; i < 200; i++) {
      nav.openSession(i);
    }
    var steps = 0;
    while (nav.canGoBack) {
      nav.back();
      steps++;
    }
    expect(steps, 50);
  });
}
