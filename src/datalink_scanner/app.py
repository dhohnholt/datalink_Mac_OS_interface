"""Native macOS application shell.

A real Cocoa app: its own window, a full menu bar, a Dock icon and Cmd-Q. The
workspace renders in a WKWebView inside that window, served by the same local
HTTP server the browser mode uses, so there is one implementation of the
scanner logic rather than two.

The server listens on an ephemeral port chosen by the OS. Nothing outside this
process needs to find it, so there is no fixed port to collide over.
"""

from __future__ import annotations

import json
import signal
import sys
import threading
import time
import webbrowser
from pathlib import Path
from urllib.parse import urlparse

import objc
from AppKit import (
    NSAlert,
    NSAlertFirstButtonReturn,
    NSAlertSecondButtonReturn,
    NSApplication,
    NSApplicationActivationPolicyRegular,
    NSBackingStoreBuffered,
    NSColor,
    NSEventModifierFlagCommand,
    NSEventModifierFlagOption,
    NSEventModifierFlagShift,
    NSFont,
    NSImage,
    NSMenu,
    NSMenuItem,
    NSModalResponseOK,
    NSOpenPanel,
    NSProgressIndicator,
    NSProgressIndicatorStyleBar,
    NSSavePanel,
    NSScreen,
    NSTerminateNow,
    NSTextField,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskResizable,
    NSWindowStyleMaskTitled,
    NSWorkspace,
)
from Foundation import (
    NSURL,
    NSBundle,
    NSMakeRect,
    NSMakeSize,
    NSObject,
    NSURLRequest,
)
from WebKit import (
    WKNavigationActionPolicyAllow,
    WKNavigationActionPolicyCancel,
    WKUserScript,
    WKUserScriptInjectionTimeAtDocumentStart,
    WKWebView,
    WKWebViewConfiguration,
)

from . import __version__, paths, updates
from .server import build_server


APP_NAME = "DataLink Scanner"
REPO_URL = "https://github.com/dhohnholt/datalink_Mac_OS_interface"
_UPDATE_ACTION = "checkForUpdates:"
# Long enough for the window to be up and drawn before a background check
# could put a dialog in front of it.
LAUNCH_CHECK_DELAY_SECONDS = 4.0

# Marks the page as running inside the native shell. app.js hides its own Quit
# button when this is set, because Cmd-Q already does the job properly.
NATIVE_FLAG_SCRIPT = "window.datalinkNative = true;"

_DELEGATE = None
_ICON = None


def claim_bundle_name() -> None:
    """Make the application menu read "DataLink Scanner" rather than "Python".

    AppKit builds that menu's title from the main bundle's CFBundleName, and
    the main bundle here is the Python framework's own app wrapper, not ours.
    The info dictionary it hands back is mutable, so overriding the key before
    the menu is installed is enough. Must run before setMainMenu_.
    """
    bundle = NSBundle.mainBundle()
    if bundle is None:
        return
    info = bundle.localizedInfoDictionary() or bundle.infoDictionary()
    if info is not None:
        info["CFBundleName"] = APP_NAME
        info["CFBundleDisplayName"] = APP_NAME


def icon_path() -> Path | None:
    candidate = Path(__file__).resolve().parent / "resources" / "DataLinkScanner.icns"
    return candidate if candidate.is_file() else None


def app_icon():
    """The app icon, loaded once. Alerts fall back to the main bundle's icon
    otherwise, which here is the Python framework's rocket."""
    global _ICON
    if _ICON is None:
        path = icon_path()
        if path is not None:
            _ICON = NSImage.alloc().initWithContentsOfFile_(str(path))
    return _ICON


def alert(message: str, informative: str = "", buttons=("OK",)):
    panel = NSAlert.alloc().init()
    panel.setMessageText_(message)
    if informative:
        panel.setInformativeText_(informative)
    image = app_icon()
    if image is not None:
        panel.setIcon_(image)
    for title in buttons:
        panel.addButtonWithTitle_(title)
    return panel


def _action_name(item) -> str:
    """The selector on a menu item, as text. PyObjC hands it over as bytes."""
    action = item.action()
    if action is None:
        return ""
    return action.decode() if isinstance(action, bytes) else str(action)


