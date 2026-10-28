import 'dart:io';

import 'package:chessever/desktop/services/player_stats_repository.dart';
import 'package:chessever/desktop/services/player_pgn_catalog.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'six-game player source includes ID-less surname-first rows in stats',
    () async {
      final dir = await Directory.systemTemp.createTemp('player-six-stats-');
      addTearDown(() async {
        await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/source.pgn');
      await file.writeAsString(_sixGames());
      final stats = await PlayerStatsRepository().computePlayerStats(
        databasePath: file.path,
        aliases: const ['Elise Moreau'],
        playerFideId: '99999901',
      );
      expect(stats.games, 6);
      expect(stats.overall.wins, 1);
      expect(stats.overall.draws, 3);
      expect(stats.overall.losses, 2);
      expect(stats.asWhite.games, 5);
      expect(stats.asBlack.games, 1);
    },
  );

  test(
    'player tree identity includes every row from the six-game source',
    () async {
      final dir = await Directory.systemTemp.createTemp('player-six-tree-');
      addTearDown(() async {
        await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/source.pgn');
      await file.writeAsString(_sixGames());
      final source = await PlayerPgnCatalog.instance.load(file.path);
      const criteria = PlayerOpeningTreeFilterCriteria(
        playerFideIds: ['99999901'],
        playerNames: ['Elise Moreau'],
      );
      final matched = source.games.where((g) {
        final m = g.game.metadata;
        return criteria.matches({
          'white': m['White'],
          'black': m['Black'],
          'whiteFideId': m['WhiteFideId'],
          'blackFideId': m['BlackFideId'],
        });
      });
      expect(matched, hasLength(6));
    },
  );

  test(
    'Games result filters recognize wins and draws without FIDE tags',
    () async {
      final dir = await Directory.systemTemp.createTemp('player-six-games-');
      addTearDown(() async {
        await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/source.pgn');
      await file.writeAsString(_sixGames());
      final source = await PlayerPgnCatalog.instance.load(file.path);
      for (final entry
          in {
            LocalPlayerOutcomeFilter.win: 1,
            LocalPlayerOutcomeFilter.draw: 3,
            LocalPlayerOutcomeFilter.loss: 2,
          }.entries) {
        final filter = LocalChessGameFilter(playerOutcome: entry.key);
        expect(
          source.games.where(
            (g) => localChessGameMatchesFilter(
              g,
              filter,
              playerFideId: '99999901',
              playerAliases: const ['Elise Moreau'],
            ),
          ),
          hasLength(entry.value),
          reason: entry.key.name,
        );
      }
    },
  );
}

String _sixGames() {
  return [
    for (var i = 0; i < 6; i++)
      '''
[Event "Player source regression"]
[Date "2026.08.${(i + 1).toString().padLeft(2, '0')}"]
[White "${i == 3
          ? 'Other Player'
          : i < 2
          ? 'Moreau,Elise'
          : 'Moreau, Elise'}"]
[Black "${i == 3 ? 'Moreau, Elise' : 'Other Player'}"]
${i < 2 ? '[WhiteFideId "99999901"]' : ''}
[Result "${i < 2 || i == 3 ? '0-1' : '1/2-1/2'}"]
[TimeControl "5400+30"]

1. d4 d5 ${i < 2 || i == 3 ? '0-1' : '1/2-1/2'}
''',
  ].join('\n');
}
