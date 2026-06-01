import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS document types include local chess file formats', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();

    for (final ext in <String>[
      'pgn',
      'pgn.gz',
      'gz',
      'fen',
      'epd',
      'cbh',
      'cbv',
      'cbf',
    ]) {
      expect(plist, contains('<string>$ext</string>'));
    }
  });

  test('macOS desktop builds are unsandboxed for local file access', () {
    for (final path in <String>[
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final entitlements = File(path).readAsStringSync();

      expect(entitlements, contains('com.apple.security.app-sandbox'));
      expect(entitlements, contains('<false/>'));
    }
  });

  test('Windows installer offers open-with associations for chess formats', () {
    final installer =
        File('windows/installer/chessever.iss').readAsStringSync();

    for (final ext in <String>[
      '.pgn',
      '.gz',
      '.fen',
      '.epd',
      '.cbh',
      '.cbv',
      '.cbf',
    ]) {
      expect(installer, contains('Software\\Classes\\$ext\\OpenWithProgids'));
    }
    expect(
      installer,
      isNot(contains('Software\\Classes\\.zip\\OpenWithProgids')),
    );
    expect(
      installer,
      isNot(contains('Software\\Classes\\.cbz\\OpenWithProgids')),
    );

    expect(installer, contains('"""{app}\\{#AppExeName}"" ""%1"""'));
    expect(installer, contains('without importing it into SQLite'));
  });

  test('Windows runner forwards associated-file argv into Dart', () {
    final main = File('windows/runner/main.cpp').readAsStringSync();
    final utils = File('windows/runner/utils.cpp').readAsStringSync();

    expect(main, contains('GetCommandLineArguments()'));
    expect(main, contains('project.set_dart_entrypoint_arguments'));
    expect(utils, contains('CommandLineToArgvW'));
    expect(utils, contains('for (int i = 1; i < argc; i++)'));
    expect(utils, contains('Utf8FromUtf16(argv[i])'));
  });

  test('macOS AppDelegate forwards Finder open-files events into Dart', () {
    final appDelegate =
        File('macos/Runner/AppDelegate.swift').readAsStringSync();
    final bridge =
        File('macos/Runner/DesktopFileOpenBridge.swift').readAsStringSync();
    final window =
        File('macos/Runner/MainFlutterWindow.swift').readAsStringSync();

    expect(
      appDelegate,
      contains(
        'application(_ sender: NSApplication, openFiles filenames: [String])',
      ),
    );
    expect(
      appDelegate,
      contains('DesktopFileOpenBridge.shared.openFiles(filenames)'),
    );
    expect(bridge, contains('FlutterMethodChannel'));
    expect(bridge, contains('"takeInitialOpenFiles"'));
    expect(
      bridge,
      contains('channel.invokeMethod("openFiles", arguments: paths)'),
    );
    expect(window, contains('name: "chessever.desktop/file_open"'));
    expect(
      window,
      contains(
        'DesktopFileOpenBridge.shared.attach(channel: fileOpenChannel!)',
      ),
    );
  });
}
