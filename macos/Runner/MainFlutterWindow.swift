import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  private var fileOpenChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }
    installDesktopFileOpenChannel(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    DesktopNativeUpdateMenuBridge.shared.attach(
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
