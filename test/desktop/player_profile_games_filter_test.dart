import 'package:chessever/desktop/widgets/player_profile_view.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('memorial profiles omit Events but keep Overview and Games', () {
    expect(
      playerProfileSectionsFor(isMemorial: true),
      const <PlayerProfileSection>[
        PlayerProfileSection.about,
        PlayerProfileSection.games,
      ],
    );
  });

  test('regular profiles retain all existing tabs', () {
    expect(
      playerProfileSectionsFor(isMemorial: false),
      PlayerProfileSection.values,
    );
  });

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

  test('Games tab count prefers authoritative TWIC total', () {
    const key = PlayerProfileKey(
      fideId: 1503014,
      playerName: 'Carlsen, Magnus',
      source: PlayerProfileDataSource.twic,
      gamebasePlayerId: 'player-1',
    );

    final state = PlayerProfileGamesState(
      playerKey: key,
      allGames: [_game('loaded-row', GameStatus.draw)],
      totalCount: 842,
      filter: GameFilter(result: GameResultFilter.draw),
    );

    expect(playerProfileGameCountForTab(state, authoritativeTotal: 4217), 4217);
    expect(playerProfileGameCountForTab(state), 842);
  });

  test('Games tab count reflects local filtered rows', () {
    const key = PlayerProfileKey(
      fideId: 1503014,
      playerName: 'Carlsen, Magnus',
      source: PlayerProfileDataSource.supabase,
    );

    final state = PlayerProfileGamesState(
      playerKey: key,
      allGames: [
        _game('white-win', GameStatus.whiteWins),
        _game('draw', GameStatus.draw),
      ],
      filter: GameFilter(result: GameResultFilter.draw),
    );

    expect(playerProfileGameCountForTab(state), 1);
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

  test('player overview excludes unknown openings', () {
    const known = OpeningStatistic(
      eco: 'B12',
      openingName: 'Caro-Kann',
      count: 12,
      wins: 6,
      draws: 3,
      losses: 3,
    );
    const unknownEco = OpeningStatistic(
      eco: 'Unknown',
      openingName: '—',
      count: 8,
      wins: 4,
      draws: 2,
      losses: 2,
    );
    const unknownName = OpeningStatistic(
      eco: 'A00',
      openingName: null,
      count: 5,
      wins: 2,
      draws: 2,
      losses: 1,
    );

    expect(shouldShowPlayerProfileOpening(known), isTrue);
    expect(shouldShowPlayerProfileOpening(unknownEco), isFalse);
    expect(shouldShowPlayerProfileOpening(unknownName), isFalse);
  });

  test('player overview separates best and lowest-scoring opening results', () {
    final groups = playerProfileOpeningResultGroups([
      _opening('A10', 'English', wins: 8, draws: 1, losses: 1),
      _opening('B12', 'Caro-Kann', wins: 6, draws: 2, losses: 2),
      _opening('C50', 'Italian', wins: 5, draws: 1, losses: 4),
      _opening('D30', 'QGD', wins: 3, draws: 2, losses: 5),
      _opening('E60', 'King\'s Indian', wins: 1, draws: 2, losses: 7),
      _opening('Unknown', 'Unknown', wins: 10, draws: 0, losses: 0),
    ], limit: 2);

    expect(groups.best.map((opening) => opening.eco), ['A10', 'B12']);
    expect(groups.worst.map((opening) => opening.eco), ['E60', 'D30']);
    expect(groups.best.toSet().intersection(groups.worst.toSet()), isEmpty);
  });

  test('rating hover resolves the closest monthly point', () {
    expect(closestRatingPointIndex(-10, 4, 104, 5), 0);
    expect(closestRatingPointIndex(54, 4, 104, 5), 2);
    expect(closestRatingPointIndex(200, 4, 104, 5), 4);
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
    expect(won.dy, closeTo(draw.dy, 1));
    expect(draw.dy, closeTo(lost.dy, 1));
    expect(won.dx, lessThan(draw.dx));
    expect(draw.dx, lessThan(lost.dx));

    await tester.tap(find.text('Draw'));
    expect(selected, PlayerResultFilter.draw);
    await tester.pump(const Duration(milliseconds: 400));
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
    lastMove: 'e4',
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

OpeningStatistic _opening(
  String eco,
  String name, {
  required int wins,
  required int draws,
  required int losses,
}) {
  return OpeningStatistic(
    eco: eco,
    openingName: name,
    count: wins + draws + losses,
    wins: wins,
    draws: draws,
    losses: losses,
  );
}
