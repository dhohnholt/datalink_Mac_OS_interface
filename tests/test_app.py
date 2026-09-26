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

    def test_handler_copies_text_to_the_pasteboard(self):
        # The integration specification is copied this way because a
        # WKWebView refuses both web clipboard routes often enough that a
        # button relying on them is one that sometimes silently does nothing.
        from AppKit import NSPasteboard, NSPasteboardTypeString
        from datalink_scanner.app import DataLinkAppDelegate

        delegate = DataLinkAppDelegate.alloc().initWithCaptureDir_(None)

        class Message:
            def __init__(self, body):
                self._body = body

            def body(self):
                return self._body

        board = NSPasteboard.generalPasteboard()
        before = board.stringForType_(NSPasteboardTypeString)
        self.addCleanup(
            lambda: (
                board.clearContents(),
                before is not None
                and board.setString_forType_(before, NSPasteboardTypeString),
            )
        )

        delegate.userContentController_didReceiveScriptMessage_(
            None, Message({"action": "copyText", "text": "a specification"})
        )
        self.assertEqual(
            board.stringForType_(NSPasteboardTypeString), "a specification"
        )

        # Nothing usable to copy must leave what is there alone.
        for payload in ({"action": "copyText"}, {"action": "copyText", "text": ""},
                        {"action": "copyText", "text": 7}):
            delegate.userContentController_didReceiveScriptMessage_(None, Message(payload))
            self.assertEqual(
                board.stringForType_(NSPasteboardTypeString), "a specification"
            )

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
        self.assertEqual(
            tabs, {"scan", "paper", "classes", "sessions", "analysis", "settings"}
        )
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
        # It belongs in its own bubble, not as standing text under the field.
        # Found by id rather than by being first, so adding another hint to the
        # row does not silently point this at the wrong one.
        bubble = self.html[self.html.index('id="questionCountHint"') :]
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


class InstallAppTests(unittest.TestCase):
    """Replacing a previous install must not strand the user on a stale build,
    and must not clobber somebody else's app."""

    def setUp(self):
        import tempfile

        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def make_app(self, path, identifier):
        (path / "Contents").mkdir(parents=True)
        (path / "Contents" / "Info.plist").write_bytes(
            b'<?xml version="1.0" encoding="UTF-8"?>'
            b'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            b'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
            b'<plist version="1.0"><dict><key>CFBundleIdentifier</key>'
            + f"<string>{identifier}</string>".encode()
            + b"</dict></plist>"
        )
        return path

    def test_reads_a_bundle_identifier(self):
        from datalink_scanner.cli import BUNDLE_IDENTIFIER, bundle_identifier

        app = self.make_app(self.root / "One.app", BUNDLE_IDENTIFIER)
        self.assertEqual(bundle_identifier(app), BUNDLE_IDENTIFIER)

    def test_an_unreadable_bundle_has_no_identifier(self):
        from datalink_scanner.cli import bundle_identifier

        (self.root / "Broken.app").mkdir()
        self.assertIsNone(bundle_identifier(self.root / "Broken.app"))

    def test_trash_names_do_not_collide(self):
        # Two replacements in the same second used to nest one inside the other.
        import os
        from datalink_scanner.cli import move_to_trash

        home = self.root / "home"
        (home / ".Trash").mkdir(parents=True)
        previous = os.environ.get("HOME")
        os.environ["HOME"] = str(home)
        try:
            first = move_to_trash(self.make_app(self.root / "A.app", "x"))
            second = move_to_trash(self.make_app(self.root / "A.app", "x"))
        finally:
            if previous is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = previous
        self.assertNotEqual(first, second)
        self.assertTrue(first.is_dir() and second.is_dir())
        self.assertNotIn(second.name, [item.name for item in first.iterdir()])


class NoShadowedFunctionsTests(unittest.TestCase):
    """Two top-level functions with one name silently shadow each other.

    This is not hypothetical: an analysis-page renderReview() overwrote the
    scan page's review dialog, so feeding a sheet that needed a student ID
    threw instead of prompting.
    """

    def test_no_top_level_function_is_defined_twice(self):
        names = re.findall(r"^function (\w+)", APP_JS, re.MULTILINE)
        duplicates = sorted({name for name in names if names.count(name) > 1})
        self.assertEqual(duplicates, [], f"defined more than once: {duplicates}")

    def test_no_top_level_const_or_let_is_declared_twice(self):
        names = re.findall(r"^(?:const|let) (\w+)\s*=", APP_JS, re.MULTILINE)
        duplicates = sorted({name for name in names if names.count(name) > 1})
        self.assertEqual(duplicates, [], f"declared more than once: {duplicates}")


