import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/broadcast_custom_scoring.dart';

void main() {
  group('standard broadcast game result labels', () {
    test('labels a win for the winning side', () {
      expect(
        standardResultLabelForSide(GameStatus.whiteWins, isWhite: true),
        '1',
      );
      expect(
        standardResultLabelForSide(GameStatus.whiteWins, isWhite: false),
        '0',
      );
    });

    test('labels a draw for both sides', () {
      expect(standardResultLabelForSide(GameStatus.draw, isWhite: true), '½');
      expect(standardResultLabelForSide(GameStatus.draw, isWhite: false), '½');
    });

    test('has no label while a game is unresolved', () {
      expect(
        standardResultLabelForSide(GameStatus.ongoing, isWhite: true),
        isNull,
      );
      expect(
        standardResultLabelForSide(GameStatus.unknown, isWhite: true),
        isNull,
      );
    });
  });

  group('broadcast standings score resolution', () {
    test('preserves custom source score and updates played count', () {
      final resolved = resolveBroadcastStandingScore(
        sourceScore: 3.0,
        sourcePlayed: 1,
        calculatedScore: 1.0,
        calculatedPlayed: 1,
      );

      expect(resolved.score, 3.0);
      expect(resolved.played, 1);
    });

    test('falls back to calculated score when no source score exists', () {
      final resolved = resolveBroadcastStandingScore(
        sourceScore: null,
        sourcePlayed: 0,
        calculatedScore: 1.5,
        calculatedPlayed: 2,
      );

      expect(resolved.score, 1.5);
      expect(resolved.played, 2);
    });
  });

  test('parses per-player customPoints from game players JSON', () {
    final player = Player.fromJson(const {
      'name': 'Alireza Firouzja',
      'rating': 2759,
      'customPoints': 3.0,
    });

    final card = PlayerCard.fromPlayer(player);

    expect(player.customPoints, 3.0);
    expect(card.customPoints, 3.0);
  });
}
