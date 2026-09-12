import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_analytics.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_explorer_access.dart';
import 'package:chessever/desktop/auth/desktop_paywall_copy.dart';
import 'package:chessever/desktop/auth/desktop_player_profile_access.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing_provider.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_board_access_gate.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// A subscription the test can flip.
class _TestSubscription extends SubscriptionNotifier {
  _TestSubscription(super.initialState) : super.stub();

  void set(SubscriptionState next) => state = next;
}

final _entitlement = StateProvider<DesktopEntitlementSnapshot>(
  (_) => const DesktopEntitlementSnapshot(accountId: 'acct-a', generation: 1),
);

SubscriptionState get _free => SubscriptionState();
SubscriptionState get _premium => SubscriptionState(
  isSubscribed: true,
  expirationDate: DateTime.now().add(const Duration(days: 30)),
);

List<Override> _accessOverrides(_TestSubscription subscription) => [
  subscriptionProvider.overrideWith((ref) => subscription),
  desktopEntitlementProvider.overrideWith((ref) => ref.watch(_entitlement)),
  desktopPricingProvider.overrideWith(
    (ref) async => DesktopPricing.resolveForCountry('US'),
  ),
];

BoardTabGameArgs _args({
  ChessboardView viewSource = ChessboardView.tour,
  DesktopAccessContext? accessContext,
  BoardTabLibrarySaveOrigin? librarySaveOrigin,
  BoardTabGamesContinuation? routeGamesContinuation,
}) => BoardTabGameArgs(
  gameId: 'game-1',
  pgn: '1. e4 e5 *',
  label: 'Carlsen vs Nepo',
  whiteName: 'Carlsen',
  blackName: 'Nepo',
  eventBroadcastId: 'event-1',
  viewSource: viewSource,
  accessContext: accessContext,
  librarySaveOrigin: librarySaveOrigin,
  routeGamesContinuation: routeGamesContinuation,
);

const _countrymen = DesktopAccessContext(
  feature: DesktopFeature.countrymen,
  action: DesktopAction.openContent,
  origin: DesktopDiscoveryOrigin.countrymen,
);

DesktopAccessDecision _decide(
  DesktopAccessContext context, {
  SubscriptionState? subscription,
}) => evaluateDesktopAccess(
  context: context,
  subscription: subscription ?? _free,
  entitlement: const DesktopEntitlementSnapshot(accountId: 'acct-a'),
);

