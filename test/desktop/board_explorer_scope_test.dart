import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_explorer_scope.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _player = GamebasePlayer(
  id: 'gulliyev-id',
  fideId: '13402960',
  name: 'Gulliyev, Namig',
  gender: PlayerGender.male,
  fed: 'AZE',
  title: 'GM',
  ratingClassical: 2468,
);

void main() {
  test('opening a normal board game clears stale player explorer scope', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final tabs = container.read(desktopTabsProvider.notifier);
    final tabId = tabs.open(
      TabKind.board,
      title: 'Gulliyev, Namig Tree',
      reuseExisting: false,
    );

    container
        .read(boardExplorerScopeByTabIdProvider.notifier)
        .update(
          (m) => <String, BoardExplorerScope>{
            ...m,
            tabId: const BoardExplorerScope(player: _player),
          },
        );

    expect(container.read(boardExplorerScopeByTabIdProvider), contains(tabId));

    final reusedTabId = openBoardGameTabFromContainer(
      container,
      const BoardTabGameArgs(
        gameId: 'normal-game-id',
        pgn: '1. e4 e5 2. Nf3 Nc6',
        label: 'Leszko, Bence vs Markantonaki, Haritomeni',
        whiteName: 'Leszko, Bence',
        blackName: 'Markantonaki, Haritomeni',
        viewSource: ChessboardView.tour,
      ),
      replaceActive: true,
    );

    expect(reusedTabId, tabId);
    expect(
      container.read(boardExplorerScopeByTabIdProvider),
      isNot(contains(tabId)),
    );
  });

  test('leaving player-scoped explorer resets global explorer filters', () {
    const scopedFilters = GamebaseFilters(
      playerIds: ['gulliyev-id'],
      selectedPlayers: [_player],
      minRating: 2400,
      timeControls: [TimeControl.rapid],
    );
    const scope = BoardExplorerScope(
      player: _player,
      initialFilters: scopedFilters,
    );

    final applied = boardExplorerFiltersForScope(
      scope: scope,
      currentFilters: const GamebaseFilters(),
      appliedScopeKey: null,
    );
    expect(applied?.playerIds, ['gulliyev-id']);
    expect(applied?.minRating, 2400);

    final cleared = boardExplorerFiltersForScope(
      scope: null,
      currentFilters: applied!,
      appliedScopeKey: scope.identityKey,
    );

    expect(cleared, const GamebaseFilters());
    expect(cleared?.playerIds, isEmpty);
    expect(cleared?.selectedPlayers, isEmpty);
  });

  test('normal board explorer clears scope applied by another tab', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const scope = BoardExplorerScope(player: _player);
    container.read(appliedBoardExplorerScopeKeyProvider.notifier).state =
        scope.identityKey;
    container
        .read(gamebaseExplorerProvider.notifier)
        .updateFilters(scope.initialScopedFilters);

    final cleared = boardExplorerFiltersForScope(
      scope: null,
      currentFilters: container.read(gamebaseExplorerProvider).filters,
      appliedScopeKey: container.read(appliedBoardExplorerScopeKeyProvider),
    );
    expect(cleared, const GamebaseFilters());

    container.read(gamebaseExplorerProvider.notifier).updateFilters(cleared!);
    container.read(appliedBoardExplorerScopeKeyProvider.notifier).state = null;

    final filters = container.read(gamebaseExplorerProvider).filters;
    expect(filters.playerIds, isEmpty);
    expect(filters.selectedPlayers, isEmpty);
    expect(container.read(appliedBoardExplorerScopeKeyProvider), isNull);
  });
}
