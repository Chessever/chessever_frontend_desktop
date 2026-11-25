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
      test('is free for everyone, guests included ($edition)', () {
        // Gamebase decides who may read Toby; the client never gates it.
        for (final (membership, entitlement) in [
          (SubscriptionState(), DesktopEntitlementSnapshot.guest),
          (
            SubscriptionState(),
            const DesktopEntitlementSnapshot(
              accountId: 'free-reader',
              generation: 1,
            ),
          ),
          (_member(), DesktopEntitlementSnapshot.guest),
          (
            SubscriptionState(isLoading: true),
            DesktopEntitlementSnapshot.guest,
          ),
          (
            SubscriptionState(error: 'offline'),
            DesktopEntitlementSnapshot.guest,
          ),
        ]) {
          final decision = _decide(
            membership,
            web: web,
            entitlement: entitlement,
          );
          expect(decision.isAllowed, isTrue, reason: '$membership');
          expect(decision.mayOfferPurchase, isFalse);
        }
        expect(
          desktopAccessWithoutMembership(tobyPredictionAccessContext).isAllowed,
          isTrue,
        );
      });

      test('is free whatever the board shows ($edition)', () {
        for (final origin in DesktopDiscoveryOrigin.values) {
          final context = tobyPredictionAccessContext.copyWith(
            origin: origin,
            ownedDocument: true,
          );
          expect(
            _decide(SubscriptionState(), web: web, context: context).isAllowed,
            isTrue,
            reason: origin.name,
          );
        }
      });
    }

    test('the Mac App Store edition reads it the same way', () {
      expect(_decide(SubscriptionState()).isAllowed, isTrue);
      expect(_decide(_member(provider: 'apple')).isAllowed, isTrue);
    });

    test('the Premium prompt Gamebase can still call for names the feature, '
        'and only through its label', () {
      final copy = desktopPaywallCopyFor(
        const DesktopAccessDecision(
          DesktopAccess.premiumRequired,
          DesktopAccessReason.premiumTobyPrediction,
        ),
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

  group('choosing the tab, and a refusal from Gamebase', () {
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

    test('lets a free reader and a guest straight in, with no prompt', () {
      final f = setUp(SubscriptionState());
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
        readDesktopAccess(
          f.container.read,
          tobyPredictionAccessContext,
        ).isAllowed,
        isTrue,
      );
      expect(
        admitDesktopAction(
          f.container,
          tobyPredictionAccessContext,
          surface: 'engine_toby_tab',
        ),
        isTrue,
      );
      expect(prompts, 0);
      expect(f.container.read(tobyReaderHasPremiumProvider), isFalse);
    });

    test('a Premium refusal opens the Premium prompt for the feature, and '
        'asks again after a purchase', () async {
      final f = setUp(SubscriptionState());
      final shown = <(DesktopAccessDecision, DesktopAccessContext?, String)>[];
      var retried = 0;
      addTearDown(
        registerDesktopPaywallPresenter(f.container, (
          decision, {
          DesktopAccessContext? context,
          DesktopAccessResume? resume,
          required String surface,
        }) async {
          shown.add((decision, context, surface));
          f.subscription.become(_member());
          await resume?.run();
          return true;
        }),
      );

      final bought = await presentTobyServerGate(
        f.container,
        surface: 'engine_toby_tab',
        resume: DesktopAccessResume(run: () => retried++),
      );

      expect(bought, isTrue);
      final (decision, context, surface) = shown.single;
      expect(decision.outcome, DesktopAccess.premiumRequired);
      expect(decision.reason, DesktopAccessReason.premiumTobyPrediction);
      // No context: a context would be re-read against the client's rule,
      // which lets everyone in, and the prompt would close itself.
      expect(context, isNull);
      expect(surface, 'engine_toby_tab');
      expect(retried, 1);
      expect(f.container.read(tobyReaderHasPremiumProvider), isTrue);
    });
  });
}
