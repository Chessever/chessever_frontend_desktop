import 'dart:io';

const _releaseDirPath = 'build/windows/x64/runner/Release';

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

const _requiredResqliteExports = <String>[
  'resqlite_open',
  'resqlite_open_with_extensions',
  'strlen',
];

void main() {
  final releaseDir = Directory(_releaseDirPath);
  if (!releaseDir.existsSync()) {
    if (Platform.isWindows) {
      stderr.writeln('Windows release directory not found: $_releaseDirPath');
      exitCode = 1;
      return;
    }

    stdout.writeln(
      'Skipping Windows release bundle verification on ${Platform.operatingSystem}.',
    );
    return;
  }

  final missingOrEmpty = <String>[];
  for (final fileName in _requiredFiles) {
    final file = File('${releaseDir.path}${Platform.pathSeparator}$fileName');
    if (!file.existsSync() || file.lengthSync() == 0) {
      missingOrEmpty.add(fileName);
    }
  }

  if (missingOrEmpty.isNotEmpty) {
    stderr.writeln('Windows release bundle is missing required files:');
    for (final fileName in missingOrEmpty) {
      stderr.writeln('- $fileName');
    }
    exitCode = 1;
    return;
  }

  final resqlite = File(
    '${releaseDir.path}${Platform.pathSeparator}resqlite.dll',
  );
  final resqliteErrors = _validateAmd64PeExports(
    resqlite,
    _requiredResqliteExports,
  );
  if (resqliteErrors.isNotEmpty) {
    stderr.writeln('Windows resqlite.dll validation failed:');
    for (final error in resqliteErrors) {
      stderr.writeln('- $error');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln('Windows release bundle contains required native files:');
  for (final fileName in _requiredFiles) {
    final file = File('${releaseDir.path}${Platform.pathSeparator}$fileName');
    final length = file.lengthSync();
    stdout.writeln('- $fileName ($length bytes)');
  }
  stdout.writeln(
    '- resqlite.dll is PE32+ AMD64 and exposes '
    '${_requiredResqliteExports.join(', ')}',
  );
}

List<String> _validateAmd64PeExports(File file, List<String> exports) {
  final bytes = file.readAsBytesSync();
  final errors = <String>[];
  if (bytes.length < 64 || bytes[0] != 0x4d || bytes[1] != 0x5a) {
    return const ['file does not have a valid DOS/PE header'];
  }

  final peOffset = _readUint32Le(bytes, 0x3c);
  if (peOffset == null ||
      peOffset < 0 ||
      peOffset + 26 > bytes.length ||
      bytes[peOffset] != 0x50 ||
      bytes[peOffset + 1] != 0x45 ||
      bytes[peOffset + 2] != 0 ||
      bytes[peOffset + 3] != 0) {
    return const ['file does not have a valid PE signature'];
  }

  final machine = _readUint16Le(bytes, peOffset + 4);
  if (machine != 0x8664) {
    errors.add(
      'expected AMD64 machine 0x8664, got '
      '${machine == null ? 'truncated header' : '0x${machine.toRadixString(16)}'}',
    );
  }
  final optionalHeaderMagic = _readUint16Le(bytes, peOffset + 24);
  if (optionalHeaderMagic != 0x20b) {
    errors.add(
      'expected PE32+ optional header 0x20b, got '
      '${optionalHeaderMagic == null ? 'truncated header' : '0x${optionalHeaderMagic.toRadixString(16)}'}',
    );
  }

  for (final export in exports) {
    if (!_containsNullTerminatedAscii(bytes, export)) {
      errors.add('missing exported symbol name $export');
    }
  }
  return errors;
}

int? _readUint16Le(List<int> bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) return null;
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int? _readUint32Le(List<int> bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return null;
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

bool _containsNullTerminatedAscii(List<int> bytes, String value) {
  final needle = <int>[...value.codeUnits, 0];
  if (needle.length > bytes.length) return false;
  for (var start = 0; start <= bytes.length - needle.length; start++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (bytes[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
