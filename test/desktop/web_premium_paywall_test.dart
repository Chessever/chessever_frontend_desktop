import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/services/billing/web_intro_offer.dart';
import 'package:chessever/desktop/widgets/paywall/web_premium_paywall.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

void main() {
  testWidgets('real modal retains Close, Escape and backdrop dismissal', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => GestureDetector(
                onTap:
                    () => showDesktopModal<void>(
                      context,
                      maxWidth: 520,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      builder:
                          (_) => const WebPremiumPaywall(
                            subtitle: 'Premium for your next move.',
                            children: [],
                          ),
                    ),
                child: const Text('Open'),
              ),
        ),
      ),
    );
    for (final dismissal in ['close', 'escape', 'backdrop']) {
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('ChessEver'), findsOneWidget);
      switch (dismissal) {
        case 'close':
          await tester.tap(find.byIcon(Icons.close_rounded));
        case 'escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        case 'backdrop':
          await tester.tapAt(const Offset(1, 1));
      }
      await tester.pumpAndSettle();
      expect(find.text('ChessEver'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
  Future<void> pumpPlans(
    WidgetTester tester, {
    DesktopResolvedPricing? pricing,
    String interval = 'year',
    ValueChanged<String>? onChanged,
    WebIntroOffer? introOffer,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 468,
            child: WebPremiumPlans(
              pricing: pricing,
              interval: interval,
              showsTrial: false,
              onChanged: onChanged,
              introOffer: introOffer,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('monthly intro discloses renewal and leaves annual unchanged', (
    tester,
  ) async {
    await pumpPlans(
      tester,
      pricing: DesktopPricing.resolveForCountry('US'),
      interval: 'month',
      introOffer: const WebIntroOffer(renewalAmountCents: 1099),
    );
    expect(find.textContaining(r'$0.99', findRichText: true), findsOneWidget);
    expect(find.text(r'First month, then $10.99 per month'), findsOneWidget);
    expect(find.text(r'$99.99 billed yearly'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpPlans(
      tester,
      pricing: DesktopPricing.resolveForCountry('US'),
      introOffer: const WebIntroOffer(renewalAmountCents: 899),
    );
    expect(find.textContaining(r'$0.99', findRichText: true), findsNothing);
    expect(find.textContaining(r'$10.99', findRichText: true), findsOneWidget);
  });

  testWidgets(
    'regional annual equivalent and full annual charge, not USD examples',
    (tester) async {
      final pricing = DesktopResolvedPricing(
        pricing: DesktopPricing.priceForTier(3),
        currencyCode: 'EUR',
        isRemote: true,
      );
      String? interval;
      await pumpPlans(
        tester,
        pricing: pricing,
        onChanged: (value) => interval = value,
      );
      expect(find.text('31.99 EUR billed yearly'), findsOneWidget);
      expect(
        find.textContaining('2.67 EUR', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('4.49 EUR', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining(r'$99.99'), findsNothing);
      final selected = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where((widget) => widget.properties.selected == true);
      expect(selected, hasLength(1));
      await tester.tap(find.text('Monthly'));
      expect(interval, 'month');
      await tester.tap(find.text('Annual'));
      // Forui keeps its pressed pointer state for 200ms, independently of frames.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(interval, 'year');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plan control responds to keyboard activation', (tester) async {
    String? interval;
    await pumpPlans(
      tester,
      pricing: DesktopPricing.resolveForCountry('US'),
      onChanged: (value) => interval = value,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(interval, 'month');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(interval, 'year');
  });

  testWidgets(
    'unresolved prices never invent an amount; disabled checkout stays disabled',
    (tester) async {
      await pumpPlans(tester);
      expect(find.textContaining('—', findRichText: true), findsNWidgets(2));
      await tester.pumpWidget(
        MaterialApp(
          home: WebPremiumCheckoutButton(
            label: 'Continue to checkout',
            onPress: null,
          ),
        ),
      );
      expect(tester.widget<FButton>(find.byType(FButton)).onPress, isNull);
    },
  );

  for (final size in [
    const Size(1040, 920),
    const Size(390, 520),
    const Size(320, 480),
  ]) {
    testWidgets('bounded dialog scrolls without overflow at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var purchased = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 520,
                    maxHeight: (size.height * .9).clamp(0.0, 704.0),
                  ),
                  child: WebPremiumPaywall(
                    subtitle: 'Full Countrymen games, with Premium.',
                    children: [
                      WebPremiumPlans(
                        pricing: DesktopPricing.resolveForCountry('US'),
                        introOffer: const WebIntroOffer(
                          renewalAmountCents: 1099,
                        ),
                        interval: 'month',
                        showsTrial: false,
                        onChanged: (_) {},
                      ),
                      const SizedBox(height: 20),
                      WebPremiumCheckoutButton(
                        label: r'Continue with $0.99 first month',
                        onPress: () => purchased = true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open the game. Go deeper.'), findsOneWidget);
      expect(
        find.text('Opening trees, Play and engine tournaments'),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byType(WebPremiumPaywall)).width,
        lessThanOrEqualTo(520),
      );
      expect(tester.takeException(), isNull);
      final close = find.byIcon(Icons.close_rounded);
      expect(tester.getRect(close).top, greaterThan(0));
      await tester.ensureVisible(find.byType(WebPremiumCheckoutButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(r'Continue with $0.99 first month'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(purchased, isTrue);
      expect(tester.getRect(close).top, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }
}