class ConnectCardLayoutTests(unittest.TestCase):
    """The connection row holds four fields that must line up."""

    def setUp(self):
        self.html = (WEBUI / "index.html").read_text()
        self.css = (WEBUI / "styles.css").read_text()

    def test_the_class_picker_sits_with_the_other_fields(self):
        controls = self.html[self.html.index('class="controls"') :]
        controls = controls[: controls.index("</div>")]
        for field in ("testName", "classSelect", "portSelect", "questionCount"):
            self.assertIn(f'id="{field}"', controls, field)

    def test_connect_buttons_moved_to_the_card_header(self):
        header = self.html[self.html.index('class="card connect-card"') :]
        header = header[: header.index('class="controls"')]
        self.assertIn('id="connectButton"', header)
        self.assertIn('id="disconnectButton"', header)

    def test_every_field_is_captioned_the_same_way(self):
        # A bare text node next to the control made one caption taller than the
        # rest, which is what knocked the row out of alignment.
        controls = self.html[self.html.index('class="controls"') :]
        controls = controls[: controls.index("</div>")]
        # Test name, class, student matching, serial port, questions per form.
        self.assertEqual(controls.count("label-text"), 5)

    def test_controls_are_given_one_height_after_the_rule_that_offsets_them(self):
        # Both selectors have the same specificity, so source order decides.
        offset = self.css.index("select, .controls input {")
        fixed = self.css.index(".controls input, .controls select {")
        self.assertGreater(fixed, offset)
        rule = self.css[fixed : self.css.index("}", fixed)]
        # The height itself is a token now, so assert what actually has to be
        # true: these get an explicit height, and it is the same one the
        # buttons beside them use, or the row stops lining up.
        self.assertIn("height: var(--control-h)", rule)
        self.assertIn("margin-top: 0", rule)
        buttons = self.css[self.css.index("select, input, button, .button {") :]
        buttons = buttons[: buttons.index("}")]
        self.assertIn("min-height: var(--control-h)", buttons)

    def test_the_roster_card_is_gone_and_its_pieces_kept(self):
        self.assertNotIn("roster-card", self.html)
        workflow = self.html[self.html.index('id="workflowCard"') :]
        workflow = workflow[: workflow.index("</section>")]
        self.assertIn('id="rosterSummary"', workflow)
        self.assertIn('id="resetRosterButton"', workflow)

    def test_nothing_references_the_removed_manage_classes_button(self):
        self.assertNotIn("manageClassesButton", self.html)
        self.assertNotIn("manageClassesButton", APP_JS)


class TtessInterfaceTests(unittest.TestCase):
    """The connection and upload surfaces described by the T-TESS spec."""

    def setUp(self):
        self.html = (WEBUI / "index.html").read_text()

    def test_settings_view_collects_the_token(self):
        self.assertIn('id="view-settings"', self.html)
        self.assertIn('id="tokenInput"', self.html)
        # A credential field must not be a plain text input.
        field = self.html[self.html.index('id="tokenInput"') :]
        self.assertIn('type="password"', field[: field.index(">")])

    def test_the_destination_picker_is_course_section_unit_test(self):
        order = [
            self.html.index(f'id="upload{part}"')
            for part in ("Course", "Section", "Unit", "Test")
        ]
        self.assertEqual(order, sorted(order))

    def test_the_success_panel_offers_the_review_link_and_says_it_is_not_final(self):
        panel = self.html[self.html.index('id="uploadSuccess"') :]
        panel = panel[: panel.index("</div>")]
        self.assertIn("uploadRunId", panel)
        self.assertIn("uploadReviewLink", panel)
        self.assertIn("does not finalize", panel)

    def test_the_upload_pane_can_refresh_the_test_list_itself(self):
        # A test created on the site while this page was open is not in the
        # list, and finding that out used to mean leaving the upload pane for
        # Settings and coming back, which loses the selection.
        # The tab button carries data-pane="upload" too; this wants the panel.
        pane = self.html[self.html.index('<section class="card" data-pane="upload"') :]
        pane = pane[: pane.index("</section>")]
        self.assertIn('id="refreshUploadTestsButton"', pane)
        self.assertIn('id="uploadButton"', pane)
        # Both refresh buttons run the same code.
        self.assertIn("refreshDestinations", APP_JS)
        for button in ("refreshDestinationsButton", "refreshUploadTestsButton"):
            self.assertIn(f'$("#{button}")', APP_JS)

    def test_the_token_is_never_rendered_back_into_the_page(self):
        self.assertNotIn("dlk_live_", APP_JS.replace('placeholder="dlk_live_…"', ""))

    def test_the_settings_card_links_to_the_teacher_site(self):
        card = self.html[self.html.index("T-TESS connection") :]
        card = card[: card.index("</section>")]
        self.assertIn('id="ttessSiteLink"', card)
        # The address used to be written in here, which meant a store build
        # shipped one school's site in its own markup. The href is filled in
        # from the site address in Settings, and the link starts hidden so it
        # never points at nothing.
        self.assertNotIn("tmechsmonitor", card)
        link = card[card.index('id="ttessSiteLink"') :]
        opening = link[: link.index(">")]
        self.assertIn('href="#"', opening)
        self.assertIn("hidden", opening)
        # Opened in the real browser: the native shell sends anything off our
        # own server out through NSWorkspace rather than the web view.
        link = card[card.index('id="ttessSiteLink"') :]
        self.assertIn('target="_blank"', link[: link.index(">")])

    def test_the_link_matches_the_address_the_server_publishes(self):
        from datalink_scanner import ttess

        self.assertIn(ttess.SITE_URL, self.html)


