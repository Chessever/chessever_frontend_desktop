import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_team_standings_view.dart';
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:chessever/screens/tour_detail/team_tour/team_tour_screen_provider.dart';

void main() {
  testWidgets('compact rail standings render ranked team rows', (tester) async {
    const india = TeamStandingModel(
      teamName: 'India',
      rank: 1,
      matchPoints: 4,
      gamePoints: 6.5,
      matchesWon: 2,
      matchesDrawn: 0,
      matchesLost: 0,
      boardsPlayed: 8,
      players: [],
    );
    const norway = TeamStandingModel(
      teamName: 'Norway',
      rank: 2,
      matchPoints: 0,
      gamePoints: 1.5,
      matchesWon: 0,
      matchesDrawn: 0,
      matchesLost: 2,
      boardsPlayed: 8,
      players: [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          teamStandingsForTourProvider(
            'team-tour',
          ).overrideWith((ref) => const AsyncValue.data([india, norway])),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 300,
              child: DesktopCompactTeamStandingsView(
                tabId: 'board-tab',
                tournamentId: 'team-tour',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('India'), findsOneWidget);
    expect(find.text('Norway'), findsOneWidget);
    expect(find.text('6.5 pts · 2 · 0 · 0'), findsOneWidget);
    expect(find.text('1.5 pts · 0 · 0 · 2'), findsOneWidget);
    expect(
      find.byKey(const Key('event-rail-team-standing-India')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('event-rail-team-standing-mp-India')),
      findsOneWidget,
    );
    expect(find.text('Carlsen'), findsNothing);
  });

  TeamStandingModel row(String name, int rank, {int? officialRound}) =>
      TeamStandingModel(
        teamName: name,
        rank: rank,
        officialRound: officialRound,
        matchPoints: 6,
        gamePoints: 10.5,
        matchesWon: 3,
        matchesDrawn: 0,
        matchesLost: 1,
        boardsPlayed: 0,
        players: const [],
      );

  Future<void> pumpTable(WidgetTester tester, List<TeamStandingModel> rows) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          teamStandingsProvider.overrideWith((ref) => AsyncValue.data(rows)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 500,
              child: DesktopTeamStandingsTable(),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('official table names its round and keeps stored shared ranks', (
    tester,
  ) async {
    await pumpTable(tester, [
      row('India', 1, officialRound: 4),
      row('Norway', 1, officialRound: 4),
      row('Brazil', 3, officialRound: 4),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Official standings · after round 4'), findsOneWidget);
    expect(find.text('Played'), findsOneWidget);
    // Two teams share first place; the third row is 3, not its list position.
    expect(find.text('1'), findsNWidgets(2));
    expect(find.text('2'), findsNothing);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('4'), findsNWidgets(3));
    expect(find.text('3 · 0 · 1'), findsNWidgets(3));
  });

  testWidgets('computed table carries no official line', (tester) async {
    await pumpTable(tester, [row('India', 1), row('Norway', 2)]);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('team-standings-official-line')), findsNothing);
    expect(find.text('India'), findsOneWidget);
    expect(find.text('Norway'), findsOneWidget);
  });
}
