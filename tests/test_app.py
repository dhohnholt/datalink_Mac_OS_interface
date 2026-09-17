"""Tests for the native shell that do not need a running NSApplication.

The window and menu bar are verified by launching the app; what is worth
pinning down here is the glue that silently breaks: the packaged icon, the
menu-to-JS bridge names, and the native-mode branch in the page.
"""

import re
import unittest
from pathlib import Path

from datalink_scanner import paths


WEBUI = Path(paths.web_root())
APP_JS = (WEBUI / "app.js").read_text()


class IconTests(unittest.TestCase):
    def test_icon_ships_with_the_package(self):
        from datalink_scanner.app import icon_path

        path = icon_path()
        self.assertIsNotNone(path, "the .icns must be installed as package data")
        self.assertGreater(path.stat().st_size, 0)


class MenuBridgeTests(unittest.TestCase):
    """Every menu action calls window.datalinkMenu.<name>; a rename on either
    side turns the menu item into a silent no-op."""

    def setUp(self):
        source = Path(__file__).resolve().parents[1] / "src" / "datalink_scanner" / "app.py"
        self.app_source = source.read_text()

    def test_every_menu_call_has_a_javascript_counterpart(self):
        called = set(re.findall(r"datalinkMenu\.(\w+)\(\)", self.app_source))
        self.assertTrue(called, "no menu bridge calls found in app.py")
        defined = set(re.findall(r"^\s{2}(\w+):", APP_JS, re.MULTILINE))
        missing = called - defined
        self.assertFalse(missing, f"app.py calls datalinkMenu.{missing} which app.js does not define")

    def test_bridge_targets_exist_in_the_page(self):
        html = (WEBUI / "index.html").read_text()
        for element_id in re.findall(r'\$\("#(\w+)"\)\.click\(\)', APP_JS):
            self.assertIn(
                f'id="{element_id}"', html, f"#{element_id} is clicked but not in index.html"
            )


class NativeModeTests(unittest.TestCase):
    def test_quit_button_is_removed_in_the_native_shell(self):
        # Cmd-Q owns quitting there; the in-page button would stop the server
        # and leave a live window on a dead page.
        self.assertIn("$(\"#quitButton\").remove()", APP_JS)

    def test_export_is_handed_to_the_app(self):
        # A WKWebView will not act on <a download>, so the native build must
        # route the export through the message handler instead.
        self.assertIn("messageHandlers.datalink.postMessage", APP_JS)
        self.assertIn('action: "export"', APP_JS)

    def test_browser_mode_keeps_its_own_quit_control(self):
        html = (WEBUI / "index.html").read_text()
        self.assertIn('id="quitButton"', html)


class ScriptMessageTests(unittest.TestCase):
    def test_handler_ignores_unexpected_payloads(self):
        from datalink_scanner.app import DataLinkAppDelegate

        delegate = DataLinkAppDelegate.alloc().initWithCaptureDir_(None)

        class Message:
            def __init__(self, body):
                self._body = body

            def body(self):
                return self._body

        saved = []
        delegate.save_csv = lambda query, filename, path="/api/export.csv": saved.append(
            (query, filename, path)
        )

        for payload in (None, "nope", 42, {}, {"action": "unknown"}):
            delegate.userContentController_didReceiveScriptMessage_(None, Message(payload))
        self.assertEqual(saved, [])

        delegate.userContentController_didReceiveScriptMessage_(
            None, Message({"action": "export", "query": "name=Unit+1", "filename": "Unit 1.csv"})
        )
        self.assertEqual(saved, [("name=Unit+1", "Unit 1.csv", "/api/export.csv")])

    def test_handler_exports_a_saved_session(self):
        from datalink_scanner.app import DataLinkAppDelegate

        delegate = DataLinkAppDelegate.alloc().initWithCaptureDir_(None)
        saved = []
        delegate.save_csv = lambda query, filename, path: saved.append(path)

        class Message:
            def __init__(self, body):
                self._body = body

            def body(self):
                return self._body

        delegate.userContentController_didReceiveScriptMessage_(
            None,
            Message({"action": "export", "filename": "s.csv", "path": "/api/sessions/7/export.csv"}),
        )
        self.assertEqual(saved, ["/api/sessions/7/export.csv"])

    def test_handler_refuses_a_path_outside_the_api(self):
        # The page should never be able to talk the app into fetching and
        # writing out something that is not one of our own endpoints.
        from datalink_scanner.app import DataLinkAppDelegate

        delegate = DataLinkAppDelegate.alloc().initWithCaptureDir_(None)
        saved = []
        delegate.save_csv = lambda *args: saved.append(args)

        class Message:
            def __init__(self, body):
                self._body = body

            def body(self):
                return self._body

        for path in ("/etc/passwd", "http://example.com/x", "../secrets"):
            delegate.userContentController_didReceiveScriptMessage_(
                None, Message({"action": "export", "filename": "x.csv", "path": path})
            )
        self.assertEqual(saved, [])