class CheckForUpdatesTests(unittest.TestCase):
    """The menu item, and the glue behind it that fails silently when wrong."""

    def setUp(self):
        source = Path(__file__).resolve().parents[1] / "src" / "datalink_scanner" / "app.py"
        self.app_source = source.read_text()
        # Menu items are written across one or several lines as they fit.
        self.flat = re.sub(r"\s+", " ", self.app_source)

    def test_the_app_menu_offers_check_for_updates(self):
        self.assertIn('"Check for Updates…", "checkForUpdates:"', self.flat)

    def test_every_menu_action_is_implemented_by_the_delegate(self):
        # A menu item whose selector has no matching method is not an error in
        # Cocoa; the item is simply disabled and does nothing.
        actions = set(re.findall(r'_item\( ?"[^"]+", "(\w+):"[^)]*target=self', self.flat))
        defined = set(re.findall(r"^    def (\w+)_\(self", self.app_source, re.MULTILINE))
        self.assertTrue(actions)
        self.assertFalse(actions - defined, f"no method for {actions - defined}")

    def test_every_main_thread_hop_names_a_real_method(self):
        # performSelectorOnMainThread_ takes the selector as a string, so a
        # typo there is a callback that never arrives and no exception.
        hops = set(
            re.findall(
                r'self\.performSelectorOnMainThread_withObject_waitUntilDone_\(\s*"(\w+):"',
                self.app_source,
            )
        )
        defined = set(re.findall(r"^    def (\w+)_\(self", self.app_source, re.MULTILINE))
        self.assertTrue(hops)
        self.assertFalse(hops - defined, f"no method for {hops - defined}")

    def test_the_check_runs_off_the_main_thread(self):
        # A blocking network call on the main thread freezes the whole window.
        handler = self.app_source[self.app_source.index("def checkForUpdates_") :]
        handler = handler[: handler.index("def _begin_update_work")]
        self.assertIn("threading.Thread", handler)

    def test_a_second_click_while_working_is_ignored(self):
        handler = self.app_source[self.app_source.index("def checkForUpdates_") :]
        self.assertIn("if self._update_busy:", handler[: handler.index("threading")])

    def test_the_sweep_runs_after_the_upgrade_not_before(self):
        # Homebrew moves the bundle it manages, so a survey taken beforehand
        # would name paths that no longer exist.
        install = self.app_source[self.app_source.index("def _install_update") :]
        install = install[: install.index("def finishUpdate_")]
        self.assertLess(install.index("updates.upgrade"), install.index("updates.sweep"))

    def test_the_launch_check_is_quiet_about_failures_and_about_good_news(self):
        present = self.app_source[self.app_source.index("def presentUpdate_") :]
        present = present[: present.index("def _offer_update")]
        # A background check that cannot reach GitHub, or that finds nothing
        # new, must not put a dialog in front of anyone.
        self.assertIn("if quiet:", present)
        self.assertIn("if not quiet:", present)

    def test_the_launch_check_waits_for_a_scan_to_finish(self):
        present = self.app_source[self.app_source.index("def presentUpdate_") :]
        present = present[: present.index("def _offer_update")]
        self.assertIn("quiet and self._scanner_is_busy()", present)

    def test_only_a_check_that_reached_github_resets_the_daily_clock(self):
        look = self.app_source[self.app_source.index("def _look_for_update") :]
        look = look[: look.index("def _scanner_is_busy")]
        remember = look.index("updates.remember_check")
        # It sits in the else of the try, not after the except.
        self.assertLess(look.index("else:"), remember)

    def test_the_settings_view_carries_the_toggle(self):
        html = (WEBUI / "index.html").read_text()
        card = html[html.index("<h2>Updates</h2>") :]
        self.assertIn('id="autoUpdateCheck"', card)
        self.assertIn('type="checkbox"', card[: card.index("</section>")])
        self.assertIn('$("#autoUpdateCheck")', APP_JS)
        self.assertIn("auto_update_check", APP_JS)

    def test_the_update_shows_a_progress_sheet_while_it_runs(self):
        offer = self.app_source[self.app_source.index("def _offer_update") :]
        offer = offer[: offer.index("def _install_update")]
        # Opened before the thread starts, so the window is never left looking
        # frozen while Homebrew works.
        self.assertLess(offer.index("_open_update_sheet"), offer.index("threading.Thread"))

    def test_the_sheet_is_closed_before_anything_is_reported(self):
        finish = self.app_source[self.app_source.index("def finishUpdate_") :]
        finish = finish[: finish.index("def _offer_cleanup")]
        self.assertLess(finish.index("_close_update_sheet"), finish.index("alert("))

    def test_homebrews_progress_is_passed_to_the_sheet(self):
        install = self.app_source[self.app_source.index("def _install_update") :]
        install = install[: install.index("def finishUpdate_")]
        self.assertIn("updates.upgrade(on_progress=self._report_update_progress)", install)

    def test_appkit_is_only_touched_on_the_main_thread(self):
        # The upgrade runs on a worker thread; setting a progress bar from
        # there is a crash waiting for a slow week.
        report = self.app_source[self.app_source.index("def _report_update_progress") :]
        report = report[: report.index("def _install_update")]
        self.assertIn("performSelectorOnMainThread", report)
        self.assertNotIn("setDoubleValue_", report)


