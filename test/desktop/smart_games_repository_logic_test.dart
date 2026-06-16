import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Games _buildGame({
  required String id,
  required int whiteRating,
  required int blackRating,
  String? pgn,
}) {
  return Games(
    id: id,
    roundId: 'round1',
    roundSlug: 'round1',
    tourId: 'tour1',
    tourSlug: 'tour1',
    status: '*',
    players: [
      Player(
        name: 'White',
        fideId: 1,
        title: 'GM',
        fed: 'USA',
        rating: whiteRating,
        clock: 0,
        team: '',
      ),
      Player(
        name: 'Black',
        fideId: 2,
        title: 'GM',
        fed: 'IND',
        rating: blackRating,
        clock: 0,
        team: '',
      ),
    ],
    pgn: pgn,
  );
}

void main() {
  group('desktop smart games GM average rating', () {
    test('uses structured player ratings when PGN rating tags are missing', () {
      final game = _buildGame(
        id: 'g1',
        whiteRating: 2520,
        blackRating: 2510,
        pgn: '[Event "Live"]\n\n1. e4 e5',
      );

      expect(gameStructuredAverageRating(game), 2515);
      expect(gameStructuredAverageRating(game) >= 2500, isTrue);
    });

    test('requires both player ratings for GM qualification', () {
      final game = _buildGame(
        id: 'g2',
        whiteRating: 2600,
        blackRating: 0,
        pgn: '[WhiteElo "2600"]\n\n1. d4 d5',
      );

      expect(gameStructuredAverageRating(game), 0);
      expect(gameStructuredAverageRating(game) >= 2500, isFalse);
    });
  });
}
