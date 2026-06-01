import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var fileOpenChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    installDesktopFileOpenChannel(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }

  private func installDesktopFileOpenChannel(
    binaryMessenger: FlutterBinaryMessenger
  ) {
    fileOpenChannel = FlutterMethodChannel(
      name: "chessever.desktop/file_open",
      binaryMessenger: binaryMessenger
    )
    DesktopFileOpenBridge.shared.attach(channel: fileOpenChannel!)
  }
}
