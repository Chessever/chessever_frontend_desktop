import 'dart:io';

import 'package:chessever/desktop/services/desktop_updater_state.dart';
import 'package:chessever/desktop/widgets/mandatory_update_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop distribution scripts', () {
    test('macOS publish script archives signed app for desktop_updater', () {
      final script =
          File('scripts/codemagic_publish_macos.sh').readAsStringSync();
      final codemagic = File('codemagic.yaml').readAsStringSync();

      expect(script, contains(r'RELEASE_VERSION="${VERSION}+${BUILD}"'));
      expect(script, contains(r'ARCHIVE_NAME="${RELEASE_VERSION}-macos"'));
      expect(script, contains('macos/Runner/Release.entitlements'));
      expect(script, contains(r'xcrun notarytool submit "$TMP_ZIP" --wait'));
      expect(script, contains(r'xcrun stapler staple "$APP"'));
      expect(
        script,
        contains(r'--verify-release-env=$EXPECTED_DART_DEFINE_KEYS'),
      );
      expect(script, contains(r'run_release_env_check "$APP"'));
      expect(script, contains(r'dart run desktop_updater:archive macos'));
      expect(script, contains(r'find "$ARCHIVE_DIR" -type l -print0'));
      expect(script, contains('Removing unhashed macOS archive symlink'));
      expect(
        script,
        contains(r'validate_desktop_updater_archive "$ARCHIVE_DIR"'),
      );
      expect(script, contains(r'entry.get("path") or entry.get("filePath")'));
      expect(script, contains(r'desktop/archive/$ARCHIVE_NAME/'));
      expect(script, contains(r'ingest macos $ARCHIVE_NAME $RELEASE_VERSION'));
      expect(script, isNot(contains('SUPARKLE')));
      expect(script, isNot(contains('sign_update')));
      expect(codemagic, contains('macos-desktop-release:'));
      expect(codemagic, contains('instance_type: mac_mini_m4'));
      expect(codemagic, contains('max_build_duration: 120'));
      expect(codemagic, contains('chessever-desktop-release'));
      expect(codemagic, contains('CM_CERTIFICATE'));
      expect(codemagic, contains('SENTRY_FLUTTER'));
      expect(codemagic, contains('GAMEBASE_PROXY_BASE'));
      expect(codemagic, isNot(contains('GAMEBASE_API_KEY')));
      expect(codemagic, contains('GOOGLE_WEB_CLIENT_ID'));
      expect(codemagic, contains('--dart-define=GOOGLE_WEB_CLIENT_ID'));
      expect(codemagic, contains('keychain initialize'));
      expect(codemagic, contains('keychain add-certificates'));
      expect(codemagic, contains('./scripts/codemagic_publish_macos.sh'));
      expect(codemagic, isNot(contains('--dart-define-from-file')));
      expect(
        codemagic,
        contains('dart run desktop_updater:release macos --release'),
      );
      expect(codemagic, isNot(contains('sign_update')));
      expect(codemagic, isNot(contains('.zip.sig')));

      final packageName = _pubspecValue('name');
      final appInfo =
          File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync();
      final infoPlist = File('macos/Runner/Info.plist').readAsStringSync();
      expect(appInfo, contains('PRODUCT_NAME = $packageName'));
      expect(infoPlist, contains('<key>CFBundleDisplayName</key>'));
      expect(infoPlist, contains('<string>ChessEver</string>'));

      final releaseEntitlements =
          File('macos/Runner/Release.entitlements').readAsStringSync();
      final debugEntitlements =
          File('macos/Runner/DebugProfile.entitlements').readAsStringSync();
      expect(
        releaseEntitlements,
        contains('<key>com.apple.security.app-sandbox</key>\n\t<false/>'),
      );
      expect(
        debugEntitlements,
        contains('<key>com.apple.security.app-sandbox</key>\n\t<false/>'),
      );
    });

    test('Windows publish script uploads desktop_updater archive directory', () {
      final script =
          File('scripts/codemagic_publish_windows.ps1').readAsStringSync();
      final buildScript =
          File(
            'scripts/codemagic_build_windows_release.ps1',
          ).readAsStringSync();
      final codemagic = File('codemagic.yaml').readAsStringSync();

      expect(script, contains(r'ReleaseVersion = "$version+$build"'));
      expect(script, contains(r'ArchiveName = "$version+$build-windows"'));
      expect(script, contains('tool/verify_windows_release_bundle.dart'));
      expect(script, contains(r'--verify-release-env=$ExpectedKeys'));
      expect(
        script,
        contains(r'Invoke-ReleaseEnvCheck -DirectoryPath $buildDir'),
      );
      expect(script, contains('Start-Process `'));
      expect(script, contains(r'ConvertFrom-Json'));
      expect(
        script,
        contains(r'Invoke-ReleaseEnvCheck -DirectoryPath $stagedDir'),
      );
      expect(script, contains(r'dart run desktop_updater:archive windows'));
      expect(
        script,
        contains(
          r'Assert-DesktopUpdaterArchiveContract -ArchiveDir $archiveDir',
        ),
      );
      expect(script, contains(r"$entry.PSObject.Properties['path']"));
      expect(script, contains(r'$decodedEntries'));
      expect(script, contains(r'$nestedEntry'));
      expect(script, contains(r'properties=$propertyNames'));
      expect(script, contains(r'$archivePrefix'));
      expect(script, isNot(contains('[IO.Path]::GetRelativePath')));
      expect(script, contains('desktop/archive/'));
      expect(
        script,
        contains(
          r'ingest windows $($release.ArchiveName) $($release.ReleaseVersion)',
        ),
      );
      expect(script, contains('Get-InnoSetupCompiler'));
      expect(script, contains('New-WindowsInstaller'));
      expect(script, contains(r'$isccOutput'));
      expect(script, contains('windows\\installer\\chessever.iss'));
      expect(script, contains('Chessever-Setup.exe'));
      expect(script, isNot(contains('Chessever-windows.zip')));
      expect(codemagic, contains('windows-desktop-release:'));
      expect(codemagic, contains('max_build_duration: 120'));
      expect(codemagic, contains('choco install innosetup'));
      expect(codemagic, contains(r'windows\installer\output\*.exe'));
      expect(codemagic, contains('GAMEBASE_PROXY_BASE'));
      expect(codemagic, isNot(contains('GAMEBASE_API_KEY')));
      expect(codemagic, contains('GOOGLE_WEB_CLIENT_ID'));
      expect(
        codemagic,
        contains(
          r'powershell -ExecutionPolicy Bypass -File .\scripts\codemagic_build_windows_release.ps1',
        ),
      );
      expect(
        codemagic,
        contains(
          r'powershell -ExecutionPolicy Bypass -File .\scripts\codemagic_publish_windows.ps1',
        ),
      );
      expect(
        buildScript,
        contains('flutter build windows --release @dartDefines'),
      );
      expect(buildScript, contains(r'"--dart-define=$Name=$value"'));
      expect(
        buildScript,
        contains(r'dist\$build\$packageName-$version+$build-windows'),
      );
      expect(codemagic, isNot(contains('--dart-define-from-file')));
    });

    test('Windows build metadata remains readable by desktop_updater', () {
      final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
      final resources = File('windows/runner/Runner.rc').readAsStringSync();
      final installer =
          File('windows/installer/chessever.iss').readAsStringSync();

      expect(
        cmake,
        contains(
          r'target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")',
        ),
      );
      expect(resources, contains('VALUE "ProductVersion", VERSION_AS_STRING'));
      expect(resources, contains('#define VERSION_AS_STRING FLUTTER_VERSION'));
      expect(installer, contains(r'DefaultDirName={userpf}\{#AppName}'));
      expect(installer, contains('PrivilegesRequired=lowest'));
      expect(
        installer,
        contains(
          'OutputBaseFilename=chessever-{#AppVersion}+{#AppBuild}-setup',
        ),
      );
    });

    test('Linux Debian launcher matches GTK application id', () {
      final script =
          File('scripts/codemagic_publish_linux.sh').readAsStringSync();
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();

      expect(cmake, contains('set(BINARY_NAME "Chessever")'));
      expect(cmake, contains('set(APPLICATION_ID "com.chessever.desktop")'));
      expect(script, contains(r'PACKAGE_BINARY="Chessever"'));
      expect(
        script,
        contains(
          r'cat > "$pkgroot/usr/share/applications/com.chessever.desktop" <<EOF',
        ),
      );
      expect(script, contains(r'cat > "$pkgroot/usr/bin/chessever" <<EOF'));
      expect(script, contains('cd /opt/chessever || exit 1'));
      expect(
        script,
        contains(
          r'export LD_LIBRARY_PATH="/opt/chessever/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"',
        ),
      );
      expect(script, contains(r'exec /opt/chessever/$PACKAGE_BINARY "\$@"'));
      expect(script, contains('Exec=/usr/bin/chessever %U'));
      expect(script, contains('StartupNotify=true'));
      expect(script, isNot(contains('com.chessever.desktop.desktop')));
      expect(script, isNot(contains(r'Exec=/opt/chessever/$PACKAGE_BINARY')));
    });

    test('Linux bundle includes ONNX Runtime SONAME libraries', () {
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();

      expect(cmake, contains('flutter_onnxruntime'));
      expect(cmake, contains('libonnxruntime*.so*'));
      expect(cmake, contains('FOLLOW_SYMLINK_CHAIN'));
      expect(cmake, contains(r'${INSTALL_BUNDLE_LIB_DIR}'));
    });

    test('server publish wrapper forwards archive commands', () {
      final wrapper =
          File('scripts/codemagic_publish_wrapper.sh').readAsStringSync();

      expect(wrapper, contains('SSH_ORIGINAL_COMMAND'));
      expect(wrapper, contains('/usr/local/bin/codemagic-finalize prepare'));
      expect(
        wrapper,
        contains('/usr/local/bin/codemagic-finalize clear-legacy'),
      );
      expect(wrapper, contains('/usr/local/bin/codemagic-finalize ingest'));
      expect(wrapper, contains('macos | windows'));
      expect(wrapper, contains('bad archive'));
    });
  });

  group('desktop updater runtime contract', () {
    test('uses desktop_updater archive URL and native install handoff', () {
      final dartService =
          File('lib/desktop/services/desktop_updater.dart').readAsStringSync();
      final nativeBridge =
          File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();
      final desktopMain =
          File('lib/desktop/desktop_main.dart').readAsStringSync();
      final desktopEnv =
          File('lib/desktop/services/desktop_env.dart').readAsStringSync();

      expect(
        dartService,
        contains('https://chessever.com/updates/desktop/app-archive.json'),
      );
      expect(dartService, contains('versionCheck'));
      expect(dartService, contains('updateApp'));
      expect(dartService, contains('installUpdate'));
      expect(dartService, contains('prepareForExternalTermination'));
      expect(dartService, contains('DesktopUpdateRecoveryMarkerStore'));
      expect(dartService, contains('manualDownloadRequired'));
      expect(dartService, contains('https://chessever.com/#download'));
      expect(dartService, contains('LaunchMode.externalApplication'));
      expect(dartService, isNot(contains('disposeContainer: true')));
      expect(dartService, isNot(contains('auto_updater')));
      expect(dartService, isNot(contains('terminateForUpdate')));
      expect(desktopMain, contains('--verify-release-env'));
      expect(desktopMain, contains('DesktopEnv.releasePresenceFor'));
      expect(desktopEnv, contains('requiredReleaseKeys'));
      expect(desktopEnv, contains('GAMEBASE_PROXY_BASE'));
      expect(desktopEnv, isNot(contains('GAMEBASE_API_KEY')));
      expect(desktopEnv, contains('BILLING_API_BASE'));
      expect(nativeBridge, isNot(contains('chessever.desktop/updater')));
      expect(nativeBridge, isNot(contains('SUPublicEDKey')));
    });

    test('shared desktop env lookups use const compile-time keys', () {
      final supabase =
          File('lib/repository/supabase/supabase.dart').readAsStringSync();
      final desktopEnv =
          File('lib/desktop/services/desktop_env.dart').readAsStringSync();

      expect(supabase, contains('const Map<String, String> _releaseEnvValues'));
      expect(supabase, contains("String.fromEnvironment('SUPABASE_URL'"));
      expect(
        supabase,
        contains("String.fromEnvironment(\n    'SUPABASE_ANON_KEY'"),
      );
      expect(supabase, isNot(contains('String.fromEnvironment(key)')));
      expect(desktopEnv, isNot(contains('String.fromEnvironment(key)')));
    });

    test('major update gate blocks once a major target is known', () {
      final gate =
          File(
            'lib/desktop/widgets/mandatory_update_gate.dart',
          ).readAsStringSync();

      expect(gate, contains('DesktopUpdateStatus.available'));
      expect(gate, contains('DesktopUpdateStatus.retrying'));
      expect(gate, contains('DesktopUpdateStatus.downloaded'));
      expect(gate, contains('DesktopUpdateStatus.installing'));
      expect(gate, contains('DesktopUpdateStatus.manualDownloadRequired'));
      expect(gate, contains('openDownloadPage'));
      expect(gate, contains('dismissible: false'));
    });

    test('major update force gate is scoped to the authenticated shell', () {
      final authGate =
          File('lib/desktop/auth/desktop_auth_gate.dart').readAsStringSync();
      final shell =
          File('lib/desktop/shell/desktop_shell.dart').readAsStringSync();

      expect(
        authGate,
        contains('return const MandatoryUpdateGate(child: DesktopShell());'),
      );
      expect(authGate, contains('return const DesktopWelcomeScreen();'));
      expect(
        authGate,
        contains('return const DesktopPremiumRequiredScreen();'),
      );
      expect(shell, isNot(contains('MandatoryUpdateGate')));
    });

    test(
      'known major updates block the shell until installed or recovered',
      () {
        expect(
          shouldBlockForMajorDesktopUpdate(
            const DesktopUpdateState(
              status: DesktopUpdateStatus.available,
              tier: DesktopUpdateTier.major,
            ),
          ),
          isTrue,
        );
        expect(
          shouldBlockForMajorDesktopUpdate(
            const DesktopUpdateState(
              status: DesktopUpdateStatus.retrying,
              tier: DesktopUpdateTier.major,
            ),
          ),
          isTrue,
        );
        expect(
          shouldBlockForMajorDesktopUpdate(
            const DesktopUpdateState(
              status: DesktopUpdateStatus.downloaded,
              tier: DesktopUpdateTier.major,
            ),
          ),
          isTrue,
        );
        expect(
          shouldBlockForMajorDesktopUpdate(
            const DesktopUpdateState(
              status: DesktopUpdateStatus.installing,
              tier: DesktopUpdateTier.major,
            ),
          ),
          isTrue,
        );
        expect(
          shouldBlockForMajorDesktopUpdate(
            const DesktopUpdateState(
              status: DesktopUpdateStatus.manualDownloadRequired,
              tier: DesktopUpdateTier.major,
            ),
          ),
          isTrue,
        );
        expect(
          shouldBlockForMajorDesktopUpdate(
            const DesktopUpdateState(
              status: DesktopUpdateStatus.downloaded,
              tier: DesktopUpdateTier.minor,
            ),
          ),
          isFalse,
        );
        expect(
          shouldBlockForMajorDesktopUpdate(
            const DesktopUpdateState(
              status: DesktopUpdateStatus.downloaded,
              tier: DesktopUpdateTier.patch,
            ),
          ),
          isFalse,
        );
      },
    );
  });
}

String _pubspecValue(String key) {
  final line = File(
    'pubspec.yaml',
  ).readAsLinesSync().firstWhere((line) => line.startsWith('$key:'));
  return line.split(':').skip(1).join(':').trim().replaceAll("'", '');
}
