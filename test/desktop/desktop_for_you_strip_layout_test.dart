import 'dart:io';

import 'package:chessever/desktop/widgets/desktop_for_you_game_context.dart';
import 'package:chessever/desktop/widgets/desktop_for_you_strip_layout.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop For You does not hydrate full tours per event', () {
    final source =
        File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

    expect(source, isNot(contains('_forYouFullEventGamesProvider')));
    expect(source, isNot(contains('ref.watch(gamesTourProvider(tourId))')));
  });

  group('DesktopForYouStripLayout', () {
    test('keeps four boards on ordinary wide rows', () {
      const availableForFour =
          DesktopForYouStripLayout.minCardWidth * 4 +
          DesktopForYouStripLayout.gap * 3;

      final layout = DesktopForYouStripLayout.compute(
        available: availableForFour,
        gameCount: 5,
      );

      expect(layout.visibleCount, 4);
      expect(layout.cardWidth, DesktopForYouStripLayout.minCardWidth);
    });

    test('allows a fifth board when the row is wide enough', () {
      const availableForFive =
          DesktopForYouStripLayout.minCardWidth * 5 +
          DesktopForYouStripLayout.gap * 4;

      final layout = DesktopForYouStripLayout.compute(
        available: availableForFive,
        gameCount: 5,
      );

      expect(layout.visibleCount, 5);
      expect(layout.cardWidth, DesktopForYouStripLayout.minCardWidth);
    });

    test('caps board width instead of stretching across ultra-wide rows', () {
      final layout = DesktopForYouStripLayout.compute(
        available: 1800,
        gameCount: 5,
      );

      expect(layout.visibleCount, 5);
      expect(layout.cardWidth, DesktopForYouStripLayout.maxCardWidth);
    });
  });

  test(
    'For You preview stays on the latest round while board context keeps every round',
    () {
      final round1 = _game('game-1', round: 1);
      final round9 = _game('game-9', round: 9);
      final upcomingRound10 = _game(
        'game-10',
        round: 10,
        status: GameStatus.unknown,
      );

      final context = buildDesktopForYouGameContext(
        snapshotGames: [round9],
        fullVisibleGames: [round1, round9],
        fullEventGames: [round1, round9, upcomingRound10],
      );

      expect(context.stripGames.map((game) => game.roundId), ['round-9']);
      expect(context.boardGames.map((game) => game.roundId), [
        'round-1',
        'round-9',
        'round-10',
      ]);
    },
  );
}

GamesTourModel _game(
  String gameId, {
  required int round,
  GameStatus status = GameStatus.whiteWins,
}) {
  return GamesTourModel(
    gameId: gameId,
    whitePlayer: _player('White $round'),
    blackPlayer: _player('Black $round'),
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-$round',
    roundSlug: 'round-$round',
    tourId: 'tour-1',
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: 0,
    countryCode: '',
    team: null,
  );
}
