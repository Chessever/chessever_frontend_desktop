import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/pgn_file_picker.dart';

void main() {
  group('loadPgnTextForBoard', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_pgn_picker_');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('returns a stable PGN snapshot', () async {
      final file = File('${temp.path}/game.pgn');
      const pgn = '[Event "Picker"]\n\n1. e4 e5 *';
      await file.writeAsString(pgn, flush: true);
      final errors = <String>[];

      final loaded = await loadPgnTextForBoard(file.path, onError: errors.add);

      expect(loaded, pgn);
      expect(errors, isEmpty);
    });

    test('reports an empty PGN without opening a board', () async {
      final file = File('${temp.path}/empty.pgn');
      await file.writeAsString('  \n', flush: true);
      final errors = <String>[];

      final loaded = await loadPgnTextForBoard(file.path, onError: errors.add);

      expect(loaded, isNull);
      expect(errors.single, contains('No playable PGN entries'));
      expect(errors.single, contains('empty.pgn'));
    });

    test('reports an actionable missing-file error', () async {
      final errors = <String>[];

      final loaded = await loadPgnTextForBoard(
        '${temp.path}/missing.pgn',
        onError: errors.add,
      );

      expect(loaded, isNull);
      expect(errors.single, contains('couldn\'t find'));
      expect(errors.single, contains('missing.pgn'));
    });
  });
}
