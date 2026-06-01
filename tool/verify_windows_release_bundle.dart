import 'dart:io';

const _releaseDirPath = 'build/windows/x64/runner/Release';

const _requiredFiles = <String>[
  'Chessever.exe',
  'flutter_windows.dll',
  'flutter_soloud_plugin.dll',
  'FLAC.dll',
  'ogg.dll',
  'opus.dll',
  'vorbis.dll',
  'vorbisfile.dll',
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

  stdout.writeln('Windows release bundle contains required native files:');
  for (final fileName in _requiredFiles) {
    final file = File('${releaseDir.path}${Platform.pathSeparator}$fileName');
    final length = file.lengthSync();
    stdout.writeln('- $fileName ($length bytes)');
  }
}
