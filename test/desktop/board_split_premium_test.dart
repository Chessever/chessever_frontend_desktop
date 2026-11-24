import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();

  void become(SubscriptionState next) => state = next;
}

SubscriptionState _member() => SubscriptionState(
  isSubscribed: true,
  expirationDate: DateTime.now().add(const Duration(days: 30)),
);

({ProviderContainer container, _Subscription subscription, String a, String b})
_setUp(
  SubscriptionState membership, {
  DesktopEntitlementSnapshot? entitlement,
}) {
  final subscription = _Subscription(membership);
  final container = ProviderContainer(
    overrides: [
      subscriptionProvider.overrideWith((ref) => subscription),
      desktopEntitlementProvider.overrideWithValue(
        entitlement ?? DesktopEntitlementSnapshot.guest,
      ),
    ],
  );
  addTearDown(container.dispose);
  final tabs = container.read(desktopTabsProvider.notifier);
  final a = tabs.open(TabKind.board, reuseExisting: false);
  final b = tabs.open(TabKind.board, reuseExisting: false);
  return (container: container, subscription: subscription, a: a, b: b);
}

bool _split(ProviderContainer container, String target, String incoming) =>
    container
        .read(boardSplitProvider.notifier)
        .watch(targetTabId: target, incomingTabId: incoming);

Future<void> _settle() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the board split access rule', () {
    DesktopAccessDecision decide(
      SubscriptionState membership, {
      DesktopAction action = DesktopAction.create,
    }) => evaluateDesktopAccess(
      context: DesktopAccessContext(
        feature: DesktopFeature.boardSplit,
        action: action,
        origin: DesktopDiscoveryOrigin.localFile,
      ),
      subscription: membership,
      entitlement: DesktopEntitlementSnapshot.guest,
    );

    for (final web in [false, true]) {
      test('is Premium (${web ? 'web' : 'desktop'})', () {
        final free = evaluateDesktopAccess(
          context: boardSplitAccessContext,
          subscription: SubscriptionState(),
          entitlement: DesktopEntitlementSnapshot.guest,
          isWebApp: web,
        );
        expect(free.outcome, DesktopAccess.premiumRequired);
        expect(free.reason, DesktopAccessReason.premiumBoardSplit);
        expect(
          evaluateDesktopAccess(
            context: boardSplitAccessContext,
            subscription: _member(),
            entitlement: DesktopEntitlementSnapshot.guest,
            isWebApp: web,
          ).outcome,
          DesktopAccess.allowed,
        );
      });
    }

    test('a membership still loading is progress, not an upsell', () {
      expect(
        decide(SubscriptionState(isLoading: true)).outcome,
        DesktopAccess.checking,
      );
      expect(
        decide(SubscriptionState(error: 'offline')).outcome,
        DesktopAccess.temporarilyUnavailable,
      );
    });

    test('taking a board out of a split is never gated', () {
      expect(
        decide(SubscriptionState(), action: DesktopAction.remove).outcome,
        DesktopAccess.allowed,
      );
    });
  });

  group('splitting', () {
    test('is refused without Premium, and asks for it', () {
      final f = _setUp(SubscriptionState());
      final shown = <DesktopAccessDecision>[];
      addTearDown(
        registerDesktopPaywallPresenter(f.container, (
          decision, {
          DesktopAccessContext? context,
          DesktopAccessResume? resume,
          required String surface,
        }) async {
          shown.add(decision);
          return false;
        }),
      );

      // The notifier refuses a split by itself, whatever path asks.
      expect(_split(f.container, f.a, f.b), isFalse);
      expect(f.container.read(boardSplitProvider).groups, isEmpty);

      expect(admitBoardSplit(f.container, surface: 'test'), isFalse);
      expect(shown.single.outcome, DesktopAccess.premiumRequired);
      expect(shown.single.reason, DesktopAccessReason.premiumBoardSplit);
    });

    test('is refused while a signed-in free account has no Premium', () {
      final f = _setUp(
        SubscriptionState(),
        entitlement: const DesktopEntitlementSnapshot(
          accountId: 'free-reader',
          generation: 1,
        ),
      );
      expect(_split(f.container, f.a, f.b), isFalse);
      expect(f.container.read(boardSplitProvider).groups, isEmpty);
    });

    test('works for a Premium member', () {
      final f = _setUp(_member());
      expect(admitBoardSplit(f.container, surface: 'test'), isTrue);
      expect(_split(f.container, f.a, f.b), isTrue);
      expect(f.container.read(boardSplitProvider).groups.single.tabIds, [
        f.a,
        f.b,
      ]);
    });
  });

  group('losing Premium', () {
    test('closes the split and keeps every board open', () async {
      final f = _setUp(_member());
      expect(_split(f.container, f.a, f.b), isTrue);
      f.container.read(desktopTabsProvider.notifier).activate(f.b);

      f.subscription.become(SubscriptionState());
      await _settle();

      expect(f.container.read(boardSplitProvider).groups, isEmpty);
      expect(f.container.read(visibleBoardSplitProvider), isNull);
      final tabs = f.container.read(desktopTabsProvider);
      expect({for (final t in tabs.tabs) t.id}, containsAll([f.a, f.b]));
      expect(tabs.activeId, f.b);
    });

    test('an expired term closes the split', () async {
      final f = _setUp(_member());
      expect(_split(f.container, f.a, f.b), isTrue);
      f.subscription.become(
        SubscriptionState(
          isSubscribed: true,
          expirationDate: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
      );
      await _settle();
      expect(f.container.read(boardSplitProvider).groups, isEmpty);
    });

    test('a refresh or an unreachable membership keeps the split', () async {
      final f = _setUp(_member());
      expect(_split(f.container, f.a, f.b), isTrue);

      // A routine refresh on top of a valid membership.
      f.subscription.become(
        SubscriptionState(
          isSubscribed: true,
          isLoading: true,
          expirationDate: DateTime.now().add(const Duration(days: 30)),
        ),
      );
      await _settle();
      expect(f.container.read(boardSplitProvider).groups, hasLength(1));

      // We could not reach the membership service: not the reader's lapse.
      f.subscription.become(SubscriptionState(error: 'offline'));
      await _settle();
      expect(f.container.read(boardSplitProvider).groups, hasLength(1));

      // Verified again.
      f.subscription.become(_member());
      await _settle();
      expect(f.container.read(boardSplitProvider).groups, hasLength(1));
    });

    test('splitting again after a renewal works', () async {
      final f = _setUp(_member());
      expect(_split(f.container, f.a, f.b), isTrue);
      f.subscription.become(SubscriptionState());
      await _settle();
      expect(f.container.read(boardSplitProvider).groups, isEmpty);
      expect(_split(f.container, f.a, f.b), isFalse);

      f.subscription.become(_member());
      await _settle();
      expect(_split(f.container, f.a, f.b), isTrue);
      // And the next lapse is still noticed.
      f.subscription.become(SubscriptionState());
      await _settle();
      expect(f.container.read(boardSplitProvider).groups, isEmpty);
    });
  });
}
