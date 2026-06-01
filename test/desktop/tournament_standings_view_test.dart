import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/tournament_standings_view.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show selectedPlayerProvider, scoreCardHasEventContextProvider;
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';

void main() {
  testWidgets('tapping a standings player name opens a score card tab', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        playerTourScreenProvider.overrideWith(_FakeStandingsNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 720,
              height: 480,
              child: TournamentStandingsView(tournamentId: 'event-1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Carlsen, Magnus'));
    await tester.pump();

    final tabs = container.read(desktopTabsProvider);
    final activeId = tabs.activeId;
    expect(tabs.active?.kind, TabKind.playerScoreCard);
    expect(container.read(selectedPlayerProvider)?.name, 'Carlsen, Magnus');
    expect(container.read(scoreCardHasEventContextProvider), isTrue);
    expect(
      container.read(playerScoreCardByTabIdProvider)[activeId]?.name,
      'Carlsen, Magnus',
    );
  });
}

class _FakeStandingsNotifier extends PlayerTourScreenNotifier {
  @override
  Future<List<PlayerStandingModel>> build() async {
    return const [
      PlayerStandingModel(
        countryCode: 'NOR',
        title: 'GM',
        name: 'Carlsen, Magnus',
        score: 2830,
        scoreChange: 0,
        matchScore: '1 / 1',
        fideId: 1503014,
        overallRank: 1,
      ),
    ];
  }
}
