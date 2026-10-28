import 'package:chessever/repository/supabase/tour/published_tiebreak.dart';
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

  testWidgets(
    'published team columns align and scroll without fabricated values',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const values = [
        PublishedTiebreak(
          points: 42.75,
          description: 'Sonneborn-Berger',
          extendedCode: 'TB1',
        ),
        PublishedTiebreak(
          points: 0,
          description: 'Direct encounter',
          extendedCode: 'TB2',
        ),
      ];
      await pumpTable(tester, [
        const TeamStandingModel(
          teamName: 'Published team',
          rank: 1,
          officialRound: 4,
          matchPoints: 6,
          gamePoints: 10.5,
          matchesWon: 3,
          matchesDrawn: 0,
          matchesLost: 1,
          boardsPlayed: 0,
          players: [],
          tiebreaks: values,
        ),
        row('Unpublished values', 2, officialRound: 4),
      ]);
      await tester.pumpAndSettle();
      final scroll = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      await tester.drag(scroll, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('TB1'), findsOneWidget);
      expect(find.text('42.75'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(
        tester.getCenter(find.text('TB1')).dx,
        closeTo(tester.getCenter(find.text('42.75')).dx, 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drops published MP and GP columns that repeat the table', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TeamStandingModel published(String name, int rank, num bh) =>
        TeamStandingModel(
          teamName: name,
          rank: rank,
          officialRound: 4,
          matchPoints: 6,
          gamePoints: 10.5,
          matchesWon: 3,
          matchesDrawn: 0,
          matchesLost: 1,
          boardsPlayed: 0,
          players: const [],
          tiebreaks: [
            const PublishedTiebreak(
              points: 6,
              description:
                  'Matchpoints (2 for wins, 1 for Draws, 0 for Losses)',
              extendedCode: 'TB1',
            ),
            const PublishedTiebreak(
              points: 10.5,
              description: 'points (game-points)',
              extendedCode: 'TB2',
            ),
            PublishedTiebreak(
              points: bh,
              description: 'Buchholz Tie-Breaks (variable with parameter)',
              extendedCode: 'TB3',
            ),
          ],
        );
    await pumpTable(tester, [
      published('India', 1, 31.5),
      published('Norway', 2, 29),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('TB1'), findsNothing);
    expect(find.text('TB2'), findsNothing);
    expect(find.text('TB3'), findsOneWidget);
    expect(find.text('31.5'), findsOneWidget);
    expect(find.text('29'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
