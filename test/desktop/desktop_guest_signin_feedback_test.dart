import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_welcome_screen.dart';
import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';

const _guestFailure =
    'Could not start a guest session. Check your connection and try again.';

void main() {
  group('welcome screen', () {
    Future<void> pumpWelcome(
      WidgetTester tester, {
      required bool guestFailed,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 760);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            // The test font's glyphs are far wider than the shipped font, so
            // halve the text to keep the fixed-width sign-in buttons in bounds.
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(0.5)),
                  child: child!,
                ),
            home: DesktopWelcomeScreen(
              onContinueAsGuest: () async {},
              guestFailed: guestFailed,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('says why it came back after a failed guest session', (
      tester,
    ) async {
      await pumpWelcome(tester, guestFailed: true);
      expect(find.text(_guestFailure), findsOneWidget);
    });

    testWidgets('shows no error before anything failed', (tester) async {
      await pumpWelcome(tester, guestFailed: false);
      expect(find.text(_guestFailure), findsNothing);
    });
  });

  test('a failed guest data capture never shows exception text', () {
    final message = desktopSignInErrorMessage(
      const DesktopGuestDataCaptureException('PostgrestException(code: 500)'),
    );
    expect(message, isNot(contains('Exception')));
    expect(message, contains('Check your connection'));
  });
}
