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

    test('maps countries to the same tier examples used by web pricing', () {
      expect(DesktopPricing.priceForCountry('US').tier, 1);
      expect(DesktopPricing.priceForCountry('TR').tier, 2);
      expect(DesktopPricing.priceForCountry('IN').tier, 3);
    });

    test('falls back to tier 1 when no country can be resolved', () {
      expect(DesktopPricing.priceForCountry(null).tier, 1);
      expect(DesktopPricing.priceForCountry('').tier, 1);
    });
  });
}
