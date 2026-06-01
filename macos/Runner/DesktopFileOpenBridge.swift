import Cocoa
import FlutterMacOS

final class DesktopFileOpenBridge {
  static let shared = DesktopFileOpenBridge()

  private var channel: FlutterMethodChannel?
  private var pendingOpenFiles: [String] = []
  private var dartReady = false

  private init() {}

  func attach(channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takeInitialOpenFiles":
        self?.dartReady = true
        result(self?.drainPendingOpenFiles() ?? [])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func openFiles(_ filenames: [String]) {
    let paths = filenames
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !paths.isEmpty else { return }

    DispatchQueue.main.async {
      if self.dartReady, let channel = self.channel {
        channel.invokeMethod("openFiles", arguments: paths)
      } else {
        self.pendingOpenFiles.append(contentsOf: paths)
      }
    }
  }

  private func drainPendingOpenFiles() -> [String] {
    let files = pendingOpenFiles
    pendingOpenFiles.removeAll()
    return files
  }
}
