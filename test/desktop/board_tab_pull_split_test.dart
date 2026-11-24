import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/shell/board_split_workspace.dart';
import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_split_view.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/game_drag_source.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

import 'support/desktop_premium_test_overrides.dart';

class _StableEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings();
}

const _workspaceKey = ValueKey('workspace');

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();

  void become(SubscriptionState next) => state = next;
}

Future<({ProviderContainer container, String carlsen, String anand})> _pump(
  WidgetTester tester, {
  bool premium = true,
}) async {
  tester.view.physicalSize = const Size(1208, 854);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      if (premium)
        ...desktopPremiumTestOverrides
      else ...[
        subscriptionProvider.overrideWith(
          (ref) => _Subscription(SubscriptionState()),
        ),
        desktopEntitlementProvider.overrideWithValue(
          DesktopEntitlementSnapshot.guest,
        ),
      ],
      engineSettingsProviderNew.overrideWith(_StableEngineSettings.new),
    ],
  );
  addTearDown(container.dispose);
  String open(String id, String white, String black) =>
      openBoardGameTabFromContainer(
        container,
        BoardTabGameArgs(
          gameId: id,
          pgn: '1. e4 e5 *',
          label: '$white vs $black',
          whiteName: white,
          blackName: black,
        ),
        reuseExisting: false,
      );
  final carlsen = open('game-a', 'Magnus Carlsen', 'Hikaru Nakamura');
  final anand = open('game-b', 'Viswanathan Anand', 'Ding Liren');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 46, child: DesktopTabBar()),
              Expanded(
                key: _workspaceKey,
                child: Consumer(
                  builder: (context, ref, _) {
                    final tabs = ref.watch(desktopTabsProvider);
                    return BoardSplitDropLayer(
                      child: DesktopWorkspaceStack(
                        tabs: tabs.tabs,
                        activeId: tabs.activeId,
                        feedbackScreenshotKey: GlobalKey(),
                        split: ref.watch(visibleBoardSplitProvider),
                        onActivateCell:
                            ref.read(desktopTabsProvider.notifier).activate,
                        contentBuilder:
                            (tab) => ColoredBox(
                              key: ValueKey('page:${tab.id}'),
                              color: Colors.black,
                            ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, carlsen: carlsen, anand: anand);
}

void main() {
  testWidgets('pulling a tab down drops it beside the board being viewed', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);

    final mouse = await tester.startGesture(
      tester.getCenter(find.textContaining('Carlsen')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // The press selects the tab at once, exactly as before.
    expect(
      fixture.container.read(desktopTabsProvider).activeId,
      fixture.carlsen,
    );
    // The board being viewed still counts as on screen during the press.
    expect(
      fixture.container.read(boardTabOnScreenProvider(fixture.anand)),
      isTrue,
    );

    await mouse.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(find.byType(GameDragChip), findsOneWidget);
    // The pull brings back the board the user was looking at.
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);

    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    await mouse.moveTo(origin + const Offset(1120, 400));
    await tester.pump();
    await mouse.moveTo(origin + const Offset(1130, 410));
    await tester.pump();
    expect(find.text('Add to Round Wall'), findsOneWidget);

    await mouse.up();
    await tester.pump();
    final split = fixture.container.read(visibleBoardSplitProvider)!;
    expect(split.tabIds, [fixture.anand, fixture.carlsen]);
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);
    final chrome = find.byType(DesktopTabBar);
    expect(
      find.descendant(of: chrome, matching: find.textContaining('Carlsen')),
      findsNothing,
    );

    final watched = find.byWidgetPredicate(
      (widget) => widget is BoardTabDragSource && widget.data?.fromWall == true,
    );
    final source = tester.getCenter(watched.last);
    final upward = await tester.startGesture(
      source,
      kind: PointerDeviceKind.mouse,
    );
    await upward.moveBy(const Offset(0, -32));
    await tester.pump();
    expect(find.byType(GameDragChip), findsOneWidget);
    await upward.moveTo(tester.getCenter(chrome));
    await tester.pump();
    await upward.up();
    await upward.removePointer();
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);
    expect(
      find.descendant(of: chrome, matching: find.textContaining('Carlsen')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('a guest pulling a tab down gets the Premium prompt instead', (
    tester,
  ) async {
    final fixture = await _pump(tester, premium: false);
    final shown = <DesktopAccessDecision>[];
    final surfaces = <String>[];
    final unregister = registerDesktopPaywallPresenter(fixture.container, (
      decision, {
      DesktopAccessContext? context,
      DesktopAccessResume? resume,
      required String surface,
    }) async {
      shown.add(decision);
      surfaces.add(surface);
      return false;
    });
    addTearDown(unregister);

    final mouse = await tester.startGesture(
      tester.getCenter(find.textContaining('Carlsen')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.moveBy(const Offset(0, 30));
    await tester.pump();
    final origin = tester.getTopLeft(find.byKey(_workspaceKey));
    await mouse.moveTo(origin + const Offset(1120, 400));
    await tester.pump();
    await mouse.moveTo(origin + const Offset(1130, 410));
    await tester.pump();
    // The landing area still shows, and says what it needs.
    expect(find.text('Add to Round Wall \u00b7 Premium'), findsOneWidget);

    await mouse.up();
    await tester.pump();
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    expect(fixture.container.read(visibleBoardSplitProvider), isNull);
    expect(shown, hasLength(1));
    expect(shown.single.outcome, DesktopAccess.premiumRequired);
    expect(shown.single.reason, DesktopAccessReason.premiumBoardSplit);
    expect(surfaces.single, 'board_split_tab_drop');
    // Both boards are still open tabs.
    final open = {
      for (final t in fixture.container.read(desktopTabsProvider).tabs) t.id,
    };
    expect(open, containsAll([fixture.carlsen, fixture.anand]));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the only board on screen keeps its old pull behaviour', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    final mouse = await tester.startGesture(
      tester.getCenter(find.textContaining('Anand')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.moveBy(const Offset(0, 30));
    await tester.pump();
    // Nothing to split with: no drag proxy, the tear-off path is untouched.
    expect(find.byType(GameDragChip), findsNothing);
    await mouse.up();
    await tester.pump();
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the tab menu shows a board beside the current one, the cell '
      'header closes it', (tester) async {
    final fixture = await _pump(tester);
    await tester.tapAt(
      tester.getCenter(find.textContaining('Carlsen')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    // The press of a right click does not switch boards.
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);
    await tester.tap(find.text('Add to Round Wall'));
    await tester.pumpAndSettle();
    expect(fixture.container.read(visibleBoardSplitProvider)!.tabIds, [
      fixture.anand,
      fixture.carlsen,
    ]);

    // The right cell's close button closes that board's tab.
    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await tester.pump();
    final tabs = fixture.container.read(desktopTabsProvider).tabs;
    expect(tabs.any((t) => t.id == fixture.carlsen), isFalse);
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('a guest asking for a board beside the current one gets the '
      'Premium prompt, and the purchase finishes the move', (tester) async {
    final fixture = await _pump(tester, premium: false);
    final surfaces = <String>[];
    final unregister = registerDesktopPaywallPresenter(fixture.container, (
      decision, {
      DesktopAccessContext? context,
      DesktopAccessResume? resume,
      required String surface,
    }) async {
      surfaces.add(surface);
      expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
      // The member buys Premium inside the prompt.
      (fixture.container.read(subscriptionProvider.notifier) as _Subscription)
          .become(
            SubscriptionState(
              isSubscribed: true,
              expirationDate: DateTime.now().add(const Duration(days: 30)),
            ),
          );
      if (resume != null && (resume.stillMatches?.call() ?? true)) {
        await resume.run();
      }
      return true;
    });
    addTearDown(unregister);

    await tester.tapAt(
      tester.getCenter(find.textContaining('Carlsen')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Round Wall'));
    await tester.pumpAndSettle();
    expect(surfaces, ['board_split_open_beside']);
    expect(fixture.container.read(visibleBoardSplitProvider)!.tabIds, [
      fixture.anand,
      fixture.carlsen,
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('a wobbly click on a tab still just selects it', (tester) async {
    final fixture = await _pump(tester);
    final mouse = await tester.startGesture(
      tester.getCenter(find.textContaining('Carlsen')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.moveBy(const Offset(1, 12));
    await tester.pump();
    expect(find.byType(GameDragChip), findsNothing);
    await mouse.up();
    await tester.pump();
    expect(
      fixture.container.read(desktopTabsProvider).activeId,
      fixture.carlsen,
    );
    expect(fixture.container.read(boardSplitProvider).groups, isEmpty);
    // A plain click: the previous board leaves the screen on release.
    expect(
      fixture.container.read(boardTabOnScreenProvider(fixture.anand)),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('closing a background tab from its close button returns to '
      'the board being viewed, not into its hidden split', (tester) async {
    final fixture = await _pump(tester);
    final tabs = fixture.container.read(desktopTabsProvider.notifier);
    final partner = tabs.open(
      TabKind.board,
      reuseExisting: false,
      focus: false,
    );
    fixture.container
        .read(boardSplitProvider.notifier)
        .watch(targetTabId: fixture.carlsen, incomingTabId: partner);
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1000, 600));
    await mouse.moveTo(tester.getCenter(find.textContaining('Carlsen')));
    await tester.pumpAndSettle();
    final close =
        find
            .descendant(
              of: find.byType(DesktopTabBar),
              matching: find.byIcon(Icons.close_rounded),
            )
            .first;
    await mouse.moveTo(tester.getCenter(close));
    await tester.pumpAndSettle();
    await mouse.down(tester.getCenter(close));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      fixture.container
          .read(desktopTabsProvider)
          .tabs
          .any((t) => t.id == fixture.carlsen),
      isFalse,
    );
    expect(fixture.container.read(desktopTabsProvider).activeId, fixture.anand);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
