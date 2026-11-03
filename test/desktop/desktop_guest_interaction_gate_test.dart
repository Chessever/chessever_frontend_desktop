import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_guest_gate.dart';
import 'package:chessever/desktop/auth/desktop_guest_interaction_gate.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/widgets/desktop_grouped_game_keyboard_focus.dart';

class _Identity extends DesktopAccountIdentityNotifier {
  _Identity(this.initial);

  final DesktopAccountIdentity initial;

  @override
  DesktopAccountIdentity build() => initial;

  void signIn() => state = const DesktopAccountIdentity(userId: 'account');
}

void main() {
  setUp(() => DesktopGuestGateObserver.instance.modalDepth.value = 0);
  late int presses;
  late int searches;
  late ProviderContainer container;

  Future<void> pumpGate(
    WidgetTester tester, {
    DesktopAccountIdentity identity = const DesktopAccountIdentity(
      userId: 'guest',
      isAnonymous: true,
    ),
    bool? enabled = true,
    Widget? child,
  }) async {
    presses = 0;
    searches = 0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        desktopAccountIdentityProvider.overrideWith(() => _Identity(identity)),
        if (enabled != null)
          desktopGuestInteractionSignInProvider.overrideWithValue(enabled),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [DesktopGuestGateObserver.instance],
          // Keep Ahem's wide test glyphs within the real sign-in button widths.
          builder:
              (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(0.5)),
                child: child!,
              ),
          home: DesktopGuestInteractionGate(
            child:
                child ??
                Shortcuts(
                  shortcuts: const {
                    SingleActivator(
                          LogicalKeyboardKey.keyF,
                          control: true,
                          shift: true,
                        ):
                        ActivateIntent(),
                    SingleActivator(
                          LogicalKeyboardKey.keyF,
                          meta: true,
                          shift: true,
                        ):
                        ActivateIntent(),
                  },
                  child: Actions(
                    actions: {
                      ActivateIntent: CallbackAction<ActivateIntent>(
                        onInvoke: (_) {
                          searches++;
                          return null;
                        },
                      ),
                    },
                    child: Focus(
                      autofocus: true,
                      child: Center(
                        child: GestureDetector(
                          onTap: () => presses++,
                          child: const Text('Open a game'),
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
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  Future<void> tapShell(WidgetTester tester) async {
    // The shell is intentionally absorbed while gated.
    await tester.tap(find.text('Open a game'), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, LogicalKeyboardKey modifier) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  testWidgets('first guest tap opens sign-in without running the action', (
    tester,
  ) async {
    await pumpGate(tester);
    expect(find.text('Sign in to keep going'), findsNothing);
    expect(find.text('Open a game'), findsOneWidget);

    await tapShell(tester);
    expect(presses, 0);
    expect(find.text('Sign in to keep going'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in to keep going'), findsNothing);
    await tapShell(tester);
    expect(find.text('Sign in to keep going'), findsOneWidget);
    expect(presses, 0);
  });

  testWidgets('a signed-out browser is gated too', (tester) async {
    await pumpGate(tester, identity: const DesktopAccountIdentity());
    await tapShell(tester);
    expect(find.text('Sign in to keep going'), findsOneWidget);
    expect(presses, 0);
  });

  testWidgets('rapid pointers do not stack dialogs and Esc dismisses', (
    tester,
  ) async {
    await pumpGate(tester);
    final point = tester.getCenter(find.text('Open a game'));
    await tester.tapAt(point);
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(find.text('Sign in to keep going'), findsOneWidget);
    expect(DesktopGuestGateObserver.instance.modalDepth.value, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Sign in to keep going'), findsNothing);
    expect(DesktopGuestGateObserver.instance.modalDepth.value, 0);
    expect(presses, 0);
  });

  testWidgets('keyboard actions open sign-in before shell shortcuts', (
    tester,
  ) async {
    await pumpGate(tester);
    await search(tester, LogicalKeyboardKey.controlLeft);
    expect(find.text('Sign in to keep going'), findsOneWidget);
    expect(searches, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Sign in to keep going'), findsOneWidget);
  });

  testWidgets('signing in releases the same shell and both search chords', (
    tester,
  ) async {
    await pumpGate(tester);
    final shellElement = tester.element(find.text('Open a game'));
    (container.read(desktopAccountIdentityProvider.notifier) as _Identity)
        .signIn();
    await tester.pumpAndSettle();
    expect(tester.element(find.text('Open a game')), same(shellElement));
    await tapShell(tester);
    expect(presses, 1);
    await search(tester, LogicalKeyboardKey.controlLeft);
    await search(tester, LogicalKeyboardKey.metaLeft);
    expect(searches, 2);
    expect(find.text('Sign in to keep going'), findsNothing);
  });

  testWidgets('restored permanent accounts can interact immediately', (
    tester,
  ) async {
    await pumpGate(
      tester,
      identity: const DesktopAccountIdentity(userId: 'account'),
    );
    await tapShell(tester);
    await search(tester, LogicalKeyboardKey.controlLeft);
    expect(presses, 1);
    expect(searches, 1);
    expect(find.text('Sign in to keep going'), findsNothing);
  });

  testWidgets('native defaults retain phone guest access', (tester) async {
    await pumpGate(tester, enabled: null);
    await tapShell(tester);
    await search(tester, LogicalKeyboardKey.controlLeft);
    expect(presses, 1);
    expect(searches, 1);
    expect(find.text('Sign in to keep going'), findsNothing);
  });

  testWidgets('hardware navigation cannot change a gated game selection', (
    tester,
  ) async {
    await pumpGate(
      tester,
      child: DesktopGroupedGameKeyboardFocus(
        scopeId: 'guest-gate-test',
        groups: const [
          DesktopGameKeyboardGroup(id: 'first', games: []),
          DesktopGameKeyboardGroup(id: 'second', games: []),
        ],
        onActivateGame: (_) => presses++,
        onActivateGroup: (_) => presses++,
        builder:
            (_, selection, _, _, _, _) =>
                Center(child: Text('Selection: ${selection?.groupId}')),
      ),
    );
    expect(find.text('Selection: first'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Sign in to keep going'), findsOneWidget);
    expect(find.text('Selection: first'), findsOneWidget);
    expect(presses, 0);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    (container.read(desktopAccountIdentityProvider.notifier) as _Identity)
        .signIn();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('Selection: second'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(presses, 1);
  });
}
