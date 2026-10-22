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

    DesktopSandboxFileAccess.shared.retain(paths)

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

/// Powerbox grants a selection once; bookmarks preserve that selection after
/// relaunch. No arbitrary path can acquire access through this channel.
final class DesktopSandboxFileAccess {
  static let shared = DesktopSandboxFileAccess()
  private let defaultsKey = "ChessEverSandboxBookmarks"
  private var active: [String: URL] = [:]
  private var channels: [FlutterMethodChannel] = []
  private var restored = false
  private var isStore: Bool {
    Bundle.main.object(forInfoDictionaryKey: "ChessEverAppStoreBuild") as? String == "YES"
  }

  func attach(binaryMessenger: FlutterBinaryMessenger) {
    guard isStore else { return }
    restore()
    let channel = FlutterMethodChannel(
      name: "chessever.desktop/sandbox_files", binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "restore":
        self?.restore()
        result(nil)
      case "retain":
        self?.retain(call.arguments as? [String] ?? [])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channels.append(channel)
  }

  private func restore() {
    guard isStore, !restored else { return }
    restored = true
    let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    for (path, data) in bookmarks {
      var stale = false
      guard let url = try? URL(
        resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
        relativeTo: nil, bookmarkDataIsStale: &stale
      ), url.startAccessingSecurityScopedResource() else { continue }
      active[path] = url
      if stale { save(url, path: path) }
    }
  }

  func retain(_ paths: [String]) {
    guard isStore else { return }
    for path in paths where active[path] == nil {
      let url = URL(fileURLWithPath: path)
      // The OS permits bookmark creation only for files already selected by
      // the user (open panel, Finder Open With, or drag and drop).
      if url.startAccessingSecurityScopedResource() { active[path] = url }
      save(url, path: path)
    }
  }

  private func save(_ url: URL, path: String) {
    guard let data = try? url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
    ) else { return }
    var bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    bookmarks[path] = data
    UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
  }
}