void main() {
  final events = <String>[];

  setUp(() {
    events.clear();
    DesktopAccessAnalytics.debugSink = (event, _) => events.add(event);
    desktopWindowIsForeground = () => true;
  });

  tearDown(() {
    DesktopAccessAnalytics.debugSink = null;
  });

  group('provenance', () {
    test('the same game is free via broadcast and gated via Countrymen', () {
      final broadcast = _args();
      final countrymen = _args(
        viewSource: ChessboardView.countryman,
        accessContext: _countrymen,
      );
      expect(broadcast.gameId, countrymen.gameId);
      expect(_decide(broadcast.admissionContext).isAllowed, isTrue);
      final gated = _decide(countrymen.admissionContext);
      expect(gated.outcome, DesktopAccess.premiumRequired);
      expect(gated.reason, DesktopAccessReason.premiumPaidSource);
      expect(
        _decide(
          countrymen.admissionContext,
          subscription: _premium,
        ).isAllowed,
        isTrue,
      );
    });

    test('provenance survives a tab move (copyWith) and restore', () {
      final moved = _args(accessContext: _countrymen).copyWith(
        pgn: '1. d4 d5 *',
        label: 'moved',
      );
      expect(moved.accessContext, _countrymen);
      expect(_decide(moved.admissionContext).isAllowed, isFalse);
    });

    test('detached window payload JSON round-trips the provenance', () {
      final args = _args(accessContext: _countrymen);
      final decoded =
          DesktopBoardWindowPayload.decode(
            DesktopBoardWindowPayload.fromArgs(args).encode(),
          ).args!;
      expect(decoded.accessContext, _countrymen);
      expect(_decide(decoded.admissionContext).isAllowed, isFalse);
    });

    test('legacy payloads without provenance infer the gated source', () {
      final legacy = _args(
        viewSource: ChessboardView.countryman,
        routeGamesContinuation: const BoardTabGamesContinuation.countrymen(),
      );
      final decoded =
          DesktopBoardWindowPayload.decode(
            DesktopBoardWindowPayload.fromArgs(legacy).encode(),
          ).args!;
      expect(decoded.accessContext, isNull);
      expect(decoded.admissionContext.origin, DesktopDiscoveryOrigin.countrymen);
      expect(_decide(decoded.admissionContext).isAllowed, isFalse);
      // An ordinary broadcast legacy payload stays free.
      expect(_decide(_args().admissionContext).isAllowed, isTrue);
    });

    test('a saved copy is free; its next paid-source game is still gated', () {
      const gamebase = DesktopAccessContext(
        feature: DesktopFeature.gamebase,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.gamebase,
      );
      final saved = _args(
        accessContext: gamebase,
        librarySaveOrigin: const BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
          analysisId: 'save-1',
          title: 'Saved',
        ),
      );
      expect(_decide(saved.admissionContext).isAllowed, isTrue);
      final next = _decide(saved.sourceAccessContext);
      expect(next.outcome, DesktopAccess.premiumRequired);
    });
  });

  group('central board admission', () {
    test('a denied interactive open opens no tab and presents once', () {
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: _accessOverrides(subscription),
      );
      addTearDown(container.dispose);
      var presented = 0;
      final unregister = registerDesktopPaywallPresenter(container, (
        decision, {
        DesktopAccessContext? context,
        DesktopAccessResume? resume,
        required String surface,
      }) async {
        presented++;
        return false;
      });
      addTearDown(unregister);

      final tabsBefore = container.read(desktopTabsProvider).tabs.length;
      final tabId = openBoardGameTabFromContainer(
        container,
        _args(accessContext: _countrymen),
      );
      expect(tabId, isEmpty);
      expect(container.read(desktopTabsProvider).tabs, hasLength(tabsBefore));
      expect(presented, 1);

      // A deferred boot/restore opens the tab un-admitted, silently.
      final deferred = openBoardGameTabFromContainer(
        container,
        _args(accessContext: _countrymen),
        admission: DesktopBoardAdmission.deferred,
      );
      expect(deferred, isNotEmpty);
      expect(container.read(boardTabAdmissionByTabIdProvider), isEmpty);
      expect(presented, 1);
    });

    test('a background (non-interactive) check never presents', () {
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: _accessOverrides(subscription),
      );
      addTearDown(container.dispose);
      var presented = 0;
      final unregister = registerDesktopPaywallPresenter(container, (
        decision, {
        DesktopAccessContext? context,
        DesktopAccessResume? resume,
        required String surface,
      }) async {
        presented++;
        return false;
      });
      addTearDown(unregister);
      expect(
        admitBoardSourceOpen(container, _countrymen, interactive: false),
        isFalse,
      );
      expect(presented, 0);
    });

    test('a denied open never reaches the repository fetch', () async {
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: _accessOverrides(subscription),
      );
      addTearDown(container.dispose);
      var fetches = 0;
      Future<void> openLikeASurface() async {
        if (!admitBoardSourceOpen(
          container,
          _countrymen,
          interactive: false,
        )) {
          return;
        }
        fetches++;
      }

      await openLikeASurface();
      expect(fetches, 0);
      subscription.set(_premium);
      await openLikeASurface();
      expect(fetches, 1);
    });

    test('engine tournaments: create and restart gated, stop free', () {
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: _accessOverrides(subscription),
      );
      addTearDown(container.dispose);
      DesktopAccessContext tournament(DesktopAction action) =>
          DesktopAccessContext(
            feature: DesktopFeature.engineTournament,
            action: action,
            origin: DesktopDiscoveryOrigin.localFile,
          );
      bool admit(DesktopAction action) => admitDesktopAction(
        container,
        tournament(action),
        surface: 'test',
        interactive: false,
      );
      expect(admit(DesktopAction.create), isFalse);
      expect(admit(DesktopAction.recompute), isFalse);
      expect(admit(DesktopAction.cancel), isTrue);
      expect(admit(DesktopAction.export), isTrue);
    });
  });

  group('explorer', () {
    List<String> knightShuffle(int plies) => [
      for (var i = 0; i < plies; i++)
        const ['g1f3', 'g8f6', 'f3g1', 'f6g8'][i % 4],
    ];

    String fenAfter(List<String> ucis) {
      Position position = Chess.initial;
      for (final uci in ucis) {
        position = position.play(NormalMove.fromUci(uci));
      }
      return position.fen;
    }

    test('plies 19 and 20 are free, 21 is gated; player scope gated', () {
      final container = ProviderContainer(
        overrides: [
          ..._accessOverrides(_TestSubscription(_free)),
          gamebaseRepositoryProvider.overrideWithValue(_CountingRepository()),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(gamebaseExplorerProvider.notifier);

      for (final plies in const [19, 20, 21]) {
        final line = knightShuffle(plies);
        // Board move / held navigation: a line from the initial position.
        notifier.setPositionWithMoves(fenAfter(line), line);
        final byLine = desktopExplorerFetchAllowed(
          container.read,
          container.read(gamebaseExplorerProvider),
          0,
        );
        // PV apply / FEN seed: only the position, counted from its FEN.
        notifier.setPosition(fenAfter(line));
        final byFen = desktopExplorerFetchAllowed(
          container.read,
          container.read(gamebaseExplorerProvider),
          0,
        );
        expect(byLine, plies <= 20, reason: 'line at $plies plies');
        expect(byFen, plies <= 20, reason: 'FEN seed at $plies plies');
      }

      final scoped = desktopExplorerAccessContext(
        container.read(gamebaseExplorerProvider),
      ).copyWith(playedPlies: 2, playerScoped: true);
      expect(readDesktopAccess(container.read, scoped).isAllowed, isFalse);
      final generalFilter = desktopExplorerAccessContext(
        container.read(gamebaseExplorerProvider),
      ).copyWith(playedPlies: 2, playerScoped: false);
      expect(
        readDesktopAccess(container.read, generalFilter).isAllowed,
        isTrue,
      );
    });

    test('the notifier refuses the fetch below navigation and prefetch', () async {
      final repository = _CountingRepository();
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: [
          ..._accessOverrides(subscription),
          gamebaseRepositoryProvider.overrideWithValue(repository),
          gamebaseExplorerProvider.overrideWith(
            (ref) => GamebaseExplorerNotifier(
              ref,
              accessCheck:
                  (state, advance) =>
                      desktopExplorerFetchAllowed(ref.read, state, advance),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final keepAlive = container.listen(gamebaseExplorerProvider, (_, _) {});
      addTearDown(keepAlive.close);
      final notifier = container.read(gamebaseExplorerProvider.notifier);

      final deep = knightShuffle(21);
      notifier.setPositionWithMoves(fenAfter(deep), deep);
      await notifier.refresh();
      expect(repository.calls, 0);
      expect(container.read(gamebaseExplorerProvider).moveAggregates, isEmpty);

      // Held navigation back to ply 20: the same notifier now fetches.
      notifier.goBack();
      await notifier.refresh();
      expect(repository.calls, greaterThan(0));

      // A member explores past ply 20.
      final before = repository.calls;
      subscription.set(_premium);
      notifier.setPositionWithMoves(fenAfter(deep), deep);
      await notifier.refresh();
      expect(repository.calls, greaterThan(before));
    });
  });

  group('paywall', () {
    Widget host(ProviderContainer container, void Function(BuildContext) onReady) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder:
              (context, child) =>
                  FTheme(data: FThemes.zinc.dark, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                onReady(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
    }

    const gated = DesktopAccessDecision(
      DesktopAccess.premiumRequired,
      DesktopAccessReason.premiumPaidSource,
    );

    testWidgets('N simultaneous gate hits open one dialog', (tester) async {
      final container = ProviderContainer(
        overrides: _accessOverrides(_TestSubscription(_free)),
      );
      addTearDown(container.dispose);
      late BuildContext context;
      await tester.pumpWidget(host(container, (c) => context = c));

      final first = showDesktopPaywall(context, gated, accessContext: _countrymen);
      final second = showDesktopPaywall(context, gated, accessContext: _countrymen);
      final third = showDesktopPaywall(context, gated, accessContext: _countrymen);
      await tester.pumpAndSettle();

      expect(find.byType(DesktopPaywallView), findsOneWidget);
      expect(debugPendingDesktopPaywallCount, 1);
      expect(events.where((e) => e == DesktopAccessAnalytics.gateShownEvent), hasLength(1));

      Navigator.of(tester.element(find.byType(DesktopPaywallView))).pop();
      await tester.pumpAndSettle();
      expect(await first, isFalse);
      expect(await second, isFalse);
      expect(await third, isFalse);
      expect(debugPendingDesktopPaywallCount, 0);
    });

    testWidgets('resumes once after a verified purchase', (tester) async {
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: _accessOverrides(subscription),
      );
      addTearDown(container.dispose);
      late BuildContext context;
      await tester.pumpWidget(host(container, (c) => context = c));

      var resumed = 0;
      final result = showDesktopPaywall(
        context,
        gated,
        accessContext: _countrymen,
        resume: DesktopAccessResume(run: () => resumed++),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DesktopPaywallView), findsOneWidget);

      // The dialog never trusts itself: only the membership flipping closes
      // it and resumes the action.
      subscription.set(_premium);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopPaywallView), findsNothing);
      expect(await result, isTrue);
      expect(resumed, 1);
      expect(
        events,
        contains(DesktopAccessAnalytics.continuationResumedEvent),
      );
    });

    testWidgets('no resume when the account changed', (tester) async {
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: _accessOverrides(subscription),
      );
      addTearDown(container.dispose);
      late BuildContext context;
      await tester.pumpWidget(host(container, (c) => context = c));

      var resumed = 0;
      final result = showDesktopPaywall(
        context,
        gated,
        accessContext: _countrymen,
        resume: DesktopAccessResume(run: () => resumed++),
      );
      await tester.pumpAndSettle();

      container.read(_entitlement.notifier).state =
          const DesktopEntitlementSnapshot(accountId: 'acct-b', generation: 2);
      subscription.set(_premium);
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(resumed, 0);
    });

    testWidgets('temporarily unavailable shows Retry, never pricing', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: _accessOverrides(
          _TestSubscription(SubscriptionState(error: 'offline')),
        ),
      );
      addTearDown(container.dispose);
      late BuildContext context;
      await tester.pumpWidget(host(container, (c) => context = c));

      unawaited(
        showDesktopPaywall(
          context,
          const DesktopAccessDecision(
            DesktopAccess.temporarilyUnavailable,
            DesktopAccessReason.entitlementUnknown,
          ),
          accessContext: _countrymen,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Continue to checkout'), findsNothing);
      expect(find.text('Monthly'), findsNothing);
      Navigator.of(tester.element(find.byType(DesktopPaywallView))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('rendering a locked board never opens the dialog', (
      tester,
    ) async {
      final subscription = _TestSubscription(_free);
      final container = ProviderContainer(
        overrides: _accessOverrides(subscription),
      );
      addTearDown(container.dispose);
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        'tab-1': _args(accessContext: _countrymen),
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder:
                (context, child) =>
                    FTheme(data: FThemes.zinc.dark, child: child!),
            home: const Scaffold(
              body: DesktopBoardAccessGate(
                tabId: 'tab-1',
                child: Text('BOARD CONTENT'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('BOARD CONTENT'), findsNothing);
      expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
      expect(find.byType(DesktopPaywallView), findsNothing);
      expect(debugPendingDesktopPaywallCount, 0);
      expect(events, isEmpty);

      // Admitted once => the board stays mounted through an expiry.
      subscription.set(_premium);
      await tester.pumpAndSettle();
      expect(find.text('BOARD CONTENT'), findsOneWidget);
      subscription.set(_free);
      await tester.pumpAndSettle();
      expect(find.text('BOARD CONTENT'), findsOneWidget);
    });
  });

  group('copy and filters', () {
    test('quota copy names the exhausted limit with its capacity', () {
      final copy = desktopPaywallCopyFor(
        const DesktopAccessDecision(
          DesktopAccess.quotaExceeded,
          DesktopAccessReason.quotaCloudSavedGames,
          capacity: DesktopQuotaCapacity(
            quota: DesktopQuota.cloudSavedGames,
            used: 10,
            limit: 10,
            requested: 1,
          ),
        ),
      );
      expect(copy.capacityLine, '10 of 10 saved games used');
      expect(copy.title, isNot(contains('—')));
      expect(
        desktopPremiumIncludes.join(' '),
        allOf(contains('Unlimited game reports'), contains('daily Botvinnik')),
      );
    });

    test('profile filter criteria count one free, two combined', () {
      final base = GameFilter.defaultFilter();
      expect(
        desktopProfileFilterCriteria(
          base,
          searchQuery: '',
          playerResult: PlayerResultFilter.all,
        ),
        0,
      );
      final one = desktopProfileFilterCriteria(
        base,
        searchQuery: 'Najdorf',
        playerResult: PlayerResultFilter.all,
      );
      final two = desktopProfileFilterCriteria(
        base,
        searchQuery: 'Najdorf',
        playerResult: PlayerResultFilter.win,
      );
      expect(one, 1);
      expect(two, 2);
      expect(_decide(desktopProfileFilterContext(one)).isAllowed, isTrue);
      expect(_decide(desktopProfileFilterContext(two)).isAllowed, isFalse);
    });
  });
}

class _CountingRepository extends GamebaseRepository {
  _CountingRepository() : super(Dio(), baseUrl: 'http://localhost');

  int calls = 0;

  @override
  Future<GamebaseResponse> getMoveAggregates({
    required String fen,
    List<String> moves = const [],
    String? playerId,
    TimeControl? timeControl,
    int? minRating,
    int? maxRating,
    String? color,
    String? result,
    int? yearFrom,
    int? yearTo,
    bool? isOnline,
  }) async {
    calls++;
    throw Exception('offline test repository');
  }
}
