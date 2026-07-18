import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../third_party/desktop_updater/bin/archive.dart' as updater_archive;

void main() {
  test(
    'Linux updater archive hashes required shared-library aliases',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'chessever_linux_archive_links_',
      );
      try {
        final library = File('${temp.path}/libonnxruntime.so.1.22.0')
          ..writeAsStringSync('onnx-runtime-binary');
        Link(
          '${temp.path}/libonnxruntime.so.1',
        ).createSync(library.uri.pathSegments.last);
        Link(
          '${temp.path}/libonnxruntime.so',
        ).createSync('libonnxruntime.so.1');

        final hashesPath = await updater_archive.genFileHashes(
          path: temp.path,
          includeFileLinks: true,
        );
        final hashes = jsonDecode(File(hashesPath!).readAsStringSync()) as List;
        final byPath = <String, Map<String, dynamic>>{
          for (final entry in hashes.whereType<Map<String, dynamic>>())
            (entry['path'] ?? entry['filePath']) as String: entry,
        };

        expect(byPath.keys, contains('libonnxruntime.so.1.22.0'));
        expect(byPath.keys, contains('libonnxruntime.so.1'));
        expect(byPath.keys, contains('libonnxruntime.so'));
        expect(
          byPath['libonnxruntime.so.1']!['calculatedHash'],
          byPath['libonnxruntime.so.1.22.0']!['calculatedHash'],
        );
        expect(byPath['libonnxruntime.so']!['length'], library.lengthSync());

        final materialize = await Process.run('bash', [
          'scripts/materialize_linux_update_archive_links.sh',
          temp.path,
        ]);
        expect(
          materialize.exitCode,
          0,
          reason:
              'stdout:\n${materialize.stdout}\nstderr:\n${materialize.stderr}',
        );
        for (final alias in const [
          'libonnxruntime.so.1',
          'libonnxruntime.so',
        ]) {
          final aliasPath = '${temp.path}/$alias';
          expect(
            FileSystemEntity.typeSync(aliasPath, followLinks: false),
            FileSystemEntityType.file,
          );
          expect(
            await updater_archive.getFileHash(File(aliasPath)),
            byPath[alias]!['calculatedHash'],
          );
        }

        final pythonHash = await Process.run('python3', [
          '-c',
          'import base64, hashlib, pathlib, sys; '
              'print(base64.b64encode(hashlib.blake2b('
              'pathlib.Path(sys.argv[1]).read_bytes()).digest()).decode())',
          '${temp.path}/libonnxruntime.so.1',
        ]);
        expect(pythonHash.exitCode, 0, reason: '${pythonHash.stderr}');
        expect(
          '${pythonHash.stdout}'.trim(),
          byPath['libonnxruntime.so.1']!['calculatedHash'],
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip:
        Platform.isWindows
            ? 'Creating symlinks may require elevated privileges on Windows.'
            : false,
  );

  test(
    'updater archive rejects a symlink that escapes its root',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'chessever_linux_archive_escape_',
      );
      try {
        final archive = Directory('${parent.path}/archive')..createSync();
        final outside = File('${parent.path}/outside.so')
          ..writeAsStringSync('must-not-enter-the-archive');
        Link('${archive.path}/liboutside.so').createSync(outside.path);

        await expectLater(
          updater_archive.genFileHashes(
            path: archive.path,
            includeFileLinks: true,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('escapes its root'),
            ),
          ),
        );
      } finally {
        await parent.delete(recursive: true);
      }
    },
    skip:
        Platform.isWindows
            ? 'Creating symlinks may require elevated privileges on Windows.'
            : false,
  );
}
