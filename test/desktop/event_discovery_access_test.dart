import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_event_discovery_access.dart';
import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_event_discovery_gate.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();
  void update(SubscriptionState value) => state = value;
}

class _BotvinnikOff extends BotvinnikEnabledNotifier {
  @override
  Future<bool> build() async => false;
}

class _LoadingForYou extends StateNotifier<ForYouState>
    implements ForYouNotifier {
  _LoadingForYou() : super(const ForYouState(isLoading: true));

  @override
  Future<void> refreshIfStale({
    Duration maxAge = const Duration(minutes: 5),
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LiveFirstStore implements TournamentLiveFirstStore {
  @override
  Future<bool?> read() async => false;

  @override
  Future<void> write(bool value) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily);
    font.addFont(
      rootBundle.load('packages/forui/assets/fonts/inter/Inter-Regular.ttf'),
    );
    await font.load();
    final appFont = FontLoader('Geist');
    appFont.addFont(
      rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'),
    );
    await appFont.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  final now = DateTime(2026, 11, 4);
  final premium = SubscriptionState(
    isSubscribed: true,
    expirationDate: DateTime(2099),
  );

  test('all event discovery is free before opening a game', () {
    for (final category in GroupEventCategory.values) {
      final decision = evaluateDesktopAccess(
        context: desktopEventDiscoveryContext(category),
        subscription: SubscriptionState(),
        entitlement: DesktopEntitlementSnapshot.guest,
        now: now,
      );
      expect(decision.outcome, DesktopAccess.allowed);
      expect(
        evaluateDesktopAccess(
          context: desktopEventDiscoveryContext(category),
          subscription: premium,
          entitlement: const DesktopEntitlementSnapshot(accountId: 'member'),
          now: now,
        ).isAllowed,
        isTrue,
      );
    }
  });

  test(
    'event discovery never reads membership, even when it is unavailable',
    () {
      final container = ProviderContainer(
        overrides: [
          subscriptionProvider.overrideWith(
            (_) => throw StateError('must not read'),
          ),
          desktopEntitlementProvider.overrideWith(
            (_) => throw StateError('must not read'),
          ),
        ],
      );
      addTearDown(container.dispose);
      for (final category in GroupEventCategory.values) {
        expect(
          container
              .read(desktopEventDiscoveryAccessProvider(category))
              .isAllowed,
          isTrue,
          reason: category.name,
        );
      }
    },
  );

  Widget host(ProviderContainer container, Widget child) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
          ),
          builder: (_, child) => FTheme(data: FThemes.zinc.dark, child: child!),
          home: Scaffold(backgroundColor: kBackgroundColor, body: child),
        ),
      );

  for (final category in GroupEventCategory.values) {
    testWidgets(
      '${category.name} stays available without Premium and during membership failures',
      (tester) async {
        final subscription = _Subscription(SubscriptionState());
        final container = ProviderContainer(
          overrides: [
            subscriptionProvider.overrideWith((_) => subscription),
            desktopEntitlementProvider.overrideWithValue(
              DesktopEntitlementSnapshot.guest,
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          host(
            container,
            DesktopEventDiscoveryGate(
              category: category,
              builder: (_) => const Text('EVENT FEED'),
            ),
          ),
        );
        for (final state in [
          SubscriptionState(),
          SubscriptionState(isLoading: true),
          SubscriptionState(error: 'offline'),
          premium,
          SubscriptionState(isSubscribed: true, expirationDate: now),
        ]) {
          subscription.update(state);
          await tester.pump();
          expect(find.text('EVENT FEED'), findsOneWidget);
          expect(find.byType(DesktopAccessLockedSurface), findsNothing);
          expect(find.text('See Premium'), findsNothing);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets(
    'real Events pane opens For You for free and keeps Past unqueried',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          subscriptionProvider.overrideWith(
            (_) => _Subscription(SubscriptionState()),
          ),
          desktopEntitlementProvider.overrideWithValue(
            DesktopEntitlementSnapshot.guest,
          ),
          botvinnikEnabledProvider.overrideWith(_BotvinnikOff.new),
          forYouEventsProvider.overrideWith((_) => _LoadingForYou()),
          groupEventScreenProvider.overrideWith(
            (_) => throw StateError('must not fetch Past'),
          ),
          tournamentLiveEventPrefetchProvider.overrideWith((_) async {}),
          tournamentLiveFirstStoreProvider.overrideWithValue(_LiveFirstStore()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        host(container, const TournamentsPane(tabId: 'events')),
      );
      await tester.pump();
      expect(
        container.read(selectedGroupCategoryProvider),
        GroupEventCategory.forYou,
      );
      expect(find.byType(DesktopAccessLockedSurface), findsNothing);
      expect(find.text('See Premium'), findsNothing);
      expect(
        find.byKey(const ValueKey('tournament-live-first-chrome')),
        findsOneWidget,
      );
      expect(find.text('Current'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
