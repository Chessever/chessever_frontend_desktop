import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_paywall_copy.dart';
import 'package:chessever/desktop/services/toby/toby_access.dart';
import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();

  void become(SubscriptionState next) => state = next;
}

SubscriptionState _member({String? provider}) => SubscriptionState(
  isSubscribed: true,
  provider: provider,
  expirationDate: DateTime.now().add(const Duration(days: 30)),
);

DesktopAccessDecision _decide(
  SubscriptionState membership, {
  bool web = false,
  DesktopEntitlementSnapshot entitlement = DesktopEntitlementSnapshot.guest,
  DesktopAccessContext context = tobyPredictionAccessContext,
}) => evaluateDesktopAccess(
  context: context,
  subscription: membership,
  entitlement: entitlement,
  isWebApp: web,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the Toby access rule', () {
    for (final web in [false, true]) {
      final edition = web ? 'web' : 'desktop';
      test('is Premium ($edition)', () {
        final free = _decide(SubscriptionState(), web: web);
        expect(free.outcome, DesktopAccess.premiumRequired);
        expect(free.reason, DesktopAccessReason.premiumTobyPrediction);
        expect(free.mayOfferPurchase, isTrue);

        final signedInFree = _decide(
          SubscriptionState(),
          web: web,
          entitlement: const DesktopEntitlementSnapshot(
            accountId: 'free-reader',
            generation: 1,
          ),
        );
        expect(signedInFree.outcome, DesktopAccess.premiumRequired);

        expect(_decide(_member(), web: web).outcome, DesktopAccess.allowed);
      });

      test('is Premium whatever the board shows ($edition)', () {
        for (final origin in DesktopDiscoveryOrigin.values) {
          final context = tobyPredictionAccessContext.copyWith(
            origin: origin,
            ownedDocument: true,
          );
          expect(
            _decide(SubscriptionState(), web: web, context: context).reason,
            DesktopAccessReason.premiumTobyPrediction,
            reason: origin.name,
          );
        }
      });
    }

    test('the Mac App Store edition reads its store membership the same '
        'way', () {
      // The store edition is a native build: the same rule, fed by the App
      // Store entitlement through RevenueCat.
      expect(
        _decide(_member(provider: 'apple')).outcome,
        DesktopAccess.allowed,
      );
      expect(
        _decide(
          SubscriptionState(
            isSubscribed: true,
            provider: 'apple',
            inBillingGracePeriod: true,
            expirationDate: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ).outcome,
        DesktopAccess.allowed,
      );
      final lapsed = _decide(
        SubscriptionState(
          isSubscribed: true,
          provider: 'apple',
          expirationDate: DateTime.now().subtract(const Duration(days: 1)),
        ),
      );
      expect(lapsed.outcome, DesktopAccess.premiumRequired);
      expect(lapsed.reason, DesktopAccessReason.premiumTobyPrediction);
    });

    test('a membership still loading is progress, never an upsell', () {
      for (final web in [false, true]) {
        final checking = _decide(SubscriptionState(isLoading: true), web: web);
        expect(checking.outcome, DesktopAccess.checking);
        expect(checking.mayOfferPurchase, isFalse);
        final offline = _decide(SubscriptionState(error: 'offline'), web: web);
        expect(offline.outcome, DesktopAccess.temporarilyUnavailable);
        expect(offline.mayOfferPurchase, isFalse);
      }
    });

    test('the paywall names the feature, and only through its label', () {
      final copy = desktopPaywallCopyFor(
        _decide(SubscriptionState()),
        context: tobyPredictionAccessContext,
      );
      expect(copy.title, '$kTobyFeatureLabel is Premium');
      expect(copy.body, isNot(contains('—')));
      // The same copy serves the store edition: no web checkout, no platform.
      for (final word in ['Stripe', 'chessever.com', 'Mac', 'website']) {
        expect(copy.title + copy.body, isNot(contains(word)), reason: word);
      }
    });

    test('the attribution is the licence text, verbatim', () {
      expect(kTobyAttribution, 'Toby © Yosha Iglesias, toby.tribychess.org');
      expect(kTobyAttribution, endsWith(kTobyAttributionLinkText));
      expect(kTobyAttributionUrl, 'https://$kTobyAttributionLinkText');
    });
  });

  group('opening the panel', () {
    ({ProviderContainer container, _Subscription subscription}) setUp(
      SubscriptionState membership,
    ) {
      final subscription = _Subscription(membership);
      final container = ProviderContainer(
        overrides: [
          subscriptionProvider.overrideWith((ref) => subscription),
          desktopEntitlementProvider.overrideWithValue(
            DesktopEntitlementSnapshot.guest,
          ),
        ],
      );
      addTearDown(container.dispose);
      return (container: container, subscription: subscription);
    }

    test(
      'asks a free reader for Premium, and opens after a purchase',
      () async {
        final f = setUp(SubscriptionState());
        final shown =
            <(DesktopAccessDecision, DesktopAccessContext?, String)>[];
        var expanded = 0;
        addTearDown(
          registerDesktopPaywallPresenter(f.container, (
            decision, {
            DesktopAccessContext? context,
            DesktopAccessResume? resume,
            required String surface,
          }) async {
            shown.add((decision, context, surface));
            // The reader buys Premium in the prompt.
            f.subscription.become(_member());
            await resume?.run();
            return true;
          }),
        );

        expect(f.container.read(tobyPredictionAccessProvider).isAllowed, false);
        final admitted = admitTobyPrediction(
          f.container,
          surface: 'toby_panel_expand',
          resume: DesktopAccessResume(run: () => expanded++),
        );
        expect(admitted, isFalse);
        await Future<void>.delayed(Duration.zero);

        final (decision, context, surface) = shown.single;
        expect(decision.outcome, DesktopAccess.premiumRequired);
        expect(decision.reason, DesktopAccessReason.premiumTobyPrediction);
        expect(context, tobyPredictionAccessContext);
        expect(surface, 'toby_panel_expand');
        expect(expanded, 1);
        expect(f.container.read(tobyPredictionAccessProvider).isAllowed, true);
      },
    );

    test('lets a Premium reader straight in, with no prompt', () {
      final f = setUp(_member());
      var prompts = 0;
      addTearDown(
        registerDesktopPaywallPresenter(f.container, (
          decision, {
          DesktopAccessContext? context,
          DesktopAccessResume? resume,
          required String surface,
        }) async {
          prompts++;
          return false;
        }),
      );
      expect(
        admitTobyPrediction(f.container, surface: 'toby_panel_expand'),
        isTrue,
      );
      expect(prompts, 0);
    });
  });
}
