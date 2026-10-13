import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: false)

    // Move offscreen so nothing is visible during Flutter engine init
    self.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    self.alphaValue = 0

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
