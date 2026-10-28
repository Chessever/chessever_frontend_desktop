// The updater's internals are vendored under third_party/ and tested here.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_updater/src/file_hash.dart' as updater_hash;
import 'package:desktop_updater/src/remote_file.dart' as updater_remote;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Real sockets: the widget-test binding would answer every request itself.
  setUp(() => HttpOverrides.global = null);

  group('downloads', () {
    late HttpServer server;
    late Directory temp;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      temp = await Directory.systemTemp.createTemp('updater_hardening_');
    });

    tearDown(() async {
      await server.close(force: true);
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test(
      'a transfer that goes silent ends with an error, not a hang',
      () async {
        final release = Completer<void>();
        server.listen((request) async {
          // Unbuffered, so the first bytes really reach the client.
          request.response
            ..bufferOutput = false
            ..contentLength = 1000
            ..add(List<int>.filled(100, 7));
          await request.response.flush();
          // The connection stays open and nothing more arrives.
          await release.future;
        });
        addTearDown(release.complete);
        final destination = File('${temp.path}/app.bin');

        await expectLater(
          updater_remote.downloadUriToFile(
            'http://127.0.0.1:${server.port}/app.bin',
            destination,
            idleTimeout: const Duration(milliseconds: 300),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(destination.existsSync(), isFalse);
        expect(
          File('${destination.path}.part').existsSync(),
          isFalse,
          reason: 'no half file is left behind for an install to pick up',
        );
      },
    );

    test('a server that never answers ends with an error', () async {
      final release = Completer<void>();
      server.listen((request) async => release.future);
      addTearDown(release.complete);

      await expectLater(
        updater_remote.downloadUriToFile(
          'http://127.0.0.1:${server.port}/app-archive.json',
          File('${temp.path}/app-archive.json'),
          connectTimeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a slow but live transfer completes', () async {
      server.listen((request) async {
        request.response
          ..bufferOutput = false
          ..contentLength = 30;
        for (var i = 0; i < 3; i++) {
          request.response.add(List<int>.filled(10, i));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        await request.response.close();
      });
      final destination = File('${temp.path}/slow.bin');

      await updater_remote.downloadUriToFile(
        'http://127.0.0.1:${server.port}/slow.bin',
        destination,
        idleTimeout: const Duration(milliseconds: 400),
      );

      expect(destination.lengthSync(), 30);
    });
  });

  group('the Windows uninstaller', () {
    test(
      'is left out of the file sweep, so an update never deletes it',
      () async {
        final install = await Directory.systemTemp.createTemp(
          'updater_install_',
        );
        addTearDown(() => install.deleteSync(recursive: true));
        for (final name in [
          'Chessever.exe',
          'unins000.exe',
          'unins000.dat',
          'UNINS001.MSG',
          'data/unins000.exe',
          'uninstall-notes.txt',
        ]) {
          File('${install.path}/$name')
            ..createSync(recursive: true)
            ..writeAsStringSync(name);
        }

        final hashesPath = await updater_hash.genFileHashes(path: install.path);
        final listed = [
          for (final entry
              in jsonDecode(File(hashesPath).readAsStringSync())
                  as List<dynamic>)
            (entry as Map<String, dynamic>)['path'] as String,
        ];

        expect(listed, [
          'Chessever.exe',
          // Only the installer's own files beside the app are skipped.
          'data/unins000.exe',
          'uninstall-notes.txt',
        ]);
      },
    );
  });
}
