import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:country_picker/country_picker.dart';

import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

void main() {
  test('board window payload round-trips serializable board args', () {
    final args = _args(
      gameId: 'game-1',
      pgn: '1. e4 e5 *',
      initialBoardFlipped: true,
      fenSeed: 'fen-seed',
      initialFen: 'initial-fen',
      viewSource: ChessboardView.favScorecard,
      gameListSelectedId: 'selected-1',
      eventBroadcastId: 'parent-event',
      eventGames: [_summary('game-1')],
      eventGamesKey: const BoardTabEventGamesKey(
        tourId: 'tour-1',
        selectedGameId: 'game-1',
        selectedRoundId: 'round-1',
        selectedBoardNumber: 1,
      ),
      routeGames: [_summary('route-1', roundLabel: 'R2')],
      databaseGames: [
        _summary(
          'database-1',
          pgn: '1. d4 d5 *',
          localPgnSource: const TournamentGameLocalPgnSource(
            sourcePath: '/tmp/local-games.pgn',
            sourceIndex: 4,
            sourceFileGameCount: 12,
            title: 'Local Carlsen vs Nakamura',
          ),
        ),
      ],
      eventGamesContinuation: const BoardTabGamesContinuation.favorites(),
      routeGamesContinuation: const BoardTabGamesContinuation.countrymen(),
      databaseGamesContinuation: const BoardTabGamesContinuation.twicDatabase(),
      librarySaveOrigin: const BoardTabLibrarySaveOrigin.localPgnFile(
        sourcePath: '/tmp/local-games.pgn',
        sourceIndex: 4,
        sourceFileGameCount: 12,
        title: 'Local Carlsen vs Nakamura',
      ),
    );

    final decoded = DesktopBoardWindowPayload.decode(
      DesktopBoardWindowPayload.fromArgs(args).encode(),
    );

    expect(decoded.title, 'Carlsen vs Nakamura');
    expect(decoded.kind, TabKind.board);
    expect(decoded.args?.gameId, 'game-1');
    expect(decoded.args?.pgn, '1. e4 e5 *');
    expect(decoded.args?.whiteName, 'Carlsen');
    expect(decoded.args?.blackName, 'Nakamura');
    expect(decoded.args?.whiteFederation, 'NOR');
    expect(decoded.args?.blackFederation, 'USA');
    expect(decoded.args?.whiteFideId, 1503014);
    expect(decoded.args?.blackFideId, 2016192);
    expect(decoded.args?.initialBoardFlipped, isTrue);
    expect(decoded.args?.fenSeed, 'fen-seed');
    expect(decoded.args?.initialFen, 'initial-fen');
    expect(decoded.args?.viewSource, ChessboardView.favScorecard);
    expect(decoded.args?.gameListSelectedId, 'selected-1');
    expect(decoded.args?.eventBroadcastId, 'parent-event');
    expect(decoded.args?.eventGames.single.id, 'game-1');
    expect(decoded.args?.eventGames.single.whitePlayer, 'Carlsen');
    expect(decoded.args?.eventGames.single.status, GameStatus.ongoing);
    expect(decoded.args?.eventGamesKey?.tourId, 'tour-1');
    expect(decoded.args?.eventGamesKey?.selectedGameId, 'game-1');
    expect(decoded.args?.eventGamesKey?.selectedRoundId, 'round-1');
    expect(decoded.args?.eventGamesKey?.selectedBoardNumber, 1);
    expect(decoded.args?.routeGames.single.id, 'route-1');
    expect(decoded.args?.routeGames.single.roundLabel, 'R2');
    expect(decoded.args?.databaseGames.single.id, 'database-1');
    expect(decoded.args?.databaseGames.single.pgn, '1. d4 d5 *');
    expect(
      decoded.args?.databaseGames.single.localPgnSource?.sourcePath,
      '/tmp/local-games.pgn',
    );
    expect(decoded.args?.databaseGames.single.localPgnSource?.sourceIndex, 4);
    expect(
      decoded.args?.librarySaveOrigin?.kind,
      BoardTabLibrarySaveOriginKind.localPgnFile,
    );
    expect(decoded.args?.librarySaveOrigin?.sourceIndex, 4);
    expect(
      decoded.args?.eventGamesContinuation?.kind,
      BoardTabGamesContinuationKind.favorites,
    );
    expect(
      decoded.args?.routeGamesContinuation?.kind,
      BoardTabGamesContinuationKind.countrymen,
    );
    expect(
      decoded.args?.databaseGamesContinuation?.kind,
      BoardTabGamesContinuationKind.twicDatabase,
    );
  });

  test('tab window payload round-trips non-board route identity', () {
    const tab = DesktopTab(
      id: 'tab-1',
      kind: TabKind.library,
      title: 'Library',
      subtitle: 'Databases',
    );

    final decoded = DesktopBoardWindowPayload.decode(
      DesktopBoardWindowPayload.fromTab(tab).encode(),
    );

    expect(decoded.kind, TabKind.library);
    expect(decoded.title, 'Library');
    expect(decoded.subtitle, 'Databases');
    expect(decoded.args, isNull);
  });

  test('opening a board window does not mutate main-window tabs', () async {
    late DesktopBoardWindowPayload captured;
    final container = ProviderContainer(
      overrides: [
        desktopBoardWindowServiceProvider.overrideWithValue(
          DesktopBoardWindowService(
            createWindow: (payload) async => captured = payload,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final before = container.read(desktopTabsProvider).tabs.length;

    await container
        .read(desktopBoardWindowServiceProvider)
        .openBoardGameWindow(_args(gameId: 'game-1'));

    expect(captured.args?.gameId, 'game-1');
    expect(container.read(desktopTabsProvider).tabs.length, before);
  });

  test(
    'detaching a board tab closes it after window creation succeeds',
    () async {
      final opened = <DesktopBoardWindowPayload>[];
      final container = ProviderContainer(
        overrides: [
          desktopBoardWindowServiceProvider.overrideWithValue(
            DesktopBoardWindowService(
              createWindow: (payload) async => opened.add(payload),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final tabId = openBoardGameTabFromContainer(
        container,
        _args(gameId: 'game-1'),
        reuseExisting: false,
      );

      final detached = await detachBoardTabToWindow(container, tabId);

      expect(detached, isTrue);
      expect(opened.single.kind, TabKind.board);
      expect(opened.single.args?.gameId, 'game-1');
      expect(
        container.read(desktopTabsProvider).tabs.any((tab) => tab.id == tabId),
        isFalse,
      );
    },
  );

  test('failed detach keeps the original board tab open', () async {
    final container = ProviderContainer(
      overrides: [
        desktopBoardWindowServiceProvider.overrideWithValue(
          DesktopBoardWindowService(
            createWindow: (_) async => throw StateError('window failed'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final tabId = openBoardGameTabFromContainer(
      container,
      _args(gameId: 'game-1'),
      reuseExisting: false,
    );

    await expectLater(
      detachBoardTabToWindow(container, tabId),
      throwsStateError,
    );

    expect(
      container.read(desktopTabsProvider).tabs.any((tab) => tab.id == tabId),
      isTrue,
    );
  });

  test('non-board tabs do not detach to a tab-content window', () async {
    final opened = <DesktopBoardWindowPayload>[];
    final container = ProviderContainer(
      overrides: [
        desktopBoardWindowServiceProvider.overrideWithValue(
          DesktopBoardWindowService(
            createWindow: (payload) async => opened.add(payload),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final tabId = container
        .read(desktopTabsProvider.notifier)
        .open(TabKind.library, reuseExisting: false);

    final detached = await detachDesktopTabToWindow(container, tabId);

    expect(detached, isFalse);
    expect(opened, isEmpty);
    expect(
      container.read(desktopTabsProvider).tabs.any((tab) => tab.id == tabId),
      isTrue,
    );
  });

  test(
    'countrymen tab window payload preserves selected country and mode',
    () async {
      late DesktopBoardWindowPayload captured;
      final container = ProviderContainer(
        overrides: [
          desktopBoardWindowServiceProvider.overrideWithValue(
            DesktopBoardWindowService(
              createWindow: (payload) async => captured = payload,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final india = CountryService().findByCode('IN');
      expect(india, isNotNull);
      container.read(temporaryCountryProvider.notifier).state = india;
      container.read(selectedCountrymenModeProvider.notifier).state =
          CountrymenScreenMode.events;
      final tabId = container
          .read(desktopTabsProvider.notifier)
          .open(TabKind.countrymen, reuseExisting: false);
      final tab = container
          .read(desktopTabsProvider)
          .tabs
          .firstWhere((tab) => tab.id == tabId);

      await container
          .read(desktopBoardWindowServiceProvider)
          .openDesktopTabWindow(container, tab);

      expect(captured.kind, TabKind.countrymen);
      expect(captured.metadata['countryCode'], 'IN');
      expect(captured.metadata['countryName'], india!.name);
      expect(
        captured.metadata['countrymenMode'],
        CountrymenScreenMode.events.name,
      );
    },
  );
}

BoardTabGameArgs _args({
  String? gameId,
  String pgn = '',
  bool initialBoardFlipped = false,
  String? fenSeed,
  String? initialFen,
  ChessboardView viewSource = ChessboardView.tour,
  String? gameListSelectedId,
  String? eventBroadcastId,
  List<TournamentGameSummary> eventGames = const <TournamentGameSummary>[],
  BoardTabEventGamesKey? eventGamesKey,
  List<TournamentGameSummary> routeGames = const <TournamentGameSummary>[],
  List<TournamentGameSummary> databaseGames = const <TournamentGameSummary>[],
  BoardTabGamesContinuation? eventGamesContinuation,
  BoardTabGamesContinuation? routeGamesContinuation,
  BoardTabGamesContinuation? databaseGamesContinuation,
  BoardTabLibrarySaveOrigin? librarySaveOrigin,
}) {
  return BoardTabGameArgs(
    gameId: gameId,
    pgn: pgn,
    label: 'Carlsen vs Nakamura',
    whiteName: 'Carlsen',
    blackName: 'Nakamura',
    whiteFederation: 'NOR',
    blackFederation: 'USA',
    whiteTitle: 'GM',
    blackTitle: 'GM',
    whiteRating: 2830,
    blackRating: 2800,
    whiteFideId: 1503014,
    blackFideId: 2016192,
    initialBoardFlipped: initialBoardFlipped,
    fenSeed: fenSeed,
    initialFen: initialFen,
    viewSource: viewSource,
    gameListSelectedId: gameListSelectedId,
    eventBroadcastId: eventBroadcastId,
    eventGames: eventGames,
    eventGamesKey: eventGamesKey,
    routeGames: routeGames,
    databaseGames: databaseGames,
    eventGamesContinuation: eventGamesContinuation,
    routeGamesContinuation: routeGamesContinuation,
    databaseGamesContinuation: databaseGamesContinuation,
    librarySaveOrigin: librarySaveOrigin,
  );
}

TournamentGameSummary _summary(
  String id, {
  String roundLabel = 'R1',
  String? pgn,
  TournamentGameLocalPgnSource? localPgnSource,
}) {
  return TournamentGameSummary(
    id: id,
    name: 'Carlsen vs Nakamura',
    whitePlayer: 'Carlsen',
    blackPlayer: 'Nakamura',
    hasPgn: pgn != null,
    tourId: 'tour-1',
    tourSlug: 'tour-slug',
    whiteFederation: 'NOR',
    blackFederation: 'USA',
    whiteTitle: 'GM',
    blackTitle: 'GM',
    whiteRating: 2830,
    blackRating: 2800,
    whiteFideId: 1503014,
    blackFideId: 2016192,
    fen: 'summary-fen',
    roundId: 'round-1',
    roundSlug: 'round-1',
    roundLabel: roundLabel,
    boardNumber: 1,
    status: GameStatus.ongoing,
    openingName: 'Sicilian Defense',
    lastMoveTime: DateTime.utc(2026, 6, 19, 12),
    startsAt: DateTime.utc(2026, 6, 19, 11),
    roundStartsAt: DateTime.utc(2026, 6, 19, 10),
    hasStarted: true,
    pgn: pgn,
    localPgnSource: localPgnSource,
  );
}
