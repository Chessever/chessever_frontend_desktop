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

    /// Older regular-file-only updater archives can leave a versioned
    /// framework without the launcher symlinks that macOS expects. Repair the
    /// installed bundle before Dart resolves a native asset such as
    /// resqlite.framework/resqlite.
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
                let values = try? frameworkURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard
                    values?.isDirectory == true,
                    values?.isSymbolicLink != true
                else {
                    NSLog(
                        "desktop_updater: refusing non-directory or symlink framework root %@",
                        frameworkURL.path
                    )
                    continue
                }
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

    private struct FrameworkVersionCandidate {
        let url: URL
        let executable: String
    }

    private static func repairVersionedFramework(
        at frameworkURL: URL,
        fileManager: FileManager
    ) throws {
        let versionsURL = frameworkURL.appendingPathComponent(
            "Versions",
            isDirectory: true
        )
        let versionsValues = try? versionsURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
            versionsValues?.isDirectory == true,
            versionsValues?.isSymbolicLink != true
        else {
            return
        }

        let versionURLs = try fileManager.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = versionURLs.compactMap { versionURL -> FrameworkVersionCandidate? in
            guard versionURL.lastPathComponent != "Current" else {
                return nil
            }
            let values = try? versionURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard
                values?.isDirectory == true,
                values?.isSymbolicLink != true
            else {
                return nil
            }

            let resourcesURL = versionURL.appendingPathComponent(
                "Resources",
                isDirectory: true
            )
            let executable = frameworkExecutableName(
                frameworkURL: frameworkURL,
                resourcesURL: resourcesURL
            )
            guard isSafePathComponent(executable) else {
                return nil
            }

            var executableIsDirectory: ObjCBool = false
            let executableURL = versionURL.appendingPathComponent(executable)
            guard fileManager.fileExists(
                atPath: executableURL.path,
                isDirectory: &executableIsDirectory
            ), !executableIsDirectory.boolValue else {
                return nil
            }

            return FrameworkVersionCandidate(
                url: versionURL,
                executable: executable
            )
        }

        let currentURL = versionsURL.appendingPathComponent("Current")
        let existingCurrent = try? fileManager.destinationOfSymbolicLink(
            atPath: currentURL.path
        )
        let selected: FrameworkVersionCandidate
        if
            let existingCurrent,
            isSafePathComponent(existingCurrent),
            let currentCandidate = candidates.first(where: {
                $0.url.lastPathComponent == existingCurrent
            })
        {
            selected = currentCandidate
        } else if candidates.count == 1, let onlyCandidate = candidates.first {
            selected = onlyCandidate
        } else {
            if candidates.count > 1 {
                NSLog(
                    "desktop_updater: refusing ambiguous framework repair for %@",
                    frameworkURL.lastPathComponent
                )
            }
            return
        }

        guard try ensureSymbolicLink(
            at: currentURL,
            destination: selected.url.lastPathComponent,
            fileManager: fileManager
        ) else {
            return
        }

        let resourcesURL = selected.url.appendingPathComponent(
            "Resources",
            isDirectory: true
        )
        var resourcesIsDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: resourcesURL.path,
            isDirectory: &resourcesIsDirectory
        ), resourcesIsDirectory.boolValue {
            _ = try ensureSymbolicLink(
                at: frameworkURL.appendingPathComponent("Resources"),
                destination: "Versions/Current/Resources",
                fileManager: fileManager
            )
        }

        _ = try ensureSymbolicLink(
            at: frameworkURL.appendingPathComponent(selected.executable),
            destination: "Versions/Current/\(selected.executable)",
            fileManager: fileManager
        )
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

    private static func isSafePathComponent(_ value: String) -> Bool {
        return !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private static func ensureSymbolicLink(
        at linkURL: URL,
        destination: String,
        fileManager: FileManager
    ) throws -> Bool {
        if let existingDestination = try? fileManager.destinationOfSymbolicLink(
            atPath: linkURL.path
        ) {
            if existingDestination == destination {
                return true
            }
            try fileManager.removeItem(at: linkURL)
        } else if fileManager.fileExists(atPath: linkURL.path) {
            NSLog(
                "desktop_updater: refusing to replace non-symlink framework node %@",
                linkURL.path
            )
            return false
        }

        try fileManager.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: destination
        )
        return true
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
          updater_link_target="$1"
          updater_link_path="$2"

          if [ -L "$updater_link_path" ]; then
            updater_existing_target="$(readlink "$updater_link_path" 2>/dev/null || true)"
            if [ "$updater_existing_target" = "$updater_link_target" ]; then
              return 0
            fi
            rm -f "$updater_link_path"
          elif [ -e "$updater_link_path" ]; then
            echo "desktop_updater: refusing to replace non-symlink framework node $updater_link_path" >&2
            return 1
          fi

          ln -s "$updater_link_target" "$updater_link_path"
        }

        framework_executable_for_version() {
          updater_framework_path="$1"
          updater_version_path="$2"
          updater_executable=""
          updater_plist="$updater_version_path/Resources/Info.plist"

          if [ -f "$updater_plist" ] && [ -x /usr/libexec/PlistBuddy ]; then
            updater_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$updater_plist" 2>/dev/null || true)"
          fi
          if [ -z "$updater_executable" ]; then
            updater_executable="$(basename "$updater_framework_path" .framework)"
          fi
          case "$updater_executable" in
            ""|.|..|*/*)
              return 1
              ;;
          esac
          printf '%s\n' "$updater_executable"
        }

        repair_versioned_frameworks() {
          updater_frameworks="$TARGET/Frameworks"
          [ -d "$updater_frameworks" ] || return 0

          for updater_framework in "$updater_frameworks"/*.framework; do
            if [ -L "$updater_framework" ]; then
              echo "desktop_updater: refusing symlink framework root $updater_framework" >&2
              continue
            fi
            [ -d "$updater_framework/Versions" ] || continue
            if [ -L "$updater_framework/Versions" ]; then
              echo "desktop_updater: refusing symlink Versions directory $updater_framework/Versions" >&2
              continue
            fi

            updater_selected_version=""
            updater_selected_name=""
            updater_selected_executable=""
            updater_only_version=""
            updater_only_name=""
            updater_only_executable=""
            updater_valid_count=0
            updater_current_name="$(readlink "$updater_framework/Versions/Current" 2>/dev/null || true)"
            for updater_candidate in "$updater_framework"/Versions/*; do
              [ -d "$updater_candidate" ] || continue
              [ -L "$updater_candidate" ] && continue
              updater_candidate_name="$(basename "$updater_candidate")"
              [ "$updater_candidate_name" = "Current" ] && continue
              updater_candidate_executable="$(framework_executable_for_version "$updater_framework" "$updater_candidate")" || continue
              [ -f "$updater_candidate/$updater_candidate_executable" ] || continue

              updater_valid_count=$((updater_valid_count + 1))
              updater_only_version="$updater_candidate"
              updater_only_name="$updater_candidate_name"
              updater_only_executable="$updater_candidate_executable"
              if [ "$updater_candidate_name" = "$updater_current_name" ]; then
                updater_selected_version="$updater_candidate"
                updater_selected_name="$updater_candidate_name"
                updater_selected_executable="$updater_candidate_executable"
              fi
            done
            if [ -z "$updater_selected_version" ]; then
              if [ "$updater_valid_count" -eq 1 ]; then
                updater_selected_version="$updater_only_version"
                updater_selected_name="$updater_only_name"
                updater_selected_executable="$updater_only_executable"
              elif [ "$updater_valid_count" -gt 1 ]; then
                echo "desktop_updater: refusing ambiguous framework repair for $updater_framework" >&2
                continue
              else
                continue
              fi
            fi

            if ! ensure_symlink "$updater_selected_name" "$updater_framework/Versions/Current"; then
              continue
            fi
            if [ -d "$updater_selected_version/Resources" ]; then
              ensure_symlink "Versions/Current/Resources" "$updater_framework/Resources" || true
            fi
            ensure_symlink "Versions/Current/$updater_selected_executable" "$updater_framework/$updater_selected_executable" || true
          done
        }
        # END DESKTOP_UPDATER_FRAMEWORK_REPAIR

        # Archives transport regular files only. Recreate the canonical
        # versioned-framework launchers before dyld starts the updated app.
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
