import 'package:chessever/repository/supabase/tour/published_tiebreak.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:flutter_test/flutter_test.dart';

TeamStandingModel _team({
  String name = 'Team',
  num matchPoints = 7,
  double gamePoints = 12.5,
  List<PublishedTiebreak> tiebreaks = const [],
}) => TeamStandingModel(
  teamName: name,
  rank: 1,
  officialRound: 5,
  matchPoints: matchPoints,
  gamePoints: gamePoints,
  matchesWon: 3,
  matchesDrawn: 1,
  matchesLost: 1,
  boardsPlayed: 20,
  players: const [],
  tiebreaks: tiebreaks,
);

void main() {
  group('Chess-Results start number and club', () {
    test('TournamentPlayer reads tolerant startNumber and trimmed club', () {
      final player = TournamentPlayer.fromJson({
        'name': 'Carlsen, Magnus',
        'played': 5,
        'startNumber': '12',
        'club': '  SK Bergen  ',
      });
      expect(player.startNumber, 12);
      expect(player.club, 'SK Bergen');
      expect(
        TournamentPlayer.fromJson({
          'name': 'A',
          'startNumber': 3.0,
        }).startNumber,
        3,
      );
      final blank = TournamentPlayer.fromJson({'name': 'B', 'club': '  '});
      expect(blank.startNumber, isNull);
      expect(blank.club, isNull);

      final json = player.toJson();
      expect(json['startNumber'], 12);
      expect(json['club'], 'SK Bergen');
      expect(TournamentPlayer.fromJson(json), player);
      expect(player.copyWith(score: 1).startNumber, 12);
      expect(player.copyWith(score: 1).club, 'SK Bergen');
    });

    test('PlayerStandingModel carries both fields through every path', () {
      final model = PlayerStandingModel.fromPlayer(
        TournamentPlayer(
          name: 'Gukesh D',
          played: 0,
          startNumber: 4,
          club: 'Chennai',
        ),
      );
      expect(model.startNumber, 4);
      expect(model.club, 'Chennai');
      expect(model.copyWith(overallRank: 2).startNumber, 4);
      expect(model.copyWith(overallRank: 2).club, 'Chennai');

      final roundTrip = PlayerStandingModel.fromJson(model.toJson());
      expect(roundTrip, model);
      expect(
        PlayerStandingModel.fromJson({'name': 'X', 'startNumber': 7.0}),
        isA<PlayerStandingModel>().having((m) => m.startNumber, 'SNo', 7),
      );
      expect(model.copyWith(club: 'Other'), isNot(model));
    });
  });

  group('team tiebreaks that repeat MP and GP', () {
    const crMatchPoints = PublishedTiebreak(
      points: 7,
      description: 'Matchpoints (2 for wins, 1 for Draws, 0 for Losses)',
      extendedCode: 'TB1',
    );
    const crGamePoints = PublishedTiebreak(
      points: 12.5,
      description: 'points (game-points)',
      extendedCode: 'TB2',
    );
    const buchholzMp = PublishedTiebreak(
      points: 31,
      description: 'Buchholz Tie-Breaks (variable with parameter)',
      extendedCode: 'BH:MP',
    );

    test('drops Chess-Results TB1/TB2 and Info64 MP/GP, keeps derived', () {
      final team = _team(
        tiebreaks: const [
          crMatchPoints,
          crGamePoints,
          buchholzMp,
          PublishedTiebreak(points: 7, description: 'MP'),
          PublishedTiebreak(
            points: 12.5,
            description: 'Game points',
            extendedCode: 'GP',
          ),
          PublishedTiebreak(points: 40, description: 'EMMSB'),
          PublishedTiebreak(points: 1, description: 'Dir_MP'),
        ],
      );
      expect(team.extraTiebreaks.map((t) => t.label), [
        'BH:MP',
        'EMMSB',
        'Dir_MP',
      ]);
    });

    test('keeps a points column whose value differs from the row', () {
      final team = _team(
        matchPoints: 6,
        tiebreaks: const [
          PublishedTiebreak(
            points: 9,
            description: 'Matchpoints (3 for wins, 1 for Draws, 0 for Losses)',
            extendedCode: 'TB1',
          ),
          crGamePoints,
        ],
      );
      expect(team.extraTiebreaks.map((t) => t.label), ['TB1']);
    });

    test('table drops a column only when every publishing row repeats it', () {
      final repeating = _team(
        name: 'A',
        tiebreaks: const [crMatchPoints, crGamePoints, buchholzMp],
      );
      final differing = _team(
        name: 'B',
        matchPoints: 5,
        tiebreaks: const [
          PublishedTiebreak(
            points: 10,
            description: 'Matchpoints (3 for wins, 1 for Draws, 0 for Losses)',
            extendedCode: 'TB1',
          ),
        ],
      );
      expect(
        TeamStandingModel.tableTiebreakColumns([repeating]).map((t) => t.label),
        ['BH:MP'],
      );
      // Different descriptions are different columns; only the repeated one
      // goes.
      expect(
        TeamStandingModel.tableTiebreakColumns([
          repeating,
          differing,
        ]).map((t) => t.description),
        [
          buchholzMp.description,
          'Matchpoints (3 for wins, 1 for Draws, 0 for Losses)',
        ],
      );
      final sameColumnDiffers = _team(
        name: 'C',
        matchPoints: 4,
        tiebreaks: const [
          PublishedTiebreak(
            points: 5,
            description: 'Matchpoints (2 for wins, 1 for Draws, 0 for Losses)',
            extendedCode: 'TB1',
          ),
        ],
      );
      expect(
        TeamStandingModel.tableTiebreakColumns([
          repeating,
          sameColumnDiffers,
        ]).map((t) => t.label),
        ['TB1', 'BH:MP'],
      );
    });
  });
}
