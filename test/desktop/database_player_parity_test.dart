import 'dart:io';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/desktop/widgets/library/local_game_player_cell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  Future<void> verify(
    WidgetTester tester,
    Map<String, dynamic> md, {
    LocalChessGame? entry,
  }) async {
    final white = md['White'] as String;
    final black = md['Black'] as String;
    final expectedWhite = white == '?' ? 'White ?' : white;
    final expectedBlack = black == '?' ? 'Black ?' : black;
    final row = TournamentGameSummary(
      id: entry?.id ?? 'normal',
      name: '$white vs $black',
      whitePlayer: white,
      blackPlayer: black,
      pgn: entry?.rawPgn ?? '[White "$white"]\n[Black "$black"]\n\n*',
      hasPgn: true,
      openingName: md['ECO']?.toString(),
      localPgnSource:
          entry == null
              ? null
              : TournamentGameLocalPgnSource(
                sourcePath: entry.sourcePath,
                sourceIndex: entry.indexInFile,
                sourceFileGameCount: entry.fileGameCount,
                pgnFingerprint: localChessPgnFingerprint(entry.rawPgn),
                title: entry.title,
              ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => {
              'tournaments-default': BoardTabGameArgs(
                pgn: row.pgn!,
                label: row.name,
                whiteName: white,
                blackName: black,
                databaseTitle: 'Study database',
                databaseGames: [row],
                gameListSelectedId: row.id,
              ),
            },
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      Expanded(
                        child: LocalGamePlayerCell(
                          metadata: md,
                          side: 'White',
                          unknownSideLabel: true,
                        ),
                      ),
                      Expanded(
                        child: LocalGamePlayerCell(
                          metadata: md,
                          side: 'Black',
                          unknownSideLabel: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const Expanded(
                  child: SizedBox(
                    width: 373,
                    child: EventGamesTable(tabId: 'tournaments-default'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(expectedWhite), findsNWidgets(2));
    expect(find.text(expectedBlack), findsNWidgets(2));
    expect(find.text('Bd2, N.'), findsNothing);
    expect(find.textContaining('· Game #'), findsNothing);
    expect(tester.takeException(), isNull);
    if (entry != null) {
      final hydrated = await tester.runAsync(
        () => hydrateRetainedLocalPgn(row),
      );
      expect(hydrated!.id, entry.id);
      expect(hydrated.localPgnSource!.sourceIndex, entry.indexInFile);
      expect(hydrated.localPgnSource!.sourceFileGameCount, 1436);
      expect(hydrated.whitePlayer, white);
      expect(hydrated.blackPlayer, black);
      expect(hydrated.pgn!.trim(), entry.rawPgn.trim());
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }

  for (final names in [
    ['French, D', 'Nc3 Bb4 Bd2'],
    ['?', '?'],
    ['Carlsen, Magnus', 'Hikaru Nakamura'],
    ['Gukesh D', 'Ding Liren'],
    ['KID', 'Main line'],
    ['1.d4 c5', 'Zhou, Francis'],
  ]) {
    testWidgets('same unmodified PGN player labels $names', (tester) async {
      await verify(tester, {'White': names[0], 'Black': names[1]});
    });
  }

  final path = Platform.environment['CBH_ACCEPTANCE_PGN'];
  testWidgets(
    'exact Son physical records 1424-1426 retain player parity and identity',
    (tester) async {
      late List<LocalChessGame> entries;
      await tester.runAsync(() async {
        final scan = await scanLocalChessPgnCatalog(path!);
        entries = scan.root.files.single.games;
        expect(entries.length, 1436);
      });
      for (final index in [1423, 1424, 1425]) {
        final entry = entries[index];
        expect(entry.indexInFile, index);
        expect(entry.game.metadata['White'], index == 1423 ? 'French, D' : '?');
        expect(
          entry.game.metadata['Black'],
          index == 1423 ? 'Nc3 Bb4 Bd2' : '?',
        );
        expect(
          entry.game.metadata['ECO'],
          {1423: 'C17', 1424: 'A18', 1425: 'A68'}[index],
        );
        await verify(tester, entry.game.metadata, entry: entry);
      }
    },
    skip: path == null,
  );
}
