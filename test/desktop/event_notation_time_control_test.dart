import 'dart:io';
import 'dart:convert';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/utils/notation_move_timing.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const rawControl = '1 min + 2 sec / move';
const rawPgn =
    '[White "White"]\n[Black "Black"]\n[Result "1/2-1/2"]\n\n'
    '1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]} 1/2-1/2';

PlayerCard player(String name) => PlayerCard(
  name: name,
  federation: '',
  title: '',
  rating: 0,
  countryCode: '',
  team: null,
);

GamesTourModel source(String pgn, {String? control = rawControl}) =>
    GamesTourModel(
      gameId: 'timing-game',
      source: GameSource.supabase,
      whitePlayer: player('White'),
      blackPlayer: player('Black'),
      whiteTimeDisplay: '00:59',
      blackTimeDisplay: '00:58',
      whiteClockSeconds: 59,
      blackClockSeconds: 58,
      whiteClockCentiseconds: 5900,
      blackClockCentiseconds: 5800,
      gameStatus: GameStatus.draw,
      roundId: 'round',
      tourId: 'timing-tour',
      pgn: pgn,
      timeControlText: control,
    );

Future<void> pumpBoard(
  WidgetTester tester, {
  String pgn = rawPgn,
  String? control = rawControl,
  BoardTabGameArgs? openingArgs,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1800, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final args =
      openingArgs ??
      BoardTabGameArgs(
        gameId: 'timing-game',
        pgn: pgn,
        label: 'Timing fixture',
        whiteName: 'White',
        blackName: 'Black',
        sourceGame: source(pgn, control: control),
      );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardTabGameArgsByTabIdProvider.overrideWith(
          (ref) => {'tournaments-default': args},
        ),
        boardSettingsProviderNew.overrideWith(_BoardSettings.new),
        engineSettingsProviderNew.overrideWith(_EngineSettings.new),
        keyboardShortcutsProvider.overrideWith(_Shortcuts.new),
        liveGameUpdateArrivalStreamProvider.overrideWith(
          (ref, id) => const Stream.empty(),
        ),
        gameUpdatesBatchStreamProvider.overrideWith(
          (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: BoardPane(tabId: 'tournaments-default')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // Only optional profile/tour enrichment is stubbed; the Board, source DTO,
    // metadata parsing, timing cache, notation and window payload are real.
    await Supabase.initialize(
      url: 'http://127.0.0.1:54321',
      anonKey: 'LOCAL-FIXTURE-KEY',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (request) async => http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
    );
    directory = await Directory(
      Platform.environment['CHESSEVER_TEST_TMP'] ?? Directory.systemTemp.path,
    ).createTemp('event-timing-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
    await AppDatabase.instance.database;
  });
  tearDownAll(() async {
    await AppDatabase.instance.close();
    await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'rail summaries retain detailed timing through thin realtime projections',
    () {
      final original = source(rawPgn);
      final summary = TournamentGameSummary.fromGamesTourModel(original);
      final updated = tournamentSummaryWithArbitratedLiveGame(
        structuralSummary: summary,
        liveGame: source(rawPgn, control: null),
      ).copyWith(pgn: rawPgn);
      expect(
        gamesTourModelFromTournamentSummary(updated).timeControlText,
        rawControl,
      );
    },
  );

  testWidgets(
    'detached Events Board retains timing without serializing the source model',
    (tester) async {
      final game = source(rawPgn);
      final original = BoardTabGameArgs(
        gameId: game.gameId,
        pgn: rawPgn,
        label: 'Detached timing',
        whiteName: 'White',
        blackName: 'Black',
        sourceGame: game,
        eventGames: [TournamentGameSummary.fromGamesTourModel(game)],
      );
      final decoded =
          DesktopBoardWindowPayload.decode(
            DesktopBoardWindowPayload.fromArgs(original).encode(),
          ).args!;
      expect(decoded.sourceGame, isNull);
      expect(
        gamesTourModelFromTournamentSummary(
          decoded.eventGames.single,
        ).timeControlText,
        rawControl,
      );
      await pumpBoard(tester, openingArgs: decoded);
      final notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      expect(notation.game.metadata['TimeControl'], '60+2');
      expect(find.text('3s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  test(
    'canonical navigation keeps timing metadata even when its position is stale',
    () {
      final current = source(rawPgn, control: null).copyWith(
        lastMoveTime: DateTime.utc(2026, 10, 21, 18, 2),
        whiteClockSeconds: 20,
      );
      final incoming = source(
        rawPgn,
      ).copyWith(lastMoveTime: DateTime.utc(2026, 10, 21, 18, 1));
      final selected = selectFreshestNavigationGame(
        current: current,
        incoming: incoming,
      );
      expect(selected.timeControlText, rawControl);
      expect(selected.lastMoveTime, current.lastMoveTime);
      expect(selected.whiteClockSeconds, 20);
      expect(current.timeControlText, isNull);
    },
  );

  final captureDirectory = Platform.environment['CHESSEVER_TIMING_CAPTURE'];
  final sourceRowPath = Platform.environment['CHESSEVER_EVENT_TIMING_ROW'];
  for (final mode in NotationLayoutMode.values) {
    testWidgets(
      'captured Wei Yi Nihal Events replay shows elapsed in ${mode.name}',
      (tester) async {
        final captured = ChessGame.fromJson(
          jsonDecode(
                File('$captureDirectory/captured-game.json').readAsStringSync(),
              )
              as Map<String, dynamic>,
        );
        final before = jsonEncode(captured.toJson());
        expect(captured.mainline, hasLength(67));
        expect(captured.metadata['TimeControl'], isNull);
        final capturedPgn = exportGameToPgn(captured);
        // Replay the owner-bound 67-ply snapshot with its actual joined tour
        // metadata. No TimeControl header is manually inserted into the PGN.
        final row =
            jsonDecode(File(sourceRowPath!).readAsStringSync())
                as Map<String, dynamic>;
        row['pgn'] = capturedPgn;
        final hydrated = GamesTourModel.fromGame(Games.fromJson(row));
        expect(hydrated.gameId, 'IdGFiaCN');
        expect(hydrated.whitePlayer.name, captured.metadata['White']);
        expect(hydrated.blackPlayer.name, captured.metadata['Black']);
        final args = BoardTabGameArgs(
          gameId: hydrated.gameId,
          pgn: capturedPgn,
          label: 'Actual Events replay',
          whiteName: hydrated.whitePlayer.name,
          blackName: hydrated.blackPlayer.name,
          sourceGame: hydrated,
        );
        await pumpBoard(tester, openingArgs: args);
        var notation = tester.widget<NotationLadderView>(
          find.byType(NotationLadderView),
        );
        notation.layoutModeController!.value = mode;
        await tester.pump();
        notation = tester.widget<NotationLadderView>(
          find.byType(NotationLadderView),
        );
        expect(notation.game.metadata['TimeControl'], '40/5400+30:1800+30');
        final timing = NotationMoveTimingIndex.fromGame(notation.game);
        expect([
          for (var i = 0; i < 67; i++)
            if (timing.at([i])?.elapsed != null) i,
        ], hasLength(66));
        expect(
          notation.game.mainline.map((m) => m.clockTime).toList(),
          captured.mainline.map((m) => m.clockTime).toList(),
        );
        expect(jsonEncode(captured.toJson()), before);
        expect(args.pgn, capturedPgn);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
      skip: captureDirectory == null || sourceRowPath == null,
    );
  }

  testWidgets('an unbound imported game never borrows orphaned event timing', (
    tester,
  ) async {
    await pumpBoard(
      tester,
      openingArgs: const BoardTabGameArgs(
        pgn: rawPgn,
        label: 'Imported',
        whiteName: 'White',
        blackName: 'Black',
        timeControlText: rawControl,
      ),
    );
    final notation = tester.widget<NotationLadderView>(
      find.byType(NotationLadderView),
    );
    expect(notation.game.metadata['TimeControl'], isNull);
    expect(
      NotationMoveTimingIndex.fromGame(notation.game).at([0])?.elapsed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  test('missing context is never borrowed from another game or tour', () {
    final current = source(rawPgn, control: null);
    for (final other in [
      source(rawPgn).copyWith(gameId: 'other'),
      source(rawPgn).copyWith(tourId: 'other-tour'),
    ]) {
      expect(
        retainMissingGameTimeControl(
          selected: current,
          alternate: other,
        ).timeControlText,
        isNull,
      );
    }
    expect(source(rawPgn), isNot(current));
    expect({source(rawPgn), current}, hasLength(2));
  });

  test(
    'Games row summary factory and metadata-only copies retain the control',
    () {
      final row = Games(
        id: 'game',
        roundId: 'round',
        roundSlug: 'round',
        tourId: 'tour',
        tourSlug: 'tour',
        timeControlText: rawControl,
      );
      final summary = TournamentGameSummary.fromGame(
        row,
      ).copyWith(whitePlayer: 'Changed');
      expect(
        gamesTourModelFromTournamentSummary(summary).timeControlText,
        rawControl,
      );
    },
  );

  test(
    'saved private analysis remains clean after an unchanged canonical refresh',
    () {
      final editedPgn = rawPgn
          .replaceFirst('[%clk 0:00:59]', 'Private comment [%clk 0:00:59]')
          .replaceFirst('e5 {', 'e5 (1... c5 \$247 {Saved variation}) {');
      ChessGame prepare(String pgn) {
        final game = ChessGame.fromPgn('timing-game', pgn);
        return game.copyWith(
          metadata: mergeDesktopGameMetadataForLibrary(
            Map.of(game.metadata),
            source(pgn),
          ),
        );
      }

      final saved = prepare(editedPgn);
      final savedPgn = exportGameToPgn(saved);
      final refreshed = reconcileCanonicalBroadcastLocalAnnotationsForTesting(
        previousBroadcastPgn: rawPgn,
        currentGame: saved,
        freshGame: prepare(rawPgn),
        userNags: const {},
      );
      expect(exportGameToPgn(refreshed.game), contains('Saved variation'));
      expect(exportGameToPgn(refreshed.game), contains('Private comment'));
      expect(refreshed.game.metadata['TimeControl'], '60+2');
      expect(
        shouldConfirmBoardAnalysisDiscard(
          dirtySinceLoad: refreshed.hasLocalEdits,
          currentPgn: exportGameToPgn(refreshed.game),
          lastAppliedPgn: rawPgn,
          lastSavedAnalysisPgn: savedPgn,
        ),
        isFalse,
      );
      final changed = refreshed.game.copyWith(
        metadata: {...refreshed.game.metadata, 'TimeControl': '120+2'},
      );
      expect(
        shouldConfirmBoardAnalysisDiscard(
          dirtySinceLoad: false,
          currentPgn: exportGameToPgn(changed),
          lastAppliedPgn: rawPgn,
          lastSavedAnalysisPgn: savedPgn,
        ),
        isTrue,
        reason: 'User edits to the control are not globally ignored',
      );
    },
  );

  testWidgets(
    'native PGN save and reopen retain machine seconds and elapsed labels',
    (tester) async {
      await pumpBoard(tester);
      final game =
          tester
              .widget<NotationLadderView>(find.byType(NotationLadderView))
              .game;
      final file = File('${directory.path}/saved-timing.pgn');
      final pgn = exportGameToPgn(game);
      expect(pgn, contains('[TimeControl "60+2"]'));
      await tester.runAsync(() => file.writeAsString(pgn));
      final reopened = await tester.runAsync(() => file.readAsString());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await pumpBoard(
        tester,
        openingArgs: BoardTabGameArgs(
          pgn: reopened!,
          label: 'Saved timing',
          whiteName: 'White',
          blackName: 'Black',
        ),
      );
      final restored =
          tester
              .widget<NotationLadderView>(find.byType(NotationLadderView))
              .game;
      expect(restored.metadata['TimeControl'], '60+2');
      expect(NotationMoveTimingIndex.fromGame(restored).at([0])?.label, '3s');
      expect(
        restored.mainline.map((m) => m.clockTime),
        game.mainline.map((m) => m.clockTime),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('same-PGN game switch clears the prior detached timing context', (
    tester,
  ) async {
    final original = BoardTabGameArgs(
      gameId: 'timing-game',
      pgn: rawPgn,
      label: 'A',
      whiteName: 'White',
      blackName: 'Black',
      sourceGame: source(rawPgn),
    );
    final decoded =
        DesktopBoardWindowPayload.decode(
          DesktopBoardWindowPayload.fromArgs(original).encode(),
        ).args!;
    await pumpBoard(tester, openingArgs: decoded);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BoardPane)),
    );
    final other = source(
      rawPgn,
      control: null,
    ).copyWith(gameId: 'other', tourId: 'other-tour');
    final next = decoded.copyWith(gameId: 'other', sourceGame: other);
    expect(next.timeControlText, isNull);
    container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
      'tournaments-default': next,
    };
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final game =
        tester.widget<NotationLadderView>(find.byType(NotationLadderView)).game;
    expect(game.metadata['TimeControl'], isNull);
    expect(NotationMoveTimingIndex.fromGame(game).at([0])?.elapsed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an imported machine TimeControl wins over event prose', (
    tester,
  ) async {
    await pumpBoard(
      tester,
      pgn: '[TimeControl "60+2"]\n$rawPgn',
      control: '2 min + 5 sec / move',
    );
    final game =
        tester.widget<NotationLadderView>(find.byType(NotationLadderView)).game;
    expect(game.metadata['TimeControl'], '60+2');
    expect(NotationMoveTimingIndex.fromGame(game).at([0])?.label, '3s');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final control in <String?>[null, 'standard', 'blitz']) {
    testWidgets(
      'unknown or category-only source control $control stays uninferred',
      (tester) async {
        await pumpBoard(tester, control: control);
        final game =
            tester
                .widget<NotationLadderView>(find.byType(NotationLadderView))
                .game;
        expect(NotationMoveTimingIndex.fromGame(game).at([0])?.elapsed, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
    );
  }

  test('unsupported delay descriptions never become Fischer increments', () {
    for (final control in [
      '1 min + 2 sec delay',
      '1 min + 2 sec Bronstein',
      '30 sec byoyomi',
      '5 min White vs 4 min Black',
    ]) {
      final metadata = mergeDesktopGameMetadataForLibrary(
        {},
        source(rawPgn, control: control),
      );
      expect(metadata['TimeControl'], isNull, reason: control);
    }
  });

  test('saving an unedited source keeps its detailed TimeControl', () {
    final metadata = mergeDesktopGameMetadataForLibrary({}, source(rawPgn));
    expect(metadata['TimeControl'], '60+2');
  });

  testWidgets(
    'real Events Board derives elapsed time from source DTO before parsing',
    (tester) async {
      await pumpBoard(tester);
      final notation = tester.widget<NotationLadderView>(
        find.byType(NotationLadderView),
      );
      expect(notation.game.metadata['TimeControl'], '60+2');
      final timings = NotationMoveTimingIndex.fromGame(notation.game);
      expect(timings.at([0])?.label, '3s');
      expect(timings.at([1])?.label, '4s');
      expect(find.text('3s'), findsOneWidget);
      expect(notation.game.mainline.first.clockTime, '0:00:59');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}

class _BoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(soundEnabled: false, showEvaluationBar: false);
}

class _EngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineGauge: false, showEngineAnalysis: false);
}

class _Shortcuts extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}
