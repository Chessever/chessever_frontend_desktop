import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'support/desktop_premium_test_overrides.dart';

void main() {
  testWidgets('imported tree bounds notation and reveals unmounted games', (
    tester,
  ) async {
    final controller = DesktopPositionGamesTableController();
    addTearDown(controller.dispose);
    final index = PlayerOpeningTreeIndex(
      treeId: 'local:imported',
      playerId: '/tmp/imported.pgn',
      maxPly: 40,
      rootNodeId: 0,
      generatedAt: DateTime(2026),
      nodesById: const {},
      nodesByFenKey: const {},
      gamesByFen: const {},
      gameRowsById: const {},
      persistedPositionCount: 4,
      persistedGameCount: 120,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...desktopPremiumTestOverrides,
          localChessDatabaseRepositoryProvider.overrideWithValue(
            _ImportedTreeRepository(),
          ),
          boardSettingsProviderNew.overrideWith(_BoardSettings.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 700,
                height: 220,
                child: AnimatedBuilder(
                  animation: controller,
                  builder:
                      (context, _) => DesktopPositionGamesTable(
                        fen: Chess.initial.fen,
                        referenceLayout: true,
                        controller: controller,
                        localOpeningTreeIndex: index,
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _waitForRows(tester, controller);
    expect(controller.rowCount, 120);
    // The old eager table mounted 4,800 hover controls for these 120 games.
    expect(find.byType(MoveHoverPreview).evaluate().length, lessThan(400));
    expect(find.text('White119'), findsNothing);

    final firstToken = find.descendant(
      of: find.byKey(
        const ValueKey<String>(
          'position-game-notation-token-explorer-imported-0-0',
        ),
      ),
      matching: find.byType(MoveHoverPreview),
    );
    final unchangedPreview = tester.widget<MoveHoverPreview>(firstToken);
    expect(unchangedPreview.replay, isNotNull);
    expect(
      unchangedPreview.replay!.fen,
      computeMovePreviewReplay(
        startingFen: unchangedPreview.startingFen,
        movesUpToHover: unchangedPreview.movesUpToHover,
      ).fen,
    );
    controller.select('imported-1', reveal: false);
    await tester.pump();
    expect(tester.widget<MoveHoverPreview>(firstToken), same(unchangedPreview));

    // Keyboard selection of a row without a mounted GlobalKey must reveal it.
    controller.select('imported-119');
    await tester.pumpAndSettle();
    expect(find.text('White119'), findsOneWidget);
    expect(find.text('White0'), findsNothing);
    expect(find.byType(MoveHoverPreview).evaluate().length, lessThan(400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an idle paginated tree does not keep scheduling frames', (
    tester,
  ) async {
    final controller = DesktopPositionGamesTableController();
    addTearDown(controller.dispose);
    final index = PlayerOpeningTreeIndex(
      treeId: 'local:paginated',
      playerId: '/tmp/imported.pgn',
      maxPly: 40,
      rootNodeId: 0,
      generatedAt: DateTime(2026),
      nodesById: const {},
      nodesByFenKey: const {},
      gamesByFen: const {},
      gameRowsById: const {},
      persistedPositionCount: 4,
      persistedGameCount: 260,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...desktopPremiumTestOverrides,
          localChessDatabaseRepositoryProvider.overrideWithValue(
            _ImportedTreeRepository(hasMore: true),
          ),
          boardSettingsProviderNew.overrideWith(_BoardSettings.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 700,
              height: 220,
              child: DesktopPositionGamesTable(
                fen: Chess.initial.fen,
                referenceLayout: true,
                controller: controller,
                localOpeningTreeIndex: index,
              ),
            ),
          ),
        ),
      ),
    );
    await _waitForRows(tester, controller);
    expect(controller.rowCount, 120);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}

/// Local pages prepare notation in a real isolate. Its reply lands in the
/// widget test's fake zone, so let real time pass and pump until it settles.
Future<void> _waitForRows(
  WidgetTester tester,
  DesktopPositionGamesTableController controller,
) async {
  for (var i = 0; i < 250 && controller.rowCount == 0; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

class _ImportedTreeRepository extends LocalChessDatabaseRepository {
  _ImportedTreeRepository({this.hasMore = false})
    : super(database: () async => throw StateError('No real database'));

  final bool hasMore;

  @override
  Future<GamebaseSearchQueryResponse?> localPositionGamesResponse({
    required String databasePath,
    required String fen,
    List<String> moves = const [],
    String? uci,
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
    required GamebaseSortField sortBy,
    required GamebaseSortDirection sortDirection,
    required int pageNumber,
    required int pageSize,
  }) async {
    final continuation = <String>[
      for (var move = 0; move < 10; move++) ...['g1f3', 'g8f6', 'f3g1', 'f6g8'],
    ];
    return GamebaseSearchQueryResponse(
      status: 'success',
      data: [
        for (var i = 0; i < 120; i++)
          {
            'id': 'imported-$i',
            'white': 'White$i',
            'black': 'Black$i',
            'whiteElo': 2600,
            'blackElo': 2600,
            'result': '1/2-1/2',
            'date': '2026-01-01',
            'timeControl': 'blitz',
            'isOnline': true,
            'continuation': continuation,
          },
      ],
      metadata: GamebasePaginationMetadata(
        pageNumber: 0,
        pageSize: 120,
        totalCount: 120,
        hasMoreValue: hasMore,
      ),
    );
  }
}

class _BoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(useFigurine: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}
