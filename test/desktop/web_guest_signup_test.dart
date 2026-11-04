import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_guest_gate.dart';
import 'package:chessever/desktop/auth/desktop_guest_interaction_gate.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/repository/local_storage/guest_session/guest_session_repository.dart';
import 'package:chessever/theme/app_theme.dart';

const _guest = DesktopAccountIdentity(userId: 'guest', isAnonymous: true);
const _permanent = DesktopAccountIdentity(userId: 'account');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  setUpAll(() async {
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily);
    font.addFont(
      rootBundle.load('packages/forui/assets/fonts/inter/Inter-Regular.ttf'),
    );
    await font.load();
    final appFont = FontLoader('Geist');
    appFont.addFont(
      rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'),
    );
    await appFont.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() => DesktopGuestGateObserver.instance.modalDepth.value = 0);
  tearDown(() => DesktopGuestGateObserver.instance.modalDepth.value = 0);

  Future<_Identity> mountGate(
    WidgetTester tester,
    _GuestStore store, {
    DesktopAccountIdentity account = _guest,
    Size size = const Size(1000, 800),
    Widget? shell,
  }) async {
    final identity = _Identity(account);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          guestSessionRepositoryProvider.overrideWithValue(store),
          desktopAccountIdentityProvider.overrideWith(() => identity),
        ],
        child: RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              scaffoldBackgroundColor: kBackgroundColor,
              textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
            ),
            navigatorObservers: [DesktopGuestGateObserver.instance],
            home: DesktopGuestGateListener(
              promptOnFirstEntry: true,
              child: DesktopGuestInteractionGate(
                child: shell ?? const Scaffold(body: Text('Open board')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(kDesktopGuestGateStartupSettle);
    await tester.pumpAndSettle();
    return identity;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final directory = Platform.environment['CHESSEVER_TICKET_QA_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('first browser visit offers Not now once across reloads', (
    tester,
  ) async {
    final store = _GuestStore();
    await mountGate(tester, store);

    expect(find.text('Not now'), findsOneWidget);
    expect(find.textContaining('for 28 days.'), findsOneWidget);
    expect(store.stamps.startedAt, isNotNull);
    await capture(tester, 'guest-initial');
    final startedAt = store.stamps.startedAt;
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.byType(FDialog), findsNothing);
    expect(store.stamps.lastPromptAt, isNotNull);

    await tester.pumpWidget(const SizedBox());
    await mountGate(tester, store);
    expect(find.byType(FDialog), findsNothing);
    expect(store.stamps.startedAt, startedAt);
  });

  testWidgets('Not now leaves shell actions and global search available', (
    tester,
  ) async {
    var actions = 0;
    var searches = 0;
    await mountGate(
      tester,
      _GuestStore(),
      shell: CallbackShortcuts(
        bindings: {
          const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
                shift: true,
              ):
              () => searches++,
          const SingleActivator(
                LogicalKeyboardKey.keyF,
                meta: true,
                shift: true,
              ):
              () => searches++,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: Center(
              child: FButton(
                onPress: () => actions++,
                child: const Text('Open game'),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DesktopGuestInteractionGate)),
    );
    expect(container.read(desktopGuestInteractionSignInProvider), isFalse);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open game'));
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(find.byType(FDialog), findsNothing);

    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(find.byType(FDialog), findsNothing);
    }
    expect(searches, 2);
    expect(tester.takeException(), isNull);
  });

  for (final days in [7, 27]) {
    testWidgets('day $days reminder can be skipped with Not now', (
      tester,
    ) async {
      final startedAt = DateTime.now().subtract(Duration(days: days));
      final store = _GuestStore(GuestSessionTimestamps(startedAt: startedAt));
      await mountGate(tester, store);

      expect(find.text('Not now'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.byType(FDialog), findsNothing);
      expect(store.stamps.startedAt, startedAt);
      expect(store.stamps.lastPromptAt, isNotNull);
    });
  }

  testWidgets(
    'day 28 requires sign-in and blocks skip, Escape and outside tap',
    (tester) async {
      final store = _GuestStore(
        GuestSessionTimestamps(
          startedAt: DateTime.now().subtract(const Duration(days: 28)),
        ),
      );
      await mountGate(tester, store);

      expect(find.text('Sign in to keep going'), findsOneWidget);
      expect(find.text('Not now'), findsNothing);
      await capture(tester, 'guest-required');
      await tester.tapAt(const Offset(5, 5));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(FDialog), findsOneWidget);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(await navigator.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(FDialog), findsOneWidget);
    },
  );

  testWidgets('restored permanent account clears the old guest clock', (
    tester,
  ) async {
    final store = _GuestStore(
      GuestSessionTimestamps(
        startedAt: DateTime.now().subtract(const Duration(days: 40)),
      ),
    );
    await mountGate(tester, store, account: _permanent);

    expect(find.byType(FDialog), findsNothing);
    expect(store.stamps, GuestSessionTimestamps.empty);
    expect(store.clearCount, 1);
  });

  testWidgets('guest upgrade closes the required gate and clears the clock', (
    tester,
  ) async {
    final store = _GuestStore(
      GuestSessionTimestamps(
        startedAt: DateTime.now().subtract(const Duration(days: 28)),
      ),
    );
    final identity = await mountGate(tester, store);
    expect(find.text('Sign in to keep going'), findsOneWidget);

    identity.setAccount(_permanent);
    await tester.pumpAndSettle();

    expect(find.byType(FDialog), findsNothing);
    expect(store.stamps, GuestSessionTimestamps.empty);
    expect(store.clearCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short browser window can scroll to Not now', (tester) async {
    await mountGate(tester, _GuestStore(), size: const Size(460, 320));
    await tester.ensureVisible(find.text('Not now'));
    await capture(tester, 'guest-short-window');
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(find.byType(FDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Identity extends DesktopAccountIdentityNotifier {
  _Identity(this.initial);

  final DesktopAccountIdentity initial;

  @override
  DesktopAccountIdentity build() => initial;

  void setAccount(DesktopAccountIdentity account) => state = account;
}

class _GuestStore extends GuestSessionRepository {
  _GuestStore([this.stamps = GuestSessionTimestamps.empty]);

  GuestSessionTimestamps stamps;
  int clearCount = 0;

  @override
  Future<GuestSessionTimestamps> read() async => stamps;

  @override
  Future<DateTime?> startIfMissing(DateTime now) async {
    stamps = GuestSessionTimestamps(
      startedAt: stamps.startedAt ?? now,
      lastPromptAt: stamps.lastPromptAt,
    );
    return stamps.startedAt;
  }

  @override
  Future<void> markPromptShown(DateTime now) async {
    stamps = GuestSessionTimestamps(
      startedAt: stamps.startedAt,
      lastPromptAt: now,
    );
  }

  @override
  Future<void> clear() async {
    clearCount++;
    stamps = GuestSessionTimestamps.empty;
  }
}
