import 'package:chessever/theme/app_theme.dart';
import 'dart:io';
import 'dart:async';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:forui/forui.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/local_raw_pgn_catalog.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/local_board_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

class _NoDiskGame extends LocalChessGame {
  _NoDiskGame(int index)
    : super(
        id: 'local-$index',
        game: ChessGame.fromPgn(
          'local-$index',
          '[White "White $index"]\n[Black "Black $index"]\n\n1. e4 e5 *',
        ),
        rawPgn: '',
        sourcePath: 'never-read.pgn',
        sourceRelativePath: 'never-read.pgn',
        fileName: 'never-read.pgn',
        indexInFile: index,
        fileGameCount: 80386,
        hasMoves: true,
        pgnFingerprint: 'fingerprint-$index',
      );
  @override
  String get rawPgn => throw StateError('Paging must not hydrate PGN');
}

class _QueryRepository extends LocalChessDatabaseRepository {
  _QueryRepository()
    : super(database: () => throw StateError('No real storage'));
  int calls = 0;
  String? search;
  LocalChessGameFilter? filter;
  LocalChessGameSortDirection? sortDirection;
  String? playerFideId;
  @override
  Future<LocalChessGameQueryPage?> localDatabaseGamesPage({
    required String databasePath,
    String search = '',
    LocalChessGameSortField sortBy = LocalChessGameSortField.originalOrder,
    LocalChessGameSortDirection sortDirection = LocalChessGameSortDirection.asc,
    LocalChessGameFilter? filter,
    String? playerFideId,
    List<String> playerAliases = const [],
    required int pageNumber,
    required int pageSize,
  }) async {
    calls++;
    this.search = search;
    this.filter = filter;
    this.sortDirection = sortDirection;
    this.playerFideId = playerFideId;
    return LocalChessGameQueryPage(
      games: List.generate(
        (301 - pageNumber * pageSize).clamp(0, pageSize),
        (i) => _NoDiskGame(pageNumber * pageSize + i),
      ),
      totalCount: 301,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
  }
}

void main() {
  setUp(debugCloseLocalRawPgnCatalogs);
  tearDown(debugCloseLocalRawPgnCatalogs);

  test(
    'raw PGN catalog source keeps full headers in worker and pages after reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('raw-pgn-catalog-');
      try {
        final file = File('${dir.path}/catalog.pgn');
        await file.writeAsString([
          _catalogPgn('Zurich', 'Carlsen', 'Nakamura', '1-0', '2024.01.01'),
          _catalogPgn('London', 'Aronian', 'Caruana', '0-1', '2023.02.02'),
          _catalogPgn(
            'Wijk',
            'Gukesh',
            'Praggnanandhaa',
            '1/2-1/2',
            '2025.03.03',
          ),
          _catalogPgn('Oslo', 'Nakamura', 'So', '*', '2022.04.04'),
          _catalogPgn('Paris', 'Ju', 'Hou', '1-0', '2021.05.05'),
        ].join('\n\n'));

        final handle = await openLocalRawPgnCatalog(file.path);
        expect(handle.descriptor.totalGames, 5);
        final database = selectedLocalChessDatabaseFile(handle.source.root)!;
        expect(database.gameCount, 5);
        expect(database.games, isEmpty);
        expect(database.rawPgnCatalog, isNotNull);

        final page = await localRawPgnCatalogPage(
          LocalRawPgnCatalogPageQuery(
            descriptor: handle.descriptor,
            search: 'naka',
            sortBy: LocalChessGameSortField.date,
            sortDirection: LocalChessGameSortDirection.desc,
            pageNumber: 0,
            pageSize: 100,
          ),
        );
        expect(page, isNotNull);
        expect(page!.totalCount, 2);
        expect(page.games.map((game) => game.indexInFile), [0, 3]);
        expect(page.games.every((game) => !game.hasInlineRawPgn), isTrue);

        final source = LocalBoardGamesSource.query(
          path: file.path,
          totalCount: 2,
          rawPgnCatalog: handle.descriptor,
          search: 'naka',
          sortBy: LocalChessGameSortField.date,
          sortDirection: LocalChessGameSortDirection.desc,
          filter: LocalChessGameFilter(),
        );
        final restored = LocalBoardGamesSource.fromJson(source.toJson());
        handle.release();

        final boardPage = await restored.page(
          LocalChessDatabaseRepository(
            database:
                () => throw StateError('Raw PGN board paging must not import'),
          ),
          0,
        );
        expect(boardPage.map((game) => game.localPgnSource!.sourceIndex), [
          0,
          3,
        ]);
        expect(boardPage.every((game) => game.pgn == null), isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'raw PGN catalog open cancellation is per waiter and retryable',
    () async {
      final dir = await Directory.systemTemp.createTemp('raw-pgn-cancel-');
      try {
        final file = File('${dir.path}/catalog.pgn');
        await file.writeAsString([
          _catalogPgn('A', 'One', 'Two', '1-0', '2024.01.01'),
          _catalogPgn('B', 'Three', 'Four', '0-1', '2024.01.02'),
        ].join('\n\n'));

        final first = OperationCancellationToken();
        final second = OperationCancellationToken();
        final canceledOpen = openLocalRawPgnCatalog(
          file.path,
          cancellationToken: first,
          debugWorkerStartDelay: const Duration(milliseconds: 80),
        );
        final survivingOpen = openLocalRawPgnCatalog(
          file.path,
          cancellationToken: second,
          debugWorkerStartDelay: const Duration(milliseconds: 80),
        );
        first.cancel();
        await expectLater(canceledOpen, throwsA(isA<OperationCanceledException>()));
        final surviving = await survivingOpen;
        expect(surviving.descriptor.totalGames, 2);
        surviving.release();

        final only = OperationCancellationToken();
        final doomed = openLocalRawPgnCatalog(
          file.path,
          cancellationToken: only,
          debugWorkerStartDelay: const Duration(milliseconds: 120),
        );
        only.cancel();
        await expectLater(doomed, throwsA(isA<OperationCanceledException>()));

        final retried = await openLocalRawPgnCatalog(file.path);
        expect(retried.descriptor.totalGames, 2);
        retried.release();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'raw PGN catalog releases retained session when canceled during validation',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'raw-pgn-validate-cancel-',
      );
      try {
        final file = File('${dir.path}/catalog.pgn');
        await file.writeAsString([
          _catalogPgn('A', 'One', 'Two', '1-0', '2024.01.01'),
          _catalogPgn('B', 'Three', 'Four', '0-1', '2024.01.02'),
        ].join('\n\n'));

        final first = await openLocalRawPgnCatalog(
          file.path,
          debugValidationDelay: const Duration(milliseconds: 80),
        );
        first.release();
        expect(debugLocalRawPgnCatalogState(file.path)['refCount'], 0);

        final token = OperationCancellationToken();
        final canceled = openLocalRawPgnCatalog(
          file.path,
          cancellationToken: token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        token.cancel();

        await expectLater(canceled, throwsA(isA<OperationCanceledException>()));
        expect(debugLocalRawPgnCatalogState(file.path)['refCount'], 0);
        expect(debugLocalRawPgnCatalogState(file.path)['isIdle'], isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'raw PGN catalog idle LRU, TTL and source-byte budget close sessions',
    () async {
      final dir = await Directory.systemTemp.createTemp('raw-pgn-evict-');
      try {
        final files = <File>[];
        for (var i = 0; i < 3; i++) {
          final file = File('${dir.path}/catalog-$i.pgn');
          await file.writeAsString(
            _catalogPgn('E$i', 'W$i', 'B$i', '*', '2024.01.0${i + 1}'),
          );
          files.add(file);
        }

        for (final file in files) {
          final handle = await openLocalRawPgnCatalog(
            file.path,
            inactivityTimeout: const Duration(minutes: 5),
          );
          handle.release();
        }
        expect(debugLocalRawPgnCatalogState(files[0].path)['sessionCount'], 2);
        expect(debugLocalRawPgnCatalogState(files[0].path)['hasSession'], isFalse);
        expect(debugLocalRawPgnCatalogState(files[2].path)['hasSession'], isTrue);

        debugCloseLocalRawPgnCatalogs();
        final ttl = await openLocalRawPgnCatalog(
          files[0].path,
          inactivityTimeout: const Duration(milliseconds: 20),
        );
        ttl.release();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(debugLocalRawPgnCatalogState(files[0].path)['sessionCount'], 0);

        debugConfigureLocalRawPgnCatalogLimits(maxIdleSourceBytes: 1);
        final budget = await openLocalRawPgnCatalog(
          files[1].path,
          inactivityTimeout: const Duration(minutes: 5),
        );
        budget.release();
        expect(debugLocalRawPgnCatalogState(files[1].path)['sessionCount'], 0);
      } finally {
        debugConfigureLocalRawPgnCatalogLimits();
        await dir.delete(recursive: true);
      }
    },
  );

  test('raw PGN catalog pages cap size and reject stale descriptors', () async {
    final dir = await Directory.systemTemp.createTemp('raw-pgn-stale-');
    try {
      final file = File('${dir.path}/catalog.pgn');
      await file.writeAsString(List.generate(
        6,
        (i) => _catalogPgn('E$i', 'W$i', 'B$i', '*', '2024.01.0${i + 1}'),
      ).join('\n\n'));
      final handle = await openLocalRawPgnCatalog(file.path);
      final capped = await localRawPgnCatalogPage(
        LocalRawPgnCatalogPageQuery(
          descriptor: handle.descriptor,
          pageNumber: 0,
          pageSize: 500,
        ),
      );
      expect(capped, isNotNull);
      expect(capped!.pageSize, 200);
      expect(capped.games.length, 6);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await file.writeAsString(
        '${await file.readAsString()}\n\n${_catalogPgn('New', 'A', 'B', '*', '2024.01.09')}',
      );
      final stale = await localRawPgnCatalogPage(
        LocalRawPgnCatalogPageQuery(
          descriptor: handle.descriptor,
          pageNumber: 0,
          pageSize: 100,
        ),
      );
      expect(stale, isNull);
      handle.release();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'raw PGN catalog refuses old Board descriptor after same-size unsampled mutation',
    () async {
      final dir = await Directory.systemTemp.createTemp('raw-pgn-strong-stale-');
      try {
        final file = File('${dir.path}/catalog.pgn');
        await file.writeAsString(_largeCatalogPgn());
        final handle = await openLocalRawPgnCatalog(file.path);
        final descriptor = handle.descriptor;
        final source = LocalBoardGamesSource.query(
          path: file.path,
          totalCount: descriptor.totalGames,
          rawPgnCatalog: descriptor,
          search: '',
          sortBy: LocalChessGameSortField.originalOrder,
          sortDirection: LocalChessGameSortDirection.asc,
          filter: LocalChessGameFilter(),
        );
        handle.release();

        final originalStat = await file.stat();
        final bytes = await file.readAsBytes();
        bytes[100 * 1024] = 'b'.codeUnitAt(0);
        await file.writeAsBytes(bytes, flush: true);
        await file.setLastModified(originalStat.modified);
        expect((await file.stat()).size, originalStat.size);

        final direct = await localRawPgnCatalogPage(
          LocalRawPgnCatalogPageQuery(
            descriptor: descriptor,
            pageNumber: 0,
            pageSize: 100,
          ),
        );
        expect(direct, isNull);

        await expectLater(
          source.page(
            LocalChessDatabaseRepository(
              database: () => throw StateError('Raw PGN board paging must not import'),
            ),
            0,
          ),
          throwsA(isA<StateError>()),
        );

        final replacement = await openLocalRawPgnCatalog(file.path);
        expect(replacement.descriptor.sessionId, isNot(descriptor.sessionId));
        replacement.release();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test('opt-in real raw PGN catalog counts use separate fixtures', () async {
    final fixtures = <({String env, int count})>[
      (env: 'ERIC_REGRESSION_PGN', count: 61147),
      (env: 'NAKA_REGRESSION_PGN', count: 80386),
    ];
    for (final fixture in fixtures) {
      final path = Platform.environment[fixture.env]?.trim() ?? '';
      if (path.isEmpty) continue;
      final handle = await openLocalRawPgnCatalog(path);
      try {
        expect(
          handle.descriptor.totalGames,
          fixture.count,
          reason: fixture.env,
        );
        final page = await localRawPgnCatalogPage(
          LocalRawPgnCatalogPageQuery(
            descriptor: handle.descriptor,
            pageNumber: fixture.count ~/ 2 ~/ 100,
            pageSize: 100,
          ),
        );
        expect(page, isNotNull, reason: fixture.env);
        expect(page!.games, isNotEmpty, reason: fixture.env);
      } finally {
        handle.release();
      }
    }
  }, skip: Platform.environment['RUN_REAL_PGN_CATALOG_FIXTURES'] != '1');

  test(
    'indexed source keeps query scope and single-flight bounded pages',
    () async {
      final repository = _QueryRepository();
      final filter = LocalChessGameFilter(
        opponentName: 'Opponent',
        base: GameFilter(result: GameResultFilter.draw),
      );
      final source = LocalBoardGamesSource.query(
        path: 'query.pgn',
        totalCount: 301,
        search: 'needle',
        sortBy: LocalChessGameSortField.date,
        sortDirection: LocalChessGameSortDirection.desc,
        filter: filter,
        playerFideId: '123',
        playerAliases: ['Player'],
      );
      final restored = LocalBoardGamesSource.fromJson(source.toJson());
      expect(restored.filter, filter);
      final pages = await Future.wait([
        restored.page(repository, 2),
        restored.page(repository, 2),
      ]);
      expect(repository.calls, 1);
      expect(pages.first.length, 100);
      expect(repository.search, 'needle');
      expect(repository.filter, filter);
      expect(repository.sortDirection, LocalChessGameSortDirection.desc);
      expect(repository.playerFideId, '123');
      expect(restored.rankOf('local-299'), 299);
    },
  );

  testWidgets(
    'navigation crosses page boundary and survives an unmounted rail',
    (tester) async {
      final games = List.generate(301, _NoDiskGame.new);
      final source = LocalBoardGamesSource.catalog(games);
      source.rememberSelection(games[99].id, 99);
      late WidgetRef navigationRef;
      late BuildContext navigationContext;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            retainedLocalPgnHydratorProvider.overrideWithValue(
              (game) async => game.copyWith(pgn: '1. e4 e5 *'),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                navigationRef = ref;
                navigationContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(navigationContext);
      final tab = container.read(desktopTabsProvider).activeId!;
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        tab: BoardTabGameArgs(
          pgn: '1. e4 e5 *',
          label: 'Local',
          whiteName: 'White',
          blackName: 'Black',
          databaseTitle: 'Full source',
          databaseGames: [localBoardGameSummary(games[99])],
          databaseGamesContinuation: BoardTabGamesContinuation.localPgn(source),
          gameListSelectedId: games[99].id,
        ),
      };
      for (final step in [
        (1, 100),
        (-1, 99),
        (201, 300),
        (1, 300),
        (-300, 0),
        (-1, 0),
      ]) {
        await navigateActiveEventGame(
          navigationRef,
          context: navigationContext,
          delta: step.$1,
        );
        await tester.pump();
        final active = container.read(desktopTabsProvider).activeId!;
        final args = container.read(boardTabGameArgsByTabIdProvider)[active]!;
        expect(args.gameListSelectedId, games[step.$2].id);
        expect(args.databaseGamesContinuation!.argument, same(source));
        expect(args.databaseGames.length, lessThanOrEqualTo(100));
        expect(args.librarySaveOrigin?.sourceIndex, step.$2);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'catalog pages preserve physical identity and filtered reverse order without PGN reads',
    () async {
      final games =
          List.generate(301, (i) => _NoDiskGame(i * 2)).reversed.toList();
      final source = LocalBoardGamesSource.catalog(games);
      final repository = LocalChessDatabaseRepository(
        database: () => throw StateError('Catalog must not use cache'),
      );
      source.rememberSelection(games[150].id, 150);
      expect(source.totalCount, 301);
      for (final number in [0, 1, 3, 2, 0]) {
        final page = await source.page(repository, number);
        expect(page.length, number == 3 ? 1 : 100);
        expect(page.first.id, games[number * 100].id);
        expect(page.every((row) => row.pgn == null), isTrue);
        expect(
          page.first.localPgnSource!.sourceIndex,
          games[number * 100].indexInFile,
        );
        expect(page.first.localPgnSource!.sourceFileGameCount, 80386);
      }
      expect(source.rankOf(games[150].id), 150);
      final restored = LocalBoardGamesSource.fromJson(source.toJson());
      expect(restored.totalCount, 301);
      expect(restored.physicalOrder, games.map((g) => g.indexInFile));
      expect(restored.rankOf(games[150].id), 150);
    },
  );

  testWidgets(
    'rail exposes full count and bounded first previous next last pages',
    (tester) async {
      final games = List.generate(301, _NoDiskGame.new);
      final source = LocalBoardGamesSource.catalog(games);
      source.rememberSelection(games[150].id, 150);
      final args = BoardTabGameArgs(
        pgn: '1. e4 e5 *',
        label: 'Local',
        whiteName: 'White',
        blackName: 'Black',
        databaseTitle: 'Full source',
        databaseGames: [localBoardGameSummary(games[150])],
        databaseGamesContinuation: BoardTabGamesContinuation.localPgn(source),
        gameListSelectedId: games[150].id,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => {'tournaments-default': args},
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: EventGamesTable.width,
                child: const EventGamesTable(tabId: 'tournaments-default'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('100/301 games'), findsOneWidget);
      expect(find.text('Page 2 / 4'), findsOneWidget);
      expect(tester.getRect(find.text('Page 2 / 4')).top, greaterThan(550));
      expect(
        tester.widget<Text>(find.text('Next')).style?.color,
        isNot(kPrimaryColor),
      );
      final list =
          find
              .descendant(
                of: find.byType(EventGamesTable),
                matching: find.byType(ListView),
              )
              .first;
      await tester.drag(list, const Offset(0, -5000));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Next')).style?.color,
        kPrimaryColor,
      );
      expect(
        tester.widget<Text>(find.text('Previous')).style?.color,
        isNot(kPrimaryColor),
      );
      expect(find.text('Page 2 / 4'), findsOneWidget); // Never auto-advance.
      tester.widget<ListView>(list).controller!.jumpTo(500);
      await tester.pump();
      expect(
        tester.widget<Text>(find.text('Next')).style?.color,
        isNot(kPrimaryColor),
      );
      await tester.drag(list, const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Previous')).style?.color,
        kPrimaryColor,
      );
      final controller = tester.widget<ListView>(list).controller!;
      await tester.tap(find.text('Previous'));
      await tester.pumpAndSettle();
      expect(find.text('Page 1 / 4'), findsOneWidget);
      expect(controller.position.extentAfter, lessThanOrEqualTo(1));
      expect(
        tester.widget<Text>(find.text('Previous')).style?.color,
        isNot(kPrimaryColor),
      );
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 / 4'), findsOneWidget);
      expect(controller.offset, 0);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      expect(
        container.read(boardTabGameArgsByTabIdProvider)['tournaments-default'],
        same(args),
      );
      await tester.tap(find.byKey(const ValueKey('local-page-Last')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Page 4 / 4'), findsOneWidget);
      expect(find.text('1/301 games'), findsOneWidget);
      expect(find.text('White 300'), findsOneWidget);
      expect(
        tester
            .widget<FButton>(find.byKey(const ValueKey('local-page-Next')))
            .onPress,
        isNull,
      );
      await tester.drag(list, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Next')).style?.color,
        isNot(kPrimaryColor),
      );
      expect(
        tester.widget<Text>(find.text('Previous')).style?.color,
        isNot(kPrimaryColor),
      );
      await tester.tap(find.text('Previous'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Page 3 / 4'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-page-First')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Page 1 / 4'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Page 2 / 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pager disables pending requests, retries failures and ignores duplicate clicks',
    (tester) async {
      final games = List.generate(301, _NoDiskGame.new);
      final source = LocalBoardGamesSource.catalog(games);
      final pending = Completer<List<TournamentGameSummary>>();
      var attempts = 0;
      final args = BoardTabGameArgs(
        pgn: '1. e4 e5 *',
        label: 'Local',
        whiteName: 'White',
        blackName: 'Black',
        databaseTitle: 'Full source',
        databaseGames: [localBoardGameSummary(games.first)],
        databaseGamesContinuation: BoardTabGamesContinuation.localPgn(source),
        gameListSelectedId: games.first.id,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => {'tournaments-default': args},
            ),
            localBoardGamesPageProvider.overrideWith((ref, key) async {
              if (key.page == 1) {
                attempts++;
                if (attempts == 1) return pending.future;
              }
              return games
                  .skip(key.page * 100)
                  .take(100)
                  .map(localBoardGameSummary)
                  .toList();
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: EventGamesTable(tabId: 'tournaments-default'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      FButton button(String name) =>
          tester.widget<FButton>(find.byKey(ValueKey('local-page-$name')));
      expect(button('Previous').onPress, isNull);
      expect(button('First').onPress, isNull);
      final next = button('Next').onPress!;
      next();
      next(); // Same frame: this must not skip a page.
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('local-page-footer')),
          matching: find.text('Loading…'),
        ),
        findsOneWidget,
      );
      for (final name in ['First', 'Previous', 'Next', 'Last']) {
        expect(button(name).onPress, isNull);
      }
      expect(attempts, 1);
      pending.completeError(StateError('page unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Could not load page · Retry'), findsOneWidget);
      await tester.tap(find.text('Could not load page · Retry'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Page 2 / 4'), findsOneWidget);
      expect(find.text('White 100'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      expect(
        container.read(boardTabGameArgsByTabIdProvider)['tournaments-default'],
        same(args),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'large page labels fit narrow rail and pager supports keyboard activation',
    (tester) async {
      final games = List.generate(100, _NoDiskGame.new);
      final source = LocalBoardGamesSource.query(
        path: 'never-read.pgn',
        totalCount: 80382,
        search: '',
        sortBy: LocalChessGameSortField.originalOrder,
        sortDirection: LocalChessGameSortDirection.asc,
        filter: LocalChessGameFilter(),
      );
      source.rememberSelection(games.first.id, 62000);
      final args = BoardTabGameArgs(
        pgn: '1. e4 e5 *',
        label: 'Local',
        whiteName: 'White',
        blackName: 'Black',
        databaseTitle: 'Full source',
        databaseGames: [localBoardGameSummary(games.first)],
        databaseGamesContinuation: BoardTabGamesContinuation.localPgn(source),
        gameListSelectedId: games.first.id,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => {'tournaments-default': args},
            ),
            localBoardGamesPageProvider.overrideWith(
              (ref, key) async => games.map(localBoardGameSummary).toList(),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: EventGamesTable(tabId: 'tournaments-default'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page 621 / 804'), findsOneWidget);
      final footer = tester.getRect(
        find.byKey(const ValueKey('local-page-footer')),
      );
      for (final label in ['First', 'Previous', 'Next', 'Last']) {
        final rect = tester.getRect(find.byKey(ValueKey('local-page-$label')));
        expect(rect.left, greaterThanOrEqualTo(footer.left));
        expect(rect.right, lessThanOrEqualTo(footer.right));
        expect(rect.height, greaterThanOrEqualTo(32));
      }
      Focus.of(tester.element(find.text('Next'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Page 622 / 804'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  final actualPath = Platform.environment['REGRESSION_PGN'];
  test(
    'actual 80386 source page beginning middle end retain source coordinates',
    () async {
      final source = await scanLocalChessPgnCatalog(
        actualPath!,
        maxGames: 2147483647,
      );
      final games = source.root.files.single.games;
      expect(games.length, 80386);
      final context = LocalBoardGamesSource.catalog(games);
      final repository = LocalChessDatabaseRepository(
        database: () => throw StateError('Catalog must not use cache'),
      );
      for (final number in [0, 401, 803]) {
        final page = await context.page(repository, number);
        expect(page.length, number == 803 ? 86 : 100);
        expect(page.first.id, games[number * 100].id);
        expect(page.first.localPgnSource!.sourceIndex, number * 100);
        expect(page.every((g) => g.pgn == null), isTrue);
        final selected = await context.prepareSelection(repository, page.first);
        expect(selected.localPgnSource!.pgnFingerprint, isNotEmpty);
        expect(selected.localPgnSource!.recordRevision, isNotEmpty);
        expect(selected.pgn, isNotEmpty);
        expect(selected.localPgnSource!.sourceIndex, number * 100);
      }
    },
    skip: actualPath == null,
  );
}

String _catalogPgn(
  String event,
  String white,
  String black,
  String result,
  String date,
) {
  return '''
[Event "$event"]
[Site "?"]
[Date "$date"]
[Round "?"]
[White "$white"]
[Black "$black"]
[Result "$result"]

1. e4 e5 $result
'''
      .trim();
}

String _largeCatalogPgn() {
  final padding = 'a' * (420 * 1024);
  return '''
[Event "Large"]
[Site "?"]
[Date "2024.01.01"]
[Round "?"]
[White "Alpha"]
[Black "Beta"]
[Result "*"]

1. e4 {$padding} e5 *

${_catalogPgn('Second', 'Gamma', 'Delta', '*', '2024.01.02')}
'''
      .trim();
}
