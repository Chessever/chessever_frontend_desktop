import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/widgets/library/local_chess_files_view.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  testWidgets('selected local database renders repository-backed game rows', (
    tester,
  ) async {
    final fallbackGame = _localGame(
      id: 'fallback',
      white: 'Hou, Yifan',
      black: 'Gukesh, D',
      sourcePath: '/tmp/view.pgn',
    );
    final databaseGame = _localGame(
      id: 'database',
      white: 'Database Only',
      black: 'Gukesh, D',
      sourcePath: '/tmp/view.pgn',
    );
    final source = _sourceWithGame(fallbackGame, gameCount: 42);
    final repository = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: <LocalChessGame>[databaseGame],
        totalCount: 1,
        pageNumber: 0,
        pageSize: 1,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 700,
              child: LocalChessFilesView(
                selectedPath: source.root.path,
                onSelectPath: (_) {},
                stateOverride: LocalChessLibraryState(
                  source: source,
                  selectedPath: source.root.path,
                ),
                onRefreshOverride: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repository.queries, hasLength(1));
    expect(repository.queries.single.search, isEmpty);
    expect(repository.queries.single.pageSize, 1000);
    expect(find.text('Database Only'), findsOneWidget);
    expect(find.text('Hou, Yifan'), findsNothing);

    await tester.enterText(find.byType(TextField), 'database only');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repository.queries.last.search, 'database only');
    expect(find.text('Database Only'), findsOneWidget);
    expect(find.text('1 / 42 entries'), findsOneWidget);
  });

  testWidgets(
    'selected local database loads more games by requesting the next page',
    (tester) async {
      final source = _sourceWithGame(
        _localGame(
          id: 'fallback',
          white: 'Fallback',
          black: 'Player',
          sourcePath: '/tmp/view.pgn',
        ),
        gameCount: 2500,
      );
      final repository = _FakeLocalChessDatabaseRepository(
        pageForQuery: (query) {
          final start = query.pageNumber * query.pageSize;
          final count = (2500 - start).clamp(0, query.pageSize);
          return LocalChessGameQueryPage(
            games: List<LocalChessGame>.generate(count, (i) {
              final index = start + i;
              return _localGame(
                id: 'database-$index',
                white: 'Database $index',
                black: 'Player',
                sourcePath: '/tmp/view.pgn',
                indexInFile: index,
              );
            }),
            totalCount: 2500,
            pageNumber: query.pageNumber,
            pageSize: query.pageSize,
          );
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localChessDatabaseRepositoryProvider.overrideWithValue(repository),
            localChessLibraryProvider.overrideWith(
              (ref) => LocalChessLibraryNotifier(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 1100,
                height: 700,
                child: LocalChessFilesView(
                  selectedPath: source.root.path,
                  onSelectPath: (_) {},
                  stateOverride: LocalChessLibraryState(
                    source: source,
                    selectedPath: source.root.path,
                  ),
                  onRefreshOverride: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(repository.queries.single.pageSize, 1000);
      expect(repository.queries.single.pageNumber, 0);
      expect(find.text('Load more'), findsOneWidget);
      expect(find.text('1000 / 2500 loaded'), findsOneWidget);

      await tester.tap(find.text('Load more'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 250));

      expect(repository.queries.last.pageNumber, 1);
      expect(repository.queries.last.pageSize, 1000);
      expect(find.text('2000 / 2500 loaded'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'database 2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(repository.queries.last.search, 'database 2');
      expect(repository.queries.last.pageNumber, 0);
      expect(repository.queries.last.pageSize, 1000);
    },
  );

  testWidgets(
    'Tree button opens a board tab scoped to the local database tree',
    (tester) async {
      final index = _usableTreeIndex();
      final source = _sourceWithGame(
        _localGame(
          id: 'database',
          white: 'Database Only',
          black: 'Gukesh, D',
          sourcePath: '/tmp/view.pgn',
        ),
        gameCount: 1,
        openingTreeIndex: index,
      );
      final repository = _FakeLocalChessDatabaseRepository(
        page: LocalChessGameQueryPage(
          games: source.root.files.single.games,
          totalCount: 1,
          pageNumber: 0,
          pageSize: 1000,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localChessDatabaseRepositoryProvider.overrideWithValue(repository),
            localChessLibraryProvider.overrideWith(
              (ref) => LocalChessLibraryNotifier(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 1100,
                height: 700,
                child: LocalChessFilesView(
                  selectedPath: source.root.path,
                  onSelectPath: (_) {},
                  stateOverride: LocalChessLibraryState(
                    source: source,
                    selectedPath: source.root.path,
                  ),
                  onRefreshOverride: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Tree'), findsOneWidget);
      await tester.tap(find.text('Tree'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalChessFilesView)),
        listen: false,
      );
      final tabs = container.read(desktopTabsProvider);
      final activeId = tabs.activeId!;
      expect(tabs.active!.kind, TabKind.board);
      expect(tabs.active!.title, 'view.pgn Tree');
      final args = container.read(boardTabGameArgsByTabIdProvider)[activeId]!;
      expect(args.localOpeningTreeIndex, isNot(same(index)));
      expect(args.localOpeningTreeIndex!.treeId, index.treeId);
      expect(args.localOpeningTreeIndex!.playerId, index.playerId);
      expect(args.localOpeningTreeIndex!.positionCount, index.positionCount);
      expect(
        args.localOpeningTreeIndex!.downloadedGameCount,
        index.downloadedGameCount,
      );
      expect(args.localOpeningTreeIndex!.nodesById, isEmpty);
      expect(args.localOpeningTreeIndex!.nodesByFenKey, isEmpty);
      expect(args.localOpeningTreeIndex!.gamesByFen, isEmpty);
      expect(args.localOpeningTreeIndex!.gameRowsById, isEmpty);
      expect(args.localOpeningTreeTitle, 'view.pgn');
      expect(container.read(rightRailActivePageProvider(activeId)), 1);
    },
  );

  testWidgets('Tree button builds when the cached local tree index is empty', (
    tester,
  ) async {
    final source = _sourceWithGame(
      _localGame(
        id: 'database',
        white: 'Database Only',
        black: 'Gukesh, D',
        sourcePath: '/tmp/view.pgn',
      ),
      gameCount: 1,
      openingTreeIndex: const PlayerOpeningTreeIndex.empty(),
    );
    final repository = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: source.root.files.single.games,
        totalCount: 1,
        pageNumber: 0,
        pageSize: 1000,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 700,
              child: LocalChessFilesView(
                selectedPath: source.root.path,
                onSelectPath: (_) {},
                stateOverride: LocalChessLibraryState(
                  source: source,
                  selectedPath: source.root.path,
                ),
                onRefreshOverride: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Build tree'), findsOneWidget);
    expect(find.text('Tree'), findsNothing);

    await tester.tap(find.text('Build tree'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LocalChessFilesView)),
      listen: false,
    );
    expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
  });

  testWidgets('opening a local PGN row carries title flag and FIDE metadata', (
    tester,
  ) async {
    final index = _usableTreeIndex();
    final source = _sourceWithGame(
      _localGame(
        id: 'metadata-game',
        white: 'Metadata White',
        black: 'Metadata Black',
        sourcePath: '/tmp/view.pgn',
        metadataOverrides: const <String, String>{
          'WhiteCountry': 'NOR',
          'BlackTeamCountry': 'USA',
          'WhiteTitle': 'GM',
          'BlackTitle': 'IM',
          'WhiteFideId': '1503014',
          'BlackFideId': '2016192',
          'CustomHeader': 'Preserved',
        },
      ),
      gameCount: 1,
      openingTreeIndex: index,
    );
    final repository = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: source.root.files.single.games,
        totalCount: 1,
        pageNumber: 0,
        pageSize: 1000,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 700,
              child: LocalChessFilesView(
                selectedPath: source.root.path,
                onSelectPath: (_) {},
                stateOverride: LocalChessLibraryState(
                  source: source,
                  selectedPath: source.root.path,
                ),
                onRefreshOverride: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final rowFinder = find.text('Metadata White');
    expect(rowFinder, findsOneWidget);
    await tester.tap(rowFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(rowFinder);
    await tester.pump(const Duration(milliseconds: 250));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LocalChessFilesView)),
      listen: false,
    );
    final tabs = container.read(desktopTabsProvider);
    final activeId = tabs.activeId!;
    expect(tabs.active!.kind, TabKind.board);
    final args = container.read(boardTabGameArgsByTabIdProvider)[activeId]!;
    expect(args.whiteFederation, 'NOR');
    expect(args.blackFederation, 'USA');
    expect(args.whiteTitle, 'GM');
    expect(args.blackTitle, 'IM');
    expect(args.whiteFideId, 1503014);
    expect(args.blackFideId, 2016192);
    expect(args.databaseGames.single.whiteFederation, 'NOR');
    expect(args.databaseGames.single.blackFederation, 'USA');
    expect(args.pgn, contains('[CustomHeader "Preserved"]'));
    expect(args.localOpeningTreeIndex, isNot(same(index)));
    expect(args.localOpeningTreeIndex!.treeId, index.treeId);
    expect(args.localOpeningTreeIndex!.nodesById, isEmpty);
    expect(args.localOpeningTreeIndex!.gameRowsById, isEmpty);
  });

  testWidgets('Tree button shows local background build progress', (
    tester,
  ) async {
    final source = _sourceWithGame(
      _localGame(
        id: 'database',
        white: 'Database Only',
        black: 'Gukesh, D',
        sourcePath: '/tmp/view.pgn',
      ),
      gameCount: 1,
    );
    final repository = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: source.root.files.single.games,
        totalCount: 1,
        pageNumber: 0,
        pageSize: 1000,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 700,
              child: LocalChessFilesView(
                selectedPath: source.root.path,
                onSelectPath: (_) {},
                stateOverride: LocalChessLibraryState(
                  source: source,
                  selectedPath: source.root.path,
                  treeBuilds: <String, LocalChessTreeBuildProgress>{
                    localChessInputPathKey(
                      '/tmp/view.pgn',
                    ): const LocalChessTreeBuildProgress(
                      path: '/tmp/view.pgn',
                      phase: LocalChessTreeBuildPhase.building,
                      fraction: 0.42,
                      message: 'Building opening tree...',
                    ),
                  },
                ),
                onRefreshOverride: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Tree 42%'), findsOneWidget);
    expect(find.text('Build tree'), findsNothing);
  });
}

class _FakeLocalChessDatabaseRepository extends LocalChessDatabaseRepository {
  _FakeLocalChessDatabaseRepository({this.page, this.pageForQuery})
    : super(database: () async => throw UnsupportedError('unused'));

  final LocalChessGameQueryPage? page;
  final LocalChessGameQueryPage Function(_QueryCall query)? pageForQuery;
  final List<_QueryCall> queries = <_QueryCall>[];

  @override
  Future<LocalChessGameQueryPage?> localDatabaseGamesPage({
    required String databasePath,
    String search = '',
    LocalChessGameSortField sortBy = LocalChessGameSortField.originalOrder,
    LocalChessGameSortDirection sortDirection = LocalChessGameSortDirection.asc,
    required int pageNumber,
    required int pageSize,
  }) async {
    final query = _QueryCall(
      databasePath: databasePath,
      search: search,
      sortBy: sortBy,
      sortDirection: sortDirection,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
    queries.add(query);
    final response = pageForQuery?.call(query) ?? page;
    if (response == null) {
      throw StateError('No fake local database page configured.');
    }
    return response;
  }
}

class _QueryCall {
  const _QueryCall({
    required this.databasePath,
    required this.search,
    required this.sortBy,
    required this.sortDirection,
    required this.pageNumber,
    required this.pageSize,
  });

  final String databasePath;
  final String search;
  final LocalChessGameSortField sortBy;
  final LocalChessGameSortDirection sortDirection;
  final int pageNumber;
  final int pageSize;
}

LocalChessSource _sourceWithGame(
  LocalChessGame game, {
  required int gameCount,
  PlayerOpeningTreeIndex? openingTreeIndex,
}) {
  const filePath = '/tmp/view.pgn';
  final root = LocalChessFolderNode.fromChildren(
    name: 'view.pgn',
    path: 'local-file:view',
    relativePath: '',
    children: <LocalChessNode>[
      LocalChessFileNode(
        name: 'view.pgn',
        path: filePath,
        relativePath: 'view.pgn',
        extension: 'pgn',
        status: LocalChessFileStatus.parsed,
        games: <LocalChessGame>[game],
        gameCount: gameCount,
        sizeBytes: 128,
        modifiedAt: DateTime(2026),
        openingTreeIndex: openingTreeIndex,
      ),
    ],
  );
  return LocalChessSource(
    id: 'local',
    label: 'view.pgn',
    paths: const <String>[filePath],
    rootPath: '/tmp',
    scannedAt: DateTime(2026),
    root: root,
  );
}

PlayerOpeningTreeIndex _usableTreeIndex() {
  return buildLocalOpeningTreeIndex(
    treeId: 'local:view',
    databaseId: '/tmp/view.pgn',
    games: <LocalOpeningTreeGameInput>[
      LocalOpeningTreeGameInput(
        id: 'database',
        rawPgn:
            '[Event "Fast tree"]\n'
            '[Site "Local"]\n'
            '[Date "2024.01.03"]\n'
            '[White "Database Only"]\n'
            '[Black "Gukesh, D"]\n'
            '[Result "1/2-1/2"]\n\n'
            '1. d4 d5 1/2-1/2',
        sourcePath: '/tmp/view.pgn',
        sourceRelativePath: 'view.pgn',
        fileName: 'view.pgn',
        indexInFile: 0,
        fileGameCount: 1,
      ),
    ],
  );
}

LocalChessGame _localGame({
  required String id,
  required String white,
  required String black,
  required String sourcePath,
  int indexInFile = 0,
  Map<String, String> metadataOverrides = const <String, String>{},
}) {
  final metadata = <String, String>{
    'Event': 'Fast tree',
    'Site': 'Local',
    'Date': '2024.01.03',
    'White': white,
    'Black': black,
    'WhiteElo': '2650',
    'BlackElo': '2760',
    'ECO': 'D06',
    'Result': '1/2-1/2',
    ...metadataOverrides,
  };
  final rawPgn = [
    for (final entry in metadata.entries) '[${entry.key} "${entry.value}"]',
    '',
    '1. d4 d5 1/2-1/2',
  ].join('\n');
  return LocalChessGame(
    id: id,
    game: ChessGame(
      gameId: id,
      startingFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      metadata: metadata,
      mainline: const [],
    ),
    rawPgn: rawPgn,
    sourcePath: sourcePath,
    sourceRelativePath: 'view.pgn',
    fileName: 'view.pgn',
    indexInFile: indexInFile,
    fileGameCount: 1,
    hasMoves: true,
  );
}
