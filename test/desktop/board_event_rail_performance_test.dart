import 'dart:async';
import 'dart:io';

import 'package:chessground/chessground.dart' as cg;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/date_time_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory databaseDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'chessever-board-event-surface-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => databaseDirectory.path,
        );
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
    await AppDatabase.instance.database;
  });

  tearDownAll(() async {
    await AppDatabase.instance.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await databaseDirectory.exists()) {
      await databaseDirectory.delete(recursive: true);
    }
  });

  testWidgets(
    'large event rail metadata tick does not rebuild or repaint the board',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast(
        sync: true,
      );
      final railUpdates =
          StreamController<Map<String, LiveGameUpdate>>.broadcast(sync: true);
      final observer = _BoardEventProviderObserver();
      addTearDown(activeUpdates.close);
      addTearDown(railUpdates.close);

      final initialMoveTime = DateTime.utc(2026, 7, 14, 18, 0);
      final sourceGame = _forYouSourceGame(initialMoveTime);
      final games = <TournamentGameSummary>[
        TournamentGameSummary.fromGamesTourModel(sourceGame),
        for (var index = 1; index < 64; index++)
          _eventGame(
            index,
            lastMoveTime: initialMoveTime.subtract(Duration(seconds: index)),
          ),
      ];
      final args = BoardTabGameArgs(
        gameId: games.first.id,
        pgn: _livePgn,
        label: 'White 1 - Black 1',
        whiteName: games.first.whitePlayer,
        blackName: games.first.blackPlayer,
        tournamentTitle: 'Titled Tuesday',
        fenSeed: _liveFen,
        sourceGame: sourceGame,
        viewSource: ChessboardView.forYou,
        eventGames: games,
        gameListSelectedId: games.first.id,
      );

      await tester.pumpWidget(
        ProviderScope(
          observers: <ProviderObserver>[observer],
          overrides: [
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
            ),
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
            engineSettingsProviderNew.overrideWith(
              _TestEngineSettingsNotifier.new,
            ),
            keyboardShortcutsProvider.overrideWith(
              _TestKeyboardShortcutsNotifier.new,
            ),
            liveGameUpdateArrivalStreamProvider.overrideWith(
              (ref, gameId) => _typedArrivals(activeUpdates.stream, gameId),
            ),
            gameUpdatesBatchStreamProvider.overrideWith(
              (ref, key) => railUpdates.stream,
            ),
            dateTimeProvider.overrideWith(
              (ref) => Stream<DateTime>.value(initialMoveTime),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: BoardPane(tabId: 'tournaments-default')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // Supabase emits the current row immediately when the focused-game
      // channel attaches. Let that one-time clock badge/layout seed settle;
      // the performance contract below measures steady live ticks afterward.
      final initialLegacyUpdate = _metadataOnlyUpdate(
        games.first.id,
        initialMoveTime,
      );
      activeUpdates.add(initialLegacyUpdate);
      railUpdates.add(<String, LiveGameUpdate>{
        games.first.id: LiveGameUpdate.fromLegacyMap(
          games.first.id,
          initialLegacyUpdate,
        ),
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.byType(DesktopChessBoard), findsOneWidget);
      expect(find.byType(cg.Chessboard), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BoardPane)),
      );
      final chessgroundScene = tester.renderObject<RenderObject>(
        find.byType(cg.Chessboard),
      );

      final rebuiltTypes = <String, int>{};
      var chessgroundScenePaints = 0;
      final previousRebuildCallback = debugOnRebuildDirtyWidget;
      final previousPaintCallback = debugOnProfilePaint;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final type = element.widget.runtimeType.toString();
        rebuiltTypes.update(type, (count) => count + 1, ifAbsent: () => 1);
      };
      debugOnProfilePaint = (renderObject) {
        if (identical(renderObject, chessgroundScene)) {
          chessgroundScenePaints++;
        }
      };
      addTearDown(() {
        debugOnRebuildDirtyWidget = previousRebuildCallback;
        debugOnProfilePaint = previousPaintCallback;
      });
      observer.startCapture();

      // A populated Board tab is fully described by its tab-scoped args. A
      // stale legacy tournament can still exist after navigating away from an
      // older flow, but installing or changing that large global list must not
      // invalidate or scan the active Board surface.
      container
          .read(tournamentGamesProvider.notifier)
          .setLoaded(
            tournamentTitle: 'Stale legacy event',
            games: <TournamentGameSummary>[
              for (var index = 0; index < 1092; index++)
                _eventGame(
                  index + 1000,
                  lastMoveTime: initialMoveTime.subtract(
                    Duration(seconds: index),
                  ),
                ),
            ],
          );
      container
          .read(tournamentGamesProvider.notifier)
          .markActive('event-game-1000');
      await tester.pump();
      await tester.pump();
      expect(
        (
          paneBuilds: rebuiltTypes['_BoardPaneContent'] ?? 0,
          boardAreaBuilds: rebuiltTypes['_BoardArea'] ?? 0,
          chessboardBuilds: rebuiltTypes['DesktopChessBoard'] ?? 0,
          eventRailBuilds: rebuiltTypes['EventGamesTable'] ?? 0,
        ),
        (
          paneBuilds: 0,
          boardAreaBuilds: 0,
          chessboardBuilds: 0,
          eventRailBuilds: 0,
        ),
      );

      rebuiltTypes.clear();
      chessgroundScenePaints = 0;
      observer.startCapture();

      final railOnlyLegacyUpdate = _metadataOnlyUpdate(
        games.first.id,
        initialMoveTime.add(const Duration(seconds: 1)),
      );
      final railOnlyTypedUpdate = LiveGameUpdate.fromLegacyMap(
        games.first.id,
        railOnlyLegacyUpdate,
      );

      // Control: the batch rail path is already isolated. This proves any
      // later board dirtiness comes from mirroring that same row through the
      // active game's single-game stream, not from the rail cell itself.
      railUpdates.add(<String, LiveGameUpdate>{
        games.first.id: railOnlyTypedUpdate,
      });
      await tester.pump();
      await tester.pump();
      final railOnlyRebuildCount = rebuiltTypes.values.fold<int>(
        0,
        (total, count) => total + count,
      );
      expect(
        rebuiltTypes['EventGamesTable'] ?? 0,
        0,
        reason:
            'A single visible-row update must stay below the 64-game rail '
            'root. Rebuilds: $rebuiltTypes',
      );
      expect(
        railOnlyRebuildCount,
        lessThanOrEqualTo(8),
        reason:
            'Rail-only live work must remain constant-sized instead of '
            'scaling with event membership. Rebuilds: $rebuiltTypes',
      );
      expect(
        (
          paneBuilds: rebuiltTypes['_BoardPaneContent'] ?? 0,
          boardAreaBuilds: rebuiltTypes['_BoardArea'] ?? 0,
          chessboardBuilds: rebuiltTypes['DesktopChessBoard'] ?? 0,
          boardScenePaints: chessgroundScenePaints,
          boardArgsUpdates: observer.boardArgsUpdates,
        ),
        (
          paneBuilds: 0,
          boardAreaBuilds: 0,
          chessboardBuilds: 0,
          boardScenePaints: 0,
          boardArgsUpdates: 0,
        ),
      );

      rebuiltTypes.clear();
      chessgroundScenePaints = 0;
      observer.startCapture();

      final metadataOnlyLegacyUpdate = _metadataOnlyUpdate(
        games.first.id,
        initialMoveTime.add(const Duration(seconds: 2)),
      );
      final typedUpdate = LiveGameUpdate.fromLegacyMap(
        games.first.id,
        metadataOnlyLegacyUpdate,
      );

      // A real Board tab receives the selected game's row from both surfaces:
      // the single-game stream drives PGN/clocks while the event rail consumes
      // the batch stream. The position itself is unchanged in this replay.
      activeUpdates.add(metadataOnlyLegacyUpdate);
      railUpdates.add(<String, LiveGameUpdate>{games.first.id: typedUpdate});
      await tester.pump();
      await tester.pump();

      final metadataOnlyRebuildCount = rebuiltTypes.values.fold<int>(
        0,
        (total, count) => total + count,
      );
      expect(
        rebuiltTypes['EventGamesTable'] ?? 0,
        0,
        reason:
            'Mirroring the selected row through both streams must not rebuild '
            'the large event rail root. Rebuilds: $rebuiltTypes',
      );
      expect(
        metadataOnlyRebuildCount,
        lessThanOrEqualTo(80),
        reason:
            'Selected clocks plus one row leaf must stay inside a small '
            'absolute leaf budget. Rebuilds: $rebuiltTypes',
      );
      expect(
        rebuiltTypes['DesktopBoardPlayerHeader'] ?? 0,
        greaterThanOrEqualTo(2),
        reason:
            'Both compact player headers must receive the real legacy clock '
            'snapshot without invalidating the board surface.',
      );
      final metadataOnlyMetrics = (
        paneBuilds: rebuiltTypes['_BoardPaneContent'] ?? 0,
        boardAreaBuilds: rebuiltTypes['_BoardArea'] ?? 0,
        chessboardBuilds: rebuiltTypes['DesktopChessBoard'] ?? 0,
        boardScenePaints: chessgroundScenePaints,
        boardArgsUpdates: observer.boardArgsUpdates,
      );

      rebuiltTypes.clear();
      chessgroundScenePaints = 0;
      observer.startCapture();

      final nextMoveTime = initialMoveTime.add(const Duration(seconds: 3));
      final nextMoveLegacyUpdate = _nextMoveUpdate(
        games.first.id,
        nextMoveTime,
      );
      final nextMoveTypedUpdate = LiveGameUpdate.fromLegacyMap(
        games.first.id,
        nextMoveLegacyUpdate,
      );

      // Preservation guard: suppressing clock-only invalidations must never
      // suppress an actual position change. The active stream advances the
      // board while the event rail receives the same projected game row.
      activeUpdates.add(nextMoveLegacyUpdate);
      railUpdates.add(<String, LiveGameUpdate>{
        games.first.id: nextMoveTypedUpdate,
      });
      await tester.pump();
      await tester.pump();

      final latestArgs = observer.argsForTab('tournaments-default');
      expect(latestArgs, isNotNull);
      expect(latestArgs!.pgn, _nextMovePgn.trim());
      expect(latestArgs.fenSeed, _nextMoveFen);
      expect(observer.boardArgsUpdates, greaterThan(0));
      expect(rebuiltTypes['_BoardArea'] ?? 0, greaterThan(0));
      expect(rebuiltTypes['DesktopChessBoard'] ?? 0, greaterThan(0));
      expect(
        tester.widget<DesktopChessBoard>(find.byType(DesktopChessBoard)).fen,
        _nextMoveFen,
        reason: 'The rendered board must advance to the genuine next move.',
      );
      final liveSession =
          container.read(
            boardPaneSessionByTabIdProvider,
          )['tournaments-default'];
      expect(liveSession, isNotNull);
      expect(
        liveSession!.game.metadata[ChessGame.metadataIsLiveKey],
        isTrue,
        reason:
            'The API ongoing status must keep attached broadcasts in live '
            'mode after an incremental move.',
      );
      rebuiltTypes.clear();
      observer.startCapture();
      final terminalLegacyUpdate = _terminalStatusUpdate(
        games.first.id,
        nextMoveTime.add(const Duration(seconds: 1)),
      );
      activeUpdates.add(terminalLegacyUpdate);
      railUpdates.add(<String, LiveGameUpdate>{
        games.first.id: LiveGameUpdate.fromLegacyMap(
          games.first.id,
          terminalLegacyUpdate,
        ),
      });
      await tester.pump();
      await tester.pump();

      final terminalArgs = observer.argsForTab('tournaments-default');
      expect(terminalArgs, isNotNull);
      expect(terminalArgs!.pgn, _nextMovePgn.trim());
      expect(terminalArgs.fenSeed, _nextMoveFen);
      expect(terminalArgs.sourceGame?.gameStatus, GameStatus.whiteWins);
      expect(terminalArgs.eventGames.first.status, GameStatus.whiteWins);
      expect(observer.boardArgsUpdates, greaterThan(0));
      final terminalSession =
          container.read(
            boardPaneSessionByTabIdProvider,
          )['tournaments-default'];
      expect(terminalSession, isNotNull);
      expect(terminalSession!.game.metadata['Result'], '1-0');
      expect(
        terminalSession.game.metadata[ChessGame.metadataIsLiveKey],
        isFalse,
      );
      expect(
        tester.widget<DesktopChessBoard>(find.byType(DesktopChessBoard)).fen,
        _nextMoveFen,
        reason:
            'A terminal status-only row must update result surfaces without '
            'moving the rendered position.',
      );
      debugOnRebuildDirtyWidget = previousRebuildCallback;
      debugOnProfilePaint = previousPaintCallback;

      // Assert the no-op metrics after the real-move preservation guard so one
      // regression test covers both halves of the update boundary.
      expect(
        metadataOnlyMetrics,
        (
          paneBuilds: 0,
          boardAreaBuilds: 0,
          chessboardBuilds: 0,
          boardScenePaints: 0,
          boardArgsUpdates: 0,
        ),
        reason:
            'The headers may refresh clocks, but a same-position row must '
            'leave the board repaint boundary cached.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'steady live-tick rebuild cost does not scale with event membership',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final single = await _measureSteadyMetadataTickRebuilds(
        tester,
        gameCount: 1,
      );
      final large = await _measureSteadyMetadataTickRebuilds(
        tester,
        gameCount: 1092,
      );

      expect(large.eventRailRoot, 0, reason: 'large=$large single=$single');
      expect(large.roundSections, 0, reason: 'large=$large single=$single');
      expect(
        large.mountedStatusCells,
        lessThanOrEqualTo(96),
        reason:
            'A 1,092-board round must mount only viewport chunks, not every '
            'status leaf. large=$large',
      );
      expect(
        large.batchProviderBuilds,
        lessThanOrEqualTo(6),
        reason:
            'Only visible/overscan chunks may own realtime batch providers. '
            'large=$large',
      );
      expect(
        large.total,
        lessThanOrEqualTo(single.total + 4),
        reason:
            'A selected-game clock/status tick must cost the same with 1092 '
            'event games as it does with one. large=$large single=$single',
      );
    },
  );

  testWidgets('large event rails use explicit 64-game pages', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1800, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final moveTime = DateTime.utc(2026, 7, 14, 18);
    final sourceGame = _forYouSourceGame(moveTime);
    final games = <TournamentGameSummary>[
      TournamentGameSummary.fromGamesTourModel(sourceGame),
      for (var index = 1; index < 1092; index++)
        _eventGame(index, lastMoveTime: moveTime),
    ];
    const tabId = 'paged-event-rail';
    final args = BoardTabGameArgs(
      gameId: games.first.id,
      pgn: _livePgn,
      label: 'White 1 - Black 1',
      whiteName: games.first.whitePlayer,
      blackName: games.first.blackPlayer,
      tournamentTitle: 'Titled Tuesday',
      fenSeed: _liveFen,
      sourceGame: sourceGame,
      viewSource: ChessboardView.forYou,
      eventGames: games,
      gameListSelectedId: games.first.id,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{tabId: args},
          ),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _TestEngineSettingsNotifier.new,
          ),
          keyboardShortcutsProvider.overrideWith(
            _TestKeyboardShortcutsNotifier.new,
          ),
          dateTimeProvider.overrideWith(
            (ref) => Stream<DateTime>.value(moveTime),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: BoardPane(tabId: tabId))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Page 1 of 18'), findsOneWidget);
    expect(
      find
          .byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_EventGameStatusCell',
          )
          .evaluate()
          .length,
      lessThanOrEqualTo(64),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('event-rail-next-page')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Page 2 of 18'), findsOneWidget);
    expect(find.text('White 65'), findsOneWidget);
  });

  testWidgets('hidden Board tabs cancel rail realtime and catch up on return', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1800, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    SharedPreferences.setMockInitialValues(const <String, Object>{});

    var railListenCount = 0;
    var railCancelCount = 0;
    final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast();
    final railUpdates = StreamController<Map<String, LiveGameUpdate>>.broadcast(
      onListen: () => railListenCount++,
      onCancel: () => railCancelCount++,
    );
    final streamRepository = _TestGameStreamRepository(railUpdates.stream);
    addTearDown(activeUpdates.close);
    addTearDown(railUpdates.close);
    final tabs = DesktopTabsNotifier();
    final moveTime = DateTime.utc(2026, 7, 14, 18);
    final sourceGame = _forYouSourceGame(moveTime);
    final games = <TournamentGameSummary>[
      TournamentGameSummary.fromGamesTourModel(sourceGame),
      for (var index = 1; index < 64; index++)
        _eventGame(
          index,
          lastMoveTime: moveTime.subtract(Duration(seconds: index)),
        ),
    ];
    final args = BoardTabGameArgs(
      gameId: games.first.id,
      pgn: _livePgn,
      label: 'White 1 - Black 1',
      whiteName: games.first.whitePlayer,
      blackName: games.first.blackPlayer,
      tournamentTitle: 'Titled Tuesday',
      fenSeed: _liveFen,
      sourceGame: sourceGame,
      viewSource: ChessboardView.forYou,
      eventGames: games,
      gameListSelectedId: games.first.id,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopTabsProvider.overrideWith((ref) => tabs),
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
          boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
          engineSettingsProviderNew.overrideWith(
            _TestEngineSettingsNotifier.new,
          ),
          keyboardShortcutsProvider.overrideWith(
            _TestKeyboardShortcutsNotifier.new,
          ),
          liveGameUpdateArrivalStreamProvider.overrideWith(
            (ref, gameId) => _typedArrivals(activeUpdates.stream, gameId),
          ),
          gameStreamRepositoryProvider.overrideWithValue(streamRepository),
          dateTimeProvider.overrideWith(
            (ref) => Stream<DateTime>.value(moveTime),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: BoardPane(tabId: 'tournaments-default')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(railListenCount, 1);

    tabs.open(TabKind.library, title: 'Library', reuseExisting: false);
    expect(tabs.state.activeId, isNot('tournaments-default'));
    for (var attempt = 0; attempt < 10 && railCancelCount == 0; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(railCancelCount, 1);

    tabs.activate('tournaments-default');
    for (var attempt = 0; attempt < 10 && railListenCount < 2; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(railListenCount, 2);
  });

  testWidgets('app pause cancels rail realtime and resume restores it', (
    tester,
  ) async {
    var railListenCount = 0;
    var railCancelCount = 0;
    final railUpdates = StreamController<Map<String, LiveGameUpdate>>.broadcast(
      onListen: () => railListenCount++,
      onCancel: () => railCancelCount++,
    );
    addTearDown(railUpdates.close);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    final moveTime = DateTime.utc(2026, 7, 14, 18);
    final game = _eventGame(0, lastMoveTime: moveTime);
    final args = BoardTabGameArgs(
      gameId: game.id,
      pgn: _livePgn,
      label: game.name,
      whiteName: game.whitePlayer,
      blackName: game.blackPlayer,
      tournamentTitle: 'Titled Tuesday',
      eventGames: <TournamentGameSummary>[game],
      gameListSelectedId: game.id,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          boardTabGameArgsByTabIdProvider.overrideWith(
            (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
          ),
          gameStreamRepositoryProvider.overrideWithValue(
            _TestGameStreamRepository(railUpdates.stream),
          ),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: EventGamesTable.width,
            height: 700,
            child: EventGamesTable(tabId: 'tournaments-default'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(railListenCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    for (var attempt = 0; attempt < 10 && railCancelCount == 0; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(railCancelCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var attempt = 0; attempt < 10 && railListenCount < 2; attempt++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(railListenCount, 2);
  });
}

typedef _TickRebuildMetrics =
    ({
      int total,
      int eventRailRoot,
      int roundSections,
      int boardArea,
      int chessboard,
      int mountedStatusCells,
      int batchProviderBuilds,
    });

Future<_TickRebuildMetrics> _measureSteadyMetadataTickRebuilds(
  WidgetTester tester, {
  required int gameCount,
}) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast(
    sync: true,
  );
  final railUpdates = StreamController<Map<String, LiveGameUpdate>>.broadcast(
    sync: true,
  );
  var batchProviderBuilds = 0;
  final moveTime = DateTime.utc(2026, 7, 14, 18);
  final sourceGame = _forYouSourceGame(moveTime);
  final games = <TournamentGameSummary>[
    TournamentGameSummary.fromGamesTourModel(sourceGame),
    for (var index = 1; index < gameCount; index++)
      _eventGame(
        index,
        lastMoveTime: moveTime.subtract(Duration(seconds: index)),
      ),
  ];
  final tabId = 'metadata-tick-$gameCount';
  final args = BoardTabGameArgs(
    gameId: games.first.id,
    pgn: _livePgn,
    label: 'White 1 - Black 1',
    whiteName: games.first.whitePlayer,
    blackName: games.first.blackPlayer,
    tournamentTitle: 'Titled Tuesday',
    fenSeed: _liveFen,
    sourceGame: sourceGame,
    viewSource: ChessboardView.forYou,
    eventGames: games,
    gameListSelectedId: games.first.id,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardTabGameArgsByTabIdProvider.overrideWith(
          (ref) => <String, BoardTabGameArgs>{tabId: args},
        ),
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        engineSettingsProviderNew.overrideWith(_TestEngineSettingsNotifier.new),
        keyboardShortcutsProvider.overrideWith(
          _TestKeyboardShortcutsNotifier.new,
        ),
        liveGameUpdateArrivalStreamProvider.overrideWith(
          (ref, gameId) => _typedArrivals(activeUpdates.stream, gameId),
        ),
        gameUpdatesBatchStreamProvider.overrideWith((ref, key) {
          batchProviderBuilds++;
          return railUpdates.stream;
        }),
        dateTimeProvider.overrideWith(
          (ref) => Stream<DateTime>.value(moveTime),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: BoardPane(tabId: tabId))),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();

  final initialUpdate = _metadataOnlyUpdate(games.first.id, moveTime);
  activeUpdates.add(initialUpdate);
  railUpdates.add(<String, LiveGameUpdate>{
    games.first.id: LiveGameUpdate.fromLegacyMap(games.first.id, initialUpdate),
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();

  final rebuiltTypes = <String, int>{};
  final mountedStatusCells =
      find
          .byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_EventGameStatusCell',
          )
          .evaluate()
          .length;
  final previousRebuildCallback = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    final type = element.widget.runtimeType.toString();
    rebuiltTypes.update(type, (count) => count + 1, ifAbsent: () => 1);
  };
  try {
    final update = _metadataOnlyUpdate(
      games.first.id,
      moveTime.add(const Duration(seconds: 1)),
    );
    activeUpdates.add(update);
    railUpdates.add(<String, LiveGameUpdate>{
      games.first.id: LiveGameUpdate.fromLegacyMap(games.first.id, update),
    });
    await tester.pump();
    await tester.pump();
  } finally {
    debugOnRebuildDirtyWidget = previousRebuildCallback;
  }

  final metrics = (
    total: rebuiltTypes.values.fold<int>(0, (total, count) => total + count),
    eventRailRoot: rebuiltTypes['EventGamesTable'] ?? 0,
    roundSections: rebuiltTypes['_EventRoundTable'] ?? 0,
    boardArea: rebuiltTypes['_BoardArea'] ?? 0,
    chessboard: rebuiltTypes['DesktopChessBoard'] ?? 0,
    mountedStatusCells: mountedStatusCells,
    batchProviderBuilds: batchProviderBuilds,
  );
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await activeUpdates.close();
  await railUpdates.close();
  return metrics;
}

const String _livePgn = '''
[Event "Titled Tuesday"]
[White "White 1"]
[Black "Black 1"]
[Result "*"]

1. e4 e5 *
''';

const String _nextMovePgn = '''
[Event "Titled Tuesday"]
[White "White 1"]
[Black "Black 1"]
[Result "*"]

1. e4 e5 2. Nf3 *
''';

const String _liveFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

const String _nextMoveFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

GamesTourModel _forYouSourceGame(DateTime lastMoveTime) {
  return GamesTourModel.fromGame(
    Games.fromJson({
      'id': 'titled-tuesday-1',
      'round_id': 'round-11',
      'round_slug': 'round-11',
      'tour_id': 'titled-tuesday',
      'tour_slug': 'titled-tuesday',
      'players': [
        {'name': 'White 1', 'fed': 'USA', 'rating': 2600},
        {'name': 'Black 1', 'fed': 'GER', 'rating': 2590},
      ],
      'status': 'ONGOING',
      'pgn': _livePgn,
      'fen': _liveFen,
      'last_move': 'e7e5',
      'last_move_time': lastMoveTime.toIso8601String(),
      'last_clock_white': 178,
      'last_clock_black': 179,
      'board_nr': 1,
    }),
  );
}

TournamentGameSummary _eventGame(int index, {required DateTime lastMoveTime}) {
  final board = index + 1;
  return TournamentGameSummary(
    id: 'titled-tuesday-$board',
    name: 'White $board - Black $board',
    whitePlayer: 'White $board',
    blackPlayer: 'Black $board',
    hasPgn: true,
    pgn: index == 0 ? _livePgn : '1. d4 d5 *',
    fen: index == 0 ? _liveFen : null,
    tourId: 'titled-tuesday',
    roundId: 'round-11',
    roundLabel: 'Round 11',
    boardNumber: board,
    status: GameStatus.ongoing,
    hasStarted: true,
    lastMoveTime: lastMoveTime,
    roundStartsAt: DateTime.utc(2026, 7, 14, 17),
  );
}

Map<String, dynamic> _metadataOnlyUpdate(String gameId, DateTime moveTime) {
  return <String, dynamic>{
    'id': gameId,
    'pgn': _livePgn,
    'fen': _liveFen,
    'status': 'ONGOING',
    'last_move': 'e7e5',
    'last_move_time': moveTime.toIso8601String(),
    'last_clock_white': 177,
    'last_clock_black': 179,
  };
}

Stream<LiveStreamArrival<LiveGameUpdate?>> _typedArrivals(
  Stream<Map<String, dynamic>?> updates,
  String gameId,
) async* {
  var sequence = 0;
  await for (final update in updates) {
    yield LiveStreamArrival<LiveGameUpdate?>(
      value:
          update == null ? null : LiveGameUpdate.fromLegacyMap(gameId, update),
      sessionEpoch: 1,
      sequence: ++sequence,
      isFallback: false,
    );
  }
}

Map<String, dynamic> _nextMoveUpdate(String gameId, DateTime moveTime) {
  return <String, dynamic>{
    'id': gameId,
    'pgn': _nextMovePgn,
    'fen': _nextMoveFen,
    'status': 'ONGOING',
    'last_move': 'g1f3',
    'last_move_time': moveTime.toIso8601String(),
    'last_clock_white': 176,
    'last_clock_black': 179,
  };
}

Map<String, dynamic> _terminalStatusUpdate(String gameId, DateTime moveTime) {
  return <String, dynamic>{
    'id': gameId,
    'pgn': _nextMovePgn,
    'fen': _nextMoveFen,
    'status': '1-0',
    'last_move': 'g1f3',
    'last_move_time': moveTime.toIso8601String(),
    'last_clock_white': 176,
    'last_clock_black': 179,
  };
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(soundEnabled: false, showEvaluationBar: false);
}

class _TestEngineSettingsNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings(
    showEngineGauge: false,
    showEngineAnalysis: false,
    autoGameAnalysis: false,
  );
}

class _TestKeyboardShortcutsNotifier extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async {
    return BoardShortcutMap(defaultBoardShortcuts());
  }
}

class _TestGameStreamRepository extends GameStreamRepository {
  _TestGameStreamRepository(this.updates);

  final Stream<Map<String, LiveGameUpdate>> updates;

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) {
    return updates;
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) {
    return updates;
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) {
    return updates;
  }
}

class _BoardEventProviderObserver extends ProviderObserver {
  bool _capturing = false;
  int boardArgsUpdates = 0;
  Map<String, BoardTabGameArgs> _latestArgs =
      const <String, BoardTabGameArgs>{};

  void startCapture() {
    boardArgsUpdates = 0;
    _capturing = true;
  }

  BoardTabGameArgs? argsForTab(String tabId) => _latestArgs[tabId];

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    if (provider == boardTabGameArgsByTabIdProvider) {
      _latestArgs = newValue! as Map<String, BoardTabGameArgs>;
      if (_capturing) boardArgsUpdates++;
    }
  }
}