if __name__ == "__main__":
    unittest.main()


class ViewSwitchingTests(unittest.TestCase):
    """The three views are toggled with the `hidden` attribute, and `main` sets
    an explicit display, so the stylesheet has to beat it or every view shows
    at once."""

    def test_stylesheet_forces_hidden_to_win(self):
        css = (WEBUI / "styles.css").read_text()
        self.assertIn("[hidden]", css)
        self.assertIn("display: none !important", css)

    def test_every_tab_has_a_matching_view(self):
        html = (WEBUI / "index.html").read_text()
        tabs = set(re.findall(r'data-view="(\w+)"', html))
        self.assertEqual(tabs, {"scan", "classes", "sessions", "analysis"})
        for view in tabs:
            self.assertIn(f'id="view-{view}"', html)


class BundleIdentityTests(unittest.TestCase):
    """macOS takes an app's name, Dock tile and icon from the bundle around the
    running executable. Exec'ing an interpreter that lives outside the bundle
    hands it Python's identity instead, so the bundle must carry its own."""

    def setUp(self):
        script = Path(__file__).resolve().parents[1] / "packaging" / "make_app_bundle.sh"
        self.script = script.read_text()

    def test_bundle_embeds_the_framework_interpreter(self):
        self.assertIn("python-runtime", self.script)
        # bin/python3.x is a stub that re-execs the inner binary, so copying it
        # would put us right back outside the bundle.
        self.assertIn("Python.app", self.script)
        self.assertIn("base_prefix", self.script)

    def test_launcher_uses_addsitedir_not_pythonpath(self):
        # PYTHONPATH entries skip .pth processing, which editable and namespace
        # installs depend on.
        self.assertIn("site.addsitedir", self.script)

    def test_a_fallback_exists_for_non_framework_pythons(self):
        self.assertIn('exec "$CLI" app', self.script)


