import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    installCheckForUpdatesMenuItem()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // PiP is a secondary Flutter window. Dismissing it must never terminate
    // the application process; primary-window shutdown remains explicit via
    // DesktopShutdownCoordinator / NSApp.terminate.
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    DesktopFileOpenBridge.shared.openFiles(filenames)
    sender.reply(toOpenOrPrint: .success)
  }

  @objc private func checkForUpdates(_ sender: Any?) {
    DesktopNativeUpdateMenuBridge.shared.checkForUpdates()
  }

  private func installCheckForUpdatesMenuItem() {
    guard let menu = applicationMenu else {
      return
    }

    if menu.items.contains(where: { $0.action == #selector(checkForUpdates(_:)) }) {
      return
    }

    let item = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(checkForUpdates(_:)),
      keyEquivalent: ""
    )
    item.target = self

    if let aboutIndex = menu.items.firstIndex(where: { $0.title.hasPrefix("About") }) {
      menu.insertItem(item, at: aboutIndex + 1)
      return
    }

    if let preferencesIndex = menu.items.firstIndex(where: {
      $0.title.hasPrefix("Preferences")
    }) {
      menu.insertItem(item, at: preferencesIndex)
      return
    }

    if menu.items.count > 1 {
      menu.insertItem(item, at: 1)
    } else {
      menu.addItem(item)
    }
  }
}

final class DesktopNativeUpdateMenuBridge {
  static let shared = DesktopNativeUpdateMenuBridge()

  private var channel: FlutterMethodChannel?
  private var pendingCheckForUpdates = false

  private init() {}

  func attach(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "chessever.desktop/native_update_menu",
      binaryMessenger: binaryMessenger
    )

    if pendingCheckForUpdates {
      pendingCheckForUpdates = false
      checkForUpdates()
    }
  }

  func checkForUpdates() {
    guard let channel else {
      pendingCheckForUpdates = true
      return
    }

    channel.invokeMethod("checkForUpdates", arguments: nil)
  }
}
