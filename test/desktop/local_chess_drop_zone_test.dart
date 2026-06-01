import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_drop_zone.dart';

void main() {
  group('local chess drop zone', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_drop_zone_');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('keeps recognized chess files and existing folders', () async {
      final folder = Directory('${temp.path}/database');
      await folder.create();
      final pgn = File('${temp.path}/round.pgn');
      await pgn.writeAsString('[Event "Drop"]\n\n1. e4 *');
      final cbh = File('${temp.path}/mega.cbh');
      await cbh.writeAsString('recognized but unsupported shell');

      expect(
        localChessDropPaths(<String>[pgn.path, folder.path, cbh.path]),
        <String>[pgn.path, folder.path, cbh.path],
      );
    });

    test(
      'rejects unrelated files, generic gzip, empty paths, and missing dirs',
      () async {
        final notes = File('${temp.path}/notes.txt');
        await notes.writeAsString('not chess');
        final gzip = File('${temp.path}/notes.gz');
        await gzip.writeAsString('not a pgn.gz');
        final zip = File('${temp.path}/database.zip');
        await zip.writeAsBytes(const <int>[80, 75, 3, 4]);
        final cbz = File('${temp.path}/archive.cbz');
        await cbz.writeAsBytes(const <int>[80, 75, 3, 4]);

        expect(
          localChessDropPaths(<String>[
            '',
            '   ',
            notes.path,
            gzip.path,
            zip.path,
            cbz.path,
            '${temp.path}/missing-folder',
          ]),
          isEmpty,
        );
      },
    );
  });
}
