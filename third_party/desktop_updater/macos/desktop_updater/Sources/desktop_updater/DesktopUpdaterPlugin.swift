import Cocoa
import FlutterMacOS

public class DesktopUpdaterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        repairInstalledVersionedFrameworks()
        let channel = FlutterMethodChannel(
            name: "desktop_updater",
            binaryMessenger: registrar.messenger
        )
        let instance = DesktopUpdaterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    /// The release archive intentionally contains regular files only, so an
    /// older updater can install a new version without the launcher symlinks
    /// used by macOS versioned frameworks. Repairing at plugin registration
    /// makes the first launch of the next release self-heal before Dart first
    /// resolves a native asset such as resqlite.framework/resqlite.
    private static func repairInstalledVersionedFrameworks() {
        let frameworksURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: frameworksURL.path) else {
            return
        }

        do {
            let frameworks = try fileManager.contentsOfDirectory(
                at: frameworksURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for frameworkURL in frameworks where frameworkURL.pathExtension == "framework" {
                do {
                    try repairVersionedFramework(
                        at: frameworkURL,
                        fileManager: fileManager
                    )
                } catch {
                    NSLog(
                        "desktop_updater: unable to repair %@: %@",
                        frameworkURL.lastPathComponent,
                        error.localizedDescription
                    )
                }
            }
        } catch {
            NSLog(
                "desktop_updater: unable to inspect versioned frameworks: %@",
                error.localizedDescription
            )
        }
    }

    private static func repairVersionedFramework(
        at frameworkURL: URL,
        fileManager: FileManager
    ) throws {
        let versionsURL = frameworkURL.appendingPathComponent(
            "Versions",
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: versionsURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return
        }

        let candidates = try fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { candidate in
            guard candidate.lastPathComponent != "Current" else {
                return false
            }
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let versionURL = candidates.first else {
            return
        }

        let currentURL = versionsURL.appendingPathComponent("Current")
        try ensureSymbolicLink(
            at: currentURL,
            destination: versionURL.lastPathComponent,
            fileManager: fileManager
        )

        let resourcesURL = versionURL.appendingPathComponent(
            "Resources",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: resourcesURL.path) {
            try ensureSymbolicLink(
                at: frameworkURL.appendingPathComponent("Resources"),
                destination: "Versions/Current/Resources",
                fileManager: fileManager
            )
        }

        let executable = frameworkExecutableName(
            frameworkURL: frameworkURL,
            resourcesURL: resourcesURL
        )
        let executableURL = versionURL.appendingPathComponent(executable)
        if fileManager.fileExists(atPath: executableURL.path) {
            try ensureSymbolicLink(
                at: frameworkURL.appendingPathComponent(executable),
                destination: "Versions/Current/\(executable)",
                fileManager: fileManager
            )
        }
    }

    private static func frameworkExecutableName(
        frameworkURL: URL,
        resourcesURL: URL
    ) -> String {
        let plistURL = resourcesURL.appendingPathComponent("Info.plist")
        if
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            let executable = plist["CFBundleExecutable"] as? String,
            !executable.isEmpty
        {
            return executable
        }
        return frameworkURL.deletingPathExtension().lastPathComponent
    }

    private static func ensureSymbolicLink(
        at linkURL: URL,
        destination: String,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: linkURL.path) {
            return
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)) != nil {
            try fileManager.removeItem(at: linkURL)
        }
        try fileManager.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: destination
        )
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        case "restartApp":
            scheduleInstallAndRelaunch(stagingPath: nil, removedFiles: [], result: result)
        case "installUpdate":
            guard
                let arguments = call.arguments as? [String: Any],
                let stagingPath = arguments["stagingPath"] as? String,
                !stagingPath.isEmpty
            else {
                result(
                    FlutterError(
                        code: "InvalidArguments",
                        message: "installUpdate requires a stagingPath.",
                        details: nil
                    )
                )
                return
            }

            let removedFiles = arguments["removedFiles"] as? [String] ?? []
            scheduleInstallAndRelaunch(
                stagingPath: stagingPath,
                removedFiles: removedFiles,
                result: result
            )
        case "getExecutablePath":
            result(Bundle.main.executablePath)
        case "getCurrentVersion":
            result(Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func scheduleInstallAndRelaunch(
        stagingPath: String?,
        removedFiles: [String],
        result: @escaping FlutterResult
    ) {
        do {
            if let stagingPath, !FileManager.default.fileExists(atPath: stagingPath) {
                result(
                    FlutterError(
                        code: "InstallError",
                        message: "Staged update directory does not exist.",
                        details: stagingPath
                    )
                )
                return
            }

            let scriptURL = try writeHelperScript(
                stagingPath: stagingPath,
                removedFiles: removedFiles
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            try process.run()

            result(nil)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            result(
                FlutterError(
                    code: "InstallError",
                    message: "Unable to schedule update installation.",
                    details: error.localizedDescription
                )
            )
        }
    }

    private func writeHelperScript(
        stagingPath: String?,
        removedFiles: [String]
    ) throws -> URL {
        let bundlePath = Bundle.main.bundlePath
        let contentsPath = (bundlePath as NSString).appendingPathComponent("Contents")
        let helperName = "desktop_updater_\(UUID().uuidString).sh"
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(helperName)

        var script = """
        #!/bin/sh
        set -eu

        PID="\(ProcessInfo.processInfo.processIdentifier)"
        STAGING=\(shellQuote(stagingPath ?? ""))
        TARGET=\(shellQuote(contentsPath))
        BUNDLE=\(shellQuote(bundlePath))
        SKIP_RELAUNCH="${DESKTOP_UPDATER_SMOKE_SKIP_RELAUNCH:-}"

        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.5
        done

        """

        if !removedFiles.isEmpty {
            script += """
            for rel in \(removedFiles.map(shellQuote).joined(separator: " ")); do
              case "$rel" in
                ""|/*|../*|*/../*|*/..|..)
                  continue
                  ;;
              esac
              rm -rf "$TARGET/$rel"
            done

            """
        }

        script += """
        if [ -n "$STAGING" ]; then
          if command -v ditto >/dev/null 2>&1; then
            ditto "$STAGING" "$TARGET"
          else
            cp -R "$STAGING"/. "$TARGET"/
          fi
          rm -rf "$STAGING"
        fi

        # BEGIN DESKTOP_UPDATER_FRAMEWORK_REPAIR
        ensure_symlink() {
          target="$1"
          link="$2"
          if [ -L "$link" ] && [ ! -e "$link" ]; then
            rm -f "$link"
          fi
          if [ -e "$link" ] || [ -L "$link" ]; then
            return 0
          fi
          ln -s "$target" "$link"
        }

        repair_versioned_frameworks() {
          frameworks="$TARGET/Frameworks"
          [ -d "$frameworks" ] || return 0

          for framework in "$frameworks"/*.framework; do
            [ -d "$framework/Versions" ] || continue

            version=""
            for candidate in "$framework"/Versions/*; do
              [ -d "$candidate" ] || continue
              [ "$(basename "$candidate")" = "Current" ] && continue
              version="$candidate"
              break
            done
            [ -n "$version" ] || continue

            version_name="$(basename "$version")"
            ensure_symlink "$version_name" "$framework/Versions/Current"

            current="$framework/Versions/Current"
            [ -d "$current" ] || continue
            if [ -d "$current/Resources" ]; then
              ensure_symlink "Versions/Current/Resources" "$framework/Resources"
            fi

            executable=""
            plist="$current/Resources/Info.plist"
            if [ -f "$plist" ] && [ -x /usr/libexec/PlistBuddy ]; then
              executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
            fi
            if [ -z "$executable" ]; then
              executable="$(basename "$framework" .framework)"
            fi
            if [ -e "$current/$executable" ]; then
              ensure_symlink "Versions/Current/$executable" "$framework/$executable"
            fi
          done
        }
        # END DESKTOP_UPDATER_FRAMEWORK_REPAIR

        # desktop_updater archives contain regular files only. Recreate the
        # standard versioned-framework launchers before dyld starts the app.
        repair_versioned_frameworks

        restore_execute_bits() {
          chmod +x "$TARGET/MacOS"/* 2>/dev/null || true

          if command -v file >/dev/null 2>&1; then
            find "$TARGET/Frameworks" -type f -exec sh -c '
              for candidate do
                if file "$candidate" 2>/dev/null | grep -q "Mach-O"; then
                  chmod +x "$candidate" 2>/dev/null || true
                fi
              done
            ' sh {} +

            find "$TARGET" -path "*/flutter_assets/assets/engine/*" -type f -exec sh -c '
              for candidate do
                if file "$candidate" 2>/dev/null | grep -q "Mach-O"; then
                  chmod +x "$candidate" 2>/dev/null || true
                fi
              done
            ' sh {} +
          else
            chmod +x "$TARGET"/Frameworks/*.framework/Versions/*/* 2>/dev/null || true
            chmod +x "$TARGET"/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/engine/macos/* 2>/dev/null || true
          fi
        }

        restore_execute_bits

        if [ "$SKIP_RELAUNCH" != "1" ]; then
          open -n "$BUNDLE"
        fi
        rm -f "$0"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
