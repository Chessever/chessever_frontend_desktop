import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/panes/desktop_smart_games_pane.dart';
import 'package:chessever/desktop/panes/library_pane.dart'
    show openLibraryLikedAnalysis;
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/services/miniatures_access.dart';
import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/desktop_date_gate_prompt.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart'
    show admitEventRailContentAction;
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

const _kFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _kTabId = 'smart-tab';
const _lockedMiniatureId = '0b1c2d3e-0000-4000-8000-000000000001';
const _todayMiniatureId = '0b1c2d3e-0000-4000-8000-000000000002';

/// Counts every PGN/game fetch a board open could start.
class _CountingGameRepository implements GameRepository {
  int fetches = 0;

  @override
  Future<Games> getGameWithPGN(String gameId) async {
    fetches++;
    throw StateError('offline in tests');
  }

  @override
  Future<String?> getGamePgn(String gameId) async {
    fetches++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SilentGameStreamRepository extends GameStreamRepository {
  @override
  Stream<Map<String, dynamic>?> subscribeToGameUpdates(String gameId) =>
      const Stream.empty();

  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) =>
      const Stream.empty();

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) => const Stream.empty();

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) => const Stream.empty();

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) => const Stream.empty();
}

/// The real collection notifier, seeded instead of fetching.
class _SeededPremiumGamesNotifier extends PremiumGamesNotifier {
  _SeededPremiumGamesNotifier(super.ref, super.type, this.seed);

  final List<GamesTourModel> seed;

  @override
  Future<void> loadGames({bool showLoading = true}) async {
    state = AsyncValue.data(
      PremiumGamesState(
        games: seed,
        filter: PremiumGamesFilter.defaultFilter,
        isLoadingMore: false,
        hasMore: false,
      ),
    );
  }
}

class _QuietBoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _QuietEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings(showEngineGauge: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

PlayerCard _player(String name) => PlayerCard(
  name: name,
  federation: 'NOR',
  title: 'GM',
  rating: 2700,
  countryCode: 'NOR',
  team: null,
);

PlayerCard _miniaturePlayer(String name) => PlayerCard(
  name: name,
  federation: '',
  title: '',
  rating: 2600,
  countryCode: '',
  team: null,
);

/// A game day that is never the local today, whatever the time zone.
DateTime get _lockedDay =>
    DateTime.now().toUtc().subtract(const Duration(days: 3));

/// The UTC calendar day matching the LOCAL today (the free Miniatures day).
DateTime get _todayUtcDay {
  final now = DateTime.now();
  return DateTime.utc(now.year, now.month, now.day);
}

GamesTourModel _miniature(String id, DateTime? date) => GamesTourModel(
  gameId: id,
  source: GameSource.gamebase,
  // Miniatures carry no titles (the gamebase mapping sets none).
  whitePlayer: _miniaturePlayer('Anand'),
  blackPlayer: _miniaturePlayer('Topalov'),
  whiteTimeDisplay: '--:--',
  blackTimeDisplay: '--:--',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: GameStatus.whiteWins,
  roundId: 'gamebase-miniatures',
  tourId: '',
  tourName: 'Miniatures',
  eventName: 'Miniatures',
  pgn: '1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0',
  fen: _kFen,
  lastMoveTime: date,
  dateStart: date,
  gameDay: date,
);

GamesTourModel _broadcastGame({String id = 'broadcast-game-1'}) =>
    GamesTourModel(
      gameId: id,
      whitePlayer: _player('Carlsen'),
      blackPlayer: _player('Nakamura'),
      whiteTimeDisplay: '--:--',
      blackTimeDisplay: '--:--',
      whiteClockCentiseconds: 0,
      blackClockCentiseconds: 0,
      gameStatus: GameStatus.ongoing,
      roundId: 'round-1',
      tourId: 'tour-1',
      tourSlug: 'test-event',
      pgn: '1. e4 e5 *',
      fen: _kFen,
      lastMoveTime: DateTime.now(),
    );

void _useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

List<Override> _freeOverrides(_CountingGameRepository repository) => [
  subscriptionProvider.overrideWith(
    (ref) => SubscriptionNotifier.stub(SubscriptionState()),
  ),
  desktopEntitlementProvider.overrideWithValue(
    const DesktopEntitlementSnapshot(accountId: 'free-user', generation: 1),
  ),
  gameRepositoryProvider.overrideWith((ref) => repository),
  gameStreamRepositoryProvider.overrideWithValue(
    _SilentGameStreamRepository(),
  ),
  boardSettingsProviderNew.overrideWith(_QuietBoardSettings.new),
  engineSettingsProviderNew.overrideWith(_QuietEngineSettings.new),
  gameCardEvalCacheOnlyProvider.overrideWith((ref, fen) async => _cloudEval()),
  gameCardEvalWithStockfishFallbackProvider.overrideWith(
    (ref, fen) async => _cloudEval(),
  ),
];

CloudEval _cloudEval() => CloudEval(
  fen: _kFen,
  knodes: 0,
  depth: 12,
  pvs: [Pv(moves: 'e2e4', cp: 20)],
  requestedMultiPv: 1,
);

Widget _shell({required List<Override> overrides, required Widget body}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      builder:
          (context, child) => FTheme(data: FThemes.zinc.dark, child: child!),
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(
              width: double.infinity,
              height: 46,
              child: DesktopTabBar(),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    ),
  );
}

