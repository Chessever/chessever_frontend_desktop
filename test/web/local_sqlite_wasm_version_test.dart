// The browser build loads the SQLite engine for local databases from
// web/sqlite/sqlite3-<version>.wasm. Its imports have to match the Dart
// package:sqlite3 version exactly; a mismatch is a LinkError when the module
// loads, so local databases fail only in the deployed web app. This test ties
// the vendored module and the shim's asset path to the locked version.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The `version:` of the `sqlite3` entry in pubspec.lock, or null.
String? _lockedSqlite3Version(String lock) {
  final lines = const LineSplitter().convert(lock);
  final start = lines.indexWhere((line) => line.trimRight() == '  sqlite3:');
  if (start < 0) return null;
  final versionLine = RegExp(r'^    version: "([^"]+)"$');
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (!line.startsWith('    ')) break;
    final match = versionLine.firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

void main() {
  late String version;

  setUpAll(() {
    final lock = File('pubspec.lock');
    expect(
      lock.existsSync(),
      isTrue,
      reason: 'run from the package root (${Directory.current.path})',
    );
    final locked = _lockedSqlite3Version(lock.readAsStringSync());
    expect(locked, isNotNull, reason: 'pubspec.lock has no sqlite3 version');
    version = locked!;
  });

  test('web/sqlite vendors the Wasm module of the locked sqlite3', () {
    final wasm = File('web/sqlite/sqlite3-$version.wasm');
    expect(
      wasm.existsSync(),
      isTrue,
      reason:
          'pubspec.lock pins sqlite3 $version, so web/sqlite/ needs the '
          'sqlite3.wasm asset of the sqlite3-$version release saved as '
          '${wasm.path} (see web/sqlite/README.md)',
    );
    final magic = wasm.openSync()..setPositionSync(0);
    try {
      expect(magic.readSync(4), <int>[
        0x00,
        0x61,
        0x73,
        0x6d,
      ], reason: '${wasm.path} is not a WebAssembly module');
    } finally {
      magic.closeSync();
    }
  });

  test('the web shim loads the Wasm module of the locked sqlite3', () {
    final shim = File('lib/web/shims/local_sqlite_web.dart');
    expect(shim.existsSync(), isTrue);
    expect(
      shim.readAsStringSync(),
      contains('sqlite/sqlite3-$version.wasm'),
      reason:
          'lib/web/shims/local_sqlite_web.dart must load '
          'sqlite/sqlite3-$version.wasm to match pubspec.lock',
    );
  });
}
