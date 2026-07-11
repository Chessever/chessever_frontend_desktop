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

    self.appearance = NSAppearance(named: .darkAqua)
    self.titlebarAppearsTransparent = true
    self.backgroundColor = NSColor(red: 0x0C / 255, green: 0x0C / 255, blue: 0x0E / 255, alpha: 1)

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