/// Pumps the real smart-games pane for [type], seeded with [games], under a
/// tab strip, as a free user.
Future<ProviderContainer> _pumpCollection(
  WidgetTester tester, {
  required PremiumGamesType type,
  required List<GamesTourModel> games,
  required _CountingGameRepository repository,
}) async {
  _useDesktopSurface(tester);
  await tester.pumpWidget(
    _shell(
      overrides: [
        ..._freeOverrides(repository),
        desktopSmartGamesTypeByTabIdProvider.overrideWith(
          (ref) => <String, PremiumGamesType>{_kTabId: type},
        ),
        premiumGamesProvider.overrideWith(
          (ref, collection) =>
              _SeededPremiumGamesNotifier(ref, collection, games),
        ),
      ],
      body: const DesktopSmartGamesPane(tabId: _kTabId),
    ),
  );
  await _settle(tester);
  return ProviderScope.containerOf(
    tester.element(find.byType(DesktopSmartGamesPane)),
    listen: false,
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Records every decision the window is asked to present.
List<String> _recordPresentedDecisions(ProviderContainer container) {
  final presented = <String>[];
  final unregister = registerDesktopPaywallPresenter(container, (
    decision, {
    DesktopAccessContext? context,
    DesktopAccessResume? resume,
    required String surface,
  }) async {
    presented.add('$surface:${decision.reason.code}');
    return false;
  });
  addTearDown(unregister);
  return presented;
}

int _tabCount(ProviderContainer container) =>
    container.read(desktopTabsProvider).tabs.length;

Future<void> _commandClick(WidgetTester tester, Finder target) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.tap(target);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await _settle(tester);
}

Future<void> _middleClick(WidgetTester tester, Finder target) async {
  await tester.tap(
    target,
    buttons: kTertiaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await _settle(tester);
}

Future<void> _dropOnTabStrip(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 400));
  await gesture.moveTo(tester.getCenter(find.byType(DesktopTabBar)));
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.up();
  await _settle(tester);
}

Future<void> _dismissDateGate(WidgetTester tester) async {
  expect(find.byType(DesktopDateGateDialog), findsOneWidget);
  await tester.tap(find.text('Not now'));
  await _settle(tester);
  expect(find.byType(DesktopDateGateDialog), findsNothing);
}

DesktopAccessDecision _decideFree(DesktopAccessContext context) =>
    evaluateDesktopAccess(
      context: context,
      subscription: SubscriptionState(),
      entitlement: const DesktopEntitlementSnapshot(accountId: 'free-user'),
    );

