import 'dart:async';
import 'dart:io';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart';
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
import 'package:chessever/desktop/state/board_picture_in_picture_mode.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
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
        0,
        reason:
            'Live clock snapshots must stay below the complete player headers. '
            'Rebuilds: $rebuiltTypes',
      );
      expect(
        rebuiltTypes['_LiveBoardPlayerClock'] ?? 0,
        greaterThanOrEqualTo(2),
        reason:
            'Both compact clock leaves must receive the real legacy snapshot '
            'without invalidating the surrounding player chrome.',
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

  testWidgets(
    'event Board keeps private moves, comments, and evaluations across canonical updates',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast(
        sync: true,
      );
      addTearDown(activeUpdates.close);
      final moveTime = DateTime.utc(2026, 7, 14, 18);
      final sourceGame = _forYouSourceGame(moveTime);
      final args = BoardTabGameArgs(
        gameId: sourceGame.gameId,
        pgn: _livePgn,
        label: 'White 1 - Black 1',
        whiteName: 'White 1',
        blackName: 'Black 1',
        tournamentTitle: 'Titled Tuesday',
        fenSeed: _liveFen,
        sourceGame: sourceGame,
        viewSource: ChessboardView.forYou,
      );

      await tester.pumpWidget(
        ProviderScope(
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

      final d2 = _boardSquareOffset(tester, Square.d2);
      final d4 = _boardSquareOffset(tester, Square.d4);
      final drag = await tester.startGesture(
        d2,
        pointer: 1,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(d4);
      await drag.up();
      await tester.pump();
      await tester.pump();

      var notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BoardPane)),
      );
      var session =
          container.read(
            boardPaneSessionByTabIdProvider,
          )['tournaments-default'];
      expect(session, isNotNull);
      expect(session!.pointer, <int>[1, 0, 0]);
      expect(notation.game.mainline[1].variations!.single.single.uci, 'd2d4');
      notation.onSetMoveComment!(const <int>[0], 'Private event note');
      notation.onToggleUserNag!(0, 16);
      await tester.pump();

      notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      expect(
        notation.game.mainline.first.comments,
        contains('Private event note'),
      );
      expect(notation.userNags[0], contains(16));

      activeUpdates.add(_nextMoveUpdate(sourceGame.gameId, moveTime));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      expect(notation.game.mainline, hasLength(3));
      expect(notation.game.mainline.map((move) => move.uci), <String>[
        'e2e4',
        'e7e5',
        'g1f3',
      ]);
      expect(notation.game.mainline[1].variations!.single.single.uci, 'd2d4');
      session =
          container.read(
            boardPaneSessionByTabIdProvider,
          )['tournaments-default'];
      expect(session, isNotNull);
      expect(session!.pointer, <int>[1, 0, 0]);
      expect(
        notation.game.mainline.first.comments,
        contains('Private event note'),
      );
      expect(notation.userNags[0], contains(16));
    },
  );

  testWidgets(
    'finished Event rail supports consecutive private analysis moves',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast();
      addTearDown(activeUpdates.close);

      final sourceGame = _forYouSourceGame(
        DateTime.utc(2026, 8, 14, 9),
      ).copyWith(
        gameStatus: GameStatus.whiteWins,
        pgn: _finishedEventPgn,
        fen: _finishedEventFen,
        lastMove: 'e5e6',
      );
      final args = BoardTabGameArgs(
        gameId: sourceGame.gameId,
        pgn: _finishedEventPgn,
        label: 'Firouzja 1 - Niemann 0',
        whiteName: 'Firouzja',
        blackName: 'Niemann',
        tournamentTitle: 'Esports World Cup 2026',
        sourceGame: sourceGame,
        viewSource: ChessboardView.forYou,
        eventGames: <TournamentGameSummary>[
          TournamentGameSummary.fromGamesTourModel(sourceGame),
        ],
        gameListSelectedId: sourceGame.gameId,
      );

      await tester.pumpWidget(
        ProviderScope(
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
            dateTimeProvider.overrideWith(
              (ref) => Stream<DateTime>.value(DateTime.utc(2026, 8, 14, 9)),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: BoardPane(tabId: 'tournaments-default')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      var notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      final finalPointer = <int>[notation.game.mainline.length - 1];
      notation.onJump(finalPointer);
      await tester.pump();

      final fallenKingBackground = find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == const Color(0xCCF53236),
        description: 'fallen-king result square',
      );
      expect(fallenKingBackground, findsOneWidget);

      final board = tester.widget<DesktopChessBoard>(
        find.byType(DesktopChessBoard),
      );
      expect(board.playerSide, cg.PlayerSide.black);
      expect(board.validMoves, isNotEmpty);
      final source = Square.h8;
      expect(board.validMoves[source], isNotEmpty);
      final destination = board.validMoves[source]!.first;

      final drag = await tester.startGesture(
        _boardSquareOffset(tester, source),
        pointer: 1,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(_boardSquareOffset(tester, destination));
      await drag.up();
      await tester.pump();
      await tester.pump();

      notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BoardPane)),
      );
      final session =
          container.read(
            boardPaneSessionByTabIdProvider,
          )['tournaments-default'];
      expect(session, isNotNull);
      expect(session!.pointer, isNot(finalPointer));
      expect(notation.activePointer, session.pointer);
      expect(notation.game.mainline, hasLength(finalPointer.first + 2));
      expect(fallenKingBackground, findsNothing);
      final firstPrivateMove = notation.game.mainline.last.uci;

      activeUpdates.add(<String, dynamic>{
        'id': sourceGame.gameId,
        'pgn': _finishedEventPgn,
        'fen': _finishedEventFen,
        'status': '1-0',
        'last_move': 'e5e6',
        'last_move_time': DateTime.utc(2026, 8, 14, 9, 0, 1).toIso8601String(),
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      expect(notation.game.mainline, hasLength(finalPointer.first + 2));
      expect(notation.game.mainline.last.uci, firstPrivateMove);
      expect(notation.activePointer, <int>[notation.game.mainline.length - 1]);
      expect(fallenKingBackground, findsNothing);

      await tester.pump(const Duration(milliseconds: 250));
      final nextBoard = tester.widget<DesktopChessBoard>(
        find.byType(DesktopChessBoard),
      );
      expect(nextBoard.sideToMove, Side.white);
      expect(nextBoard.playerSide, cg.PlayerSide.white);
      expect(nextBoard.validMoves, isNotEmpty);
      final nextSource = nextBoard.validMoves.keys.first;
      final nextDestination = nextBoard.validMoves[nextSource]!.first;
      final nextDrag = await tester.startGesture(
        _boardSquareOffset(tester, nextSource),
        pointer: 2,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      activeUpdates.add(<String, dynamic>{
        'id': sourceGame.gameId,
        'pgn': _finishedEventPgn,
        'fen': _finishedEventFen,
        'status': '1-0',
        'last_move': 'e5e6',
        'last_move_time': DateTime.utc(2026, 8, 14, 9, 0, 2).toIso8601String(),
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await nextDrag.moveTo(_boardSquareOffset(tester, nextDestination));
      await nextDrag.up();
      await tester.pump();
      await tester.pump();

      notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      expect(notation.game.mainline, hasLength(finalPointer.first + 3));
      expect(
        notation.game.mainline
            .skip(finalPointer.first + 1)
            .map((move) => move.uci),
        <String>[firstPrivateMove, notation.game.mainline.last.uci],
      );
      expect(notation.activePointer, <int>[notation.game.mainline.length - 1]);
      expect(fallenKingBackground, findsNothing);

      final containerArgs =
          ProviderScope.containerOf(
            tester.element(find.byType(BoardPane)),
          ).read(boardTabGameArgsByTabIdProvider)['tournaments-default'];
      expect(containerArgs?.pgn, _finishedEventPgn);
    },
  );

  testWidgets(
    'drawn Event Board shows peace icons until private analysis moves away',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final sourceGame = _forYouSourceGame(
        DateTime.utc(2026, 8, 14, 9),
      ).copyWith(
        gameStatus: GameStatus.draw,
        pgn: _drawnEventPgn,
        fen: _drawnEventFen,
        lastMove: 'b8c6',
      );
      final args = BoardTabGameArgs(
        gameId: sourceGame.gameId,
        pgn: _drawnEventPgn,
        label: 'White ½ - Black ½',
        whiteName: 'White',
        blackName: 'Black',
        sourceGame: sourceGame,
        viewSource: ChessboardView.forYou,
      );

      await tester.pumpWidget(
        ProviderScope(
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
            dateTimeProvider.overrideWith(
              (ref) => Stream<DateTime>.value(DateTime.utc(2026, 8, 14, 9)),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: BoardPane(tabId: 'tournaments-default')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      var notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      final finalPointer = <int>[notation.game.mainline.length - 1];
      notation.onJump(finalPointer);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('🕊️'), findsNWidgets(2));

      final board = tester.widget<DesktopChessBoard>(
        find.byType(DesktopChessBoard),
      );
      expect(board.playerSide, cg.PlayerSide.white);
      expect(board.validMoves, isNotEmpty);
      final source = board.validMoves.keys.first;
      final destination = board.validMoves[source]!.first;
      final drag = await tester.startGesture(
        _boardSquareOffset(tester, source),
        pointer: 1,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(_boardSquareOffset(tester, destination));
      await drag.up();
      await tester.pump();
      await tester.pump();

      notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      expect(notation.activePointer, isNot(finalPointer));
      expect(find.text('🕊️'), findsNothing);
    },
  );

  testWidgets('large event rails start at 64 rows and grow by scrolling', (
    tester,
  ) async {
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

    int renderedMatchupCells() =>
        find
            .byWidgetPredicate(
              (widget) =>
                  widget.runtimeType.toString() == '_EventGameMatchupCell',
            )
            .evaluate()
            .length;

    // A 1092-game event opens with one bounded slice of rows, not all of them.
    expect(renderedMatchupCells(), lessThanOrEqualTo(64));

    // No page controls: the rail is scroll-to-fetch only.
    expect(find.text('Page 1 of 18'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('event-rail-next-page')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('event-rail-previous-page')),
      findsNothing,
    );

    // Row 65 lives past the opening window and appears once the user scrolls.
    expect(find.text('White 65'), findsNothing);

    final railScrollable =
        find
            .descendant(
              of: find.byType(EventGamesTable),
              matching: find.byType(Scrollable),
            )
            .first;

    // Each time the user reaches the bottom the rail reveals another slice, so
    // repeated scrolling walks deeper into the event.
    for (var attempt = 0; attempt < 8; attempt++) {
      if (find.text('White 65').evaluate().isNotEmpty) break;
      await tester.drag(railScrollable, const Offset(0, -2000));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(renderedMatchupCells(), greaterThan(0));
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

  testWidgets(
    'picture-in-picture renders the board without a one-child split',
    (tester) async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 620);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final activeUpdates = StreamController<Map<String, dynamic>?>.broadcast(
        sync: true,
      );
      final railUpdates =
          StreamController<Map<String, LiveGameUpdate>>.broadcast(sync: true);
      addTearDown(activeUpdates.close);
      addTearDown(railUpdates.close);

      final initialMoveTime = DateTime.utc(2026, 7, 14, 18);
      final sourceGame = _forYouSourceGame(initialMoveTime);
      final game = TournamentGameSummary.fromGamesTourModel(sourceGame);
      final args = BoardTabGameArgs(
        gameId: game.id,
        pgn: _livePgn,
        label: 'White 1 - Black 1',
        whiteName: game.whitePlayer,
        blackName: game.blackPlayer,
        tournamentTitle: 'Titled Tuesday',
        fenSeed: _liveFen,
        sourceGame: sourceGame,
        viewSource: ChessboardView.forYou,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardPictureInPictureModeProvider.overrideWith((ref) => true),
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => <String, BoardTabGameArgs>{'pip': args},
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
            home: Scaffold(body: BoardPane(tabId: 'pip')),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(DesktopChessBoard), findsOneWidget);
      // The exception check above only proves the debug-mode assert is gone.
      // Release builds strip asserts, so pin the actual structural claim as
      // well: PiP must not construct a splitter at all, in any build mode.
      // Otherwise a later refactor could satisfy the assert by handing the
      // splitter a filler pane and quietly reintroduce a dead gutter.
      expect(find.byType(ResizableSplitView), findsNothing);
    },
  );
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
  final railUpdates = StreamController<
    LiveStreamArrival<Map<String, LiveGameUpdate>>
  >.broadcast(sync: true);
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
        gameUpdatesBatchArrivalStreamProvider.overrideWith((ref, key) {
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
  final batchSnapshot = <String, LiveGameUpdate>{
    for (final game in games)
      game.id: LiveGameUpdate.fromLegacyMap(
        game.id,
        _metadataOnlyUpdate(game.id, moveTime),
      ),
  };
  activeUpdates.add(initialUpdate);
  railUpdates.add(
    LiveStreamArrival<Map<String, LiveGameUpdate>>(
      value: batchSnapshot,
      sessionEpoch: 1,
      sequence: 1,
      isFallback: false,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();

  final rebuiltTypes = <String, int>{};
  final mountedStatusCells =
      find
          .byWidgetPredicate(
            (widget) =>
                widget.runtimeType.toString() == '_EventGameMatchupCell',
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
    railUpdates.add(
      LiveStreamArrival<Map<String, LiveGameUpdate>>(
        value: <String, LiveGameUpdate>{
          ...batchSnapshot,
          games.first.id: LiveGameUpdate.fromLegacyMap(games.first.id, update),
        },
        sessionEpoch: 1,
        sequence: 2,
        isFallback: false,
      ),
    );
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

const String _finishedEventPgn = '''
[Event "Esports World Cup 2026"]
[White "Firouzja"]
[Black "Niemann"]
[Result "1-0"]

1. d4 Nf6 2. Nf3 d5 3. Bf4 e6 4. Nbd2 c5 5. e3 Qb6 6. Rb1 Bd6
7. dxc5 Qxc5 8. Bg5 Nbd7 9. b4 Qc7 10. c4 b6 11. Nd4 a6 12. cxd5 Nxd5
13. Rc1 Qb7 14. a3 O-O 15. Ne4 Be7 16. Bd3 Ne5 17. Bb1 f5 18. Bxe7 Qxe7
19. Nd2 Bb7 20. O-O Rad8 21. Qe2 Qf6 22. Ba2 Kh8 23. h3 g5 24. Nc4 Ng6
25. Qb2 Ba8 26. Nxe6 1-0
''';

const String _finishedEventFen =
    'b2r1r1k/7p/pp2Nqn1/3n1pp1/1PN5/P3P2P/BQ3PP1/2R2RK1 b - - 0 26';

const String _drawnEventPgn = '''
[Event "Drawn event"]
[White "White"]
[Black "Black"]
[Result "1/2-1/2"]

1. e4 e5 2. Nf3 Nc6 1/2-1/2
''';

const String _drawnEventFen =
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

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

Offset _boardSquareOffset(WidgetTester tester, Square square) {
  final rect = tester.getRect(find.byKey(const ValueKey('board-container')));
  final squareSize = rect.width / 8;
  return Offset(
    rect.left + (square.file * squareSize) + squareSize / 2,
    rect.top + ((7 - square.rank) * squareSize) + squareSize / 2,
  );
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
