import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DesktopPricing', () {
    test('uses the same three subscription amounts as web Stripe pricing', () {
      expect(DesktopPricing.priceForTier(1).monthlyAmount, 10.99);
      expect(DesktopPricing.priceForTier(1).annualAmount, 99.99);

      expect(DesktopPricing.priceForTier(2).monthlyAmount, 8.99);
      expect(DesktopPricing.priceForTier(2).annualAmount, 79.99);

      expect(DesktopPricing.priceForTier(3).monthlyAmount, 4.49);
      expect(DesktopPricing.priceForTier(3).annualAmount, 31.99);
    });

    test('labels annual savings as a percent, matching the website', () {
      expect(DesktopPricing.priceForTier(1).annualSavingsPercent, 24);
      expect(DesktopPricing.priceForTier(1).annualPlanLabel, 'Annual · Save 24%');

      expect(DesktopPricing.priceForTier(2).annualSavingsPercent, 26);
      expect(DesktopPricing.priceForTier(2).annualPlanLabel, 'Annual · Save 26%');

      expect(DesktopPricing.priceForTier(3).annualSavingsPercent, 41);
      expect(DesktopPricing.priceForTier(3).annualPlanLabel, 'Annual · Save 41%');
    });

    test('maps countries to the same tier examples used by web pricing', () {
      expect(DesktopPricing.priceForCountry('US').tier, 1);
      expect(DesktopPricing.priceForCountry('TR').tier, 2);
      expect(DesktopPricing.priceForCountry('IN').tier, 3);
    });

    test('falls back to tier 1 when no country can be resolved', () {
      expect(DesktopPricing.priceForCountry(null).tier, 1);
      expect(DesktopPricing.priceForCountry('').tier, 1);
    });

    test('quotes annual savings in dollars, matching the website', () {
      expect(
        DesktopPricing.priceForTier(1).annualSavingsAmount,
        closeTo(31.89, 0.001),
      );
      expect(
        DesktopPricing.priceForTier(2).annualSavingsAmount,
        closeTo(27.89, 0.001),
      );
      expect(
        DesktopPricing.priceForTier(3).annualSavingsAmount,
        closeTo(21.89, 0.001),
      );
    });

    test('formats amounts with USD or a trailing code', () {
      expect(DesktopPricing.formatAmount(10.99, 'USD'), r'$10.99');
      expect(DesktopPricing.formatAmount(100, 'USD'), r'$100');
      expect(DesktopPricing.formatAmount(10.99, 'EUR'), '10.99 EUR');
    });
  });

  group('DesktopPricing trial copy', () {
    test('matches the store and Stripe introductory offer', () {
      expect(DesktopPricing.trialDays, 3);
    });

    test('offers the trial unless eligibility is known false', () {
      expect(DesktopPricing.offersTrial(null), isTrue);
      expect(DesktopPricing.offersTrial(true), isTrue);
      expect(DesktopPricing.offersTrial(false), isFalse);
    });

    test('assurance line matches the website', () {
      expect(
        DesktopPricing.premiumAssuranceLabel(showsTrial: true),
        'Secure checkout · Cancel anytime before day 3',
      );
      expect(
        DesktopPricing.premiumAssuranceLabel(showsTrial: false),
        'Secure checkout · Cancel anytime · Every device',
      );
    });

    test('monthly detail matches the website subtext', () {
      expect(
        DesktopPricing.monthlyPlanDetail(showsTrial: true),
        '3 days free, then billed monthly',
      );
      expect(
        DesktopPricing.monthlyPlanDetail(showsTrial: false),
        'Billed monthly',
      );
    });

    test('annual detail keeps the equivalent with site savings', () {
      expect(
        DesktopPricing.annualPlanDetail(
          pricing: DesktopPricing.priceForTier(1),
          showsTrial: true,
        ),
        r'3 days free, then $8.33 a month · Save $31.89/yr',
      );
      expect(
        DesktopPricing.annualPlanDetail(
          pricing: DesktopPricing.priceForTier(1),
          showsTrial: false,
        ),
        r'$8.33 a month · Save $31.89/yr',
      );
      expect(
        DesktopPricing.annualPlanDetail(
          pricing: DesktopPricing.priceForTier(2),
          showsTrial: false,
        ),
        r'$6.67 a month · Save $27.89/yr',
      );
      expect(
        DesktopPricing.annualPlanDetail(
          pricing: DesktopPricing.priceForTier(3),
          showsTrial: false,
        ),
        r'$2.67 a month · Save $21.89/yr',
      );
    });

    test('annual detail omits savings when there are none', () {
      const flat = DesktopTierPricing(
        tier: 1,
        monthlyAmount: 10,
        annualAmount: 120,
      );
      expect(
        DesktopPricing.annualPlanDetail(pricing: flat, showsTrial: true),
        r'3 days free, then $10 a month',
      );
    });

    test('plan subtext matches the website verbatim', () {
      final tier1 = DesktopPricing.priceForTier(1);
      expect(
        DesktopPricing.planSubtext(
          pricing: tier1,
          interval: 'year',
          showsTrial: true,
        ),
        r'3 days free, then $99.99 billed annually · Save $31.89/yr',
      );
      expect(
        DesktopPricing.planSubtext(
          pricing: tier1,
          interval: 'year',
          showsTrial: false,
        ),
        r'$99.99 billed annually · Save $31.89/yr',
      );
      expect(
        DesktopPricing.planSubtext(
          pricing: tier1,
          interval: 'month',
          showsTrial: true,
        ),
        '3 days free, then billed monthly',
      );
      expect(
        DesktopPricing.planSubtext(
          pricing: tier1,
          interval: 'month',
          showsTrial: false,
        ),
        'Billed monthly',
      );
    });
  });
}
