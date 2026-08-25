import 'package:chessever/desktop/widgets/explorer_filter_bar.dart';
import 'package:chessever/desktop/widgets/explorer_filter_scope.dart';
import 'package:chessever/desktop/services/player_opening_tree_filter_adapter.dart';
import 'package:chessever/screens/gamebase/models/gamebase_game.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('scoped subject is not active; opponent is clearable', () {
    const subject = GamebasePlayer(
      id: 'rosen',
      fideId: '2000544',
      name: 'Rosen, Eric',
      gender: PlayerGender.male,
      fed: 'USA',
    );
    const alias = GamebasePlayer(
      id: 'chesscom-imrosen',
      fideId: '',
      name: 'IMRosen',
      gender: PlayerGender.male,
      fed: 'USA',
    );
    const opponent = GamebasePlayer(
      id: 'carlsen',
      fideId: '1503014',
      name: 'Carlsen, Magnus',
      gender: PlayerGender.male,
      fed: 'NOR',
    );
    const scoped = GamebaseFilters(
      playerIds: <String>['rosen'],
      selectedPlayers: <GamebasePlayer>[subject, alias],
    );

    expect(explorerActiveFilterCount(scoped, subject), 0);

    final withOpponent = setBuildTreeOpponentFilter(scoped, subject, opponent);
    expect(buildTreeOpponentFilter(withOpponent, subject), opponent);
    expect(explorerActiveFilterCount(withOpponent, subject), 1);
    final criteria = playerOpeningTreeCriteriaFromFilters(withOpponent);
    expect(criteria.playerNames, <String>['Rosen, Eric', 'IMRosen']);
    expect(criteria.opponentNames, <String>['Carlsen, Magnus']);

    final cleared = clearBuildTreeExplorerFilters(withOpponent, subject);
    expect(buildTreeOpponentFilter(cleared, subject), isNull);
    expect(cleared.playerIds, <String>['rosen']);
    expect(cleared.selectedPlayers, <GamebasePlayer>[subject, alias]);
    expect(explorerActiveFilterCount(cleared, subject), 0);
  });

  test(
    'Build Tree filter sanitizing preserves every filter axis and aliases',
    () {
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
          timeControls: <TimeControl>[TimeControl.rapid],
          titles: <GamebasePlayerTitle>[GamebasePlayerTitle.im],
          minRating: 2400,
          maxRating: 2800,
          playerIds: <String>['player-uuid'],
          selectedPlayers: <GamebasePlayer>[player, chessComAlias],
          playerColor: GamebasePlayerColor.white,
          gameResult: GamebaseGameResult.draw,
          isOnline: false,
          yearFrom: 2018,
          yearTo: 2026,
          sortBy: GamebaseSortField.whiteElo,
          sortDirection: GamebaseSortDirection.asc,
        ),
        player,
      );

      expect(sanitized.playerIds, <String>['player-uuid']);
      expect(sanitized.selectedPlayers, <GamebasePlayer>[
        player,
        chessComAlias,
      ]);
      expect(sanitized.playerColor, GamebasePlayerColor.white);
      expect(sanitized.timeControls, <TimeControl>[TimeControl.rapid]);
      expect(sanitized.titles, <GamebasePlayerTitle>[GamebasePlayerTitle.im]);
      expect(sanitized.minRating, 2400);
      expect(sanitized.maxRating, 2800);
      expect(sanitized.gameResult, GamebaseGameResult.draw);
      expect(sanitized.isOnline, isFalse);
      expect(sanitized.yearFrom, 2018);
      expect(sanitized.yearTo, 2026);
      expect(sanitized.sortBy, GamebaseSortField.whiteElo);
      expect(sanitized.sortDirection, GamebaseSortDirection.asc);
    },
  );

  test('Build Tree clear resets axes but retains player source aliases', () {
    const player = GamebasePlayer(
      id: 'player-uuid',
      fideId: '1503014',
      name: 'Vasif Durarbayli',
      gender: PlayerGender.male,
      fed: 'AZE',
    );
    const alias = GamebasePlayer(
      id: 'workspace-chesscom-durarbayli',
      fideId: '',
      name: 'Durarbayli',
      gender: PlayerGender.male,
      fed: 'AZE',
    );

    const configured = GamebaseFilters(
      playerIds: <String>['player-uuid'],
      selectedPlayers: <GamebasePlayer>[player, alias],
      timeControls: <TimeControl>[TimeControl.blitz],
      minRating: 2400,
      playerColor: GamebasePlayerColor.black,
      gameResult: GamebaseGameResult.whiteWins,
      isOnline: true,
      yearFrom: 2020,
    );
    expect(explorerActiveFilterCount(configured, player), 6);

    final cleared = clearBuildTreeExplorerFilters(configured, player);

    expect(cleared.playerIds, <String>['player-uuid']);
    expect(cleared.selectedPlayers, <GamebasePlayer>[player, alias]);
    expect(cleared.timeControls, isEmpty);
    expect(cleared.minRating, isNull);
    expect(cleared.playerColor, isNull);
    expect(cleared.gameResult, isNull);
    expect(cleared.isOnline, isNull);
    expect(cleared.yearFrom, isNull);
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
