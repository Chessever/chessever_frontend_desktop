import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_event_discovery_access.dart';
import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/state/tournament_live_first.dart';
import 'package:chessever/desktop/widgets/desktop_event_discovery_gate.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/providers/group_event_category.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();
  void update(SubscriptionState value) => state = value;
}

class _BotvinnikOff extends BotvinnikEnabledNotifier {
  @override
  Future<bool> build() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  final now = DateTime(2026, 11, 4);
  final premium = SubscriptionState(
    isSubscribed: true,
    expirationDate: DateTime(2099),
  );

  test('only Current is free; other Events categories require Premium', () {
    for (final category in GroupEventCategory.values) {
      final decision = evaluateDesktopAccess(
        context: desktopEventDiscoveryContext(category),
        subscription: SubscriptionState(),
        entitlement: DesktopEntitlementSnapshot.guest,
        now: now,
      );
      expect(
        decision.outcome,
        category == GroupEventCategory.current
            ? DesktopAccess.allowed
            : DesktopAccess.premiumRequired,
      );
      if (category != GroupEventCategory.current) {
        expect(decision.reason, DesktopAccessReason.premiumEventDiscovery);
      }
      expect(
        evaluateDesktopAccess(
          context: desktopEventDiscoveryContext(category),
          subscription: premium,
          entitlement: const DesktopEntitlementSnapshot(accountId: 'member'),
          now: now,
        ).isAllowed,
        isTrue,
      );
    }
  });

  test(
    'Current never reads membership, even when the lookup is unavailable',
    () {
      final container = ProviderContainer(
        overrides: [
          subscriptionProvider.overrideWith(
            (_) => throw StateError('must not read'),
          ),
          desktopEntitlementProvider.overrideWith(
            (_) => throw StateError('must not read'),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(
        container
            .read(
              desktopEventDiscoveryAccessProvider(GroupEventCategory.current),
            )
            .isAllowed,
        isTrue,
      );
    },
  );

  Widget host(ProviderContainer container, Widget child) =>
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
          ),
          builder: (_, child) => FTheme(data: FThemes.zinc.dark, child: child!),
          home: Scaffold(backgroundColor: kBackgroundColor, body: child),
        ),
      );

  for (final category in [GroupEventCategory.forYou, GroupEventCategory.past]) {
    testWidgets(
      '${category.name} stays unmounted until verified Premium and relocks on expiry',
      (tester) async {
        final subscription = _Subscription(SubscriptionState());
        final container = ProviderContainer(
          overrides: [
            subscriptionProvider.overrideWith((_) => subscription),
            desktopEntitlementProvider.overrideWithValue(
              const DesktopEntitlementSnapshot(accountId: 'member'),
            ),
          ],
        );
        addTearDown(container.dispose);
        var builds = 0;
        await tester.pumpWidget(
          host(
            container,
            DesktopEventDiscoveryGate(
              category: category,
              builder: (_) {
                builds++;
                return const Text('EVENT FEED');
              },
            ),
          ),
        );
        expect(builds, 0);
        expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
        expect(
          find.textContaining('Current events and Calendar stay free.'),
          findsOneWidget,
        );
        expect(find.text('See Premium'), findsOneWidget);
        subscription.update(premium);
        await tester.pump();
        expect(find.text('EVENT FEED'), findsOneWidget);
        subscription.update(SubscriptionState());
        await tester.pump();
        expect(find.text('EVENT FEED'), findsNothing);
        expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
      },
    );
  }

  testWidgets(
    'unknown membership offers checking or Retry rather than an upsell',
    (tester) async {
      final subscription = _Subscription(SubscriptionState(isLoading: true));
      final container = ProviderContainer(
        overrides: [
          subscriptionProvider.overrideWith((_) => subscription),
          desktopEntitlementProvider.overrideWithValue(
            DesktopEntitlementSnapshot.guest,
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        host(
          container,
          DesktopEventDiscoveryGate(
            category: GroupEventCategory.past,
            builder: (_) => const Text('EVENT FEED'),
          ),
        ),
      );
      expect(find.text('Checking your membership'), findsOneWidget);
      expect(find.text('See Premium'), findsNothing);
      subscription.update(SubscriptionState(error: 'offline'));
      await tester.pump();
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('See Premium'), findsNothing);
      expect(find.text('EVENT FEED'), findsNothing);
    },
  );

  testWidgets(
    'real Events pane switches locked tabs without querying their feeds',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          subscriptionProvider.overrideWith(
            (_) => _Subscription(SubscriptionState()),
          ),
          desktopEntitlementProvider.overrideWithValue(
            DesktopEntitlementSnapshot.guest,
          ),
          botvinnikEnabledProvider.overrideWith(_BotvinnikOff.new),
          forYouEventsProvider.overrideWith(
            (_) => throw StateError('must not fetch For You'),
          ),
          groupEventScreenProvider.overrideWith(
            (_) => throw StateError('must not fetch Past'),
          ),
          tournamentLiveEventPrefetchProvider.overrideWith(
            (_) => throw StateError('must not prefetch'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        host(
          container,
          RepaintBoundary(
            key: key,
            child: const TournamentsPane(tabId: 'events'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
      expect(find.text('Current'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Past'));
      await tester.pumpAndSettle();
      expect(
        container.read(selectedGroupCategoryProvider),
        GroupEventCategory.past,
      );
      expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
      expect(tester.takeException(), isNull);
      final qaDirectory = Platform.environment['CHESSEVER_TICKET_QA_DIR'];
      if (qaDirectory == null) return;
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(qaDirectory).create(recursive: true);
        await File(
          '$qaDirectory/events-paywall.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    },
  );
}
