import 'package:chessever/desktop/widgets/explorer_filter_availability.dart';
import 'package:chessever/desktop/widgets/explorer_filter_bar.dart';
import 'package:chessever/screens/gamebase/models/gamebase_game.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets(
    'Whole Database filter chips show coming soon and do not mutate filters',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: ExplorerFilterBar(),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Classical'));
      await tester.pump();

      expect(find.text(wholeDatabaseFiltersComingSoonMessage), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ExplorerFilterBar)),
      );
      expect(
        container.read(gamebaseExplorerProvider).filters.timeControls,
        isEmpty,
      );
    },
  );

  testWidgets('scoped player Build Tree filter chips still update filters', (
    tester,
  ) async {
    const player = GamebasePlayer(
      id: 'player-uuid',
      fideId: '1503014',
      name: 'Carlsen, Magnus',
      gender: PlayerGender.male,
      fed: 'NOR',
      title: 'GM',
      ratingClassical: 2830,
    );

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: kBackgroundColor,
            body: ExplorerFilterBar(scopedPlayer: player),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Classical'));
    await tester.pump();

    expect(find.text(wholeDatabaseFiltersComingSoonMessage), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExplorerFilterBar)),
    );
    expect(container.read(gamebaseExplorerProvider).filters.timeControls, [
      TimeControl.classical,
    ]);
  });
}
