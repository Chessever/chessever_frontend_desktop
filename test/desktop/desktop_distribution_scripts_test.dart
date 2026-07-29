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
      final updaterPlugin =
          File(
            'third_party/desktop_updater/macos/desktop_updater/Sources/'
            'desktop_updater/DesktopUpdaterPlugin.swift',
          ).readAsStringSync();
      final frameworkRepairFixture =
          File(
            'scripts/test_macos_updater_framework_repair.sh',
          ).readAsStringSync();

      expect(script, contains(r'RELEASE_VERSION="${VERSION}+${BUILD}"'));
      expect(
        script,
        contains(r'ARCHIVE_NAME="${RELEASE_VERSION}-${UPDATE_PLATFORM}"'),
      );
      expect(script, contains(r'UPDATE_PLATFORM="macos-${MACOS_RELEASE_ARCH}"'));
      expect(script, contains('macos/Runner/Release.entitlements'));
      expect(script, contains(r'xcrun notarytool submit "$TMP_ZIP" --wait'));
      expect(script, contains(r'xcrun stapler staple "$APP"'));
      expect(
        script,
        contains(r'--verify-release-env=$EXPECTED_DART_DEFINE_KEYS'),
      );
      expect(script, contains(r'run_release_env_check "$APP"'));
      expect(
        script,
        contains(r'dart run desktop_updater:archive "$UPDATE_PLATFORM"'),
      );
      expect(
        script,
        contains(r'remove_transport_only_framework_links "$ARCHIVE_DIR"'),
      );
      expect(
        script,
        contains('updater archive contains unsupported symbolic links'),
      );
      expect(
        script,
        isNot(contains('Removing unhashed macOS archive symlink')),
      );
      expect(script, contains('validate_versioned_frameworks'));
      expect(
        script,
        contains(r'lipo "$RESQLITE_BIN" -verify_arch arm64 x86_64'),
      );
      expect(script, contains('"_resqlite_open"'));
      expect(
        script,
        contains(r'validate_desktop_updater_archive "$ARCHIVE_DIR"'),
      );
      expect(script, contains(r'entry.get("path") or entry.get("filePath")'));
      expect(script, contains(r'desktop/archive/$ARCHIVE_NAME/'));
      expect(
        script,
        contains(r'ingest $UPDATE_PLATFORM $ARCHIVE_NAME $RELEASE_VERSION'),
      );
      expect(script, contains('Chessever-arm64.dmg'));
      expect(script, contains('Chessever-intel.dmg'));
      expect(script, contains('must be a single-arch binary'));
      _expectInstallerUploadsBeforePrune(
        script: script,
        platform: r'$UPDATE_PLATFORM',
        versionedUpload:
            r'desktop/downloads/${VERSIONED_DMG_NAME}',
        stableUpload: r'desktop/downloads/${STABLE_DMG_NAME}',
      );
      expect(script, isNot(contains('SUPARKLE')));
      expect(script, isNot(contains('sign_update')));
      expect(codemagic, contains('macos-desktop-release:'));
      expect(codemagic, contains('instance_type: mac_mini_m4'));
      expect(codemagic, contains('max_build_duration: 180'));
      expect(codemagic, contains('chessever-desktop-release'));
      expect(codemagic, contains('CM_CERTIFICATE'));
      expect(codemagic, contains('SENTRY_FLUTTER'));
      expect(codemagic, contains('CHESSEVER_CLOUDFLARE_API_BASE'));
      expect(codemagic, contains('GAMEBASE_PROXY_BASE'));
      expect(codemagic, isNot(contains('GAMEBASE_API_KEY')));
      expect(codemagic, contains('GOOGLE_WEB_CLIENT_ID'));
      expect(codemagic, contains('--dart-define=GOOGLE_WEB_CLIENT_ID'));
      expect(codemagic, contains('keychain initialize'));
      expect(codemagic, contains('keychain add-certificates'));
      expect(codemagic, contains('./scripts/codemagic_publish_macos.sh'));
      expect(
        codemagic,
        contains('bash ./scripts/test_macos_updater_framework_repair.sh'),
      );
      expect(codemagic, isNot(contains('--dart-define-from-file')));
      expect(codemagic, contains('for ARCH in arm64 x64'));
      expect(codemagic, contains(r'macos-${ARCH}'));
      expect(codemagic, contains('--dart-define=MACOS_RELEASE_ARCH'));
      expect(codemagic, isNot(contains('sign_update')));
      expect(codemagic, isNot(contains('.zip.sig')));

      final repairCall = updaterPlugin.indexOf(
        'repairInstalledVersionedFrameworks()',
      );
      final channelRegistration = updaterPlugin.indexOf(
        'FlutterMethodChannel(',
      );
      expect(repairCall, greaterThanOrEqualTo(0));
      expect(channelRegistration, greaterThan(repairCall));
      expect(
        updaterPlugin,
        contains('# BEGIN DESKTOP_UPDATER_FRAMEWORK_REPAIR'),
      );
      expect(updaterPlugin, contains('repair_versioned_frameworks'));
      expect(updaterPlugin, contains('candidates.count == 1'));
      expect(updaterPlugin, contains('existingCurrent'));
      expect(updaterPlugin, contains('isSymbolicLink != true'));
      expect(frameworkRepairFixture, contains('do-not-delete'));
      expect(
        frameworkRepairFixture,
        contains('unambiguous or existing framework version'),
      );

      final packageName = _pubspecValue('name');
      final appInfo =
          File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync();
      final infoPlist = File('macos/Runner/Info.plist').readAsStringSync();
      expect(appInfo, contains('PRODUCT_NAME = $packageName'));
      expect(appInfo, contains('CHESSEVER_DISPLAY_NAME = ChessEver'));
      expect(appInfo, contains('CHESSEVER_URL_SCHEME = chessever'));
      expect(infoPlist, contains('<key>CFBundleDisplayName</key>'));
      expect(
        infoPlist,
        contains(r'<string>$(CHESSEVER_DISPLAY_NAME)</string>'),
      );
      expect(infoPlist, contains(r'<string>$(CHESSEVER_URL_SCHEME)</string>'));

      final project =
          File('macos/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      expect(
        project,
        contains(
          'PRODUCT_BUNDLE_IDENTIFIER = '
          'com.chessever.desktop.development;',
        ),
      );
      expect(
        project,
        contains('CHESSEVER_DISPLAY_NAME = "ChessEver Development";'),
      );

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
      final symbolScript =
          File(
            'scripts/codemagic_upload_windows_symbols.ps1',
          ).readAsStringSync();
      final codemagic = File('codemagic.yaml').readAsStringSync();
      final windowsCmake = File('windows/CMakeLists.txt').readAsStringSync();
      final bundleVerifier =
          File('tool/verify_windows_release_bundle.dart').readAsStringSync();

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
      expect(bundleVerifier, contains("'resqlite.dll'"));
      expect(bundleVerifier, contains("'sqlite3.dll'"));
      expect(bundleVerifier, contains("'onnxruntime.dll'"));
      expect(bundleVerifier, contains("'flutter_onnxruntime_plugin.dll'"));
      expect(bundleVerifier, contains("'desktop_updater_plugin.dll'"));
      expect(bundleVerifier, contains('expected AMD64 machine 0x8664'));
      expect(bundleVerifier, contains('expected PE32+ optional header 0x20b'));
      expect(bundleVerifier, contains("'resqlite_open_with_extensions'"));
      expect(bundleVerifier, contains("'strlen'"));
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
      _expectInstallerUploadsBeforePrune(
        script: script,
        platform: 'windows',
        versionedUpload: r'desktop/downloads/$versionedInstallerName',
        stableUpload: 'desktop/downloads/Chessever-Setup.exe',
      );
      expect(codemagic, contains('windows-desktop-release:'));
      expect(
        codemagic,
        contains(
          'flutter test --no-pub '
          'test/desktop/windows_release_bundle_verifier_test.dart',
        ),
      );
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
      expect(windowsCmake, contains(r'$<$<CONFIG:Release>:/Zi>'));
      expect(windowsCmake, contains(r'$<$<CONFIG:Release>:/DEBUG:FULL>'));
      expect(buildScript, contains("Join-Path \$BuildRoot 'native-symbols'"));
      expect(
        symbolScript,
        contains(r'build\windows\x64\native-symbols\$releaseVersion'),
      );
      expect(buildScript, contains('flutter_windows.dll.pdb'));
      expect(buildScript, contains(r"-Filter '*.pdb'"));
      expect(buildScript, contains(r'Remove-Item -LiteralPath $_.FullName'));
      expect(buildScript, contains('Assert-NoRuntimePdbs'));
      expect(symbolScript, contains('SENTRY_AUTH_TOKEN'));
      expect(symbolScript, contains('SENTRY_ORG'));
      expect(symbolScript, contains('SENTRY_PROJECT'));
      expect(symbolScript, contains('Write-Warning'));
      expect(symbolScript, contains('chessever-desktop-release'));
      expect(symbolScript, isNot(contains('--auth-token')));
      expect(
        symbolScript,
        contains(r'@("debug-files", "upload", "--wait", $symbolDir)'),
      );
      expect(symbolScript, contains('Get-Command sentry'));
      expect(symbolScript, contains('Get-Command sentry-cli'));
      expect(symbolScript, contains("install --global 'sentry'"));

      final symbolsStepName = codemagic.indexOf(
        '- name: Upload Windows native symbols',
      );
      final symbolsStep = codemagic.indexOf(
        r'powershell -ExecutionPolicy Bypass -File .\scripts\codemagic_upload_windows_symbols.ps1',
      );
      final publishStep = codemagic.indexOf(
        r'powershell -ExecutionPolicy Bypass -File .\scripts\codemagic_publish_windows.ps1',
      );
      final installInnoStep = codemagic.indexOf(
        '- name: Install Inno Setup',
        symbolsStep,
      );
      expect(symbolsStepName, greaterThanOrEqualTo(0));
      expect(symbolsStep, greaterThanOrEqualTo(0));
      expect(installInnoStep, greaterThan(symbolsStep));
      expect(
        codemagic.substring(symbolsStepName, installInnoStep),
        contains('ignore_failure: true'),
      );
      expect(symbolsStep, lessThan(publishStep));
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
      _expectInstallerUploadsBeforePrune(
        script: script,
        platform: 'linux',
        versionedUpload:
            r'desktop/downloads/Chessever-${RELEASE_VERSION}-amd64.deb',
        stableUpload: r'desktop/downloads/Chessever.deb',
      );
    });

    test('Linux bundle includes ONNX Runtime SONAME libraries', () {
      final cmake = File('linux/CMakeLists.txt').readAsStringSync();
      final archive =
          File(
            'third_party/desktop_updater/bin/archive.dart',
          ).readAsStringSync();
      final publish =
          File('scripts/codemagic_publish_linux.sh').readAsStringSync();
      final materialize =
          File(
            'scripts/materialize_linux_update_archive_links.sh',
          ).readAsStringSync();

      expect(cmake, contains('flutter_onnxruntime'));
      expect(cmake, contains('libonnxruntime*.so*'));
      expect(cmake, contains('FOLLOW_SYMLINK_CHAIN'));
      expect(cmake, contains(r'${INSTALL_BUNDLE_LIB_DIR}'));
      expect(archive, contains('includeFileLinks: platform == "linux"'));
      expect(publish, contains('materialize_linux_update_archive_links.sh'));
      expect(publish, contains('validate_linux_native_archive'));
      expect(publish, contains('lib/libflutter_onnxruntime_plugin.so'));
      expect(publish, contains('lib/libonnxruntime.so.1'));
      expect(publish, contains('lib/libresqlite.so'));
      expect(publish, contains('ELF 64-bit LSB shared object'));
      expect(publish, contains('resqlite_open_with_extensions'));
      expect(
        publish,
        contains("grep -Fq 'Shared library: [libonnxruntime.so.1]'"),
      );
      expect(materialize, contains('cp -pL'));
      expect(materialize, contains('mktemp'));
      expect(materialize, contains(r'unlink "$link"'));
      expect(
        File('codemagic.yaml').readAsStringSync(),
        contains(
          'flutter test --no-pub '
          'test/desktop/desktop_updater_archive_symlink_test.dart',
        ),
      );
      expect(
        publish,
        isNot(contains('Removing unhashed Linux archive symlink')),
      );
    });

    test('live archive verifier requires native runtime payloads', () {
      final verifier =
          File('tool/verify_desktop_app_archive.dart').readAsStringSync();

      expect(verifier, contains("'Frameworks/resqlite.framework/Versions/'"));
      expect(verifier, contains("'resqlite.dll'"));
      expect(verifier, contains("'lib/libresqlite.so'"));
      expect(verifier, contains("'lib/libonnxruntime.so.1'"));
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
      expect(wrapper, contains('KEEP_LAST_N=2'));
      expect(wrapper, isNot(contains('KEEP_LAST_N=3')));
      expect(wrapper, contains(r'--keep-last-n "$KEEP_LAST_N"'));
      expect(wrapper, contains('macos | windows | linux'));
      expect(wrapper, contains('bad archive'));
      expect(wrapper, contains('"prune-downloads "*'));
      expect(wrapper, contains('too many prune-downloads arguments'));
      expect(
        wrapper,
        contains('/usr/local/bin/codemagic-finalize prune-downloads'),
      );
      expect(wrapper, contains(r'"$platform" --keep-last-n "$KEEP_LAST_N"'));
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
      expect(desktopEnv, contains('CHESSEVER_CLOUDFLARE_API_BASE'));
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
      expect(
        authGate,
        contains(
          'return const DesktopStandaloneWindowChrome(child: DesktopWelcomeScreen());',
        ),
      );
      expect(authGate, contains('child: DesktopPremiumRequiredScreen(),'));
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

void _expectInstallerUploadsBeforePrune({
  required String script,
  required String platform,
  required String versionedUpload,
  required String stableUpload,
}) {
  final versionedUploadIndex = script.indexOf(versionedUpload);
  final stableUploadIndex = script.indexOf(stableUpload);
  final pruneCommand = 'prune-downloads $platform';
  final pruneIndex = script.indexOf(pruneCommand);

  expect(versionedUploadIndex, greaterThanOrEqualTo(0));
  expect(stableUploadIndex, greaterThan(versionedUploadIndex));
  expect(pruneIndex, greaterThan(stableUploadIndex));
  // Dual macOS packages use `$UPDATE_PLATFORM` (macos-arm64 / macos-x64).
  // Windows/Linux still use bare platform keys.
  expect(script, contains(pruneCommand));
}