def _copies(number: int) -> str:
    return "the other copy" if number == 1 else f"the {number} other copies"


def _moved_note(moved) -> str:
    if not moved:
        return ""
    names = "\n".join(f"•  {Path(path).name}" for path in moved)
    return f"\n\nMoved to the Trash:\n{names}"


def _same_bundle(left, right) -> bool:
    if left is None or right is None:
        return False
    try:
        return Path(left).resolve() == Path(right).resolve()
    except OSError:
        return False


def _item(title, action, key="", target=None, modifiers=None):
    """Build a menu item. A nil target sends the action down the responder
    chain, which is what the standard Edit commands need in order to reach the
    web view's text fields."""
    item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, key)
    if target is not None:
        item.setTarget_(target)
    if modifiers is not None:
        item.setKeyEquivalentModifierMask_(modifiers)
    return item


def _separator():
    return NSMenuItem.separatorItem()


def _submenu(menubar, title):
    menu = NSMenu.alloc().initWithTitle_(title)
    holder = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, None, "")
    holder.setSubmenu_(menu)
    menubar.addItem_(holder)
    return menu


class DataLinkAppDelegate(NSObject):
    """Owns the window, the menu bar and the embedded server."""

    def initWithCaptureDir_(self, capture_dir):
        self = objc.super(DataLinkAppDelegate, self).init()
        if self is None:
            return None
        self._capture_dir = capture_dir
        self._server = None
        self._controller = None
        self._thread = None
        self._window = None
        self._webview = None
        self._url = None
        self._update_item = None
        self._update_sheet = None
        self._update_bar = None
        self._update_line = None
        self._update_step = (0.0, "")
        self._update_busy = False
        self._update_quiet = False
        self._update_result = None
        return self

    # ---------------------------------------------------------------- startup

    def applicationDidFinishLaunching_(self, notification):
        # Cocoa swallows exceptions raised inside delegate callbacks, which in
        # a windowless GUI process means a silent failure with no clue why.
        try:
            self._start_server()
            self._build_menu()
            self._build_window()
            self._start_launch_check()
        except Exception:
            import traceback

            detail = traceback.format_exc()
            print(detail, file=sys.stderr, flush=True)
            alert(f"{APP_NAME} could not start", detail, buttons=("Quit",)).runModal()
            NSApplication.sharedApplication().terminate_(None)

    def _start_server(self):
        self._server, self._controller, _ = build_server(
            "127.0.0.1", 0, self._capture_dir
        )
        port = self._server.server_address[1]
        self._url = f"http://127.0.0.1:{port}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def _build_window(self):
        configuration = WKWebViewConfiguration.alloc().init()
        script = WKUserScript.alloc().initWithSource_injectionTime_forMainFrameOnly_(
            NATIVE_FLAG_SCRIPT, WKUserScriptInjectionTimeAtDocumentStart, True
        )
        controller = configuration.userContentController()
        controller.addUserScript_(script)
        # A download attribute makes WebKit skip navigation policy entirely,
        # so exporting is requested over an explicit message channel instead.
        controller.addScriptMessageHandler_name_(self, "datalink")

        visible = NSScreen.mainScreen().visibleFrame()
        width = min(1180.0, visible.size.width - 80.0)
        height = min(860.0, visible.size.height - 80.0)
        frame = NSMakeRect(0, 0, width, height)

        style = (
            NSWindowStyleMaskTitled
            | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable
            | NSWindowStyleMaskResizable
        )
        window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            frame, style, NSBackingStoreBuffered, False
        )
        window.setTitle_(APP_NAME)
        window.setMinSize_(NSMakeSize(820, 560))
        # Remembers position and size between launches.
        window.setFrameAutosaveName_("DataLinkScannerMainWindow")

        webview = WKWebView.alloc().initWithFrame_configuration_(
            window.contentView().bounds(), configuration
        )
        webview.setAutoresizingMask_(1 << 1 | 1 << 4)  # width | height
        webview.setNavigationDelegate_(self)
        webview.setUIDelegate_(self)
        window.contentView().addSubview_(webview)

        request = NSURLRequest.requestWithURL_(NSURL.URLWithString_(self._url))
        webview.loadRequest_(request)

        window.center()
        window.makeKeyAndOrderFront_(None)
        self._window = window
        self._webview = webview

    # ------------------------------------------------------------------ menus

    def _build_menu(self):
        menubar = NSMenu.alloc().init()
        NSApplication.sharedApplication().setMainMenu_(menubar)

        # The first menu's title is what appears in bold next to the Apple menu.
        app_menu = _submenu(menubar, APP_NAME)
        app_menu.addItem_(_item(f"About {APP_NAME}", "showAbout:", target=self))
        app_menu.addItem_(_separator())
        self._update_item = _item(
            "Check for Updates…", "checkForUpdates:", target=self
        )
        app_menu.addItem_(self._update_item)
        app_menu.addItem_(_separator())
        app_menu.addItem_(
            _item("Open Session Folder", "openSessionFolder:", target=self)
        )
        app_menu.addItem_(_separator())
        services = NSMenu.alloc().init()
        services_item = _item("Services", None)
        services_item.setSubmenu_(services)
        app_menu.addItem_(services_item)
        NSApplication.sharedApplication().setServicesMenu_(services)
        app_menu.addItem_(_separator())
        app_menu.addItem_(_item(f"Hide {APP_NAME}", "hide:", "h"))
        app_menu.addItem_(
            _item(
                "Hide Others",
                "hideOtherApplications:",
                "h",
                modifiers=NSEventModifierFlagCommand | NSEventModifierFlagOption,
            )
        )
        app_menu.addItem_(_item("Show All", "unhideAllApplications:"))
        app_menu.addItem_(_separator())
        app_menu.addItem_(_item(f"Quit {APP_NAME}", "terminate:", "q"))

        file_menu = _submenu(menubar, "File")
        file_menu.addItem_(_item("New Class…", "newClass:", "n", target=self))
        file_menu.addItem_(
            _item("Edit Selected Class…", "editClass:", target=self)
        )
        file_menu.addItem_(_separator())
        file_menu.addItem_(
            _item("Read Paper Batch…", "readPaperBatch:", "o", target=self)
        )
        file_menu.addItem_(_separator())
        file_menu.addItem_(_item("Export CSV…", "exportCSV:", "e", target=self))
        file_menu.addItem_(
            _item(
                "Export Item Analysis…",
                "exportAnalysis:",
                "e",
                target=self,
                modifiers=NSEventModifierFlagCommand | NSEventModifierFlagShift,
            )
        )
        file_menu.addItem_(_separator())
        file_menu.addItem_(_item("Close Window", "performClose:", "w"))

        edit_menu = _submenu(menubar, "Edit")
        edit_menu.addItem_(_item("Undo", "undo:", "z"))
        edit_menu.addItem_(
            _item(
                "Redo",
                "redo:",
                "z",
                modifiers=NSEventModifierFlagCommand | NSEventModifierFlagShift,
            )
        )
        edit_menu.addItem_(_separator())
        edit_menu.addItem_(_item("Cut", "cut:", "x"))
        edit_menu.addItem_(_item("Copy", "copy:", "c"))
        edit_menu.addItem_(_item("Paste", "paste:", "v"))
        edit_menu.addItem_(_item("Select All", "selectAll:", "a"))

        scanner_menu = _submenu(menubar, "Scanner")
        scanner_menu.addItem_(
            _item("Start Scanning Session", "connectScanner:", "k", target=self)
        )
        scanner_menu.addItem_(
            _item(
                "End Session",
                "endSession:",
                "k",
                target=self,
                modifiers=NSEventModifierFlagCommand | NSEventModifierFlagShift,
            )
        )
        scanner_menu.addItem_(_separator())
        scanner_menu.addItem_(_item("Re-send Handshake", "resetScanner:", target=self))
        scanner_menu.addItem_(_item("Disconnect", "disconnectScanner:", target=self))
        scanner_menu.addItem_(_separator())
        scanner_menu.addItem_(_item("Skip Absent Student", "skipStudent:", target=self))
        scanner_menu.addItem_(
            _item("Start at First Student", "startAtFirstStudent:", target=self)
        )
        scanner_menu.addItem_(_separator())
        scanner_menu.addItem_(_item("Clear View", "clearView:", target=self))

        view_menu = _submenu(menubar, "View")
        view_menu.addItem_(_item("Scan", "showScan:", "1", target=self))
        view_menu.addItem_(_item("Paper", "showPaper:", "2", target=self))
        view_menu.addItem_(_item("Classes", "showClasses:", "3", target=self))
        view_menu.addItem_(_item("Sessions", "showSessions:", "4", target=self))
        view_menu.addItem_(_item("Analysis", "showAnalysis:", "5", target=self))
        view_menu.addItem_(_item("Settings", "showSettings:", "6", target=self))
        view_menu.addItem_(_separator())
        view_menu.addItem_(
            _item("Show Protocol Details", "toggleProtocol:", target=self)
        )

        window_menu = _submenu(menubar, "Window")
        window_menu.addItem_(_item("Minimize", "performMiniaturize:", "m"))
        window_menu.addItem_(_item("Zoom", "performZoom:"))
        window_menu.addItem_(_separator())
        window_menu.addItem_(_item("Reload", "reloadWorkspace:", "r", target=self))
        window_menu.addItem_(
            _item("Open in Browser", "openInBrowser:", target=self)
        )
        window_menu.addItem_(_separator())
        window_menu.addItem_(_item("Bring All to Front", "arrangeInFront:"))
        NSApplication.sharedApplication().setWindowsMenu_(window_menu)

        help_menu = _submenu(menubar, "Help")
        help_menu.addItem_(
            _item(f"{APP_NAME} Help", "openHelp:", "?", target=self)
        )
        help_menu.addItem_(_item("Protocol Notes", "openProtocolNotes:", target=self))
        help_menu.addItem_(_separator())
        help_menu.addItem_(_item("Report an Issue", "openIssues:", target=self))
        NSApplication.sharedApplication().setHelpMenu_(help_menu)

    # ---------------------------------------------------------------- actions

    def _run_js(self, script):
        if self._webview is not None:
            self._webview.evaluateJavaScript_completionHandler_(script, None)

    def connectScanner_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.connect()")

    def endSession_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.endSession()")

    def resetScanner_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.resetScanner()")

    def disconnectScanner_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.disconnect()")

    def clearView_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.clearView()")

    def skipStudent_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.skipStudent()")

    def startAtFirstStudent_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.startAtFirst()")

    def toggleProtocol_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.toggleProtocol()")

    def showScan_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.showScan()")

    def showPaper_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.showPaper()")

    def readPaperBatch_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.choosePaperPdf()")

    def showClasses_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.showClasses()")

    def showSessions_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.showSessions()")

    def showAnalysis_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.showAnalysis()")

    def showSettings_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.showSettings()")

    def newClass_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.newClass()")

    def editClass_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.editClass()")

    def reloadWorkspace_(self, sender):
        if self._webview is not None:
            self._webview.reload_(None)

    def exportCSV_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.exportCsv()")

    def exportAnalysis_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.exportAnalysis()")

    def openInBrowser_(self, sender):
        if self._url:
            webbrowser.open(self._url)

    def openSessionFolder_(self, sender):
        folder = paths.capture_root(self._capture_dir)
        folder.mkdir(parents=True, exist_ok=True)
        NSWorkspace.sharedWorkspace().openURL_(
            NSURL.fileURLWithPath_(str(folder))
        )

    def openHelp_(self, sender):
        self._open_external(f"{REPO_URL}#use")

    def openProtocolNotes_(self, sender):
        self._open_external(f"{REPO_URL}/blob/main/docs/PROTOCOL.md")

    def openIssues_(self, sender):
        self._open_external(f"{REPO_URL}/issues")

    def _open_external(self, url):
        NSWorkspace.sharedWorkspace().openURL_(NSURL.URLWithString_(url))

    def showAbout_(self, sender):
        alert(
            APP_NAME,
            f"Version {__version__}\n\n"
            "An independent macOS interface for the Apperson DataLink 1200 "
            "optical mark scanner. Not affiliated with or endorsed by "
            "Apperson; “Apperson” and “DataLink” are their trademarks.\n\n"
            "Everything stays on this Mac — no scan data is sent to any "
            "network service.",
        ).runModal()

    # ---------------------------------------------------------------- updates

    def validateMenuItem_(self, item):
        # Cocoa re-enables every item with a live target each time a menu
        # opens, so the check has to happen here rather than once at build.
        if _action_name(item) == _UPDATE_ACTION and self._update_busy:
            return False
        return True

    def checkForUpdates_(self, sender):
        if self._update_busy:
            return
        self._begin_update_work("Checking for Updates…")
        threading.Thread(target=self._look_for_update, daemon=True).start()

    def _start_launch_check(self):
        """The daily check, if it is due and the teacher has left it on.

        It says nothing at all unless there is a newer version: an app that
        interrupts every launch to report that nothing has changed is an app
        people learn to dismiss without reading.
        """
        store = self._controller.store if self._controller is not None else None
        if store is None or self._update_busy or not updates.check_is_due(store):
            return
        self._update_busy = True
        self._update_quiet = True
        threading.Thread(target=self._look_for_update, daemon=True).start()

    def _begin_update_work(self, title):
        self._update_busy = True
        self._update_quiet = False
        if self._update_item is not None:
            self._update_item.setTitle_(title)

    def _end_update_work(self):
        self._update_busy = False
        self._update_quiet = False
        if self._update_item is not None:
            self._update_item.setTitle_("Check for Updates…")

    def _look_for_update(self):
        """Network and disk work, off the main thread so the UI keeps drawing."""
        quiet = self._update_quiet
        if quiet:
            time.sleep(LAUNCH_CHECK_DELAY_SECONDS)
        result: dict = {"quiet": quiet}
        try:
            result["release"] = updates.latest_release()
        except Exception as exc:  # a stuck menu item is worse than a message
            result["error"] = str(exc)
        else:
            # Only a check that actually reached GitHub resets the daily clock,
            # so a week offline does not count as a week of checking.
            if self._controller is not None:
                try:
                    updates.remember_check(self._controller.store)
                except Exception:
                    pass
        try:
            result["survey"] = updates.survey()
        except Exception:
            result["survey"] = {}
        self._update_result = result
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "presentUpdate:", None, False
        )

    def _scanner_is_busy(self) -> bool:
        if self._controller is None:
            return False
        try:
            return str(self._controller.snapshot().get("state")) in (
                "connecting",
                "connected",
            )
        except Exception:
            return False

    def presentUpdate_(self, sender):
        result = self._update_result or {}
        quiet = bool(result.get("quiet"))
        self._end_update_work()
        if result.get("error"):
            if quiet:
                # No network, no news: nothing worth a dialog at launch.
                return
            panel = alert(
                "Could not check for updates",
                result["error"],
                buttons=("OK", "Open Releases Page"),
            )
            if panel.runModal() != NSAlertFirstButtonReturn:
                self._open_external(updates.RELEASES_PAGE)
            return
        release = result.get("release") or {}
        survey = result.get("survey") or {}
        if not updates.is_newer(release.get("version", ""), __version__):
            if not quiet:
                self._offer_cleanup(survey)
            return
        # Sheets are going through the feeder; the news keeps until tomorrow.
        if quiet and self._scanner_is_busy():
            return
        self._offer_update(release, survey)

    def _offer_update(self, release, survey):
        version = release.get("version") or ""
        if not updates.homebrew_managed():
            panel = alert(
                f"Version {version} is available",
                f"You are running {__version__}. This copy was installed from "
                "the disk image rather than Homebrew, so it cannot replace "
                "itself — download the new one and drag it to Applications.",
                buttons=("Download…", "Later"),
            )
            if panel.runModal() == NSAlertFirstButtonReturn:
                self._open_external(release.get("url") or updates.RELEASES_PAGE)
            return

        extra = survey.get("duplicates") or []
        tidy = ""
        if extra:
            tidy = (
                f"\n\nIt will also move {_copies(len(extra))} of the app on this "
                "Mac to the Trash."
            )
        panel = alert(
            f"Version {version} is available",
            f"You are running {__version__}. DataLink Scanner will install the "
            f"update, then close and reopen.{tidy}",
            buttons=("Update & Relaunch", "Release Notes", "Later"),
        )
        choice = panel.runModal()
        if choice == NSAlertFirstButtonReturn:
            self._begin_update_work("Updating…")
            self._open_update_sheet()
            threading.Thread(
                target=self._install_update, args=(release,), daemon=True
            ).start()
        elif choice == NSAlertSecondButtonReturn:
            self._open_external(release.get("url") or updates.RELEASES_PAGE)

    # ------------------------------------------------------- progress sheet

    def _sheet_text(self, frame, size, colour=None):
        field = NSTextField.alloc().initWithFrame_(frame)
        field.setBezeled_(False)
        field.setDrawsBackground_(False)
        field.setEditable_(False)
        field.setSelectable_(False)
        field.setFont_(NSFont.systemFontOfSize_(size))
        if colour is not None:
            field.setTextColor_(colour)
        return field

    def _open_update_sheet(self):
        """A sheet rather than an alert: an alert needs a button, and there is
        nothing useful to press while Homebrew is part-way through replacing
        the app underneath us."""
        if self._window is None:
            return
        width, height = 460.0, 118.0
        sheet = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, width, height),
            NSWindowStyleMaskTitled,
            NSBackingStoreBuffered,
            False,
        )
        content = sheet.contentView()

        title = self._sheet_text(NSMakeRect(22, height - 44, width - 44, 20), 13)
        title.setFont_(NSFont.boldSystemFontOfSize_(13))
        title.setStringValue_(f"Updating {APP_NAME}")
        content.addSubview_(title)

        bar = NSProgressIndicator.alloc().initWithFrame_(
            NSMakeRect(22, height - 74, width - 44, 20)
        )
        bar.setStyle_(NSProgressIndicatorStyleBar)
        bar.setIndeterminate_(False)
        bar.setMinValue_(0.0)
        bar.setMaxValue_(1.0)
        bar.setDoubleValue_(0.0)
        content.addSubview_(bar)

        line = self._sheet_text(
            NSMakeRect(22, height - 100, width - 44, 18), 11, NSColor.secondaryLabelColor()
        )
        line.setStringValue_("Starting…")
        content.addSubview_(line)

        self._update_sheet = sheet
        self._update_bar = bar
        self._update_line = line
        self._window.beginSheet_completionHandler_(sheet, None)

    def _close_update_sheet(self):
        if self._update_sheet is None:
            return
        if self._window is not None:
            self._window.endSheet_(self._update_sheet)
        self._update_sheet.orderOut_(None)
        self._update_sheet = None
        self._update_bar = None
        self._update_line = None

    def updateSheetProgress_(self, sender):
        """Called on the main thread; AppKit must not be touched from the
        thread running Homebrew."""
        fraction, message = self._update_step
        if self._update_bar is not None:
            self._update_bar.setDoubleValue_(fraction)
        if self._update_line is not None and message:
            self._update_line.setStringValue_(message)

    def _report_update_progress(self, fraction, message):
        self._update_step = (fraction, message)
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "updateSheetProgress:", None, False
        )

    def _install_update(self, release):
        result: dict = {"release": release}
        try:
            updates.upgrade(on_progress=self._report_update_progress)
        except Exception as exc:
            result["error"] = str(exc)
        else:
            # Surveyed again afterwards: Homebrew has just moved things, and
            # the copy to keep is the one it now points at.
            survey = updates.survey()
            result["survey"] = survey
            result["moved"] = updates.sweep(survey.get("duplicates") or [])
        self._update_result = result
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "finishUpdate:", None, False
        )

    def finishUpdate_(self, sender):
        self._close_update_sheet()
        self._end_update_work()
        result = self._update_result or {}
        if result.get("error"):
            alert("The update did not finish", result["error"]).runModal()
            return
        version = (result.get("release") or {}).get("version") or ""
        moved = result.get("moved") or []
        alert(
            f"Updated to {version}",
            f"DataLink Scanner will close and reopen now.{_moved_note(moved)}",
        ).runModal()
        self._reopen_after_update(result.get("survey") or {})

    def _offer_cleanup(self, survey):
        extra = survey.get("duplicates") or []
        if not extra:
            alert(
                f"{APP_NAME} is up to date",
                f"Version {__version__} is the latest release.",
            ).runModal()
            return
        # The path the user recognises, rather than the Homebrew opt path the
        # symlink in /Applications points at.
        kept = updates.relaunch_target(survey.get("keeper"), survey.get("running"))
        listing = "\n".join(f"•  {path}" for path in extra[:8])
        if len(extra) > 8:
            listing += f"\n•  and {len(extra) - 8} more"
        found = (
            "there is another copy"
            if len(extra) == 1
            else f"there are {len(extra)} other copies"
        )
        panel = alert(
            f"{APP_NAME} is up to date",
            f"Version {__version__} is the latest release, but {found} of the "
            f"app on this Mac:\n\n{listing}\n\n"
            f"{'Moving it' if len(extra) == 1 else 'Moving those'} to the Trash "
            f"leaves {kept} as the only one.",
            buttons=("Move to Trash", "Keep Them"),
        )
        if panel.runModal() != NSAlertFirstButtonReturn:
            return
        # Checked before the sweep, because a moved path no longer resolves.
        running = survey.get("running")
        reopening = any(_same_bundle(path, running) for path in extra)
        moved = updates.sweep(extra)
        if reopening:
            alert(
                "Older copies moved to the Trash",
                f"The copy that was running is one of them, so DataLink "
                f"Scanner will close and reopen from {survey.get('keeper')}."
                f"{_moved_note(moved)}",
            ).runModal()
            self._reopen_after_update(survey)
            return
        alert(
            "Older copies moved to the Trash",
            "\n".join(f"•  {Path(path).name}" for path in moved),
        ).runModal()

    def _reopen_after_update(self, survey):
        target = updates.relaunch_target(survey.get("keeper"), survey.get("running"))
        if target is None:
            alert(
                f"Reopen {APP_NAME}",
                "Everything is installed — open the app again from Applications.",
            ).runModal()
            return
        try:
            updates.relaunch(target)
        except OSError as exc:
            alert(
                f"{APP_NAME} could not reopen itself",
                f"Everything is installed — open it again from Applications. ({exc})",
            ).runModal()
            return
        NSApplication.sharedApplication().terminate_(None)

    # ------------------------------------------------------------- CSV saving

    def save_csv(self, query: str, suggested: str, path: str = "/api/export.csv"):
        """Fetch the export from the local server and write it where the user
        chooses. Doing it here rather than through a web-view download gives a
        real Save panel and a real default filename."""
        import urllib.request

        panel = NSSavePanel.savePanel()
        panel.setNameFieldStringValue_(suggested)
        panel.setTitle_("Export CSV")
        if panel.runModal() != NSModalResponseOK:
            return
        destination = panel.URL().path()
        url = f"{self._url}{path}"
        if query:
            url = f"{url}?{query}"
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                body = response.read()
            Path(destination).write_bytes(body)
        except Exception as exc:  # surfaced to the user, not swallowed
            alert("The CSV could not be saved", str(exc)).runModal()

    def choose_pdf(self):
        """A real Open panel: a web file input hands the page bytes, and the
        image pipeline needs a path on disk."""
        panel = NSOpenPanel.openPanel()
        panel.setTitle_("Choose the scanned PDF")
        panel.setAllowedFileTypes_(["pdf"])
        panel.setAllowsMultipleSelection_(False)
        panel.setCanChooseDirectories_(False)
        if panel.runModal() != NSModalResponseOK:
            return
        url = panel.URL()
        if url is None:
            return
        chosen = json.dumps(str(url.path()))
        self._run_js(f"window.datalinkPaper && datalinkPaper.chosen({chosen})")

    # ------------------------------------------- WKScriptMessageHandler

    def userContentController_didReceiveScriptMessage_(self, controller, message):
        body = message.body()
        try:
            action = body["action"]
        except (TypeError, KeyError):
            return
        if action == "reveal":
            self.openSessionFolder_(None)
            return
        if action == "choosePdf":
            self.choose_pdf()
            return
        if action == "export":
            query = body.get("query") or ""
            filename = body.get("filename") or "datalink-session.csv"
            path = body.get("path") or "/api/export.csv"
            # Only ever fetch from our own API surface.
            if not str(path).startswith("/api/"):
                return
            self.save_csv(str(query), str(filename), str(path))

    # --------------------------------------------------- WKNavigationDelegate

    def webView_decidePolicyForNavigationAction_decisionHandler_(
        self, webview, action, handler
    ):
        url = action.request().URL()
        text = url.absoluteString() if url is not None else ""
        parsed = urlparse(str(text))

        # Export is handled natively so the user gets a Save panel.
        if parsed.path == "/api/export.csv":
            handler(WKNavigationActionPolicyCancel)
            suggested = "datalink-session.csv"
            from urllib.parse import parse_qs

            name = parse_qs(parsed.query).get("name", [""])[0]
            if name:
                suggested = name if name.lower().endswith(".csv") else f"{name}.csv"
            self.save_csv(parsed.query, suggested)
            return

        # Anything pointing off our own server opens in the real browser.
        if parsed.scheme in ("http", "https") and parsed.netloc not in (
            urlparse(self._url).netloc,
        ):
            handler(WKNavigationActionPolicyCancel)
            self._open_external(str(text))
            return

        handler(WKNavigationActionPolicyAllow)

    # ----------------------------------------------------------- WKUIDelegate

    def webView_runJavaScriptAlertPanelWithMessage_initiatedByFrame_completionHandler_(
        self, webview, message, frame, handler
    ):
        alert(APP_NAME, message).runModal()
        handler()

    def webView_runJavaScriptConfirmPanelWithMessage_initiatedByFrame_completionHandler_(
        self, webview, message, frame, handler
    ):
        # Without this, every confirm() in the page silently returns false and
        # the corresponding button appears to do nothing.
        panel = alert(APP_NAME, message, buttons=("OK", "Cancel"))
        handler(panel.runModal() == NSAlertFirstButtonReturn)

    def webView_createWebViewWithConfiguration_forNavigationAction_windowFeatures_(
        self, webview, configuration, action, features
    ):
        url = action.request().URL()
        if url is not None:
            self._open_external(url.absoluteString())
        return None

    # --------------------------------------------------------------- shutdown

    def applicationShouldTerminateAfterLastWindowClosed_(self, sender):
        return True

    def applicationShouldTerminate_(self, sender):
        if self._controller is not None:
            self._controller.disconnect()
            # Folds the write-ahead log back into the database; without it the
            # app leaves -wal and -shm files behind on every quit.
            self._controller.store.close()
        if self._server is not None:
            threading.Thread(target=self._server.shutdown, daemon=True).start()
        return NSTerminateNow


