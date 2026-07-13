import 'package:chessever/desktop/widgets/player_profile_view.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TWIC player profile game-result chips filter loaded rows locally', () {
    const key = PlayerProfileKey(
      fideId: 1503014,
      playerName: 'Carlsen, Magnus',
      source: PlayerProfileDataSource.twic,
      gamebasePlayerId: 'player-1',
    );

    final state = PlayerProfileGamesState(
      playerKey: key,
      allGames: [
        _game('white-win', GameStatus.whiteWins),
        _game('draw', GameStatus.draw),
        _game('black-win', GameStatus.blackWins),
      ],
      filter: GameFilter(result: GameResultFilter.draw),
    );

    expect(state.filteredGames.map((g) => g.gameId), ['draw']);
  });

  test('game-result filter accepts all draw result formats', () {
    expect(GameStatus.fromString('1/2-1/2'), GameStatus.draw);
    expect(GameStatus.fromString('½-½'), GameStatus.draw);
    expect(GameStatus.fromString('0.5-0.5'), GameStatus.draw);
    expect(
      GameResultFilter.draw.matches(GameStatus.fromString('1/2-1/2')),
      true,
    );
  });

  testWidgets('desktop result summary keeps W/D/L in one horizontal row', (
    tester,
  ) async {
    PlayerResultFilter? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: DesktopPlayerProfileResultSummary(
                stats: const ResultStatistics(
                  totalGames: 12,
                  wins: 7,
                  draws: 3,
                  losses: 2,
                ),
                selected: PlayerResultFilter.all,
                onSelect: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Step into the game history'), findsNothing);
    expect(find.text('Open game history'), findsNothing);
    expect(find.text('Drew'), findsNothing);
    expect(find.text('Won'), findsOneWidget);
    expect(find.text('Draw'), findsOneWidget);
    expect(find.text('Lost'), findsOneWidget);

    final won = tester.getTopLeft(find.text('Won'));
    final draw = tester.getTopLeft(find.text('Draw'));
    final lost = tester.getTopLeft(find.text('Lost'));
    expect(won.dy, draw.dy);
    expect(draw.dy, lost.dy);
    expect(won.dx, lessThan(draw.dx));
    expect(draw.dx, lessThan(lost.dx));

    await tester.tap(find.text('Draw'));
    expect(selected, PlayerResultFilter.draw);
  });
}

GamesTourModel _game(String id, GameStatus status) {
  return GamesTourModel(
    gameId: id,
    source: GameSource.twic,
    whitePlayer: _player('White'),
    blackPlayer: _player('Black'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'event-1',
    lastMoveTime: DateTime.utc(2026),
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: 2700,
    countryCode: '',
    team: null,
  );
}
