import 'package:chessever/desktop/widgets/desktop_team_match_grouping.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

PlayerCard _player(String name, String team) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: team,
  );
}

GamesTourModel _game({
  required String id,
  required String whiteTeam,
  required String blackTeam,
  required GameStatus status,
  int board = 1,
}) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: _player('White $id', whiteTeam),
    blackPlayer: _player('Black $id', blackTeam),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'tour-1',
    boardNr: board,
  );
}

void main() {
  test('groups reversed-color boards into the same team match', () {
    final groups = buildDesktopTeamMatchGroups([
      _game(
        id: 'board-1',
        whiteTeam: 'Team A',
        blackTeam: 'Team B',
        status: GameStatus.whiteWins,
        board: 1,
      ),
      _game(
        id: 'board-2',
        whiteTeam: 'Team B',
        blackTeam: 'Team A',
        status: GameStatus.whiteWins,
        board: 2,
      ),
      _game(
        id: 'board-3',
        whiteTeam: 'Team A',
        blackTeam: 'Team B',
        status: GameStatus.draw,
        board: 3,
      ),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.leftTeam, 'Team A');
    expect(groups.single.rightTeam, 'Team B');
    expect(groups.single.games.map((game) => game.game.gameId), [
      'board-1',
      'board-2',
      'board-3',
    ]);
    expect(groups.single.score.left, 1.5);
    expect(groups.single.score.right, 1.5);
  });

  test('does not split team names that contain vs', () {
    final groups = buildDesktopTeamMatchGroups([
      _game(
        id: 'board-1',
        whiteTeam: 'Team vs Shadows',
        blackTeam: 'Rivals Club',
        status: GameStatus.blackWins,
      ),
      _game(
        id: 'board-2',
        whiteTeam: 'Rivals Club',
        blackTeam: 'Team vs Shadows',
        status: GameStatus.blackWins,
      ),
      _game(
        id: 'other',
        whiteTeam: 'Knights',
        blackTeam: 'Bishops',
        status: GameStatus.ongoing,
      ),
    ]);

    expect(groups, hasLength(2));
    expect(groups.first.leftTeam, 'Team vs Shadows');
    expect(groups.first.rightTeam, 'Rivals Club');
    expect(groups.first.games.map((game) => game.game.gameId), [
      'board-1',
      'board-2',
    ]);
    expect(groups.first.score.left, 1.0);
    expect(groups.first.score.right, 1.0);
    expect(groups.last.leftTeam, 'Knights');
    expect(groups.last.rightTeam, 'Bishops');
  });
}
