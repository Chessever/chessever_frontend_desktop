import 'dart:async';

import 'package:chessever/desktop/services/billing/web_premium_navigation.dart';
import 'package:chessever/desktop/widgets/paywall/web_premium_paywall.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final interval in ['month', 'year']) {
    test(
      'Premium URL preserves $interval without account or checkout data',
      () {
        final uri = webPremiumPageUri(interval);
        expect(uri.scheme, 'https');
        expect(uri.host, 'chessever.com');
        expect(uri.path, '/premium');
        expect(uri.queryParameters, {'interval': interval});
        expect(uri.fragment, isEmpty);
      },
    );
  }

  test('invalid intervals are rejected before launching', () async {
    var called = false;
    await expectLater(
      openWebPremiumPage(
        interval: 'year&action=checkout',
        navigate: (uri, {required windowName}) async {
          called = true;
          return true;
        },
      ),
      throwsArgumentError,
    );
    expect(called, isFalse);
  });

  test(
    'navigation starts immediately in the same tab without an async gate',
    () async {
      var called = false;
      final completion = Completer<bool>();
      final pending = openWebPremiumPage(
        interval: 'year',
        navigate: (uri, {required windowName}) {
          called = true;
          expect(windowName, '_self');
          expect(uri.toString(), 'https://chessever.com/premium?interval=year');
          return completion.future;
        },
      );
      expect(called, isTrue);
      completion.complete(true);
      await pending;
    },
  );

  test('a rejected navigation is a visible failure, not success', () async {
    await expectLater(
      openWebPremiumPage(
        interval: 'month',
        navigate: (uri, {required windowName}) async => false,
      ),
      throwsStateError,
    );
  });

  test('launcher exceptions reach the caller for its retry message', () async {
    await expectLater(
      openWebPremiumPage(
        interval: 'year',
        navigate:
            (uri, {required windowName}) async => throw StateError('blocked'),
      ),
      throwsStateError,
    );
  });

  testWidgets('checkout button opens Premium without a billing session', (
    tester,
  ) async {
    Uri? destination;
    String? target;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WebPremiumCheckoutButton(
            label: 'Continue to checkout',
            onPress:
                () => openWebPremiumPage(
                  interval: 'year',
                  navigate: (uri, {required windowName}) async {
                    destination = uri;
                    target = windowName;
                    return true;
                  },
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Continue to checkout'));
    await tester.pump();
    expect(destination, webPremiumPageUri('year'));
    expect(target, '_self');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
