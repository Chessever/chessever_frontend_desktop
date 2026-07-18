import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const _requiredFiles = <String>[
  'Chessever.exe',
  'flutter_windows.dll',
  'desktop_updater_plugin.dll',
  'flutter_onnxruntime_plugin.dll',
  'flutter_soloud_plugin.dll',
  'onnxruntime.dll',
  'resqlite.dll',
  'sqlite3.dll',
  'FLAC.dll',
  'ogg.dll',
  'opus.dll',
  'vorbis.dll',
  'vorbisfile.dll',
];

void main() {
  test('finds bundled Dart from FLUTTER_ROOT before PATH', () async {
    final temp = await Directory.systemTemp.createTemp(
      'chessever_dart_executable_flutter_root_',
    );
    try {
      final configuredRoot = Directory('${temp.path}/configured');
      final configuredDart = _createFakeDartExecutable(configuredRoot);
      final pathRoot = Directory('${temp.path}/path');
      _createFakeDartExecutable(pathRoot);
      final flutter = _createFakeFlutterExecutable(pathRoot);

      expect(
        File(
          _findBundledDartExecutable(
            environment: {
              'FLUTTER_ROOT': configuredRoot.path,
              'PATH': flutter.parent.path,
            },
          ),
        ).resolveSymbolicLinksSync(),
        configuredDart.resolveSymbolicLinksSync(),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('finds bundled Dart from Flutter on PATH', () async {
    final temp = await Directory.systemTemp.createTemp(
      'chessever_dart_executable_path_',
    );
    try {
      final flutterRoot = Directory('${temp.path}/flutter');
      final dart = _createFakeDartExecutable(flutterRoot);
      final flutter = _createFakeFlutterExecutable(flutterRoot);

      expect(
        File(
          _findBundledDartExecutable(
            environment: {'PATH': flutter.parent.path},
          ),
        ).resolveSymbolicLinksSync(),
        dart.resolveSymbolicLinksSync(),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('Windows release verifier checks PE architecture and exports', () async {
    final repository = Directory.current;
    final temp = await Directory.systemTemp.createTemp(
      'chessever_windows_bundle_verifier_',
    );
    try {
      final release = Directory('${temp.path}/build/windows/x64/runner/Release')
        ..createSync(recursive: true);
      for (final name in _requiredFiles) {
        File('${release.path}/$name').writeAsBytesSync(const [1]);
      }
      final resqlite = File('${release.path}/resqlite.dll');
      resqlite.writeAsBytesSync(_syntheticResqliteDll());

      final valid = await _runVerifier(repository: repository, cwd: temp);
      expect(
        valid.exitCode,
        0,
        reason: 'stdout:\n${valid.stdout}\nstderr:\n${valid.stderr}',
      );

      resqlite.writeAsBytesSync(_syntheticResqliteDll(machine: 0x014c));
      final wrongArchitecture = await _runVerifier(
        repository: repository,
        cwd: temp,
      );
      expect(wrongArchitecture.exitCode, isNot(0));
      expect(wrongArchitecture.stderr, contains('expected AMD64 machine'));

      resqlite.writeAsBytesSync(
        _syntheticResqliteDll(exports: const ['resqlite_open', 'strlen']),
      );
      final missingExport = await _runVerifier(
        repository: repository,
        cwd: temp,
      );
      expect(missingExport.exitCode, isNot(0));
      expect(
        missingExport.stderr,
        contains('missing exported symbol name resqlite_open_with_extensions'),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });
}

Future<ProcessResult> _runVerifier({
  required Directory repository,
  required Directory cwd,
}) {
  return Process.run(_findBundledDartExecutable(), [
    '${repository.path}/tool/verify_windows_release_bundle.dart',
  ], workingDirectory: cwd.path);
}

String _findBundledDartExecutable({Map<String, String>? environment}) {
  final currentEnvironment = environment ?? Platform.environment;
  final flutterRoots = <Directory>[];
  final configuredRoot = _environmentValue(currentEnvironment, 'FLUTTER_ROOT');
  if (configuredRoot != null && configuredRoot.trim().isNotEmpty) {
    flutterRoots.add(Directory(_unquote(configuredRoot)));
  }

  final path = _environmentValue(currentEnvironment, 'PATH');
  if (path != null) {
    final flutterName = Platform.isWindows ? 'flutter.bat' : 'flutter';
    final pathSeparator = Platform.isWindows ? ';' : ':';
    for (final rawEntry in path.split(pathSeparator)) {
      final entry = _unquote(rawEntry);
      if (entry.isEmpty) continue;
      final flutter = File('$entry${Platform.pathSeparator}$flutterName');
      if (!flutter.existsSync()) continue;
      try {
        flutterRoots.add(
          File(flutter.resolveSymbolicLinksSync()).parent.parent,
        );
      } on FileSystemException {
        flutterRoots.add(flutter.parent.parent);
      }
    }
  }

  final searched = <String>[];
  final dartName = Platform.isWindows ? 'dart.exe' : 'dart';
  for (final flutterRoot in flutterRoots) {
    final dart = File(
      '${flutterRoot.path}${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
      '${Platform.pathSeparator}bin${Platform.pathSeparator}$dartName',
    );
    searched.add(dart.path);
    if (dart.existsSync()) return dart.path;
  }

  throw StateError(
    'Could not find Flutter bundled Dart executable. Searched: '
    '${searched.isEmpty ? '(no Flutter SDK candidates)' : searched.join(', ')}',
  );
}

String? _environmentValue(Map<String, String> environment, String name) {
  for (final entry in environment.entries) {
    if (entry.key.toUpperCase() == name) return entry.value;
  }
  return null;
}

String _unquote(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

File _createFakeDartExecutable(Directory flutterRoot) {
  final dartName = Platform.isWindows ? 'dart.exe' : 'dart';
  return File(
    '${flutterRoot.path}${Platform.pathSeparator}bin'
    '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
    '${Platform.pathSeparator}bin${Platform.pathSeparator}$dartName',
  )..createSync(recursive: true);
}

File _createFakeFlutterExecutable(Directory flutterRoot) {
  final flutterName = Platform.isWindows ? 'flutter.bat' : 'flutter';
  return File(
    '${flutterRoot.path}${Platform.pathSeparator}bin'
    '${Platform.pathSeparator}$flutterName',
  )..createSync(recursive: true);
}

Uint8List _syntheticResqliteDll({
  int machine = 0x8664,
  List<String> exports = const [
    'resqlite_open',
    'resqlite_open_with_extensions',
    'strlen',
  ],
}) {
  final bytes = Uint8List(512);
  bytes[0] = 0x4d;
  bytes[1] = 0x5a;
  _writeUint32Le(bytes, 0x3c, 0x80);
  bytes.setRange(0x80, 0x84, const [0x50, 0x45, 0, 0]);
  _writeUint16Le(bytes, 0x84, machine);
  _writeUint16Le(bytes, 0x98, 0x020b);

  var offset = 0x120;
  for (final export in exports) {
    final encoded = <int>[...export.codeUnits, 0];
    bytes.setRange(offset, offset + encoded.length, encoded);
    offset += encoded.length;
  }
  return bytes;
}

void _writeUint16Le(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}

void _writeUint32Le(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = (value >> 24) & 0xff;
}
