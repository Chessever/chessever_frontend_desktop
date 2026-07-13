import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/player_score_card_board_context.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/widgets/player_score_card_view.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';

void main() {
  group('selectPlayerScoreCardBoardRailGames', () {
    test(
      'prefers displayed player-scoped games over broader resolved source',
      () {
        final selected = selectPlayerScoreCardBoardRailGames<String>(
          displayedGames: const ['player-round-1', 'player-round-2'],
          resolvedGames: const ['board-1', 'board-2', 'board-3'],
        );

        expect(selected, const ['player-round-1', 'player-round-2']);
      },
    );

    test('falls back to resolved games while displayed list is empty', () {
      final selected = selectPlayerScoreCardBoardRailGames<String>(
        displayedGames: const [],
        resolvedGames: const ['loaded-game'],
      );

      expect(selected, const ['loaded-game']);
    });

    test('caps the board rail around the selected displayed game', () {
      final games = [for (var i = 0; i < 100; i++) 'game-$i'];

      final selected = selectPlayerScoreCardBoardRailGames<String>(
        displayedGames: games,
        resolvedGames: const [],
        selectedGame: 'game-50',
        isSameGame: (game, selectedGame) => game == selectedGame,
      );

      expect(selected.length, 61);
      expect(selected.first, 'game-20');
      expect(selected.last, 'game-80');
    });
  });

  test('Favorites score cards override a stale broadcast board source', () {
    const favoritesContext = PlayerScoreCardTabContext(
      hasEventContext: false,
      profileDataSource: PlayerProfileDataSource.supabase,
    );

    expect(
      playerScoreCardBoardViewSource(
        tabContext: favoritesContext,
        hasSelectedBroadcast: true,
      ),
      ChessboardView.favScorecard,
    );
    expect(
      playerScoreCardBoardViewSource(
        tabContext: favoritesContext,
        hasSelectedBroadcast: false,
      ),
      ChessboardView.favScorecard,
    );
  });

  test('event score cards retain their event board source', () {
    const eventContext = PlayerScoreCardTabContext(
      hasEventContext: true,
      profileDataSource: PlayerProfileDataSource.supabase,
    );

    expect(
      playerScoreCardBoardViewSource(
        tabContext: eventContext,
        hasSelectedBroadcast: false,
      ),
      ChessboardView.tour,
    );
  });
}
