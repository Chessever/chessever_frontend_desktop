import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

int _desktopAverageRating(GamesTourModel game) {
  final white = game.whitePlayer.rating;
  final black = game.blackPlayer.rating;
  if (white <= 0 || black <= 0) return 0;
  return (white + black) ~/ 2;
}

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
      final model = GamesTourModel.fromGame(
        _buildGame(
          id: 'g1',
          whiteRating: 2520,
          blackRating: 2510,
          pgn: '[Event "Live"]\n\n1. e4 e5',
        ),
      );

      expect(_desktopAverageRating(model), 2515);
      expect(_desktopAverageRating(model) >= 2500, isTrue);
    });

    test('requires both player ratings for GM qualification', () {
      final model = GamesTourModel.fromGame(
        _buildGame(
          id: 'g2',
          whiteRating: 2600,
          blackRating: 0,
          pgn: '[WhiteElo "2600"]\n\n1. d4 d5',
        ),
      );

      expect(_desktopAverageRating(model), 0);
      expect(_desktopAverageRating(model) >= 2500, isFalse);
    });
  });
}
