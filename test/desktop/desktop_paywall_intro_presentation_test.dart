import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chessever/desktop/auth/desktop_access_analytics.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing_provider.dart';
import 'package:chessever/desktop/services/billing/desktop_trial_eligibility_provider.dart';
import 'package:chessever/desktop/services/billing/web_intro_offer.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/desktop/widgets/paywall/web_premium_paywall.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _member = DesktopEntitlementSnapshot(
  accountId: 'free-member',
  generation: 1,
);
const _guest = DesktopEntitlementSnapshot(
  accountId: 'anonymous-guest',
  isAnonymous: true,
  generation: 1,
);
const _offer = WebIntroOffer(renewalAmountCents: 1099);
const _countrymen = DesktopAccessContext(
  feature: DesktopFeature.countrymen,
  action: DesktopAction.openContent,
  origin: DesktopDiscoveryOrigin.countrymen,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalSignIn = debugDesktopPaywallSignIn;
  final captureKey = GlobalKey();

  setUpAll(() async {
    final foruiFont = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily)
      ..addFont(
        rootBundle.load('packages/forui/assets/fonts/inter/Inter-Regular.ttf'),
      );
    final appFont = FontLoader('Geist')
      ..addFont(rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([foruiFont.load(), appFont.load(), icons.load()]);
  });

  setUp(() {
    DesktopAccessAnalytics.debugSink = (_, _) {};
  });

  tearDown(() {
    DesktopAccessAnalytics.debugSink = null;
    debugDesktopPaywallSignIn = originalSignIn;
  });

  Future<void> mount(
    WidgetTester tester, {
    DesktopEntitlementSnapshot entitlement = _member,
    WebIntroOffer? offer = _offer,
    Future<WebIntroOffer?>? pendingOffer,
  }) async {
    // Run the actual native DesktopPaywallView branch, not a stand-alone
    // presentation widget that could pass while desktop still uses old plans.
    expect(kIsWeb, isFalse);
    await tester.binding.setSurfaceSize(const Size(1040, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subscriptionProvider.overrideWith(
            (_) => SubscriptionNotifier.stub(SubscriptionState()),
          ),
          desktopEntitlementProvider.overrideWithValue(entitlement),
          desktopPricingProvider.overrideWith(
            (_) async => DesktopPricing.resolveForCountry('US'),
          ),
          desktopTrialEligibilityProvider.overrideWith((_) async => false),
          webIntroOfferProvider(
            1,
          ).overrideWith((_) => pendingOffer ?? Future.value(offer)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: kBackgroundColor,
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
          ),
          builder: (_, child) => FTheme(data: FThemes.zinc.dark, child: child!),
          home: Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 520,
                  maxHeight: 704,
                ),
                child: RepaintBoundary(
                  key: captureKey,
                  child: Material(
                    color: kBlack2Color,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: const DesktopPaywallView(
                      decision: DesktopAccessDecision(
                        DesktopAccess.premiumRequired,
                        DesktopAccessReason.premiumPaidSource,
                      ),
                      accessContext: _countrymen,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['CHESSEVER_PAYWALL_QA_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage(PngAsset.newAppLogo),
        tester.element(find.byType(WebPremiumPaywall)),
      );
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('native paywall opens Monthly with first charge and renewal', (
    tester,
  ) async {
    await mount(tester);

    expect(find.byType(WebPremiumPaywall), findsOneWidget);
    expect(find.text(r'$0.99'), findsOneWidget);
    expect(find.text('First month only'), findsOneWidget);
    expect(find.text(r'From month 2: $10.99/month.'), findsOneWidget);
    expect(find.text(r'Start first month for $0.99'), findsOneWidget);
    expect(
      tester.widget<WebPremiumPlans>(find.byType(WebPremiumPlans)).interval,
      'month',
    );
    expect(
      tester
          .widget<WebPremiumCheckoutButton>(
            find.byType(WebPremiumCheckoutButton),
          )
          .onPress,
      isNotNull,
    );
    await capture(tester, 'native-monthly-eligible');
  });

  testWidgets('annual tap shows full annual charge and removes intro action', (
    tester,
  ) async {
    await mount(tester);

    await tester.tap(find.text('Annual'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text(r'$99.99'), findsOneWidget);
    expect(find.text('per year'), findsOneWidget);
    expect(find.text(r'$8.33 per month, billed yearly.'), findsOneWidget);
    expect(find.text(r'$0.99'), findsNothing);
    expect(find.text(r'Start first month for $0.99'), findsNothing);
    expect(find.text('Continue to checkout'), findsOneWidget);

    await tester.tap(find.text('Monthly'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text(r'$0.99'), findsOneWidget);
    expect(find.text(r'Start first month for $0.99'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guest offer remains conditional and requires sign-in first', (
    tester,
  ) async {
    var signInCalls = 0;
    debugDesktopPaywallSignIn = (_) async {
      signInCalls++;
      return false;
    };
    await mount(
      tester,
      entitlement: _guest,
      offer: const WebIntroOffer(
        renewalAmountCents: 1099,
        requiresSignIn: true,
      ),
    );

    expect(
      find.text('For first-time subscribers. Sign in to check eligibility.'),
      findsOneWidget,
    );
    expect(find.text('Check my first-month offer'), findsOneWidget);
    expect(find.text(r'Start first month for $0.99'), findsNothing);
    await capture(tester, 'native-monthly-guest');

    await tester.tap(find.text('Check my first-month offer'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byType(WebPremiumCheckoutButton), findsNothing);
    expect(find.text('Opening checkout'), findsNothing);
    expect(find.text('Checkout could not be opened. Try again.'), findsNothing);

    await tester.tap(find.text('Sign in'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(signInCalls, 1);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byType(WebPremiumCheckoutButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('checkout stays disabled while offer eligibility is pending', (
    tester,
  ) async {
    final pending = Completer<WebIntroOffer?>();
    await mount(tester, pendingOffer: pending.future);

    expect(find.text('Checking your offer'), findsOneWidget);
    expect(
      tester
          .widget<WebPremiumCheckoutButton>(
            find.byType(WebPremiumCheckoutButton),
          )
          .onPress,
      isNull,
    );
    expect(find.text(r'$0.99'), findsNothing);

    pending.complete(_offer);
    await tester.pumpAndSettle();
    expect(find.text(r'Start first month for $0.99'), findsOneWidget);
    expect(
      tester
          .widget<WebPremiumCheckoutButton>(
            find.byType(WebPremiumCheckoutButton),
          )
          .onPress,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final scenario
      in <String, WebIntroOffer?>{
        'older backend without offer contract': WebIntroOffer.fromJson({
          'trial_eligible': false,
          'trial_days': 0,
        }),
        'quote with a different renewal price': const WebIntroOffer(
          renewalAmountCents: 899,
        ),
      }.entries) {
    testWidgets('${scenario.key} keeps ordinary pricing', (tester) async {
      await mount(tester, offer: scenario.value);

      expect(find.text(r'$10.99'), findsOneWidget);
      expect(find.text('per month'), findsWidgets);
      expect(find.text(r'$0.99'), findsNothing);
      expect(find.text('First month only'), findsNothing);
      expect(find.text('Continue to checkout'), findsOneWidget);
      expect(find.text('Check my first-month offer'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