def install_signal_handlers() -> None:
    """Quit cleanly on SIGTERM, the way Cmd-Q does.

    Python only runs signal handlers between bytecodes, and the main thread
    spends its life inside NSApplication.run(), so an ordinary handler would
    not fire until something else happened to wake the interpreter. Block the
    signals instead and have a dedicated thread wait on them, then ask AppKit
    to terminate on the main thread so applicationShouldTerminate_ still runs
    and the database is checkpointed.
    """
    wanted = [
        number
        for number in (
            getattr(signal, name, None) for name in ("SIGTERM", "SIGHUP", "SIGINT")
        )
        if number is not None
    ]
    if not wanted or not hasattr(signal, "pthread_sigmask"):
        return
    try:
        # Must happen before any other thread starts, so they inherit the mask.
        signal.pthread_sigmask(signal.SIG_BLOCK, wanted)
    except (OSError, ValueError):
        return

    def wait_for_signal() -> None:
        try:
            signal.sigwait(wanted)
        except (OSError, ValueError):
            return
        NSApplication.sharedApplication().performSelectorOnMainThread_withObject_waitUntilDone_(
            "terminate:", None, False
        )

    threading.Thread(target=wait_for_signal, daemon=True).start()


def run(capture_dir: str | None = None) -> int:
    """Start the Cocoa application. Blocks until the user quits."""
    claim_bundle_name()
    install_signal_handlers()
    application = NSApplication.sharedApplication()
    application.setActivationPolicy_(NSApplicationActivationPolicyRegular)

    icon = icon_path()
    if icon is not None:
        image = NSImage.alloc().initWithContentsOfFile_(str(icon))
        if image is not None:
            application.setApplicationIconImage_(image)

    global _DELEGATE
    # setDelegate_ does not retain, so the delegate must be kept alive here or
    # it is collected and every menu action becomes a no-op.
    _DELEGATE = DataLinkAppDelegate.alloc().initWithCaptureDir_(capture_dir)
    application.setDelegate_(_DELEGATE)

    application.activateIgnoringOtherApps_(True)
    application.run()
    return 0