SavedAnalysis _like(String id, DateTime likedAt) => SavedAnalysis(
  id: id,
  userId: 'user-1',
  folderId: 'likes',
  title: 'Carlsen vs Nakamura',
  sourceGameId: 'game-$id',
  chessGame: ChessGame.fromPgn(
    'game-$id',
    '[White "Carlsen, Magnus"]\n[Black "Nakamura, Hikaru"]\n'
        '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0',
  ),
  analysisState: const {},
  variationComments: const {},
  lastViewedPosition: -1,
  tags: const [],
  isFavorite: false,
  createdAt: likedAt,
  updatedAt: likedAt,
);

void main() {
  late bool Function() previousForeground;

  setUp(() {
    previousForeground = desktopWindowIsForeground;
    desktopWindowIsForeground = () => true;
  });

  tearDown(() => desktopWindowIsForeground = previousForeground);

  group('locked Miniature, every entry path', () {
    testWidgets('opens no tab and starts no fetch on any entry path', (
      tester,
    ) async {
      final repository = _CountingGameRepository();
      final container = await _pumpCollection(
        tester,
        type: PremiumGamesType.miniatures,
        games: [_miniature(_lockedMiniatureId, _lockedDay)],
        repository: repository,
      );
      final presented = _recordPresentedDecisions(container);
      final tabsBefore = _tabCount(container);
      final card = find.byType(DesktopGameCard);
      expect(card, findsOneWidget);
      // Rendering a locked card never presents anything.
      expect(presented, isEmpty);

      await _commandClick(tester, card);
      await _middleClick(tester, card);
      await _dropOnTabStrip(tester, card);

      // Each explicit gesture explains the specific rule once, in this window.
      expect(presented, const [
        'game_card_new_tab:premium_miniature_not_today',
        'game_card_new_tab:premium_miniature_not_today',
        'tab_strip_drop:premium_miniature_not_today',
      ]);

      // Keyboard: End selects the game, Enter activates it.
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      await _dismissDateGate(tester);

      // Plain click.
      await tester.tap(card);
      await _settle(tester);
      await _dismissDateGate(tester);

      expect(_tabCount(container), tabsBefore);
      expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
      expect(repository.fetches, 0);
    });

    testWidgets('a Miniature dated today still opens in a new tab', (
      tester,
    ) async {
      final repository = _CountingGameRepository();
      final container = await _pumpCollection(
        tester,
        type: PremiumGamesType.miniatures,
        games: [_miniature(_todayMiniatureId, _todayUtcDay)],
        repository: repository,
      );
      final presented = _recordPresentedDecisions(container);
      final tabsBefore = _tabCount(container);

      await _commandClick(tester, find.byType(DesktopGameCard));

      expect(presented, isEmpty);
      expect(_tabCount(container), tabsBefore + 1);
      final opened = container.read(boardTabGameArgsByTabIdProvider).values;
      expect(opened.single.accessContext?.origin, DesktopDiscoveryOrigin.miniatures);
    });
  });

  group('Live collection', () {
    testWidgets(
      'gates tap, keyboard, modifier-click and menu content actions',
      (tester) async {
        final repository = _CountingGameRepository();
        final container = await _pumpCollection(
          tester,
          type: PremiumGamesType.live,
          games: [_broadcastGame(id: 'live-collection-game')],
          repository: repository,
        );
        final presented = _recordPresentedDecisions(container);
        final tabsBefore = _tabCount(container);
        final card = find.byType(DesktopGameCard);
        expect(card, findsOneWidget);
        expect(presented, isEmpty);

        await tester.tap(card);
        await _settle(tester);
        await _commandClick(tester, card);

        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(tester);

        await tester.tapAt(
          tester.getCenter(card),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await _settle(tester);
        await tester.tap(find.text('Open in new tab'));
        await _settle(tester);

        await tester.tapAt(
          tester.getCenter(card),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await _settle(tester);
        await tester.tap(find.text('Like game'));
        await _settle(tester);

        expect(presented, const [
          'tournament_game_open:premium_paid_source',
          'game_card_new_tab:premium_paid_source',
          'tournament_game_open:premium_paid_source',
          'tournament_game_open:premium_paid_source',
          'tournament_game_context_menu:premium_paid_source',
        ]);
        expect(_tabCount(container), tabsBefore);
        expect(repository.fetches, 0);
      },
    );
  });

  group('free broadcast control', () {
    testWidgets('opens by drop and modifier-click without reading membership', (
      tester,
    ) async {
      _useDesktopSurface(tester);
      final repository = _CountingGameRepository();
      var membershipReads = 0;
      await tester.pumpWidget(
        _shell(
          overrides: [
            ..._freeOverrides(repository),
            subscriptionProvider.overrideWith((ref) {
              membershipReads++;
              return SubscriptionNotifier.stub(SubscriptionState());
            }),
          ],
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 340,
              child: LiveDesktopGameCard(
                game: _broadcastGame(),
                tournamentTitle: 'Test Event',
                layout: DesktopCardLayout.compact,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LiveDesktopGameCard)),
        listen: false,
      );
      final presented = _recordPresentedDecisions(container);
      final tabsBefore = _tabCount(container);
      final card = find.byType(DesktopGameCard);

      await _dropOnTabStrip(tester, card);
      await _commandClick(tester, card);

      expect(_tabCount(container), tabsBefore + 2);
      expect(presented, isEmpty);
      expect(membershipReads, 0);
    });
  });

  group('provenance at the operation boundary', () {
    test('a Miniatures context carried to another game takes its date', () {
      final today = _miniature(_todayMiniatureId, _todayUtcDay);
      final locked = _miniature(_lockedMiniatureId, _lockedDay);
      final carried = miniatureGameAccessContext(
        today,
        DesktopAction.openContent,
      );
      expect(_decideFree(carried).isAllowed, isTrue);

      final rail = tournamentGameAccessContext(
        locked,
        'Miniatures',
        accessContext: carried,
      );
      expect(rail.contentDate, locked.lastMoveTime);
      expect(
        _decideFree(rail).reason,
        DesktopAccessReason.premiumMiniatureNotToday,
      );

      final undated = tournamentGameAccessContext(
        _miniature('undated', null),
        'Miniatures',
        accessContext: carried,
      );
      expect(undated.contentDate, isNull);
      expect(_decideFree(undated).outcome, DesktopAccess.premiumRequired);

      // Ownership of one retained row never carries to another game.
      final owned = carried.copyWith(
        ownedDocument: true,
        retainedSaveId: 'save-1',
      );
      expect(
        retargetMiniatureAccessContext(owned, _lockedDay).ownershipCovers,
        isFalse,
      );
      // Other provenance does not depend on the game date.
      const countrymen = DesktopAccessContext(
        feature: DesktopFeature.countrymen,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.countrymen,
      );
      expect(
        identical(retargetMiniatureAccessContext(countrymen, _lockedDay), countrymen),
        isTrue,
      );
    });

    test('drag payloads expose the gated provenance; broadcasts carry none', () {
      final locked = _miniature(_lockedMiniatureId, _lockedDay);
      final payload = tournamentGameDragPayload(
        locked,
        'Miniatures',
        accessContext: smartGamesAccessContextFor(
          PremiumGamesType.miniatures,
          locked,
        ),
      );
      expect(payload.accessContext?.origin, DesktopDiscoveryOrigin.miniatures);
      expect(_decideFree(payload.accessContext!).isAllowed, isFalse);
      expect(
        tournamentGameDragPayload(_broadcastGame(), 'Event').accessContext,
        isNull,
      );
      expect(
        smartGamesAccessContextFor(PremiumGamesType.live, _broadcastGame())
            .origin,
        DesktopDiscoveryOrigin.smartCollection,
      );
    });

    test('a detached or restored Miniatures board keeps its date rule', () {
      final locked = _miniature(_lockedMiniatureId, _lockedDay);
      final args = buildTournamentBoardTabArgs(
        locked,
        'Miniatures',
        accessContext: miniatureGameAccessContext(
          locked,
          DesktopAction.openContent,
        ),
      );
      final decoded =
          DesktopBoardWindowPayload.decode(
            DesktopBoardWindowPayload.fromArgs(args).encode(),
          ).args!;
      expect(
        decoded.admissionContext.origin,
        DesktopDiscoveryOrigin.miniatures,
      );
      expect(
        _decideFree(decoded.admissionContext).reason,
        DesktopAccessReason.premiumMiniatureNotToday,
      );
    });

    test('a Favorites board records its origin and stays free', () {
      final legacy = BoardTabGameArgs(
        gameId: 'fav-game',
        pgn: '1. e4 e5 *',
        label: 'Carlsen vs Nakamura',
        whiteName: 'Carlsen',
        blackName: 'Nakamura',
        eventBroadcastId: 'event-1',
        eventGamesContinuation: const BoardTabGamesContinuation.favorites(),
      );
      expect(legacy.admissionContext.origin, DesktopDiscoveryOrigin.favorites);
      expect(
        desktopAccessWithoutMembership(legacy.admissionContext).isAllowed,
        isTrue,
      );
      // Saving from it spends saved games, never favourite players.
      expect(
        desktopFavoritesFeedAccessContext
            .copyWith(action: DesktopAction.save)
            .effectiveQuota,
        DesktopQuota.cloudSavedGames,
      );
    });

    test('rail insert and copy are admitted per game before any fetch', () {
      final container = ProviderContainer(
        overrides: _freeOverrides(_CountingGameRepository()),
      );
      addTearDown(container.dispose);
      final presented = _recordPresentedDecisions(container);
      final today = _miniature(_todayMiniatureId, _todayUtcDay);
      final locked = _miniature(_lockedMiniatureId, _lockedDay);
      final miniatureBoard = buildTournamentBoardTabArgs(
        today,
        'Miniatures',
        accessContext: miniatureGameAccessContext(
          today,
          DesktopAction.openContent,
        ),
      );
      final todayRow = TournamentGameSummary.fromGamesTourModel(today);
      final lockedRow = TournamentGameSummary.fromGamesTourModel(locked);

      expect(
        admitEventRailContentAction(
          container,
          activeArgs: miniatureBoard,
          games: [todayRow],
          action: DesktopAction.insertMove,
          surface: 'rail_test',
        ),
        isTrue,
      );
      expect(
        admitEventRailContentAction(
          container,
          activeArgs: miniatureBoard,
          games: [todayRow, lockedRow],
          action: DesktopAction.copy,
          surface: 'rail_test',
        ),
        isFalse,
      );
      expect(presented, const ['rail_test:premium_miniature_not_today']);

      final broadcastBoard = buildTournamentBoardTabArgs(
        _broadcastGame(),
        'Test Event',
      );
      expect(
        admitEventRailContentAction(
          container,
          activeArgs: broadcastBoard,
          games: [TournamentGameSummary.fromGamesTourModel(_broadcastGame())],
          action: DesktopAction.insertMove,
          surface: 'rail_test',
        ),
        isTrue,
      );
      expect(presented, hasLength(1));
    });

    testWidgets('an out-of-window like opens nothing through the board open', (
      tester,
    ) async {
      final now = DateTime.now();
      final old = _like('old', DateTime(now.year, now.month, now.day - 30));
      final recent = _like('recent', DateTime(now.year, now.month, now.day));
      await tester.pumpWidget(
        ProviderScope(
          overrides: _freeOverrides(_CountingGameRepository()),
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  return Column(
                    children: [
                      TextButton(
                        onPressed:
                            () => openLibraryLikedAnalysis(
                              ref,
                              old,
                              openable: [old],
                            ),
                        child: const Text('open-old'),
                      ),
                      TextButton(
                        onPressed:
                            () => openLibraryLikedAnalysis(
                              ref,
                              recent,
                              openable: [recent],
                            ),
                        child: const Text('open-recent'),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.text('open-old')),
        listen: false,
      );
      final presented = _recordPresentedDecisions(container);
      final tabsBefore = _tabCount(container);

      await tester.tap(find.text('open-old'));
      await tester.pump();
      expect(_tabCount(container), tabsBefore);
      expect(presented, const ['board_open:premium_likes_outside_window']);

      await tester.tap(find.text('open-recent'));
      await tester.pump();
      expect(_tabCount(container), tabsBefore + 1);
      final opened = container.read(boardTabGameArgsByTabIdProvider).values;
      expect(opened.single.accessContext?.origin, DesktopDiscoveryOrigin.likes);
      expect(presented, hasLength(1));
    });
  });
}
