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
        delegate.save_csv = lambda query, filename: saved.append((query, filename))

        for payload in (None, "nope", 42, {}, {"action": "unknown"}):
            delegate.userContentController_didReceiveScriptMessage_(None, Message(payload))
        self.assertEqual(saved, [])

        delegate.userContentController_didReceiveScriptMessage_(
            None, Message({"action": "export", "query": "name=Unit+1", "filename": "Unit 1.csv"})
        )
        self.assertEqual(saved, [("name=Unit+1", "Unit 1.csv")])


if __name__ == "__main__":
    unittest.main()
