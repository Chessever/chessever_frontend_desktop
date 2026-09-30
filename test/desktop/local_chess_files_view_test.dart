import 'package:resqlite/resqlite.dart' as resqlite;
import 'dart:async';
import 'package:chessever/theme/app_theme.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/desktop/state/local_game_grid_layout.dart';
import 'package:chessever/desktop/state/local_board_games.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'dart:io';
import 'package:chessever/desktop/widgets/event_games_table.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/desktop_premium_test_overrides.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/widgets/library/local_chess_files_view.dart';
import 'package:chessever/desktop/widgets/library/local_tree_action_button.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  testWidgets('setup-only actual record keeps full-source Board identity', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late LocalChessSource source;
    await tester.runAsync(() async {
      source = await scanLocalChessPgnCatalog(Platform.environment['SETUP_POSITION_PGN']!);
    });
    final games = source.root.files.single.games;
    expect(games, hasLength(42));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(_GridPreferences()),
        ...desktopPremiumTestOverrides,
      ],
      child: FTheme(data: FThemes.zinc.dark, child: FToaster(child: MaterialApp(
        home: Scaffold(body: LocalChessFilesView(
          selectedPath: source.root.files.single.path,
          onSelectPath: (_) {},
          stateOverride: LocalChessLibraryState(source: source, selectedPath: source.root.files.single.path),
        )),
      ))),
    ));
    await tester.pump();
    final row = find.byKey(ValueKey('local-game-table-${games[3].id}'));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 250));
    final container = ProviderScope.containerOf(tester.element(find.byType(LocalChessFilesView)));
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, isNull);
    expect(args.gameListSelectedId, games[3].id);
    expect(args.librarySaveOrigin!.sourceIndex, 3);
    expect(args.librarySaveOrigin!.sourceFileGameCount, 42);
    expect(args.librarySaveOrigin!.sourcePgnFingerprint, isNotEmpty);
    expect(args.librarySaveOrigin!.sourceRecordRevision, isNotEmpty);
    expect(args.databaseGamesContinuation, isNotNull);
    final continuation = args.databaseGamesContinuation!.argument as LocalBoardGamesSource;
    expect(continuation.totalCount, 42);
    final repository = LocalChessDatabaseRepository(database: () => throw StateError('No cache access expected'));
    await tester.runAsync(() async {
      final page = await continuation.page(repository, 0);
      expect(page, hasLength(42));
      expect(page[3].hasPgn, isTrue);
      expect(page[3].hasStarted, isFalse);
      expect(page.last.localPgnSource!.sourceIndex, 41);
      final selected = await continuation.prepareSelection(repository, page[3]);
      final hydrated = await hydrateRetainedLocalPgn(selected);
      expect(hydrated.id, args.gameListSelectedId);
      expect(hydrated.localPgnSource!.sourceIndex, 3);
      expect(hydrated.localPgnSource!.sourceFileGameCount, 42);
      expect(hydrated.pgn, args.pgn);
    });
    expect(ChessGame.fromPgn('opened', args.pgn).mainline, isEmpty);
    expect(args.fenSeed, Platform.environment['SETUP_POSITION_FEN']);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: Platform.environment['SETUP_POSITION_PGN'] == null);

  testWidgets('pending cache preview cannot become a truncated Board source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = _localGame(
      id: 'preview',
      white: 'Preview',
      black: 'Opponent',
      sourcePath: '/tmp/view.pgn',
    );
    final source = _sourceWithGame(game, gameCount: 301);
    final pending = Completer<LocalChessGameQueryPage>();
    final repository = _FakeLocalChessDatabaseRepository(
      pageForQuery: (_) => pending.future,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
          ...desktopPremiumTestOverrides,
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
        ],
        child: FTheme(data: FThemes.zinc.dark, child: FToaster(child: MaterialApp(
          home: Scaffold(
            body: LocalChessFilesView(
              selectedPath: source.root.files.single.path,
              onSelectPath: (_) {},
              stateOverride: LocalChessLibraryState(
                source: source,
                selectedPath: source.root.files.single.path,
              ),
            ),
          ),
        ))),
      ),
    );
    await tester.pump();
    final row = find.byKey(const ValueKey('local-game-table-preview'));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(row);
    await tester.pump(const Duration(milliseconds: 250));
    final c = ProviderScope.containerOf(
      tester.element(find.byType(LocalChessFilesView)),
    );
    expect(c.read(boardTabGameArgsByTabIdProvider), isEmpty);
    expect(
      find.text(
        'The full database list is still loading. Please try again shortly.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'regression actual full source remains available from Board',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late LocalChessSource source;
      await tester.runAsync(() async {
        source = await scanLocalChessPgnCatalog(
          Platform.environment['REGRESSION_PGN']!,
          maxGames: 2147483647,
        );
      });
      final games = source.root.files.single.games;
      debugPrint('REGRESSION source physical count=${games.length}');
      final watch = Stopwatch()..start();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(_GridPreferences()),
            ...desktopPremiumTestOverrides,
            localChessLibraryProvider.overrideWith(
              (ref) => LocalChessLibraryNotifier(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LocalChessFilesView(
                selectedPath: source.root.files.single.path,
                onSelectPath: (_) {},
                stateOverride: LocalChessLibraryState(
                  source: source,
                  selectedPath: source.root.files.single.path,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      debugPrint('REGRESSION initial UI pump ms=${watch.elapsedMilliseconds}');
      final row = find.byKey(ValueKey('local-game-table-${games[1].id}'));
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 50));
      watch.reset();
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 250));
      debugPrint(
        'REGRESSION actual table open ms=${watch.elapsedMilliseconds}',
      );
      final c = ProviderScope.containerOf(
        tester.element(find.byType(LocalChessFilesView)),
      );
      final args = c.read(boardTabGameArgsByTabIdProvider).values.single;
      debugPrint(
        'REGRESSION Board args count=${args.databaseGames.length} continuation=${args.databaseGamesContinuation} pagination=${args.databaseGamesPagination} selected=${args.gameListSelectedId}',
      );
      expect(args.gameListSelectedId, games[1].id);
      expect(args.librarySaveOrigin!.sourceIndex, 1);
      expect(args.librarySaveOrigin!.sourceFileGameCount, games.length);
      expect(
        args.databaseGames.length == games.length ||
            args.databaseGamesContinuation != null ||
            args.databaseGamesPagination != null,
        isTrue,
        reason:
            'The source rail must not terminate at the bounded context window',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: Platform.environment['REGRESSION_PGN'] == null,
  );

  final gridPgn = Platform.environment['LOCAL_GRID_ACCEPTANCE_PGN'];
  testWidgets(
    'actual production PGN metadata and sparse rows align in exact local grid',
    (tester) async {
      tester.view.physicalSize = const Size(1800, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late LocalChessSource catalog;
      await tester.runAsync(() async {
        final loader = FontLoader(
          'Geist',
        )..addFont(rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'));
        await loader.load();
        // Load the actual Forui font for this opt-in visual fixture;
        // unregistered package fonts otherwise render as Ahem squares.
        await (FontLoader('packages/forui/Inter')
              ..addFont(
                rootBundle.load(
                  'packages/forui/assets/fonts/inter/Inter-Regular.ttf',
                ),
              )
              ..addFont(
                rootBundle.load(
                  'packages/forui/assets/fonts/inter/Inter-Bold.ttf',
                ),
              ))
            .load();
        await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        catalog = await scanLocalChessPgnCatalog(gridPgn!);
      });
      final games = catalog.root.files.single.games;
      expect(games, isNotEmpty);
      final source = _sourceWithGame(games.first, gameCount: games.length);
      final repo = _FakeLocalChessDatabaseRepository(
        page: LocalChessGameQueryPage(
          games: games,
          totalCount: games.length,
          pageNumber: 0,
          pageSize: 200,
        ),
      );
      final capture = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(_GridPreferences()),
            localChessDatabaseRepositoryProvider.overrideWithValue(repo),
            localChessLibraryProvider.overrideWith(
              (ref) => LocalChessLibraryNotifier(),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: capture,
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
      await tester.pump(const Duration(milliseconds: 100));
      final tables = tester.widgetList<Table>(find.byType(Table)).toList();
      for (final row in tables.skip(1)) {
        for (var i = 0; i < 11; i++) {
          final h = tester.getRect(
            find.byWidget(tables.first.children.single.children[i]),
          );
          final r = tester.getRect(
            find.byWidget(row.children.single.children[i]),
          );
          expect(r.left, closeTo(h.left, .1));
          expect(r.width, closeTo(h.width, .1));
        }
      }
      final visibleIds =
          tester
              .widgetList(
                find.byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      (w.key as ValueKey<String>).value.startsWith(
                        'local-game-table-',
                      ),
                ),
              )
              .map(
                (w) => (w.key as ValueKey<String>).value.substring(
                  'local-game-table-'.length,
                ),
              )
              .toSet();
      final visible = games.where((g) => visibleIds.contains(g.id));
      expect(visible, isNotEmpty);
      for (final g in visible) {
        final annotator = (g.game.metadata['Annotator'] ?? '').toString();
        if (annotator.isNotEmpty) expect(find.text(annotator), findsWidgets);
      }
      expect(tester.takeException(), isNull);

      final output = Platform.environment['LOCAL_GRID_CAPTURE'];
      if (output != null) {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LocalChessFilesView)),
        );
        final layout = container.read(localGameGridLayoutProvider);
        container
            .read(localGameGridLayoutProvider.notifier)
            .update(
              layout.copyWith(
                order: [
                  ...layout.order.where(
                    (id) => id != 'date' && id != 'opening',
                  ),
                  'date',
                  'opening',
                ],
                widths: {...layout.widths, 'date': 300},
              ),
            );
        await tester.pumpAndSettle();
        await tester.tap(find.text('DATE'));
        await tester.pumpAndSettle();
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(output).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
    skip: gridPgn == null,
  );

  testWidgets('local grid gestures preserve sparse cells, order and geometry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = _localGame(
      id: 'grid',
      sourcePath: '/tmp/view.pgn',
      white: 'Karo',
      black: '5.Vg4!?',
      metadataOverrides: {
        'WhiteElo': '',
        'BlackElo': '',
        'Event': '',
        'Date': '2020.02.24',
        'Annotator': 'Durarbayli Vasif',
      },
    );
    final source = _sourceWithGame(game, gameCount: 3);
    final repo = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: [game],
        totalCount: 3,
        pageNumber: 0,
        pageSize: 200,
      ),
    );
    final db = _GridPreferences();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          localChessDatabaseRepositoryProvider.overrideWithValue(repo),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LocalChessFilesView(
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
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LocalChessFilesView)),
    );
    void geometry() {
      final tables = tester.widgetList<Table>(find.byType(Table)).toList();
      final headers = tables.first.children.single.children;
      for (final row in tables.skip(1)) {
        expect(row.children.single.children.length, headers.length);
        for (var i = 0; i < headers.length; i++) {
          final h = tester.getRect(find.byWidget(headers[i]));
          final r = tester.getRect(
            find.byWidget(row.children.single.children[i]),
          );
          expect(r.left, closeTo(h.left, .1));
          expect(r.width, closeTo(h.width, .1));
        }
      }
      expect(tester.takeException(), isNull);
    }

    expect(
      tester
          .getSize(
            find.byWidget(
              tester
                  .widget<Table>(find.byType(Table).first)
                  .children
                  .single
                  .children[3],
            ),
          )
          .width,
      greaterThanOrEqualTo(72),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('local-column-resizer-white')))
          .height,
      42,
    );
    expect(find.text('Durarbayli Vasif'), findsOneWidget);
    expect(find.text('5.Vg4!?'), findsOneWidget);
    geometry();
    for (final id in localGameGridColumns) {
      final handle = find.byKey(ValueKey('local-column-resizer-$id'));
      await tester.ensureVisible(handle);
      await tester.drag(handle, const Offset(35, 0));
      await tester.pump();
      geometry();
    }
    // A saved width is not an active resize. Real mouse enter/exit and
    // dragging outside the header must be the only edge highlights.
    Color edgeColor(String id) =>
        (tester
                    .widget<AnimatedContainer>(
                      find.descendant(
                        of: find.byKey(ValueKey('local-column-resizer-$id')),
                        matching: find.byType(AnimatedContainer),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    final whiteEdge = find.byKey(const ValueKey('local-column-resizer-white'));
    await tester.ensureVisible(whiteEdge);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(edgeColor('white'), kDividerColor);
    await mouse.moveTo(tester.getCenter(whiteEdge));
    await tester.pumpAndSettle();
    expect(edgeColor('white'), kPrimaryColor);
    expect(edgeColor('black'), kDividerColor);
    await mouse.moveTo(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(edgeColor('white'), kDividerColor);
    await mouse.down(tester.getCenter(whiteEdge));
    await mouse.moveBy(const Offset(30, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(20, 80));
    await tester.pumpAndSettle();
    expect(edgeColor('white'), kPrimaryColor);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(edgeColor('white'), kDividerColor);
    await mouse.removePointer();
    final queriesBefore = repo.queries.length;
    await tester.ensureVisible(find.text('WHITE'));
    final from = tester.getCenter(find.text('WHITE'));
    final to = tester.getCenter(find.text('BLACK'));
    await tester.dragFrom(from, to - from);
    await tester.pump();
    expect(
      container.read(localGameGridLayoutProvider).order.indexOf('white'),
      greaterThan(
        container.read(localGameGridLayoutProvider).order.indexOf('black'),
      ),
    );
    expect(repo.queries.length, queriesBefore, reason: 'drag must not sort');
    geometry();
    // Put Date before Opening, as in the reported customized layout.
    await tester.dragFrom(
      tester.getCenter(find.text('DATE')),
      tester.getCenter(find.text('OPENING')) -
          tester.getCenter(find.text('DATE')),
    );
    await tester.pump();
    geometry();
    double glyphX(Finder text) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)).first,
      );
      return paragraph
          .localToGlobal(
            paragraph
                .getBoxesForSelection(
                  const TextSelection(baseOffset: 0, extentOffset: 1),
                )
                .first
                .toRect()
                .topLeft,
          )
          .dx;
    }

    final dateX = glyphX(find.text('2020.02.24'));
    final headerX = glyphX(find.text('DATE'));
    final openingX = glyphX(find.text('OPENING'));
    expect(dateX, closeTo(headerX, .5)); // Header letter spacing adds .2px.
    final dateEdge = find.byKey(const ValueKey('local-column-resizer-date'));
    await tester.drag(dateEdge, const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(glyphX(find.text('2020.02.24')), closeTo(dateX, .1));
    expect(glyphX(find.text('DATE')), closeTo(headerX, .1));
    expect(glyphX(find.text('OPENING')), greaterThan(openingX + 100));
    await tester.tap(find.text('DATE'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('DATE')).style!.color, kPrimaryColor);
    expect(tester.widget<Text>(find.text('#')).style!.color, kLightGreyColor);
    expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.arrow_drop_down)).color,
      kPrimaryColor,
    );
    await tester.tap(find.text('DATE'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.arrow_drop_up), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    await tester.tap(find.text('WHITE'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('DATE')).style!.color,
      kLightGreyColor,
    );
    expect(tester.widget<Text>(find.text('WHITE')).style!.color, kPrimaryColor);
    expect(find.byIcon(Icons.arrow_drop_up), findsOneWidget);
    geometry();
    final handle = find.byKey(const ValueKey('local-column-resizer-white'));
    await tester.ensureVisible(handle);
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(handle);
    await tester.pump();
    expect(
      container.read(localGameGridLayoutProvider).widths['white'],
      lessThan(200),
    );
    geometry();
    await tester.tap(find.text('Columns'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Event'));
    await tester.pumpAndSettle();
    expect(find.text('EVENT'), findsNothing);
    geometry();
    tester.view.physicalSize = const Size(700, 900);
    await tester.pump();
    await tester.ensureVisible(find.text('ANNOTATOR'));
    await tester.pump();
    geometry();
    expect(tester.getRect(find.text('ANNOTATOR')).right, lessThan(701));
    final saved = LocalGameGridLayout.fromJson(db.value);
    expect(saved.hidden, contains('event'));
    expect(
      saved.widths['white'],
      container.read(localGameGridLayoutProvider).widths['white'],
    );
    final mountedGrid = tester.widget<ProviderScope>(
      find.byType(ProviderScope).first,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(mountedGrid);
    await tester.pumpAndSettle();
    final reopened = ProviderScope.containerOf(
      tester.element(find.byType(LocalChessFilesView)),
    );
    expect(reopened.read(localGameGridLayoutProvider).order, saved.order);
    expect(reopened.read(localGameGridLayoutProvider).widths, saved.widths);
    expect(reopened.read(localGameGridLayoutProvider).hidden, saved.hidden);
    expect(edgeColor('date'), kDividerColor);
    geometry();
    await tester.tap(find.text('Columns'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset columns'));
    await tester.pumpAndSettle();
    expect(
      reopened.read(localGameGridLayoutProvider).order,
      localGameGridColumns,
    );
    expect(reopened.read(localGameGridLayoutProvider).widths, isEmpty);
    expect(find.text('EVENT'), findsOneWidget);
    geometry();
  });

  final actualPgn = Platform.environment['CBH_ACCEPTANCE_PGN'];
  testWidgets(
    'real Son table opener and rail preserve physical 1424-1426 labels',
    (tester) async {
      late LocalChessSource catalog;
      await tester.runAsync(() async {
        catalog = await scanLocalChessPgnCatalog(actualPgn!);
      });
      final entries = catalog.root.files.single.games.sublist(1423, 1426);
      // A paged catalog shell; row data and physical identity are the real scan.
      final source = _sourceWithGame(entries.first, gameCount: 1436);
      final repository = _FakeLocalChessDatabaseRepository(
        page: LocalChessGameQueryPage(
          games: entries,
          totalCount: 3,
          pageNumber: 0,
          pageSize: 200,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(_GridPreferences()),
            localChessDatabaseRepositoryProvider.overrideWithValue(repository),
            localChessLibraryProvider.overrideWith(
              (ref) => LocalChessLibraryNotifier(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LocalChessFilesView(
                selectedPath: source.root.files.single.path,
                onSelectPath: (_) {},
                stateOverride: LocalChessLibraryState(
                  source: source,
                  selectedPath: source.root.files.single.path,
                ),
                onRefreshOverride: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('French, D'), findsOneWidget);
      expect(find.text('Nc3 Bb4 Bd2'), findsOneWidget);
      expect(find.text('White ?'), findsNWidgets(2));
      expect(find.text('Black ?'), findsNWidgets(2));
      // Open physical #1426 through the actual table handler, not a hand-built summary.
      final pick = find.text('White ?').last;
      await tester.tap(pick);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(pick);
      await tester.pump(const Duration(milliseconds: 250));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalChessFilesView)),
      );
      final args =
          container.read(boardTabGameArgsByTabIdProvider).values.single;
      expect(args.gameListSelectedId, entries.last.id);
      expect(args.librarySaveOrigin!.sourceIndex, 1425);
      expect(args.librarySaveOrigin!.sourceFileGameCount, 1436);
      expect(args.pgn.trim(), entries.last.rawPgn.trim());
      expect(args.databaseGames.map((g) => g.id), entries.map((e) => e.id));
      expect(args.databaseGames.map((g) => g.localPgnSource!.sourceIndex), [
        1423,
        1424,
        1425,
      ]);
      expect(args.databaseGames.map((g) => g.whitePlayer), [
        'French, D',
        '?',
        '?',
      ]);
      expect(args.databaseGames.map((g) => g.blackPlayer), [
        'Nc3 Bb4 Bd2',
        '?',
        '?',
      ]);
      expect(args.databaseGames.map((g) => g.openingName), [
        'C17',
        'A18',
        'A68',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(_GridPreferences()),
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => {'tournaments-default': args},
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 373,
                child: EventGamesTable(tabId: 'tournaments-default'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('French, D'), findsOneWidget);
      expect(find.text('Nc3 Bb4 Bd2'), findsOneWidget);
      expect(find.text('White ?'), findsNWidgets(2));
      expect(find.text('Black ?'), findsNWidgets(2));
      expect(find.textContaining('· Game #'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    skip: actualPgn == null,
  );

  test('header-only player games preserve Overview filters without SQLite', () {
    final game = _localGame(
      id: 'direct-filter',
      white: 'Hikaru',
      black: 'Opponent',
      sourcePath: '/tmp/direct.pgn',
      metadataOverrides: const <String, String>{
        'WhiteFideId': '2016192',
        'Result': '1-0',
        'Site': 'https://chess.com/game/1',
        'TimeControl': '180+2',
        'ECO': 'B90',
      },
    );
    const fideId = '2016192';
    const aliases = <String>['Hikaru Nakamura', 'Hikaru'];

    expect(
      localChessGameMatchesFilter(
        game,
        localChessGameFilterFromOverview(
          const PlayerOverviewFilterRequest(
            facet: PlayerOverviewFilterFacet.wins,
          ),
        ),
        playerFideId: fideId,
        playerAliases: aliases,
      ),
      isTrue,
    );
    expect(
      localChessGameMatchesFilter(
        game,
        localChessGameFilterFromOverview(
          const PlayerOverviewFilterRequest(
            facet: PlayerOverviewFilterFacet.asBlack,
          ),
        ),
        playerFideId: fideId,
        playerAliases: aliases,
      ),
      isFalse,
    );
    expect(
      localChessGameMatchesFilter(
        game,
        localChessGameFilterFromOverview(
          const PlayerOverviewFilterRequest(
            facet: PlayerOverviewFilterFacet.timeControl,
            timeControlCategory: 'blitz',
          ),
        ),
        playerFideId: fideId,
        playerAliases: aliases,
      ),
      isTrue,
    );
  });

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
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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
                showLatestGamesFirst: true,
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
    expect(repository.queries.single.sortBy, LocalChessGameSortField.date);
    expect(
      repository.queries.single.sortDirection,
      LocalChessGameSortDirection.desc,
    );
    expect(repository.queries.single.pageSize, 200);
    expect(find.byIcon(Icons.unfold_more_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
    expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('local-column-resizer-date')),
      findsOneWidget,
    );
    expect(find.text('ANNOTATOR'), findsOneWidget);
    // Every formerly flexible column must keep the header and rows aligned.
    for (final name in ['white', 'black', 'event', 'opening']) {
      final handle = find.byKey(ValueKey('local-column-resizer-$name'));
      await tester.ensureVisible(handle);
      await tester.drag(handle, const Offset(75, 0));
      await tester.pump();
      final tables = find.byType(Table);
      final header = tester.getRect(tables.first);
      final row = tester.getRect(tables.at(1));
      expect(header.left, closeTo(row.left, 0.1));
      expect(header.width, closeTo(row.width, 0.1));
    }

    // Local PGN player labels retain their source spelling.
    expect(find.text('Database Only'), findsOneWidget);
    expect(find.text('Hou, Yifan'), findsNothing);

    await tester.ensureVisible(find.text('WHITE'));
    await tester.tap(find.text('WHITE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(repository.queries.last.sortBy, LocalChessGameSortField.white);
    expect(
      repository.queries.last.sortDirection,
      LocalChessGameSortDirection.asc,
    );

    await tester.ensureVisible(find.text('DATE'));
    await tester.tap(find.text('DATE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(repository.queries.last.sortBy, LocalChessGameSortField.date);
    expect(
      repository.queries.last.sortDirection,
      LocalChessGameSortDirection.desc,
    );

    await tester.enterText(find.byType(TextField), 'database only');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repository.queries.last.search, 'database only');
    expect(find.text('Database Only'), findsOneWidget);
    expect(find.text('1 / 42 entries'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('local PGN row menus offer paste games', (tester) async {
    final game = _localGame(
      id: 'database',
      white: 'Database Only',
      black: 'Gukesh, D',
      sourcePath: '/tmp/view.pgn',
    );
    final source = _sourceWithGame(game, gameCount: 1);
    final repository = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: <LocalChessGame>[game],
        totalCount: 1,
        pageNumber: 0,
        pageSize: 1,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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

    await tester.tapAt(
      tester.getCenter(find.text('Database Only')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Copy PGN'), findsOneWidget);
    expect(find.text('Paste games'), findsOneWidget);
    expect(find.text('Delete game'), findsOneWidget);
  });

  testWidgets('Shift-click selects an inclusive local database range', (
    tester,
  ) async {
    final games = List<LocalChessGame>.generate(
      3,
      (index) => _localGame(
        id: 'database-$index',
        white: 'Database Player $index',
        black: 'Opponent $index',
        sourcePath: '/tmp/view.pgn',
        indexInFile: index,
      ),
    );
    final source = _sourceWithGame(games.first, gameCount: games.length);
    final repository = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: games,
        totalCount: games.length,
        pageNumber: 0,
        pageSize: games.length,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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

    final firstRow = find.byKey(
      const ValueKey<String>('local-game-table-database-0'),
    );
    final middleRow = find.byKey(
      const ValueKey<String>('local-game-table-database-1'),
    );
    final lastRow = find.byKey(
      const ValueKey<String>('local-game-table-database-2'),
    );
    tester
        .widget<GestureDetector>(
          find.descendant(of: firstRow, matching: find.byType(GestureDetector)),
        )
        .onTapDown!(TapDownDetails());
    await tester.pump();
    expect((tester.widget(firstRow) as dynamic).selected, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(
      HardwareKeyboard.instance.logicalKeysPressed,
      contains(LogicalKeyboardKey.shiftLeft),
    );
    tester
        .widget<GestureDetector>(
          find.descendant(of: lastRow, matching: find.byType(GestureDetector)),
        )
        .onTapDown!(TapDownDetails());
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect((tester.widget(firstRow) as dynamic).selected, isTrue);
    expect((tester.widget(middleRow) as dynamic).selected, isTrue);
    expect((tester.widget(lastRow) as dynamic).selected, isTrue);
  });

  testWidgets('Ctrl-click additively selects local database rows', (
    tester,
  ) async {
    final games = List<LocalChessGame>.generate(
      3,
      (index) => _localGame(
        id: 'database-$index',
        white: 'Database Player $index',
        black: 'Opponent $index',
        sourcePath: '/tmp/view.pgn',
        indexInFile: index,
      ),
    );
    final source = _sourceWithGame(games.first, gameCount: games.length);
    final repository = _FakeLocalChessDatabaseRepository(
      page: LocalChessGameQueryPage(
        games: games,
        totalCount: games.length,
        pageNumber: 0,
        pageSize: games.length,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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

    Finder row(String id) =>
        find.byKey(ValueKey<String>('local-game-table-$id'));
    void tapRow(Finder finder) {
      tester
          .widget<GestureDetector>(
            find.descendant(of: finder, matching: find.byType(GestureDetector)),
          )
          .onTapDown!(TapDownDetails());
    }

    final firstRow = row('database-0');
    final middleRow = row('database-1');
    final lastRow = row('database-2');
    tapRow(firstRow);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    tapRow(lastRow);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect((tester.widget(firstRow) as dynamic).selected, isTrue);
    expect((tester.widget(middleRow) as dynamic).selected, isFalse);
    expect((tester.widget(lastRow) as dynamic).selected, isTrue);
  });

  testWidgets(
    'showCountMeta:false hides the header entries/indexed-positions line',
    (tester) async {
      final treeIndex = _usableTreeIndex();
      expect(treeIndex.positionCount, greaterThan(0));
      final source = _sourceWithGame(
        _localGame(
          id: 'fallback',
          white: 'Hou, Yifan',
          black: 'Gukesh, D',
          sourcePath: '/tmp/view.pgn',
        ),
        gameCount: 42,
        openingTreeIndex: treeIndex,
      );
      final repository = _FakeLocalChessDatabaseRepository(
        page: LocalChessGameQueryPage(
          games: <LocalChessGame>[
            _localGame(
              id: 'database',
              white: 'Database Only',
              black: 'Gukesh, D',
              sourcePath: '/tmp/view.pgn',
            ),
          ],
          totalCount: 1,
          pageNumber: 0,
          pageSize: 1,
        ),
      );

      Widget build({required bool showCountMeta}) => ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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
                showCountMeta: showCountMeta,
              ),
            ),
          ),
        ),
      );

      // Default (Library) keeps the entry count but never the internal
      // "indexed positions" metric, even with a populated tree index.
      await tester.pumpWidget(build(showCountMeta: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('42 entries'), findsOneWidget);
      expect(find.textContaining('indexed positions'), findsNothing);

      // Embedded (Players Games tab) suppresses the redundant count line while
      // still rendering the rows.
      await tester.pumpWidget(build(showCountMeta: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('42 entries'), findsNothing);
      expect(find.textContaining('indexed positions'), findsNothing);
      expect(find.text('Database Only'), findsOneWidget);
    },
  );

  testWidgets('idle large jump resolves both sides of page boundary', (
    tester,
  ) async {
    final source = _sourceWithGame(
      _localGame(
        id: 'fallback',
        white: 'Fallback',
        black: 'Player',
        sourcePath: '/tmp/view.pgn',
      ),
      gameCount: 2691,
    );
    final pending = <int, Completer<LocalChessGameQueryPage>>{};
    LocalChessGameQueryPage page(int number) => LocalChessGameQueryPage(
      games: List.generate((2691 - number * 200).clamp(0, 200), (i) {
        final index = number * 200 + i;
        return _localGame(
          id: 'database-$index',
          white: 'Database $index',
          black: 'Player',
          sourcePath: '/tmp/view.pgn',
          indexInFile: index,
        );
      }),
      totalCount: 2691,
      pageNumber: number,
      pageSize: 200,
    );
    final repository = _FakeLocalChessDatabaseRepository(
      pageForQuery: (q) {
        if (q.pageNumber == 0) return page(0);
        return pending
            .putIfAbsent(q.pageNumber, Completer<LocalChessGameQueryPage>.new)
            .future;
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LocalChessFilesView(
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
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('local-games-table-list')),
        matching: find.byType(Scrollable),
      ),
    );
    scroll.position.jumpTo(1995 * 44);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      pending.keys,
      containsAll([9, 10]),
      reason:
          'every visible page must be requested, not just last itemBuilder callback',
    );
    pending[10]!.complete(page(10));
    await tester.pump();
    pending[9]!.complete(page(9));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.byKey(const ValueKey('local-game-table-database-2000')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('local-game-table-database-1995')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid jumps errors retry and sort reject stale completions', (
    tester,
  ) async {
    final source = _sourceWithGame(
      _localGame(
        id: 'fallback',
        white: 'Fallback',
        black: 'Player',
        sourcePath: '/tmp/view.pgn',
      ),
      gameCount: 2691,
    );
    final pending = <String, Completer<LocalChessGameQueryPage>>{};
    String key(_QueryCall q) =>
        '${q.sortBy.name}-${q.sortDirection.name}-${q.pageNumber}';
    LocalChessGameQueryPage page(int number, String prefix) =>
        LocalChessGameQueryPage(
          games: List.generate((2691 - number * 200).clamp(0, 200), (i) {
            final index = number * 200 + i;
            return _localGame(
              id: '$prefix-$index',
              white: '$prefix $index',
              black: 'Player',
              sourcePath: '/tmp/view.pgn',
              indexInFile: index,
            );
          }),
          totalCount: 2691,
          pageNumber: number,
          pageSize: 200,
        );
    final repository = _FakeLocalChessDatabaseRepository(
      pageForQuery: (q) {
        if (q.pageNumber == 0) return page(0, q.sortBy.name);
        return pending
            .putIfAbsent(key(q), Completer<LocalChessGameQueryPage>.new)
            .future;
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LocalChessFilesView(
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
    );
    Future<void> frames() async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    await frames();
    ScrollPosition position() =>
        tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byKey(const ValueKey('local-games-table-list')),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
    position().jumpTo(650 * 44);
    await frames();
    position().jumpTo(1250 * 44);
    await frames();
    position().jumpTo(2010 * 44);
    await frames();
    expect(
      pending.keys,
      containsAll(['originalOrder-asc-3', 'originalOrder-asc-6']),
    );
    pending['originalOrder-asc-3']!.complete(page(3, 'originalOrder'));
    await frames();
    expect(pending.keys, contains('originalOrder-asc-10'));
    pending
        .remove('originalOrder-asc-10')!
        .completeError(StateError('read failed'));
    await frames();
    expect(find.text('Retry'), findsWidgets);
    final callsBeforeRetry = repository.queries.length;
    await frames();
    expect(repository.queries.length, callsBeforeRetry);
    await tester.tap(find.text('Retry').first);
    await frames();
    pending['originalOrder-asc-10']!.complete(page(10, 'originalOrder'));
    await frames();
    expect(
      find.byKey(const ValueKey('local-game-table-originalOrder-2010')),
      findsOneWidget,
    );
    await tester.tap(find.text('ELO W'));
    await frames();
    // The old page 6 fails after the new sort has already published.
    pending['originalOrder-asc-6']!.completeError(StateError('obsolete'));
    await frames();
    expect(find.text('Retry'), findsNothing);
    expect(repository.queries.last.sortBy, LocalChessGameSortField.whiteElo);
    position().jumpTo(2010 * 44);
    await frames();
    final currentKey = pending.keys.firstWhere(
      (k) => k.startsWith('whiteElo-') && k.endsWith('-10'),
    );
    pending[currentKey]!.complete(page(10, 'whiteElo'));
    await frames();
    expect(
      find.byKey(const ValueKey('local-game-table-whiteElo-2010')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('local-game-table-originalOrder-2010')),
      findsNothing,
    );
    // Sort direction flips with old pages in flight, then unmount safely.
    position().jumpTo(650 * 44);
    await frames();
    await tester.tap(find.text('ELO W'));
    await frames();
    for (final c in pending.values.where((c) => !c.isCompleted)) {
      c.completeError(StateError('late'));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await frames();
    expect(tester.takeException(), isNull);
  });

  final pagingPgn = Platform.environment['LOCAL_GRID_PAGING_PGN'];
  testWidgets('real MY Games SQL Elo pages resolve rapid idle jumps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1905, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capture = GlobalKey();
    late LocalChessFileNode file;
    final sqlPages = <String, LocalChessGameQueryPage>{};
    await tester.runAsync(() async {
      await (FontLoader('Geist')..addFont(
        rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'),
      )).load();
      await (FontLoader('packages/forui/Inter')
            ..addFont(
              rootBundle.load(
                'packages/forui/assets/fonts/inter/Inter-Regular.ttf',
              ),
            )
            ..addFont(
              rootBundle.load(
                'packages/forui/assets/fonts/inter/Inter-Bold.ttf',
              ),
            ))
          .load();
      await (FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      final catalog = await scanLocalChessPaths([pagingPgn!]);
      file = catalog.root.singlePlayableDatabaseInSubtree!;
      final temp = await Directory.systemTemp.createTemp('local-grid-sql-');
      final db = await resqlite.Database.open('${temp.path}/pages.db');
      try {
        await createLocalChessResqliteDatabaseSchema(db);
        final repo = LocalChessDatabaseRepository(database: () async => db);
        await repo.persistFileNode(file, sourceLabel: 'Paging acceptance copy');
        for (final field in [
          LocalChessGameSortField.originalOrder,
          LocalChessGameSortField.whiteElo,
        ]) {
          for (final direction in LocalChessGameSortDirection.values) {
            for (var p = 0; p < 14; p++) {
              final page =
                  (await repo.localDatabaseGamesPage(
                    databasePath: file.path,
                    sortBy: field,
                    sortDirection: direction,
                    pageNumber: p,
                    pageSize: 200,
                  ))!;
              expect(page.totalCount, 2691);
              sqlPages['${field.name}-${direction.name}-$p'] = page;
            }
            final all = [
              for (var p = 0; p < 14; p++)
                ...sqlPages['${field.name}-${direction.name}-$p']!.games,
            ];
            expect(all.map((g) => g.id).toSet().length, 2691);
            if (field == LocalChessGameSortField.whiteElo) {
              final ratings =
                  all
                      .map(
                        (g) =>
                            int.tryParse(g.game.metadata['WhiteElo'] ?? '') ??
                            0,
                      )
                      .where((r) => r > 0)
                      .toList();
              for (var i = 1; i < ratings.length; i++) {
                expect(
                  direction == LocalChessGameSortDirection.asc
                      ? ratings[i] >= ratings[i - 1]
                      : ratings[i] <= ratings[i - 1],
                  isTrue,
                );
              }
            }
          }
        }
      } finally {
        await db.close();
        await temp.delete(recursive: true);
      }
    });
    final source = _sourceWithGame(file.games.first, gameCount: 2691);
    final pending = <String, Completer<LocalChessGameQueryPage>>{};
    final repository = _FakeLocalChessDatabaseRepository(
      pageForQuery: (q) {
        final k = '${q.sortBy.name}-${q.sortDirection.name}-${q.pageNumber}';
        if (q.pageNumber == 0) return sqlPages[k]!;
        return pending
            .putIfAbsent(k, Completer<LocalChessGameQueryPage>.new)
            .future;
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
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
    Future<void> frames() async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    ScrollPosition position() =>
        tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byKey(const ValueKey('local-games-table-list')),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
    await frames();
    for (var direction = 0; direction < 2; direction++) {
      await tester.tap(find.text('ELO W'));
      await frames();
      for (final index in [650, 1250, 2000, 50, 1995]) {
        position().jumpTo(index * 44);
        await frames();
      }
      for (var round = 0; round < 5; round++) {
        for (final e in pending.entries.toList().reversed) {
          if (!e.value.isCompleted) e.value.complete(sqlPages[e.key]!);
        }
        await frames();
      }
      final q = repository.queries.last;
      for (final index in [1995, 2000]) {
        final g =
            sqlPages['whiteElo-${q.sortDirection.name}-${index ~/ 200}']!
                .games[index % 200];
        expect(
          find.byKey(ValueKey('local-game-table-${g.id}')),
          findsOneWidget,
        );
      }
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    final output = Platform.environment['LOCAL_GRID_PAGING_CAPTURE'];
    if (output != null) {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await frames();
  }, skip: pagingPgn == null);

  testWidgets('selected local database exposes its full virtual scroll range', (
    tester,
  ) async {
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
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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

    expect(repository.queries.single.pageSize, 200);
    expect(repository.queries.single.pageNumber, 0);
    expect(find.text('Load more'), findsNothing);
    expect(find.text('2500 entries'), findsWidgets);

    final tableScrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('local-games-table-list')),
        matching: find.byType(Scrollable),
      ),
    );
    tableScrollable.position.jumpTo(tableScrollable.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));

    expect(repository.queries.last.pageNumber, 12);
    expect(repository.queries.last.pageSize, 200);
    expect(find.text('Load more'), findsNothing);
    expect(find.text('2500 entries'), findsWidgets);

    await tester.enterText(find.byType(TextField), 'database 2');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repository.queries.last.search, 'database 2');
    expect(repository.queries.last.pageNumber, 0);
    expect(repository.queries.last.pageSize, 200);
  });

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
          pageSize: 200,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(_GridPreferences()),
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
        pageSize: 200,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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

    expect(find.text('Build Tree'), findsOneWidget);
    expect(find.text('Tree'), findsNothing);

    await tester.tap(find.text('Build Tree'));
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
        pageSize: 200,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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
        pageSize: 200,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(_GridPreferences()),
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
    expect(find.text('Build Tree'), findsNothing);
  });

  testWidgets(
    'database workspace shows live tree progress and can stop the build',
    (tester) async {
      final source = _sourceWithGame(
        _localGame(
          id: 'database',
          white: 'Database Only',
          black: 'Gukesh, D',
          sourcePath: '/tmp/view.pgn',
        ),
        gameCount: 1,
      );
      final releaseBuild = Completer<void>();
      final repository = _HoldingTreeBuildRepository(
        page: LocalChessGameQueryPage(
          games: source.root.files.single.games,
          totalCount: 1,
          pageNumber: 0,
          pageSize: 200,
        ),
        releaseBuild: releaseBuild,
      );
      final notifier = _SeededLocalChessLibraryNotifier(
        source: source,
        repository: repository,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(_GridPreferences()),
            // Building an opening tree is Premium.
            ...desktopPremiumTestOverrides,
            localChessDatabaseRepositoryProvider.overrideWithValue(repository),
            localChessLibraryProvider.overrideWith((ref) => notifier),
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

      await tester.tap(find.text('Build Tree'));
      await tester.pump();

      expect(find.text('Tree 0%'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('Tree 0%'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Build Tree'), findsOneWidget);
      expect(repository.buildWasCanceled, isTrue);
      if (!releaseBuild.isCompleted) releaseBuild.complete();
    },
  );

  testWidgets('active Tree percentage button stops the build when clicked', (
    tester,
  ) async {
    var stopped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalTreeActionButton(
            progress: const LocalChessTreeBuildProgress(
              path: '/tmp/nakamura.pgn',
              phase: LocalChessTreeBuildPhase.building,
              fraction: 0.93,
              message: 'Saving tree moves...',
              startedAtMs: 0,
              updatedAtMs: 93000,
            ),
            onCancel: () => stopped = true,
          ),
        ),
      ),
    );

    expect(find.text('Tree 93%'), findsOneWidget);
    expect(find.textContaining('~7s'), findsNothing);
    await tester.tap(find.byType(LocalTreeActionButton));
    await tester.pump(const Duration(seconds: 1));
    expect(stopped, isTrue);
  });

  testWidgets('tree cache check cannot accidentally start a rebuild', (
    tester,
  ) async {
    var built = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalTreeActionButton(
            checkingCache: true,
            onBuild: () => built = true,
          ),
        ),
      ),
    );

    expect(find.text('Tree'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(LocalTreeActionButton));
    await tester.pump(const Duration(seconds: 1));
    expect(built, isFalse);
  });

  testWidgets('tree preparation shows zero percent and can be stopped', (
    tester,
  ) async {
    var stopped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalTreeActionButton(
            preparingBuild: true,
            onCancel: () => stopped = true,
          ),
        ),
      ),
    );

    expect(find.text('Tree 0%'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(LocalTreeActionButton));
    await tester.pump(const Duration(seconds: 1));
    expect(stopped, isTrue);
  });
}

class _FakeLocalChessDatabaseRepository extends LocalChessDatabaseRepository {
  _FakeLocalChessDatabaseRepository({this.page, this.pageForQuery})
    : super(database: () async => throw UnsupportedError('unused'));

  final LocalChessGameQueryPage? page;
  final FutureOr<LocalChessGameQueryPage> Function(_QueryCall query)?
  pageForQuery;
  final List<_QueryCall> queries = <_QueryCall>[];

  @override
  Future<LocalChessGameQueryPage?> localDatabaseGamesPage({
    required String databasePath,
    String search = '',
    LocalChessGameSortField sortBy = LocalChessGameSortField.originalOrder,
    LocalChessGameSortDirection sortDirection = LocalChessGameSortDirection.asc,
    LocalChessGameFilter? filter,
    String? playerFideId,
    List<String> playerAliases = const <String>[],
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

class _HoldingTreeBuildRepository extends _FakeLocalChessDatabaseRepository {
  _HoldingTreeBuildRepository({
    required super.page,
    required this.releaseBuild,
  });

  final Completer<void> releaseBuild;
  bool buildWasCanceled = false;

  @override
  Future<LocalChessOpeningTreeRebuildResult?> rebuildOpeningTreeFromPgnFile({
    required String databasePath,
    void Function(LocalChessScanProgress progress)? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    try {
      await Future.any<void>([
        releaseBuild.future,
        if (cancellationToken != null) cancellationToken.whenCanceled,
      ]);
      cancellationToken?.throwIfCanceled();
      return LocalChessOpeningTreeRebuildResult(
        index: _usableTreeIndex(),
        skippedGames: 0,
      );
    } catch (error) {
      if (isOperationCanceled(error)) buildWasCanceled = true;
      rethrow;
    }
  }
}

class _SeededLocalChessLibraryNotifier extends LocalChessLibraryNotifier {
  _SeededLocalChessLibraryNotifier({
    required LocalChessSource source,
    required LocalChessDatabaseRepository repository,
  }) : super(localDatabaseRepository: repository) {
    state = LocalChessLibraryState(
      source: source,
      selectedPath: source.root.path,
    );
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

class _GridPreferences implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  Object? value;
  @override
  Future<T?> getJson<T>(String key) async => value as T?;
  @override
  Future<void> setJson(String key, Object value) async {
    this.value = value;
  }
}
