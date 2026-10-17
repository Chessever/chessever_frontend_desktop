import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/editorial/inbox_provider.dart';
import 'package:chessever/desktop/shell/desktop_chrome_metrics.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/providers/app_version_provider.dart';

/// Trello #1247: on a laptop at Windows 125 % scaling the sidebar's Settings
/// row was cut off at the bottom of the window. These heights are the window
/// heights (logical px) of the laptop setups that card names.
void main() {
  const version = '22.13.6';
  // Every sidebar row with Botvinnik on: 10 routes + Search, How to use,
  // Feedback, Inbox, Botvinnik.
  const navRows = 15;

  const windowHeights = <String, double>{
    '1920x1080 at 100 % maximized': 1040,
    '1920x1080 at 125 % maximized': 826,
    'reported laptop window (screenshot at 125 %)': 752,
    '1366x768 at 100 % maximized': 728,
    '1920x1080 at 150 % maximized': 688,
    '1920x1080 at 150 % default window': 640,
    'shorter than any tier': 560,
  };

  group('desktopSidebarDensityFor', () {
    DesktopSidebarDensity densityAt(double windowHeight, {required bool pro}) =>
        desktopSidebarDensityFor(
          bodyHeight: windowHeight - kDesktopChromeBarHeight,
          navRows: navRows,
          showPremium: !pro,
        );

    double slackAt(double windowHeight, {required bool pro}) =>
        windowHeight -
        kDesktopChromeBarHeight -
        densityAt(
          windowHeight,
          pro: pro,
        ).bodyExtent(navRows: navRows, showPremium: !pro);

    test('keeps the designed 44 px rows when the window is tall enough', () {
      expect(densityAt(1040, pro: false), DesktopSidebarDensity.regular);
      expect(densityAt(1040, pro: true), DesktopSidebarDensity.regular);
      // 2560x1440 at 150 % maximized.
      expect(densityAt(912, pro: true), DesktopSidebarDensity.regular);
    });

    test('the regular density is the original rail spacing', () {
      const regular = DesktopSidebarDensity.regular;
      expect(regular.rowHeight, 44);
      expect(regular.rowGap, 2);
      expect(regular.navGap, 8);
      expect(regular.premiumGap, 8);
      expect(regular.versionTopGap, 8);
      expect(regular.versionBottomGap, 10);
    });

    test('tightens rows on laptop heights instead of clipping', () {
      for (final windowHeight in [826.0, 752.0, 728.0, 688.0, 640.0]) {
        for (final pro in [false, true]) {
          final density = densityAt(windowHeight, pro: pro);
          final reason = '$windowHeight px, ${pro ? 'Pro' : 'free'}';
          expect(density.rowHeight, inInclusiveRange(30, 43), reason: reason);
          expect(
            slackAt(windowHeight, pro: pro),
            greaterThanOrEqualTo(0),
            reason: reason,
          );
        }
      }
    });

    test('taller windows never get shorter rows', () {
      for (final pro in [false, true]) {
        var previous = 0.0;
        for (var height = 520.0; height <= 1100; height++) {
          final rowHeight = densityAt(height, pro: pro).rowHeight;
          expect(rowHeight, greaterThanOrEqualTo(previous));
          previous = rowHeight;
        }
      }
    });

    test('tightened rows fill the rail instead of leaving a gap', () {
      for (final pro in [false, true]) {
        for (var height = 520.0; height <= 1100; height++) {
          final density = densityAt(height, pro: pro);
          final slack = slackAt(height, pro: pro);
          if (density == DesktopSidebarDensity.regular || slack < 0) continue;
          // One pixel more per row costs ~17 px; the 1 to 2 px row gap step
          // at 40 px rows costs up to one regular row. The leftover never
          // exceeds that.
          expect(
            slack,
            lessThanOrEqualTo(DesktopSidebarDensity.regular.rowExtent),
            reason: '$height px',
          );
        }
      }
    });
  });

  for (final MapEntry(key: setup, value: height) in windowHeights.entries) {
    for (final expanded in [false, true]) {
      for (final pro in [false, true]) {
        final state =
            '${expanded ? 'expanded' : 'collapsed'}, ${pro ? 'Pro' : 'free'}';
        testWidgets('$setup ($state): Settings and footer stay whole', (
          tester,
        ) async {
          final selected = <DesktopPane>[];
          await _pumpSidebar(
            tester,
            height: height,
            expanded: expanded,
            pro: pro,
            onSelect: selected.add,
          );

          expect(tester.takeException(), isNull);

          final settings = find.byIcon(Icons.settings_outlined);
          expect(settings, findsOneWidget);
          final settingsRect = tester.getRect(settings);
          expect(settingsRect.top, greaterThanOrEqualTo(0));
          expect(settingsRect.bottom, lessThanOrEqualTo(height));

          final versionRect = tester.getRect(find.text('v$version'));
          expect(versionRect.bottom, lessThanOrEqualTo(height));
          expect(versionRect.top, greaterThan(settingsRect.bottom));

          if (!pro) {
            final premium = find.byIcon(Icons.workspace_premium_rounded);
            expect(premium, findsOneWidget);
            expect(tester.getRect(premium).bottom, lessThan(settingsRect.top));
          }

          await tester.tap(settings);
          await tester.pumpAndSettle();
          expect(selected, [DesktopPane.settings]);

          final nav = _navScrollPosition(tester);
          final bodyHeight = height - kDesktopChromeBarHeight;
          final fitsWithoutScrolling =
              bodyHeight >=
              DesktopSidebarDensity.tightest.bodyExtent(
                navRows: navRows,
                showPremium: !pro,
              );
          if (fitsWithoutScrolling) {
            expect(nav.maxScrollExtent, 0);
          } else {
            expect(nav.maxScrollExtent, greaterThan(0));
          }

          // The last nav row is always reachable, scrolling if it must.
          await tester.scrollUntilVisible(
            find.byIcon(Icons.forum_outlined),
            40,
            scrollable: find.descendant(
              of: find.byKey(const ValueKey('desktop-sidebar-nav-scroll')),
              matching: find.byType(Scrollable),
            ),
          );
          final lastRow = tester.getRect(find.byIcon(Icons.forum_outlined));
          expect(lastRow.bottom, lessThanOrEqualTo(settingsRect.top));
        });
      }
    }
  }

  testWidgets('a pane selected off-screen scrolls into view', (tester) async {
    await _pumpSidebar(
      tester,
      height: 560,
      expanded: true,
      pro: false,
      onSelect: (_) {},
    );
    final inbox = find.byIcon(Icons.inbox_outlined);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('desktop-sidebar-nav-scroll')),
    );
    expect(tester.getRect(inbox).bottom, greaterThan(viewport.bottom));
    // Rows continue below: only the bottom edge fades.
    expect(_edgeFadeOpacities(tester), [0, 1]);

    await _pumpSidebar(
      tester,
      height: 560,
      expanded: true,
      pro: false,
      current: DesktopPane.inbox,
      onSelect: (_) {},
    );

    final inboxRect = tester.getRect(inbox);
    expect(inboxRect.top, greaterThanOrEqualTo(viewport.top));
    expect(inboxRect.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(_edgeFadeOpacities(tester).first, 1);
  });

  testWidgets('a tall window shows no scroll fade', (tester) async {
    await _pumpSidebar(
      tester,
      height: 1040,
      expanded: true,
      pro: false,
      onSelect: (_) {},
    );
    expect(_edgeFadeOpacities(tester), [0, 0]);
  });
}