class HintTests(unittest.TestCase):
    """Inline help is a button revealing a bubble, not static text under the
    field."""

    def setUp(self):
        self.html = (WEBUI / "index.html").read_text()
        self.css = (WEBUI / "styles.css").read_text()

    def test_the_form_length_hint_is_a_bubble_not_body_text(self):
        hint = "unanswered questions at the end are kept as blanks"
        self.assertIn(hint, self.html)
        # It belongs in the bubble, not as standing text under the field.
        bubble = self.html[self.html.index('class="hint-bubble"') :]
        self.assertIn(hint, bubble[: bubble.index("</span>")])
        controls = self.html[self.html.index('class="controls"') :]
        self.assertNotIn("<small>", controls[: controls.index("</section>")])

    def test_every_hint_button_controls_a_real_bubble(self):
        buttons = re.findall(r'<button[^>]*class="hint"[^>]*>', self.html)
        self.assertTrue(buttons)
        for button in buttons:
            target = re.search(r'aria-controls="([^"]+)"', button)
            self.assertIsNotNone(target, button)
            self.assertIn(f'id="{target.group(1)}"', self.html)

    def test_the_field_points_at_its_own_hint(self):
        self.assertIn('aria-describedby="questionCountHint"', self.html)

    def test_hint_opens_on_focus_as_well_as_hover(self):
        # Hover alone would leave the hint unreachable from the keyboard.
        self.assertIn(".hint:focus-visible + .hint-bubble", self.css)
        self.assertIn(".hint-bubble.open", self.css)

    def test_the_bubble_does_not_capture_the_pointer(self):
        # It is a child of its own hover target and floats over neighbouring
        # controls, so without this it holds itself open and eats their clicks.
        bubble = self.css[self.css.index(".hint-bubble {"):]
        self.assertIn("pointer-events: none", bubble[: bubble.index("}")])

    def test_leaving_closes_a_hint_opened_by_clicking(self):
        self.assertIn('"mouseleave"', APP_JS)
        self.assertIn('"blur"', APP_JS)

    def test_hint_can_be_dismissed(self):
        self.assertIn("closeHints", APP_JS)
        self.assertIn('event.key === "Escape"', APP_JS)

    def test_the_bubble_is_kept_inside_the_window(self):
        # Anchoring in CSS alone just moves the overflow to the other edge.
        self.assertIn("placeHint", APP_JS)
        self.assertIn("window.innerWidth", APP_JS)
        self.assertIn('"resize"', APP_JS)
        self.assertIn("--arrow-left", APP_JS)
        self.assertIn("var(--arrow-left", self.css)

    def test_the_hint_button_is_never_stretched_full_width(self):
        # .controls button { width: 100% } at narrow widths turned the circle
        # into a long ellipse.
        self.assertNotIn(".controls button { width: 100%; }", self.css)
        self.assertIn(".controls button:not(.hint)", self.css)
        self.assertIn("aspect-ratio: 1", self.css)


class SignalHandlingTests(unittest.TestCase):
    """A `kill` must go through the same shutdown as Cmd-Q, or the database is
    left with an unmerged write-ahead log."""

    def setUp(self):
        root = Path(__file__).resolve().parents[1] / "src" / "datalink_scanner"
        self.app_source = (root / "app.py").read_text()
        self.server_source = (root / "server.py").read_text()

    def test_the_app_waits_on_signals_in_a_thread(self):
        # The main thread sits inside NSApplication.run(), so Python would not
        # get to run an ordinary handler.
        self.assertIn("pthread_sigmask", self.app_source)
        self.assertIn("sigwait", self.app_source)
        self.assertIn("SIGTERM", self.app_source)

    def test_the_app_terminates_through_appkit(self):
        # Going through terminate: keeps applicationShouldTerminate_ in play,
        # which is what closes the store.
        self.assertIn("performSelectorOnMainThread", self.app_source)
        self.assertIn('"terminate:"', self.app_source)

    def test_browser_mode_handles_sigterm_too(self):
        self.assertIn("signal.signal", self.server_source)
        self.assertIn("SIGTERM", self.server_source)

    def test_signals_are_blocked_before_threads_start(self):
        # Threads inherit the mask, so this has to happen first.
        install = self.app_source.index("def install_signal_handlers")
        run = self.app_source.index("def run(")
        self.assertLess(install, run)
        self.assertIn("install_signal_handlers()", self.app_source)


class TimestampTests(unittest.TestCase):
    def test_an_unparseable_timestamp_does_not_render_as_invalid_date(self):
        self.assertIn("Number.isNaN(when.getTime())", APP_JS)


class AnalysisButtonTests(unittest.TestCase):
    def setUp(self):
        self.html = (WEBUI / "index.html").read_text()

    def test_the_session_view_offers_an_item_analysis_export(self):
        self.assertIn('id="sessionAnalysisButton"', self.html)
        self.assertIn("analysis.json", APP_JS)

    def test_it_is_routed_through_the_native_save_panel(self):
        self.assertIn('"sessionAnalysisButton"', APP_JS)

    def test_a_disabled_export_does_not_navigate(self):
        self.assertIn('classList.contains("disabled")', APP_JS)
