import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/billing/web_intro_offer.dart';

void main() {
  const quote = <String, Object>{
    'id': WebIntroOffer.id,
    'eligible': true,
    'amount_cents': 99,
    'currency': 'usd',
    'interval': 'month',
    'renewal_amount_cents': 1099,
  };
  test('only an eligible, complete first-month quote may be advertised', () {
    final offer = WebIntroOffer.fromJson(quote)!;
    expect(offer.matches(currency: 'USD', monthlyAmount: 10.99), isTrue);
    expect(offer.matches(currency: 'USD', monthlyAmount: 8.99), isFalse);
    expect(offer.matches(currency: 'EUR', monthlyAmount: 10.99), isFalse);
    for (final invalid in <Object?>[
      null,
      {},
      {...quote, 'eligible': false},
      {...quote, 'eligible': null},
      {...quote, 'id': 'another_offer'},
      {...quote, 'interval': 'year'},
      {...quote, 'amount_cents': 0},
      {...quote, 'currency': 'eur'},
      {...quote, 'renewal_amount_cents': null},
      {...quote, 'renewal_amount_cents': 99},
    ]) {
      expect(WebIntroOffer.fromJson(invalid), isNull, reason: '$invalid');
    }
  });
}
