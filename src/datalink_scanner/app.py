"""Native macOS application shell.

A real Cocoa app: its own window, a full menu bar, a Dock icon and Cmd-Q. The
workspace renders in a WKWebView inside that window, served by the same local
HTTP server the browser mode uses, so there is one implementation of the
scanner logic rather than two.

The server listens on an ephemeral port chosen by the OS. Nothing outside this
process needs to find it, so there is no fixed port to collide over.
"""

from __future__ import annotations

import sys
import threading
import webbrowser
from pathlib import Path
from urllib.parse import urlparse

import objc
from AppKit import (
    NSAlert,
    NSAlertFirstButtonReturn,
    NSApplication,
    NSApplicationActivationPolicyRegular,
    NSBackingStoreBuffered,
    NSEventModifierFlagCommand,
    NSEventModifierFlagOption,
    NSEventModifierFlagShift,
    NSImage,
    NSMenu,
    NSMenuItem,
    NSModalResponseOK,
    NSSavePanel,
    NSScreen,
    NSTerminateNow,
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

from . import __version__, paths
from .server import build_server


APP_NAME = "DataLink Scanner"
REPO_URL = "https://github.com/dhohnholt/datalink_Mac_OS_interface"

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
        return self

    # ---------------------------------------------------------------- startup

    def applicationDidFinishLaunching_(self, notification):
        # Cocoa swallows exceptions raised inside delegate callbacks, which in
        # a windowless GUI process means a silent failure with no clue why.
        try:
            self._start_server()
            self._build_menu()
            self._build_window()
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
        file_menu.addItem_(_item("Export CSV…", "exportCSV:", "e", target=self))
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
            _item("Connect and Enter Data Collection", "connectScanner:", "k", target=self)
        )
        scanner_menu.addItem_(
            _item(
                "Disconnect",
                "disconnectScanner:",
                "k",
                target=self,
                modifiers=NSEventModifierFlagCommand | NSEventModifierFlagShift,
            )
        )
        scanner_menu.addItem_(_separator())
        scanner_menu.addItem_(_item("Skip Absent Student", "skipStudent:", target=self))
        scanner_menu.addItem_(
            _item("Start at First Student", "startAtFirstStudent:", target=self)
        )
        scanner_menu.addItem_(_separator())
        scanner_menu.addItem_(_item("Add Demo Scan", "addDemoScan:", "d", target=self))
        scanner_menu.addItem_(_item("Clear View", "clearView:", target=self))
        scanner_menu.addItem_(_separator())
        scanner_menu.addItem_(
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

    def disconnectScanner_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.disconnect()")

    def addDemoScan_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.addDemo()")

    def clearView_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.clearView()")

    def skipStudent_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.skipStudent()")

    def startAtFirstStudent_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.startAtFirst()")

    def toggleProtocol_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.toggleProtocol()")

    def newClass_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.newClass()")

    def editClass_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.editClass()")

    def reloadWorkspace_(self, sender):
        if self._webview is not None:
            self._webview.reload_(None)

    def exportCSV_(self, sender):
        self._run_js("window.datalinkMenu && datalinkMenu.exportCsv()")

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
            "A macOS interface for the Apperson DataLink 1200 optical mark "
            "scanner.\n\nEverything stays on this Mac — no scan data is sent "
            "to any network service.",
        ).runModal()

    # ------------------------------------------------------------- CSV saving

    def save_csv(self, query: str, suggested: str):
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
        url = f"{self._url}/api/export.csv"
        if query:
            url = f"{url}?{query}"
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                body = response.read()
            Path(destination).write_bytes(body)
        except Exception as exc:  # surfaced to the user, not swallowed
            alert("The CSV could not be saved", str(exc)).runModal()

    # ------------------------------------------- WKScriptMessageHandler

    def userContentController_didReceiveScriptMessage_(self, controller, message):
        body = message.body()
        try:
            action = body["action"]
        except (TypeError, KeyError):
            return
        if action == "export":
            query = body.get("query") or ""
            filename = body.get("filename") or "datalink-session.csv"
            self.save_csv(str(query), str(filename))

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
        if self._server is not None:
            threading.Thread(target=self._server.shutdown, daemon=True).start()
        return NSTerminateNow


def run(capture_dir: str | None = None) -> int:
    """Start the Cocoa application. Blocks until the user quits."""
    claim_bundle_name()
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
