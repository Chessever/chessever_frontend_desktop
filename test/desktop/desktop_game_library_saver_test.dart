import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  group('mergeDesktopGameMetadataForLibrary', () {
    test(
      'does not overwrite PGN black player with placeholder TWIC row data',
      () {
        final metadata = <String, dynamic>{
          'White': 'Grining, Maria',
          'Black': 'Dietrich, Anja',
          'Date': '2026.06.04',
          'ECO': 'C54',
          'Result': '1-0',
        };
        final game = _desktopGame(
          whiteName: 'Grining, Maria',
          blackName: '?',
          result: GameStatus.whiteWins,
          gameDay: DateTime(2026, 6, 4),
        );

        final merged = mergeDesktopGameMetadataForLibrary(metadata, game);

        expect(merged['White'], 'Grining, Maria');
        expect(merged['Black'], 'Dietrich, Anja');
        expect(merged['Date'], '2026.06.04');
        expect(merged['ECO'], 'C54');
        expect(merged['Result'], '1-0');
      },
    );

    test('fills date and ECO from desktop row when copied PGN lacks tags', () {
      final metadata = <String, dynamic>{
        'White': 'GM Caruana, Fabiano',
        'Black': 'GM Sindarov, Javokhir',
        'Result': '1/2-1/2',
      };
      final game = _desktopGame(
        whiteName: 'GM Caruana, Fabiano',
        blackName: 'GM Sindarov, Javokhir',
        whiteRating: 2788,
        blackRating: 2776,
        result: GameStatus.draw,
        gameDay: DateTime(2026, 5, 14),
        eco: 'C54',
      );

      final merged = mergeDesktopGameMetadataForLibrary(metadata, game);

      expect(merged['Date'], '2026.05.14');
      expect(merged['ECO'], 'C54');
      expect(merged['WhiteElo'], '2788');
      expect(merged['BlackElo'], '2776');
    });
  });
}

GamesTourModel _desktopGame({
  required String whiteName,
  required String blackName,
  int whiteRating = 0,
  int blackRating = 0,
  GameStatus result = GameStatus.unknown,
  DateTime? gameDay,
  String? eco,
}) {
  return GamesTourModel(
    gameId: 'g1',
    source: GameSource.twic,
    whitePlayer: _player(whiteName, rating: whiteRating),
    blackPlayer: _player(blackName, rating: blackRating),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: result,
    roundId: 'round1',
    tourId: 'twic',
    gameDay: gameDay,
    eco: eco,
  );
}

PlayerCard _player(String name, {int rating = 0}) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: rating,
    countryCode: '',
    team: null,
  );
}
