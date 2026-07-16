import 'package:chessever/desktop/widgets/explorer_filter_bar.dart';
import 'package:chessever/desktop/widgets/explorer_filter_scope.dart';
import 'package:chessever/screens/gamebase/models/gamebase_game.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('Build Tree filter sanitizing preserves source aliases', () {
    const player = GamebasePlayer(
      id: 'player-uuid',
      fideId: '1503014',
      name: 'Vasif Durarbayli',
      gender: PlayerGender.male,
      fed: 'AZE',
    );
    const chessComAlias = GamebasePlayer(
      id: 'workspace-chesscom-durarbayli',
      fideId: '',
      name: 'Durarbayli',
      gender: PlayerGender.male,
      fed: 'AZE',
    );

    final sanitized = sanitizeBuildTreeExplorerFilters(
      const GamebaseFilters(
        playerIds: <String>['player-uuid'],
        selectedPlayers: <GamebasePlayer>[player, chessComAlias],
        playerColor: GamebasePlayerColor.white,
      ),
      player,
    );

    expect(sanitized.playerIds, <String>['player-uuid']);
    expect(sanitized.selectedPlayers, <GamebasePlayer>[
      player,
      chessComAlias,
    ]);
    expect(sanitized.playerColor, GamebasePlayerColor.white);
  });

  testWidgets('offers Bullet and Ultrabullet opening-tree filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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

    expect(find.text('Bullet'), findsOneWidget);
    expect(find.text('Ultrabullet'), findsOneWidget);

    await tester.tap(find.text('Bullet'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExplorerFilterBar)),
    );
    expect(container.read(gamebaseExplorerProvider).filters.timeControls, [
      TimeControl.bullet,
    ]);
  });

  testWidgets('Whole Database filter chips mutate filters (reactivated)', (
    tester,
  ) async {
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExplorerFilterBar)),
    );
    expect(container.read(gamebaseExplorerProvider).filters.timeControls, [
      TimeControl.classical,
    ]);
  });

  testWidgets('scoped player Build Tree filter chips update filters', (
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExplorerFilterBar)),
    );
    expect(container.read(gamebaseExplorerProvider).filters.timeControls, [
      TimeControl.classical,
    ]);
    expect(find.textContaining('Fetched'), findsNothing);
    expect(find.textContaining('positions'), findsNothing);
  });
}
