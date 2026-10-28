import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/widgets/desktop_profile_sign_in.dart';
import 'package:chessever/theme/app_theme.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily);
    for (final weight in ['Regular', 'SemiBold', 'Bold', 'Black']) {
      font.addFont(
        rootBundle.load('packages/forui/assets/fonts/inter/Inter-$weight.ttf'),
      );
    }
    await font.load();
  });

  testWidgets('guest sign-in is immediate and survives a profile load error', (
    tester,
  ) async {
    final profile = Completer<PlayUserProfile>();
    await _pumpProfile(tester, profile: profile.future);

    expect(find.text('Sign in with Google').hitTestable(), findsOneWidget);
    expect(find.text('Sign in with Apple').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.byType(DesktopProfileSignIn)).dy, 0);

    profile.completeError(StateError('Profile unavailable'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Sign in with Google').hitTestable(), findsOneWidget);
    expect(find.text('Sign in with Apple').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'permanent sign-in removes the prompt without reopening the tab',
    (tester) async {
      final identity = _Identity();
      await _pumpProfile(
        tester,
        profile: Completer<PlayUserProfile>().future,
        identity: identity,
      );
      expect(find.byType(DesktopProfileSignIn), findsOneWidget);

      identity.setPermanent();
      await tester.pump();

      expect(find.byType(DesktopProfileSignIn), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'both provider buttons respond to clicks and keyboard activation',
    (tester) async {
      final selected = <DesktopAccountProvider>[];
      await tester.pumpWidget(
        _app(DesktopProfileSignIn(onSignIn: selected.add)),
      );
      await tester.tap(find.text('Sign in with Google'));
      await tester.tap(find.text('Sign in with Apple'));
      await tester.pumpAndSettle();
      expect(selected, [
        DesktopAccountProvider.google,
        DesktopAccountProvider.apple,
      ]);

      // FButton owns keyboard behavior; the profile adds no shortcut map that
      // could shadow the shell's Cmd/Ctrl+Shift+F global search shortcut.
      Focus.of(tester.element(find.text('Sign in with Google'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected.last, DesktopAccountProvider.google);
      expect(selected.length, 3);
    },
  );

  testWidgets(
    'in-flight sign-in disables both choices and announces progress',
    (tester) async {
      await tester.pumpWidget(
        _app(
          DesktopProfileSignIn(
            busyProvider: DesktopAccountProvider.google,
            onSignIn: (_) => fail('A second sign-in must not start'),
          ),
        ),
      );
      expect(find.text('Signing in…'), findsOneWidget);
      expect(
        find.textContaining('Finish signing in with Google'),
        findsOneWidget,
      );
      for (final button in tester.widgetList<FButton>(find.byType(FButton))) {
        expect(button.onPress, isNull);
      }
    },
  );

  testWidgets('failed sign-in shows retry feedback with both choices enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        DesktopProfileSignIn(error: 'Sign-in was cancelled.', onSignIn: (_) {}),
      ),
    );
    expect(find.text('Sign-in was cancelled.'), findsOneWidget);
    for (final button in tester.widgetList<FButton>(find.byType(FButton))) {
      expect(button.onPress, isNotNull);
    }
  });

  testWidgets(
    'sign-in stays visible at minimum window size with enlarged text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(924, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpProfile(
        tester,
        profile: Completer<PlayUserProfile>().future,
        textScale: 1.5,
      );
      final google = tester.getRect(find.text('Sign in with Google'));
      final apple = tester.getRect(find.text('Sign in with Apple'));
      expect(apple.top, greaterThan(google.bottom));
      expect(apple.bottom, lessThan(640));
      expect(find.text('Sign in with Google').hitTestable(), findsOneWidget);
      expect(find.text('Sign in with Apple').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpProfile(
  WidgetTester tester, {
  required Future<PlayUserProfile> profile,
  _Identity? identity,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        desktopAccountIdentityProvider.overrideWith(
          () => identity ?? _Identity(),
        ),
        playUserProfileProvider.overrideWith((ref) => profile),
        playRecentGamesProvider.overrideWith((ref) async => []),
        playAchievementsProvider.overrideWith((ref) => _Achievements()),
      ],
      child: _app(const PlayProfilePane(), textScale: textScale),
    ),
  );
  await tester.pump();
}

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  theme: ThemeData(fontFamily: 'Geist'),
  builder:
      (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
  home: Scaffold(
    backgroundColor: kBackgroundColor,
    body: FTheme(data: FThemes.zinc.dark, child: child),
  ),
);

class _Identity extends DesktopAccountIdentityNotifier {
  @override
  DesktopAccountIdentity build() =>
      const DesktopAccountIdentity(userId: 'guest', isAnonymous: true);

  void setPermanent() {
    state = const DesktopAccountIdentity(userId: 'signed-in');
  }
}

class _Achievements extends StateNotifier<PlayAchievementsState>
    implements PlayAchievementsNotifier {
  _Achievements()
    : super(
        const PlayAchievementsState(
          stats: PlayAchievementStats(),
          unlocked: {},
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
