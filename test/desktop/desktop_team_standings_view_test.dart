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
}
