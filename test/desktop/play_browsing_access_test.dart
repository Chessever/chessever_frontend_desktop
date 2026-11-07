import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_play_access.dart';
import 'package:chessever/desktop/panes/play_pane.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing_provider.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_from_here.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_tournament_history_repository.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/play_setup.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  // Forui's press feedback uses a delayed timer after pointer down.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final appFont = FontLoader('Geist');
    appFont.addFont(
      rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'),
    );
    await appFont.load();
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily);
    for (final weight in ['Regular', 'SemiBold', 'Bold', 'Black']) {
      font.addFont(
        rootBundle.load('packages/forui/assets/fonts/inter/Inter-$weight.ttf'),
      );
    }
    await font.load();
  });
  Future<ProviderContainer> pumpPlay(
    WidgetTester tester, {
    Widget? child,
    SubscriptionState? membership,
    bool engineInstalled = true,
    Size size = const Size(1440, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        subscriptionProvider.overrideWith(
          (_) => SubscriptionNotifier.stub(membership ?? SubscriptionState()),
        ),
        desktopEntitlementProvider.overrideWithValue(
          DesktopEntitlementSnapshot.guest,
        ),
        desktopPricingProvider.overrideWith(
          (_) async => DesktopPricing.resolveForCountry('US'),
        ),
        engineInstallProvider.overrideWith(
          (_, kind) => _Engine(kind, installed: engineInstalled),
        ),
        playAchievementsProvider.overrideWith((_) => _Achievements()),
        playedTournamentEventsProvider.overrideWith((_) async => []),
      ],
    );
    addTearDown(container.dispose);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
          ),
          builder:
              (_, child) => FTheme(
                data: FThemes.zinc.dark,
                child: DesktopPaywallHost(
                  navigatorKey: navigatorKey,
                  child: child!,
                ),
              ),
          home: Scaffold(body: child ?? const PlayPane(tabId: 'play')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    });
    return container;
  }

  for (final (label, membership) in [
    ('free', SubscriptionState()),
    ('checking', SubscriptionState(isLoading: true)),
    ('unavailable', SubscriptionState(error: 'offline')),
  ]) {
    testWidgets('Play can be configured while membership is $label', (
      tester,
    ) async {
      final container = await pumpPlay(tester, membership: membership);
      expect(find.text('Play vs bot'), findsOneWidget);
      expect(find.byType(DesktopAccessLockedSurface), findsNothing);
      expect(find.byType(DesktopPaywallView), findsNothing);

      await _tap(tester, find.text('Rapid'));
      await _tap(tester, find.text('Black'));
      expect(
        container.read(playSetupProvider).category,
        TimeControlCategory.rapid,
      );
      expect(container.read(playSetupProvider).color, PlayColorChoice.black);
      expect(container.read(playSessionArgsByTabIdProvider), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Play now asks for Premium without creating a session', (
    tester,
  ) async {
    final container = await pumpPlay(tester);
    await _tap(tester, find.text('Black'));
    await _tap(tester, find.text('Play now'));
    expect(find.byType(DesktopPaywallView), findsOneWidget);
    expect(container.read(playSessionArgsByTabIdProvider), isEmpty);
    Navigator.of(tester.element(find.byType(DesktopPaywallView))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Play vs bot'), findsOneWidget);
    expect(container.read(playSetupProvider).color, PlayColorChoice.black);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tournament setup is free; Create and start is the paywall',
    // Forui 0.16 input semantics hit the same framework debug assertion as
    // library_book_dialog_test; this test covers admission and pointer actions.
    semanticsEnabled: false,
    (tester) async {
      final container = await pumpPlay(tester);
      await _tap(tester, find.text('Tournaments'));
      await _tap(tester, find.text('Start tournament'));
      expect(find.text('Create and start'), findsOneWidget);
      expect(find.byType(DesktopPaywallView), findsNothing);
      expect(
        container.read(tournamentServerProvider).status,
        TournamentServerStatus.stopped,
      );

      await _tap(tester, find.text('Create and start'));
      expect(find.byType(DesktopPaywallView), findsOneWidget);
      expect(
        container.read(tournamentServerProvider).status,
        TournamentServerStatus.stopped,
      );
      expect(container.read(tournamentServerProvider).snapshot, isNull);
      Navigator.of(tester.element(find.byType(DesktopPaywallView))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Create and start'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final installed in [true, false]) {
    testWidgets(
      'Play from here opens setup before admission (ready: $installed)',
      semanticsEnabled: false,
      (tester) async {
        final container = await pumpPlay(
          tester,
          engineInstalled: installed,
          size: const Size(1024, 720),
          child: Consumer(
            builder:
                (context, ref, _) => FButton(
                  onPress:
                      () => showPlayFromHereDialog(
                        context,
                        ref,
                        seed: PlayFromHereSeed(fen: Chess.initial.fen),
                      ),
                  child: const Text('Play from here'),
                ),
          ),
        );
        await _tap(tester, find.text('Play from here'));
        expect(find.byType(DesktopPaywallView), findsNothing);
        await _tap(tester, find.text('Mirror sides'));
        expect(find.text('Independent'), findsOneWidget);
        await _tap(tester, find.text('3+2'));
        expect(find.text('Mirror sides'), findsOneWidget);
        await tester.enterText(find.byType(EditableText).at(1), '7');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await _tap(tester, find.text(installed ? 'Start game' : 'Open setup'));
        expect(
          find.byType(DesktopPaywallView),
          installed ? findsOneWidget : findsNothing,
        );
        expect(container.read(playSessionArgsByTabIdProvider), isEmpty);
        if (installed) {
          Navigator.of(tester.element(find.byType(DesktopPaywallView))).pop();
          await tester.pumpAndSettle();
          expect(find.text('Start game'), findsOneWidget);
        } else {
          expect(
            container.read(playSetupProvider).startingFen,
            Chess.initial.fen,
          );
          expect(container.read(playSetupProvider).baseSeconds, 420);
          expect(container.read(playSetupProvider).incrementSeconds, 2);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'Play browsing is free on desktop and web; starting remains protected',
    () {
      for (final web in [false, true]) {
        for (final membership in [
          SubscriptionState(),
          SubscriptionState(isLoading: true),
          SubscriptionState(error: 'offline'),
        ]) {
          expect(
            evaluateDesktopAccess(
              context: desktopPlayAccessContext.copyWith(
                action: DesktopAction.view,
              ),
              subscription: membership,
              entitlement: DesktopEntitlementSnapshot.guest,
              isWebApp: web,
            ).isAllowed,
            isTrue,
          );
          expect(
            evaluateDesktopAccess(
              context: desktopPlayAccessContext,
              subscription: membership,
              entitlement: DesktopEntitlementSnapshot.guest,
              isWebApp: web,
            ).isAllowed,
            isFalse,
          );
        }
      }
    },
  );
}

class _Engine extends StateNotifier<EngineInstallState>
    implements EngineInstallNotifier {
  _Engine(BotEngineKind kind, {required bool installed})
    : super(
        EngineInstallState(
          kind: kind,
          status:
              installed
                  ? EngineInstallStatus.installed
                  : EngineInstallStatus.notInstalled,
          binaryPath: installed ? '/unused-test-engine' : null,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