class BrandingTests(unittest.TestCase):
    """The app must not read as one of the scanner vendor's own products."""

    def setUp(self):
        self.html = (WEBUI / "index.html").read_text()
        self.header = self.html[self.html.index("<header>") : self.html.index("</header>")]

    def test_the_branding_line_reads_as_compatibility_not_ownership(self):
        eyebrow = self.header[self.header.index('class="eyebrow"') :]
        eyebrow = eyebrow[: eyebrow.index("</p>")]
        # The vendor's product name standing alone in the branding slot is what
        # made people think this shipped from Apperson; naming it as something
        # the app works *with* does not.
        self.assertIn("DESIGNED TO WORK WITH", eyebrow.upper())

    def test_the_header_disclaims_affiliation(self):
        self.assertIn("not affiliated", self.header.lower())

    def test_the_about_box_disclaims_affiliation_too(self):
        source = Path(__file__).resolve().parents[1] / "src" / "datalink_scanner" / "app.py"
        about = source.read_text()
        about = about[about.index("def showAbout_") :]
        about = about[: about.index("# ----")]
        self.assertIn("Not affiliated", about)

    def test_the_readme_says_so_before_anything_else(self):
        readme = (Path(__file__).resolve().parents[1] / "README.md").read_text()
        opening = readme[: readme.index("## ")]
        self.assertIn("independent", opening.lower())
        self.assertIn("not affiliated", opening.lower())


class StudentMatchingTests(unittest.TestCase):
    """Sheets can be fed in any order when the ID area is bubbled."""

    def setUp(self):
        self.html = (WEBUI / "index.html").read_text()

    def test_the_scan_page_offers_the_three_ways_of_matching(self):
        picker = self.html[self.html.index('id="studentMatching"') :]
        picker = picker[: picker.index("</select>")]
        for mode in ('value="id"', 'value="roster"', 'value="manual"'):
            self.assertIn(mode, picker)

    def test_ids_are_compared_without_their_leading_zeros(self):
        # The scanner writes the ID as bubbled, which can be zero-padded; a
        # roster typed by hand is not. Comparing them raw quietly fell back to
        # roster order, which is what looked like being forced into an order.
        self.assertIn("function sameStudentId", APP_JS)
        self.assertIn("replace(/^0+(?=\\d)/", APP_JS)

    def test_no_raw_string_comparison_of_ids_is_left(self):
        self.assertNotIn("student.id === review.scanner_id", APP_JS)

    def test_roster_order_ignores_what_the_scanner_read(self):
        # The point of that mode: sheets whose ID area was left blank.
        self.assertIn('studentMatching === "id" && Boolean(review.scanner_id)', APP_JS)

    def test_the_mode_is_remembered_between_launches(self):
        self.assertIn("student_matching", APP_JS)
        server = (
            Path(__file__).resolve().parents[1]
            / "src" / "datalink_scanner" / "server.py"
        ).read_text()
        self.assertIn('"student_matching"', server)


