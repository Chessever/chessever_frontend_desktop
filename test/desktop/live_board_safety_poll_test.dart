import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_past_event_access.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/desktop_board_access_gate.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/utils/date_time_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _livePgn =
    '[Event "Total Chess"]\n'
    '[White "Niemann, Hans Moke"]\n'
    '[Black "Nepomniachtchi, Ian"]\n'
    '[Result "*"]\n\n'
    '1. Nf3 d5 2. e3 *';
const _liveFen =
    'rnbqkbnr/ppp1pppp/8/3p4/8/4PN2/PPPP1PPP/RNBQKB1R w KQkq - 0 3';

PlayerCard _player(String name) => PlayerCard(
  name: name,
  federation: 'USA',
  title: 'GM',
  rating: 2700,
  countryCode: 'USA',
  team: null,
);

GamesTourModel _preStartGame() => GamesTourModel(
  gameId: 'live-seed',
  source: GameSource.supabase,
  whitePlayer: _player('Niemann, Hans Moke'),
  blackPlayer: _player('Nepomniachtchi, Ian'),
  whiteTimeDisplay: '03:02',
  blackTimeDisplay: '03:02',
  whiteClockCentiseconds: 18200,
  blackClockCentiseconds: 18200,
  whiteClockSeconds: 182,
  blackClockSeconds: 182,
  gameStatus: GameStatus.ongoing,
  roundId: 'round-8',
  tourId: 'total-chess',
  fen: _startFen,
);

LiveGameUpdate _liveUpdate() => LiveGameUpdate(
  gameId: 'live-seed',
  pgn: _livePgn,
  fen: _liveFen,
  lastMove: 'e2e3',
  lastMoveTime: DateTime.now().toUtc().toIso8601String(),
  lastClockWhite: 176,
  lastClockBlack: 179,
  status: 'live',
  players: [
    {
      'name': 'Niemann, Hans Moke',
      'fed': 'USA',
      'rating': 2700,
      'clock': 17600,
    },
    {
      'name': 'Nepomniachtchi, Ian',
      'fed': 'RUS',
      'rating': 2765,
      'clock': 17900,
    },
  ],
  isFullRow: true,
);

class _PollRepository extends GameStreamRepository {
  _PollRepository(this.update);

  final LiveGameUpdate? update;
  int reads = 0;

  @override
  Future<LiveGameUpdate?> fetchCurrentLiveGameUpdate(String gameId) async {
    reads++;
    return update;
  }
}

class _BoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(showEvaluationBar: false);
}

class _EngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings();
}

class _Shortcuts extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}

