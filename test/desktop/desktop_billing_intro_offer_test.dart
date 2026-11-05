import 'dart:convert';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/billing/web_intro_offer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _quote = <String, Object>{
  'id': WebIntroOffer.id,
  'eligible': true,
  'amount_cents': 99,
  'currency': 'usd',
  'interval': 'month',
  'renewal_amount_cents': 1099,
};
const _offer = WebIntroOffer(renewalAmountCents: 1099);

Session _session({bool anonymous = false}) =>
    Session.fromJson({
      'access_token': 'test-session',
      'token_type': 'bearer',
      'expires_at': 4102444800,
      'user': {
        'id': anonymous ? 'guest-fixture' : 'member-fixture',
        'aud': 'authenticated',
        'role': 'authenticated',
        'app_metadata': <String, Object>{},
        'user_metadata': <String, Object>{},
        'created_at': '2026-11-01T00:00:00Z',
        'is_anonymous': anonymous,
      },
    })!;

void main() {
  late MockClient client;
  late List<http.Request> requests;
  late List<bool> refreshes;
  late Future<http.Response> Function(http.Request) response;
  late Session? session;

  DesktopBillingService service({bool appStore = false}) =>
      DesktopBillingService.forTesting(
        client: client,
        activeSession: ({required forceRefresh}) async {
          refreshes.add(forceRefresh);
          return session;
        },
        baseUrl: 'https://example.invalid/functions/v1',
        appStore: appStore,
      );

  setUp(() {
    requests = [];
    refreshes = [];
    session = _session();
    response =
        (_) async => http.Response(
          jsonEncode({
            'url': 'https://checkout.stripe.com/c/pay/test-fixture',
            'trial_days': 0,
            'intro_offer': _quote,
          }),
          200,
        );
    client = MockClient((request) {
      requests.add(request);
      return response(request);
    });
  });
  tearDown(() => client.close());

  test(
    'desktop explicitly requests and confirms the displayed offer',
    () async {
      final checkout = await service().createCheckoutSession(
        tier: 1,
        interval: 'month',
        introOffer: _offer,
      );
      expect(refreshes, [true]);
      expect(requests.single.method, 'POST');
      expect(jsonDecode(requests.single.body), {
        'tier': 1,
        'interval': 'month',
        'return_to': 'desktop',
        'intro_offer': WebIntroOffer.id,
        'expected_renewal_amount_cents': 1099,
      });
      expect(checkout.url, 'https://checkout.stripe.com/c/pay/test-fixture');
    },
  );

  test(
    'annual and ordinary monthly checkout never implicitly request an offer',
    () async {
      for (final interval in ['year', 'month']) {
        await service().createCheckoutSession(tier: 1, interval: interval);
        expect(jsonDecode(requests.last.body), {
          'tier': 1,
          'interval': interval,
          'return_to': 'desktop',
        });
      }
    },
  );

  test(
    'old backend, denied terms and changed renewal never yield a URL',
    () async {
      for (final granted in <Object?>[
        null,
        {},
        {..._quote, 'eligible': false},
        {..._quote, 'amount_cents': 100},
        {..._quote, 'renewal_amount_cents': 899},
        {..._quote, 'currency': 'eur'},
      ]) {
        response =
            (_) async => http.Response(
              jsonEncode({
                'url': 'https://checkout.stripe.com/c/pay/test-fixture',
                'intro_offer': granted,
              }),
              200,
            );
        await expectLater(
          service().createCheckoutSession(
            tier: 1,
            interval: 'month',
            introOffer: _offer,
          ),
          throwsA(
            isA<DesktopIntroOfferException>().having(
              (error) => error.refreshOffer,
              'refreshOffer',
              isTrue,
            ),
          ),
        );
      }
    },
  );

  test(
    'server refusal tells the paywall to refresh before another click',
    () async {
      for (final code in [
        'intro_offer_unavailable',
        'pricing_changed',
        'invalid_intro_offer',
      ]) {
        response =
            (_) async => http.Response(
              jsonEncode({
                'error': code,
                'message': 'Review the updated terms.',
              }),
              409,
            );
        await expectLater(
          service().createCheckoutSession(
            tier: 1,
            interval: 'month',
            introOffer: _offer,
          ),
          throwsA(
            isA<DesktopIntroOfferException>().having(
              (error) => error.message,
              'message',
              'Review the updated terms.',
            ),
          ),
        );
      }
    },
  );

  test('an operational failure keeps the offer retryable', () async {
    response =
        (_) async => http.Response(
          jsonEncode({
            'error': 'offer_eligibility_unavailable',
            'message': 'Try again.',
          }),
          503,
        );
    await expectLater(
      service().createCheckoutSession(
        tier: 1,
        interval: 'month',
        introOffer: _offer,
      ),
      throwsA(
        allOf(
          isA<DesktopCheckoutException>(),
          isNot(isA<DesktopIntroOfferException>()),
        ),
      ),
    );
  });

  test(
    'guest and annual quotes cannot be submitted as discounted checkout',
    () async {
      for (final arguments in [
        ('year', _offer),
        (
          'month',
          const WebIntroOffer(renewalAmountCents: 1099, requiresSignIn: true),
        ),
      ]) {
        await expectLater(
          service().createCheckoutSession(
            tier: 1,
            interval: arguments.$1,
            introOffer: arguments.$2,
          ),
          throwsA(isA<DesktopIntroOfferException>()),
        );
      }
      session = _session(anonymous: true);
      await expectLater(
        service().createCheckoutSession(
          tier: 1,
          interval: 'month',
          introOffer: _offer,
        ),
        throwsStateError,
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'the same rejected eligibility is conditional for guests, absent for members',
    () async {
      response =
          (_) async => http.Response(
            jsonEncode({
              'intro_offer': {..._quote, 'eligible': false},
            }),
            200,
          );
      expect(await service().fetchWebIntroOffer(1), isNull);
      session = _session(anonymous: true);
      final guest = await service().fetchWebIntroOffer(1);
      expect(guest?.requiresSignIn, isTrue);
      expect(guest?.renewalAmountCents, 1099);
      expect(requests.last.url.queryParameters, {'tier': '1'});
      expect(refreshes, [false, false]);
    },
  );

  test('signed out, unknown and failed quotes never invent an offer', () async {
    session = null;
    expect(await service().fetchWebIntroOffer(1), isNull);
    expect(requests, isEmpty);
    session = _session(anonymous: true);
    for (final result in [
      http.Response('{"trial_eligible":false}', 200),
      http.Response('{"intro_offer":null}', 200),
      http.Response('{}', 503),
    ]) {
      response = (_) async => result;
      expect(await service().fetchWebIntroOffer(1), isNull);
    }
  });

  test('Mac App Store never probes or starts Stripe checkout', () async {
    final appStore = service(appStore: true);
    expect(await appStore.fetchWebIntroOffer(1), isNull);
    await expectLater(
      appStore.createCheckoutSession(
        tier: 1,
        interval: 'month',
        introOffer: _offer,
      ),
      throwsStateError,
    );
    expect(refreshes, isEmpty);
    expect(requests, isEmpty);
  });
}
