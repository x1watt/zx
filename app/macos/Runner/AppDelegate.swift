import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Files Finder asked to open (double click, Open With) before the Dart
  // side asked for them, and the channel to send later ones.
  var pendingFiles: [String] = []
  var filesChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    if let channel = filesChannel {
      channel.invokeMethod("open", arguments: filenames)
    } else {
      pendingFiles.append(contentsOf: filenames)
    }
    sender.reply(toOpenOrPrint: .success)
  }
}
