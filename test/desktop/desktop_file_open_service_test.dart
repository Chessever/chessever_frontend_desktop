import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_file_open_service.dart';

void main() {
  group('DesktopFileOpenService', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_file_open_');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('filters startup arguments to local chess paths', () async {
      final pgn = File('${temp.path}/round.pgn');
      final compressedPgn = File('${temp.path}/rounds.pgn.gz');
      final zip = File('${temp.path}/database.zip');
      final cbz = File('${temp.path}/archive.cbz');
      final cbh = File('${temp.path}/database.cbh');
      final ignored = File('${temp.path}/notes.txt');
      final ignoredGzip = File('${temp.path}/notes.gz');
      await pgn.writeAsString('[Event "x"]\n\n*');
      await compressedPgn.writeAsBytes(const <int>[31, 139, 8, 0]);
      await zip.writeAsBytes(const <int>[80, 75, 3, 4]);
      await cbz.writeAsBytes(const <int>[1, 2, 3]);
      await cbh.writeAsBytes(const <int>[0, 1, 2, 3]);
      await ignored.writeAsString('not chess');
      await ignoredGzip.writeAsBytes(const <int>[31, 139, 8, 0]);

      final paths = DesktopFileOpenService.chessPathsFromArguments(<String>[
        '--some-engine-flag',
        '/updated',
        ignored.path,
        ignoredGzip.path,
        pgn.path,
        compressedPgn.path,
        pgn.path,
        zip.path,
        Uri.file(cbz.path).toString(),
        cbh.path,
        temp.path,
        '${temp.path}/missing.pgn',
      ]);

      expect(paths, <String>[
        pgn.path,
        compressedPgn.path,
        cbh.path,
        temp.path,
      ]);
    });

    test('coerces platform channel payloads', () async {
      final fen = File('${temp.path}/prep.fen');
      await fen.writeAsString('8/8/8/8/8/8/8/K6k w - - 0 1');

      expect(
        DesktopFileOpenService.chessPathsFromPlatformPayload(<Object?>[
          fen.path,
          7,
          null,
          '${temp.path}/missing.txt',
        ]),
        <String>[fen.path],
      );
    });
    test(
      'encodes single-instance handoff payloads as filtered chess paths',
      () async {
        final pgn = File('${temp.path}/round.pgn');
        final ignored = File('${temp.path}/notes.txt');
        await pgn.writeAsString('[Event "x"]\n\n*');
        await ignored.writeAsString('not chess');

        final payload = DesktopFileOpenService.singleInstancePayloadForPaths(
          <String>[pgn.path, ignored.path, pgn.path],
        );

        expect(
          DesktopFileOpenService.chessPathsFromSingleInstancePayload(payload),
          <String>[pgn.path],
        );
        expect(
          DesktopFileOpenService.chessPathsFromSingleInstancePayload(
            'not-json',
          ),
          isEmpty,
        );
      },
    );
  });
}
