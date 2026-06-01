import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  group('local library game updater', () {
    test('finds multi-game PGN ranges by first header after movetext', () {
      const pgn =
          '[Event "One"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *\n\n[Event "Two"]\n[White "C"]\n[Black "D"]\n\n1. d4 d5 *\n';

      final ranges = pgnGameRanges(pgn);

      expect(ranges, hasLength(2));
      expect(
        pgn.substring(ranges.first.start, ranges.first.end),
        contains('[Event "One"]'),
      );
      expect(
        pgn.substring(ranges.last.start, ranges.last.end),
        contains('[Event "Two"]'),
      );
    });

    test('updates only the selected PGN game in place', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-local-update-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/database.pgn');
      await file.writeAsString(
        '[Event "One"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *\n\n'
        '[Event "Two"]\n[White "C"]\n[Black "D"]\n\n1. d4 d5 *\n',
      );
      final replacement = ChessGame.fromPgn(
        'replacement',
        '[Event "Two"]\n[White "C"]\n[Black "D"]\n\n1. Nf3 Nf6 *',
      );

      await updateLocalLibraryPgnGame(
        target: LocalLibraryGameUpdateTarget(
          sourcePath: file.path,
          indexInFile: 1,
          fileGameCount: 2,
        ),
        game: replacement,
      );

      final updated = await file.readAsString();
      expect(updated, contains('[Event "One"]'));
      expect(updated, contains('1. e4 e5'));
      expect(updated, contains('[Event "Two"]'));
      expect(updated, contains('1. Nf3 Nf6'));
      expect(updated, isNot(contains('1. d4 d5')));
    });

    test(
      'rejects in-place updates when the source PGN game count changed',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-update-stale-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/database.pgn');
        const currentPgn =
            '[Event "One"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *\n\n'
            '[Event "Two"]\n[White "C"]\n[Black "D"]\n\n1. d4 d5 *\n\n'
            '[Event "Three"]\n[White "E"]\n[Black "F"]\n\n1. c4 c5 *\n';
        await file.writeAsString(currentPgn);
        final replacement = ChessGame.fromPgn(
          'replacement',
          '[Event "Two"]\n[White "C"]\n[Black "D"]\n\n1. Nf3 Nf6 *',
        );

        expect(
          () => updateLocalLibraryPgnGame(
            target: LocalLibraryGameUpdateTarget(
              sourcePath: file.path,
              indexInFile: 1,
              fileGameCount: 2,
            ),
            game: replacement,
          ),
          throwsA(isA<StateError>()),
        );
        expect(await file.readAsString(), currentPgn);
      },
    );
  });
}
