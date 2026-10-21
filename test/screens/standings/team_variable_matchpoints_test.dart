import 'package:chessever/repository/supabase/tour/published_tiebreak.dart';
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a variable match-point column that repeats the row is hidden', () {
    // Andalucía rapid teams: "Tie Break1: Matchpoints (variabel)" (3/1/0).
    const mp = PublishedTiebreak(
      points: 21,
      description: 'Matchpoints (variabel)',
      extendedCode: 'TB1',
    );
    const bh = PublishedTiebreak(
      points: 116.5,
      description: 'Buchholz Tie-Breaks (variabel with parameter)',
      extendedCode: 'TB3',
    );
    TeamStandingModel team(num matchPoints) => TeamStandingModel(
      teamName: 'Prodomasa Coin',
      rank: 1,
      tiebreaks: const [mp, bh],
      matchPoints: matchPoints,
      gamePoints: 24,
      matchesWon: 7,
      matchesDrawn: 0,
      matchesLost: 0,
      boardsPlayed: 0,
      players: const [],
    );
    expect(team(21).extraTiebreaks, [bh]);
    // A column that disagrees with the row stays visible.
    expect(team(14).extraTiebreaks, [mp, bh]);
  });
}
