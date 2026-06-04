import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_library_writer.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  group('LocalLibraryWriter', () {
    test('appends games to an existing PGN file destination', () async {
      final temp = await Directory.systemTemp.createTemp('local-pgn-save-');
      addTearDown(() async => temp.delete(recursive: true));

      final file = File('${temp.path}/Aadvik prep.pgn');
      await file.writeAsString('[Event "Existing"]\n\n1. d4 d5 *\n');

      final game = ChessGame.fromPgn(
        'new-game',
        '[Event "Lesson"]\n[White "Student"]\n[Black "Coach"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
      );

      final outcome = await LocalLibraryWriter(
        folderPath: file.path,
      ).writeGames([game]);

      expect(outcome.hasError, isFalse);
      expect(outcome.written, 1);
      expect(outcome.writtenPaths.single, file.path);

      final saved = await file.readAsString();
      expect(saved, contains('[Event "Existing"]'));
      expect(saved, contains('[Event "Lesson"]'));
      expect(saved, contains('1. e4 e5 2. Nf3 Nc6 1-0'));
      expect(saved, isNot(contains('${file.path}/')));
    });

    test(
      'creates a PGN file destination when the parent folder exists',
      () async {
        final temp = await Directory.systemTemp.createTemp('local-pgn-create-');
        addTearDown(() async => temp.delete(recursive: true));

        final file = File('${temp.path}/new database.pgn');
        final game = ChessGame.fromPgn('game', '1. c4 e5 *');

        final outcome = await LocalLibraryWriter(
          folderPath: file.path,
        ).writeGames([game]);

        expect(outcome.hasError, isFalse);
        expect(outcome.written, 1);
        expect(await file.exists(), isTrue);
        expect(await file.readAsString(), contains('1. c4 e5 *'));
      },
    );

    test(
      'keeps legacy folder destinations writing individual PGN files',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'local-folder-save-',
        );
        addTearDown(() async => temp.delete(recursive: true));

        final game = ChessGame.fromPgn(
          'folder-game',
          '[White "Alpha"]\n[Black "Beta"]\n[Date "2026.06.03"]\n\n1. e4 e5 *',
        );

        final outcome = await LocalLibraryWriter(
          folderPath: temp.path,
        ).writeGames([game]);

        expect(outcome.hasError, isFalse);
        expect(outcome.written, 1);
        expect(outcome.writtenPaths.single, endsWith('.pgn'));
        expect(await File(outcome.writtenPaths.single).exists(), isTrue);
        expect(
          await File(outcome.writtenPaths.single).readAsString(),
          contains('1. e4 e5 *'),
        );
      },
    );
  });
}
