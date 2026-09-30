import 'dart:io';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/database_game_label.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('unknown sides are explicit without replacing player data', () {
    for (final value in ['', '?', '???', 'Unknown', 'White', 'Black']) {
      expect(databaseGamePlayerLabel(value, 'White'), 'White ?');
      expect(databaseGamePlayerLabel(value, 'Black'), 'Black ?');
      expect(databaseGamePlayerLabel(value, 'White', showUnknown: false), '');
    }
    expect(databaseGamePlayerLabel('French, D', 'White'), 'French, D');
    expect(databaseGamePlayerLabel('Nc3 Bb4 Bd2', 'Black'), 'Nc3 Bb4 Bd2');
  });

  // Opt-in real converted data: no private database content in the repository.
  final path = Platform.environment['CBH_ACCEPTANCE_PGN'];
  final indices =
      (Platform.environment['CBH_BLANK_INDICES'] ?? '')
          .split(',')
          .map(int.tryParse)
          .whereType<int>()
          .toList();
  final count = int.tryParse(
    Platform.environment['CBH_ACCEPTANCE_RECORDS'] ?? '',
  );
  testWidgets(
    'actual catalog blank records remain visible and open by physical index',
    (tester) async {
      late List<LocalChessGame> entries;
      await tester.runAsync(() async {
        final result = await scanLocalChessPgnCatalog(path!);
        final file = result.root.files.single;
        expect(file.gameCount, count);
        expect(file.pgnOffsetIndex!.totalGames, count);
        entries = file.games;
        expect(entries.length, count);
        expect(
          entries.map((e) => e.indexInFile),
          List.generate(count!, (i) => i),
        );
      });
      TournamentGameSummary fromEntry(LocalChessGame entry) {
        final md = entry.game.metadata;
        return TournamentGameSummary(
          id: entry.id,
          name: entry.title,
          whitePlayer: md['White']?.toString() ?? '',
          blackPlayer: md['Black']?.toString() ?? '',
          hasPgn: true,
          pgn: entry.rawPgn,
          hasStarted: entry.hasMoves,
          openingName: (md['Opening'] ?? md['ECO'])?.toString(),
          localPgnSource: TournamentGameLocalPgnSource(
            sourcePath: entry.sourcePath,
            sourceIndex: entry.indexInFile,
            sourceFileGameCount: entry.fileGameCount,
            pgnFingerprint: localChessPgnFingerprint(entry.rawPgn),
            title: entry.title,
          ),
        );
      }

      final guiding =
          entries
              .where(
                (e) => e.game.metadata['ChessBaseRecordType'] == 'GuidingText',
              )
              .toList();
      expect(guiding, hasLength(5));
      for (final entry in guiding) {
        expect(entry.hasMoves, isFalse);
        expect(
          databaseGamePlayerLabel(fromEntry(entry).whitePlayer, 'White'),
          'White ?',
        );
      }
      // Include the original named neighbours, not just idealized empty rows.
      final rows =
          entries
              .sublist(indices.first - 1, indices.last + 2)
              .map(fromEntry)
              .toList();
      final displayed = [...rows, ...guiding.map(fromEntry)];
      Future<TournamentGameSummary?>? hydration;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => {
                'tournaments-default': BoardTabGameArgs(
                  pgn: rows.first.pgn!,
                  label: rows.first.name,
                  whiteName: rows.first.whitePlayer,
                  blackName: rows.first.blackPlayer,
                  databaseTitle: 'Converted database',
                  databaseGames: displayed,
                  gameListSelectedId: rows.first.id,
                ),
              },
            ),
            // The real physical reader runs, but recovery is disallowed: tests must
            // not write the user's cache if a source identity fails verification.
            retainedLocalPgnHydratorProvider.overrideWithValue((row) async {
              hydration = tester.runAsync(() => hydrateRetainedLocalPgn(row));
              return (await hydration)!;
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 373,
                child: EventGamesTable(tabId: 'tournaments-default'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      for (final index in [...indices, ...guiding.map((e) => e.indexInFile)]) {
        final target = fromEntry(entries[index]);
        final playerCell = find.byKey(
          ValueKey('database-player-white-${target.id}'),
        );
        expect(playerCell, findsOneWidget);
        expect(
          find.descendant(of: playerCell, matching: find.text('White ?')),
          findsOneWidget,
        );
        await tester.tap(playerCell);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(hydration, isNotNull);
        await hydration;
        await tester.pump();
        final opened =
            container.read(boardTabGameArgsByTabIdProvider).values.single;
        expect(opened.gameListSelectedId, target.id);
        expect(opened.librarySaveOrigin?.sourceIndex, index);
        expect(opened.librarySaveOrigin?.sourceFileGameCount, count);
        expect(opened.whiteName, target.whitePlayer);
        expect(opened.blackName, target.blackPlayer);
        expect(opened.pgn.trim(), target.pgn!.trim());
        expect(
          opened.databaseGames.map((e) => e.id),
          displayed.map((e) => e.id),
        );
        expect(tester.takeException(), isNull);
      }
    },
    skip: path == null || indices.isEmpty || count == null,
  );
}