class AnswerCorrectionTests(unittest.TestCase):
    """A mark read as blank that was not has to be fixable after the fact."""

    def setUp(self):
        self.html = (WEBUI / "index.html").read_text()

    def test_the_session_table_offers_a_picker(self):
        self.assertIn('id="answerDialog"', self.html)
        choices = self.html[self.html.index('id="answerDialog"') :]
        choices = choices[: choices.index("</dialog>")]
        self.assertIn('id="answerChoices"', choices)

    def test_every_response_cell_is_clickable(self):
        self.assertIn('data-scan="${scan.number}"', APP_JS)
        self.assertIn('data-question="${index + 1}"', APP_JS)

    def test_confirming_a_blank_is_one_of_the_choices(self):
        picker = APP_JS[APP_JS.index('#answerChoices").innerHTML') :]
        picker = picker[: picker.index("showModal")]
        self.assertIn("Blank", picker)

    def test_the_whole_row_is_sent_back_not_just_the_one_answer(self):
        # The server checks the response count against the form length, so a
        # single answer on its own would be rejected.
        handler = APP_JS[APP_JS.index('$("#answerForm").addEventListener') :]
        self.assertIn("scan.responses.slice()", handler[: handler.index("});")])

    def test_an_unchanged_answer_is_not_sent(self):
        handler = APP_JS[APP_JS.index('$("#answerForm").addEventListener') :]
        self.assertIn("already what is recorded", handler[: handler.index("});")])

    def test_asking_every_sheet_does_not_guess_from_the_roster(self):
        # Otherwise it behaves exactly like roster order and the third mode
        # means nothing.
        self.assertIn('studentMatching === "manual"', APP_JS)


class FaintMarkReviewTests(unittest.TestCase):
    """A barely-there mark and a double mark read differently to a teacher."""

    def test_the_two_reasons_are_worded_differently(self):
        problems = APP_JS[APP_JS.index("function reviewProblems") :]
        problems = problems[: problems.index("return rows.sort")]
        self.assertIn('item.reason === "faint"', problems)
        self.assertIn("much lighter than this student", problems)
        self.assertIn("more than one mark", problems)

    def test_a_faint_mark_is_correctable_like_any_other_answer_item(self):
        # It rides the existing answer control, so the A-E/Blank picker and
        # the apply button work on it with no extra wiring.
        render = APP_JS[APP_JS.index("function renderAnalysisReview") :]
        render = render[: render.index("}).join")]
        self.assertIn('row.kind === "student_id"', render)
        self.assertIn('data-fix="answer"', render)

    def test_a_sheet_wide_note_is_shown_but_has_nothing_to_correct(self):
        problems = APP_JS[APP_JS.index("function reviewProblems") :]
        problems = problems[: problems.index("return rows.sort")]
        self.assertIn('item.field === "sheet"', problems)
        render = APP_JS[APP_JS.index("function renderAnalysisReview") :]
        self.assertIn('row.kind === "note"', render[: render.index("}).join")])


class LauncherBundleSigningTests(unittest.TestCase):
    """The bundle Homebrew installs is ad-hoc signed. If its seal does not
    cover the nested interpreter, macOS calls the app damaged -- and it still
    opens from a terminal, because `open` does not consult Gatekeeper, while
    Finder, the Dock and Launchpad refuse it."""

    script = Path("packaging/make_app_bundle.sh").read_text()

    def test_the_nested_interpreter_is_signed_before_the_bundle(self):
        # python-runtime is a copy of Homebrew's Python and arrives carrying
        # Python's own signature. Sealing only the outer bundle leaves the two
        # disagreeing: "nested code is modified or invalid".
        inner = self.script.index('--sign - "$APP/Contents/MacOS/python-runtime"')
        outer = self.script.index('--sign - "$APP"\n')
        self.assertLess(inner, outer)

    def test_a_bad_signature_fails_the_build(self):
        # This used to end in `|| true`, which is how a broken seal shipped
        # without anybody noticing.
        self.assertIn("--verify", self.script)
        self.assertIn("satisfies its Designated Requirement", self.script)
        signing = self.script[self.script.index("# Ad-hoc signature") :]
        self.assertNotIn('--sign - "$APP" 2>/dev/null || true', signing)