/// Opacity of the nav viewport's [top, bottom] scroll fades.
List<double> _edgeFadeOpacities(WidgetTester tester) {
  final fades = tester.widgetList<AnimatedOpacity>(
    find.byWidgetPredicate(
      (widget) =>
          widget is AnimatedOpacity &&
          widget.child is DecoratedBox &&
          switch ((widget.child! as DecoratedBox).decoration) {
            BoxDecoration(:final gradient) => gradient != null,
            _ => false,
          },
    ),
  );
  return [for (final fade in fades) fade.opacity];
}

ScrollPosition _navScrollPosition(WidgetTester tester) {
  final state = tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const ValueKey('desktop-sidebar-nav-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  return state.position;
}

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required double height,
  required bool expanded,
  required bool pro,
  DesktopPane? current,
  required void Function(DesktopPane pane) onSelect,
}) async {
  tester.view.physicalSize = Size(800, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appVersionProvider.overrideWith((ref) async => '22.13.6'),
        inboxHasUnreadProvider.overrideWithValue(false),
        botvinnikEnabledProvider.overrideWith(_BotvinnikOn.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              height: height,
              child: DesktopSidebar(
                current: current,
                expanded: expanded,
                onSelect: (pane, {required inNewTab}) => onSelect(pane),
                feedbackScreenshotKey: GlobalKey(),
                onToggleExpanded: () {},
                onSearch: () {},
                onHowToUse: () {},
                loadEntitlement:
                    () async =>
                        pro ? const EntitlementSnapshot(isActive: true) : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _BotvinnikOn extends BotvinnikEnabledNotifier {
  @override
  Future<bool> build() async => true;
}