class _IdleGames extends StateNotifier<AsyncValue<List<Games>>>
    implements GamesTourNotifier {
  _IdleGames() : super(const AsyncValue.loading());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
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
    ).createTemp('live-board-poll-');
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

  test('safety poll is limited to foreground broadcast boards', () {
    BoardTabGameArgs args({GameSource? source, String databaseTitle = ''}) =>
        BoardTabGameArgs(
          gameId: 'live-seed',
          pgn: '',
          label: 'Game',
          whiteName: '',
          blackName: '',
          databaseTitle: databaseTitle,
          sourceGame:
              source == null
                  ? _preStartGame()
                  : _preStartGame().copyWith(source: source),
        );

    expect(
      shouldRunLiveBoardSafetyPoll(
        isForegroundTab: true,
        gameId: 'live-seed',
        args: args(),
      ),
      isTrue,
    );
    expect(
      shouldRunLiveBoardSafetyPoll(
        isForegroundTab: false,
        gameId: 'live-seed',
        args: args(),
      ),
      isFalse,
    );
    expect(
      shouldRunLiveBoardSafetyPoll(
        isForegroundTab: true,
        gameId: null,
        args: args(),
      ),
      isFalse,
    );
    expect(
      shouldRunLiveBoardSafetyPoll(
        isForegroundTab: true,
        gameId: 'live-seed',
        args: args(databaseTitle: 'My database'),
      ),
      isFalse,
    );
    expect(
      shouldRunLiveBoardSafetyPoll(
        isForegroundTab: true,
        gameId: 'live-seed',
        args: args(source: GameSource.gamebase),
      ),
      isFalse,
    );
  });

  test('a server report names the games row only for a broadcast tab', () {
    BoardTabGameArgs args({
      String? gameId = 'GLT6Si5W',
      String databaseTitle = '',
      GameSource? source,
      bool withSourceGame = true,
    }) => BoardTabGameArgs(
      gameId: gameId,
      pgn: '',
      label: 'Game',
      whiteName: '',
      blackName: '',
      databaseTitle: databaseTitle,
      sourceGame:
          !withSourceGame
              ? null
              : source == null
              ? _preStartGame()
              : _preStartGame().copyWith(source: source),
    );

    expect(boardReportDatabaseGameId(args()), 'GLT6Si5W');
    // A tab opened by id alone, with no source model yet, is a broadcast tab.
    expect(boardReportDatabaseGameId(args(withSourceGame: false)), 'GLT6Si5W');
    expect(boardReportDatabaseGameId(args(gameId: ' GLT6Si5W ')), 'GLT6Si5W');

    // No tab, a scratch board, or a detached PGN: there is no id to send.
    expect(boardReportDatabaseGameId(null), isNull);
    expect(boardReportDatabaseGameId(args(gameId: null)), isNull);
    expect(boardReportDatabaseGameId(args(gameId: '  ')), isNull);
    // A local database owns its snapshot even when its id looks like a row's.
    expect(
      boardReportDatabaseGameId(args(databaseTitle: 'My database')),
      isNull,
    );
    // Every other source carries an id from another store.
    for (final source in GameSource.values) {
      if (source == GameSource.supabase) continue;
      expect(
        boardReportDatabaseGameId(args(source: source)),
        isNull,
        reason: source.name,
      );
    }
  });

  test('safety poll only feeds rows that changed the board', () {
    final update = _liveUpdate();
    final current = mergeLiveGameUpdateWithBase(
      baseGame: _preStartGame(),
      update: update,
    );

    expect(liveUpdateCarriesNewGameData(_preStartGame(), update), isTrue);
    expect(liveUpdateCarriesNewGameData(current, update), isFalse);
    expect(
      liveUpdateCarriesNewGameData(
        current,
        LiveGameUpdate(
          gameId: update.gameId,
          pgn: update.pgn,
          fen: update.fen,
          lastMove: update.lastMove,
          lastMoveTime: update.lastMoveTime,
          lastClockWhite: 170,
          lastClockBlack: update.lastClockBlack,
          status: update.status,
          players: update.players,
          isFullRow: true,
        ),
      ),
      isTrue,
    );
  });

  testWidgets(
    'a focused live board falls back to an exact row read when Realtime is '
    'silent',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final repository = _PollRepository(_liveUpdate());
      final game = _preStartGame();
      final args = BoardTabGameArgs(
        gameId: game.gameId,
        pgn: '',
        label: 'Niemann vs Nepomniachtchi',
        whiteName: game.whitePlayer.name,
        blackName: game.blackPlayer.name,
        fenSeed: _startFen,
        sourceGame: game,
        eventGames: [TournamentGameSummary.fromGamesTourModel(game)],
        gameListSelectedId: game.gameId,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopPastEventAccessEnabledProvider.overrideWithValue(false),
            desktopBoardMembershipRecheckEnabledProvider.overrideWithValue(
              false,
            ),
            desktopEntitlementProvider.overrideWithValue(
              DesktopEntitlementSnapshot.guest,
            ),
            subscriptionProvider.overrideWith(
              (_) => _Subscription(SubscriptionState()),
            ),
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => <String, BoardTabGameArgs>{'tournaments-default': args},
            ),
            boardSettingsProviderNew.overrideWith(_BoardSettings.new),
            engineSettingsProviderNew.overrideWith(_EngineSettings.new),
            keyboardShortcutsProvider.overrideWith(_Shortcuts.new),
            gameStreamRepositoryProvider.overrideWithValue(repository),
            dateTimeProvider.overrideWith(
              (ref) => Stream<DateTime>.value(DateTime.now()),
            ),
            gamesTourProvider.overrideWith((ref, tourId) => _IdleGames()),
            liveGameUpdateArrivalStreamProvider.overrideWith(
              (ref, id) =>
                  const Stream<LiveStreamArrival<LiveGameUpdate?>>.empty(),
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

      expect(find.text('No move played yet.'), findsOneWidget);

      // No Realtime arrival in this fixture: only the timer can recover.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));

      expect(repository.reads, greaterThan(0));
      expect(find.text('No move played yet.'), findsNothing);
      expect(find.text('02:56'), findsWidgets);
      expect(find.text('02:59'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
