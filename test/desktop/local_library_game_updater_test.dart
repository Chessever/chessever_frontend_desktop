import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
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
      'successful update returns an identity that supports another update',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-repeat-update-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/database.pgn');
        const original =
            '[Event "Preparation"]\n[White "Original"]\n[Black "Opponent"]\n\n1. e4 e5 *';
        await file.writeAsString('$original\n');

        final firstUpdate = ChessGame.fromPgn(
          'first-update',
          '[Event "Preparation"]\n[White "First name"]\n[Black "Opponent"]\n\n1. e4 e5 2. Nf3 *',
        );
        final firstOutcome = await updateLocalLibraryPgnGame(
          target: LocalLibraryGameUpdateTarget(
            sourcePath: file.path,
            indexInFile: 0,
            fileGameCount: 1,
            pgnFingerprint: localChessPgnFingerprint(original),
          ),
          game: firstUpdate,
        );
        final afterFirstUpdate = await file.readAsString();
        final firstRange = pgnGameRanges(afterFirstUpdate).single;
        final firstSavedPgn =
            afterFirstUpdate.substring(firstRange.start, firstRange.end).trim();
        expect(
          firstOutcome.updateTarget.pgnFingerprint,
          localChessPgnFingerprint(firstSavedPgn),
        );

        final renamedAgain = ChessGame.fromPgn(
          'second-update',
          '[Event "Preparation"]\n[White "Final name"]\n[Black "Opponent"]\n\n1. e4 e5 2. Nf3 *',
        );
        await updateLocalLibraryPgnGame(
          target: firstOutcome.updateTarget,
          game: renamedAgain,
        );

        final finalText = await file.readAsString();
        expect(finalText, contains('[White "Final name"]'));
        expect(finalText, isNot(contains('[White "First name"]')));
      },
    );

    test('cache-backed update returns the fingerprint it wrote', () async {
      final repository = _SuccessfulCachedUpdateRepository();
      final game = ChessGame.fromPgn(
        'cached-update',
        '[Event "Preparation"]\n[White "Renamed"]\n[Black "Opponent"]\n\n1. e4 e5 *',
      );

      final outcome = await updateLocalLibraryPgnGame(
        target: const LocalLibraryGameUpdateTarget(
          sourcePath: r'C:\Games\cached.pgn',
          indexInFile: 2,
          fileGameCount: 4,
          pgnFingerprint: 'before-update',
        ),
        game: game,
        repository: repository,
      );

      expect(repository.writtenPgn, isNotEmpty);
      expect(
        outcome.updateTarget.pgnFingerprint,
        localChessPgnFingerprint(repository.writtenPgn!),
      );
      expect(outcome.updateTarget.indexInFile, 2);
      expect(outcome.updateTarget.fileGameCount, 4);
    });

    test('refreshed identity still rejects a later external edit', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-local-repeat-update-conflict-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/database.pgn');
      const original =
          '[Event "Preparation"]\n[White "Original"]\n[Black "Opponent"]\n\n1. e4 e5 *';
      await file.writeAsString('$original\n');

      final firstOutcome = await updateLocalLibraryPgnGame(
        target: LocalLibraryGameUpdateTarget(
          sourcePath: file.path,
          indexInFile: 0,
          fileGameCount: 1,
          pgnFingerprint: localChessPgnFingerprint(original),
        ),
        game: ChessGame.fromPgn(
          'first-update',
          '[Event "Preparation"]\n[White "First name"]\n[Black "Opponent"]\n\n1. e4 e5 *',
        ),
      );
      const externalEdit =
          '[Event "Externally changed"]\n[White "Other editor"]\n[Black "Opponent"]\n\n1. d4 d5 *\n';
      await file.writeAsString(externalEdit);

      expect(
        () => updateLocalLibraryPgnGame(
          target: firstOutcome.updateTarget,
          game: ChessGame.fromPgn(
            'second-update',
            '[Event "Preparation"]\n[White "Final name"]\n[Black "Opponent"]\n\n1. e4 e5 *',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await file.readAsString(), externalEdit);
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

    test(
      'rejects in-place updates when the indexed game fingerprint changed',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'chessever-local-update-reordered-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/database.pgn');
        const first = '[Event "One"]\n[White "A"]\n[Black "B"]\n\n1. e4 e5 *';
        const second = '[Event "Two"]\n[White "C"]\n[Black "D"]\n\n1. d4 d5 *';
        await file.writeAsString('$second\n\n$first\n');
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
              pgnFingerprint: localChessPgnFingerprint(second),
            ),
            game: replacement,
          ),
          throwsA(isA<StateError>()),
        );
        expect(await file.readAsString(), '$second\n\n$first\n');
      },
    );
  });
}

class _SuccessfulCachedUpdateRepository extends LocalChessDatabaseRepository {
  _SuccessfulCachedUpdateRepository()
    : super(database: () async => throw UnimplementedError());

  String? writtenPgn;

  @override
  Future<bool?> replaceLocalPgnGame({
    required String databasePath,
    required int indexInFile,
    required String rawPgn,
    int? expectedFileGameCount,
    String? expectedPgnFingerprint,
  }) async {
    writtenPgn = rawPgn;
    return true;
  }
}
