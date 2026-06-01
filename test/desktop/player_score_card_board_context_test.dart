import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/player_score_card_board_context.dart';

void main() {
  group('selectPlayerScoreCardBoardRailGames', () {
    test('prefers displayed player-scoped games over broader resolved source', () {
      final selected = selectPlayerScoreCardBoardRailGames<String>(
        displayedGames: const ['player-round-1', 'player-round-2'],
        resolvedGames: const ['board-1', 'board-2', 'board-3'],
      );

      expect(selected, const ['player-round-1', 'player-round-2']);
    });

    test('falls back to resolved games while displayed list is empty', () {
      final selected = selectPlayerScoreCardBoardRailGames<String>(
        displayedGames: const [],
        resolvedGames: const ['loaded-game'],
      );

      expect(selected, const ['loaded-game']);
    });
  });
}
