import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Below this the layouts, tested down to 1100 x 760 at double text size,
    // would start to crowd.
    self.contentMinSize = NSSize(width: 1000, height: 700)
    // Remember the teacher's preferred size; first launch uses most of the
    // available desktop so the scan and correction panels fit comfortably.
    if !self.setFrameUsingName("DataLinkMainWindow") {
      let desktop = (self.screen ?? NSScreen.main)?.visibleFrame ?? self.frame
      let size = NSSize(width: min(1600, desktop.width * 0.94),
                        height: min(1050, desktop.height * 0.94))
      let origin = NSPoint(x: desktop.midX - size.width / 2,
                           y: desktop.midY - size.height / 2)
      self.setFrame(NSRect(origin: origin, size: size), display: true)
    }
    self.setFrameAutosaveName("DataLinkMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
