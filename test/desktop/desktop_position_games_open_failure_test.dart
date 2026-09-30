import 'package:chessever/desktop/services/local_chess_database_open_guard.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'support/desktop_premium_test_overrides.dart';

/// Regression sources for the reported dead-end: a player's opening-tree store
/// (`<database>.pgn.cetg`) could not be opened while the games table fetched
/// the position, and the panel showed
/// `Couldn't load games` / `Failed to open database at "..."` until the user
/// left the tab and came back. The tree store is a generated sidecar that a
/// build publishes while the panel is already reading, so the failure is
/// transient: the panel must retry, keep the last good rows, and offer a Retry
/// action instead of a raw native string.
const String _positionFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const String _localDatabasePath =
    'C:/ws/player-workspace/player-1-x/CHESSEVER_1_CHESSEVER_X.pgn';

void main() {
  testWidgets('recovers in place when the tree store is briefly unopenable', (
    tester,
  ) async {
    final repository = _FakeLocalChessRepository(failuresBeforeSuccess: 1);

    await tester.pumpWidget(_host(repository));
    await tester.pump();

    // First attempt fails: the panel must show actionable wording, never the
    // raw native string, and must still offer a way forward.
    expect(find.text("Couldn't load games"), findsOneWidget);
    expect(find.textContaining('Failed to open database at'), findsNothing);
    expect(find.textContaining('Retry'), findsOneWidget);
    expect(find.text('Carlsen'), findsNothing);

    // The bounded auto-retry runs without the user leaving the tab.
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load games"), findsNothing);
    expect(find.text('Carlsen'), findsOneWidget);
    expect(repository.calls, 2);
  });

  testWidgets('a persistent tree-store failure offers Retry that recovers', (
    tester,
  ) async {
    final repository = _FakeLocalChessRepository(failuresBeforeSuccess: 99);

    await tester.pumpWidget(_host(repository));
    await tester.pump();

    // Two bounded auto-retries, then the panel settles on the error surface.
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load games"), findsOneWidget);
    expect(find.textContaining('Failed to open database at'), findsNothing);
    expect(repository.calls, 3);

    // The store finishes publishing; the user's explicit Retry recovers.
    repository.failuresBeforeSuccess = 0;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load games"), findsNothing);
    expect(find.text('Carlsen'), findsOneWidget);
  });

  testWidgets('keeps the last good rows when a refresh fails transiently', (
    tester,
  ) async {
    final repository = _FakeLocalChessRepository(failuresBeforeSuccess: 0);

    await tester.pumpWidget(_host(repository));
    await tester.pumpAndSettle();
    expect(find.text('Carlsen'), findsOneWidget);

    // A refresh (filter change) now fails: the rows already on screen must stay
    // rather than being replaced by the error surface.
    repository.failuresBeforeSuccess = 1;
    ProviderScope.containerOf(
      tester.element(find.byType(DesktopPositionGamesTable)),
    ).read(gamebaseExplorerProvider.notifier).updateFilters(
      const GamebaseFilters(timeControls: [TimeControl.rapid]),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Carlsen'), findsOneWidget);
    expect(find.text("Couldn't load games"), findsNothing);

    // The bounded auto-retry then succeeds and the rows stay in place.
    repository.failuresBeforeSuccess = 0;
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    expect(find.text('Carlsen'), findsOneWidget);
    expect(find.text("Couldn't load games"), findsNothing);
  });
}

Widget _host(_FakeLocalChessRepository repository) {
  return ProviderScope(
    overrides: [
      ...desktopPremiumTestOverrides,
      localChessDatabaseRepositoryProvider.overrideWithValue(repository),
      boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
    ],
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: kBackgroundColor,
        body: SizedBox(
          width: 360,
          height: 520,
          child: DesktopPositionGamesTable(
            fen: _positionFen,
            localOpeningTreeIndex: _localTreeIndex(),
            localOpeningTreeTitle: 'CHESSEVER_1_CHESSEVER_X.pgn',
          ),
        ),
      ),
    ),
  );
}

/// The handle a Prepare workspace passes to the table: identity only, with no
/// rows — the games come from the local position query.
PlayerOpeningTreeIndex _localTreeIndex() {
  return PlayerOpeningTreeIndex(
    treeId: 'tree-1',
    playerId: _localDatabasePath,
    maxPly: 30,
    rootNodeId: 0,
    generatedAt: DateTime(2026, 9, 17),
    nodesById: const <int, PlayerOpeningTreeNode>{},
    nodesByFenKey: const <String, PlayerOpeningTreeNode>{},
    gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
    gameRowsById: const <String, Map<String, dynamic>>{},
    persistedPositionCount: 12,
    persistedGameCount: 4,
  );
}

class _FakeLocalChessRepository extends LocalChessDatabaseRepository {
  _FakeLocalChessRepository({required this.failuresBeforeSuccess})
    : super(
        database: () async =>
            throw StateError('the fake never opens the real database'),
      );

  int failuresBeforeSuccess;
  int calls = 0;

  @override
  Future<GamebaseSearchQueryResponse?> localPositionGamesResponse({
    required String databasePath,
    required String fen,
    List<String> moves = const <String>[],
    String? uci,
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
    required GamebaseSortField sortBy,
    required GamebaseSortDirection sortDirection,
    required int pageNumber,
    required int pageSize,
  }) async {
    calls += 1;
    if (calls <= failuresBeforeSuccess) {
      // Exactly what resqlite raises, surfaced through the loader's label.
      throw LocalChessDatabaseUnavailableException(
        path: '$databasePath.cetg',
        operation: LocalChessDatabaseOperation.open,
        attempts: 4,
        purpose: 'opening-tree game index',
        label: 'CHESSEVER_1_CHESSEVER_X.pgn',
      );
    }
    return GamebaseSearchQueryResponse(
      status: 'success',
      data: const <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'local-1',
          'white': 'Carlsen',
          'black': 'Nakamura',
          'whiteElo': 2830,
          'blackElo': 2780,
          'result': '1-0',
          'date': '2024-05-02',
          'event': 'Local DB',
          'site': 'Disk',
        },
      ],
      metadata: const GamebasePaginationMetadata(
        pageNumber: 0,
        pageSize: 25,
        hasMoreValue: false,
      ),
    );
  }
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(useFigurine: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}
