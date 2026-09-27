import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // "zx/files": the archives Finder opens with zx (see AppDelegate).
    let channel = FlutterMethodChannel(
      name: "zx/files", binaryMessenger: flutterViewController.engine.binaryMessenger)
    if let delegate = NSApp.delegate as? AppDelegate {
      delegate.filesChannel = channel
      channel.setMethodCallHandler { call, result in
        if call.method == "pending" {
          result(delegate.pendingFiles)
          delegate.pendingFiles = []
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    super.awakeFromNib()
  }
}
