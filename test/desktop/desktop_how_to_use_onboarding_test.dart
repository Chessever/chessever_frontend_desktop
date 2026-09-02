import 'dart:async';

import 'package:chessever/desktop/services/desktop_how_to_use_onboarding.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('first installation opens How to use for the current version', () {
    expect(
      shouldOpenDesktopHowToUse(
        currentVersion: '20.28.18',
        dismissedVersion: null,
      ),
      isTrue,
    );
  });

  test('same-version dismissal suppresses automatic reopening', () async {
    final tabs = DesktopTabsNotifier();

    final openedTabId = await maybeAutoOpenDesktopHowToUse(
      tabs: tabs,
      currentVersion: '20.28.18',
      loadDismissedVersion: () async => '20.28.18',
    );

    expect(openedTabId, isNull);
    expect(
      tabs.state.tabs.map((tab) => tab.kind),
      isNot(contains(TabKind.howToUse)),
    );
  });

  test('a new app version reopens How to use', () async {
    final tabs = DesktopTabsNotifier();

    final openedTabId = await maybeAutoOpenDesktopHowToUse(
      tabs: tabs,
      currentVersion: '20.28.19',
      loadDismissedVersion: () async => '20.28.18',
    );

    expect(openedTabId, isNotNull);
    expect(tabs.state.active?.kind, TabKind.howToUse);
  });

  test('a destination opened during persistence lookup keeps focus', () async {
    final tabs = DesktopTabsNotifier();
    final lookup = Completer<String?>();
    final pendingOpen = maybeAutoOpenDesktopHowToUse(
      tabs: tabs,
      currentVersion: '20.28.18',
      loadDismissedVersion: () => lookup.future,
    );

    final libraryTabId = tabs.open(TabKind.library, reuseExisting: false);
    lookup.complete(null);
    final howToUseTabId = await pendingOpen;

    expect(howToUseTabId, isNotNull);
    expect(tabs.state.activeId, libraryTabId);
  });

  test(
    'closing How to use during version lookup suppresses reopening',
    () async {
      final tabs = DesktopTabsNotifier();
      final lookup = Completer<String?>();
      var dismissed = false;
      final pendingOpen = maybeAutoOpenDesktopHowToUse(
        tabs: tabs,
        currentVersion: '20.28.18',
        loadDismissedVersion: () => lookup.future,
        wasDismissed: () => dismissed,
      );

      final howToUseTabId = tabs.open(TabKind.howToUse);
      final beforeClose = tabs.state;
      tabs.close(howToUseTabId);
      dismissed = didCloseDesktopHowToUse(beforeClose, tabs.state);
      lookup.complete(null);

      expect(await pendingOpen, isNull);
      expect(
        tabs.state.tabs.map((tab) => tab.kind),
        isNot(contains(TabKind.howToUse)),
      );
    },
  );

  test('startup focuses How to use while Events is still the default', () {
    final tabs = DesktopTabsNotifier();

    expect(shouldFocusDesktopHowToUse(tabs.state), isTrue);
  });

  test('startup does not steal focus from an opened destination', () {
    final tabs = DesktopTabsNotifier();
    final libraryTabId = tabs.open(TabKind.library, reuseExisting: false);

    final howToUseTabId = autoOpenDesktopHowToUseTab(tabs);

    expect(tabs.state.activeId, libraryTabId);
    expect(
      tabs.state.tabs.singleWhere((tab) => tab.id == howToUseTabId).kind,
      TabKind.howToUse,
    );
  });

  test('closing How to use is the dismissal boundary', () {
    final tabs = DesktopTabsNotifier();
    final howToUseTabId = autoOpenDesktopHowToUseTab(tabs);
    final beforeClose = tabs.state;

    tabs.close(howToUseTabId);

    expect(didCloseDesktopHowToUse(beforeClose, tabs.state), isTrue);
  });

  test('closing How to use persists the dismissed app version', () async {
    final tabs = DesktopTabsNotifier();
    final howToUseTabId = autoOpenDesktopHowToUseTab(tabs);
    final beforeClose = tabs.state;
    String? persistedVersion;

    tabs.close(howToUseTabId);
    final persisted = await persistDesktopHowToUseDismissalIfClosed(
      previous: beforeClose,
      next: tabs.state,
      currentVersion: '20.28.18',
      persistDismissedVersion: (version) async => persistedVersion = version,
    );

    expect(persisted, isTrue);
    expect(persistedVersion, '20.28.18');
  });
}
