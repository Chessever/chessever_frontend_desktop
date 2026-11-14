import 'package:chessever/desktop/services/desktop_how_to_use_onboarding.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dismissed in <String?>[null, '', '22.30.7', '22.30.8']) {
    test(
      'install/update never auto-opens help (dismissed=$dismissed)',
      () async {
        final tabs = DesktopTabsNotifier();
        addTearDown(tabs.dispose);
        expect(
          shouldOpenDesktopHowToUse(
            currentVersion: '22.30.8',
            dismissedVersion: dismissed,
          ),
          isFalse,
        );
        expect(shouldFocusDesktopHowToUse(tabs.state), isFalse);
        expect(shouldFocusDesktopHowToUse(tabs.state, isWeb: true), isFalse);
        expect(
          await maybeAutoOpenDesktopHowToUse(
            tabs: tabs,
            currentVersion: '22.30.8',
            loadDismissedVersion: () async => dismissed,
          ),
          isNull,
        );
        expect(tabs.state.tabs, isEmpty);
        expect(tabs.state.isHomeVisible, isTrue);
      },
    );
  }
  for (final kind in [
    TabKind.library,
    TabKind.tournamentDetail,
    TabKind.board,
  ]) {
    test(
      'startup help compatibility preserves explicit ${kind.name} destination',
      () async {
        final tabs = DesktopTabsNotifier();
        addTearDown(tabs.dispose);
        final id = tabs.open(kind);
        await maybeAutoOpenDesktopHowToUse(
          tabs: tabs,
          currentVersion: '22.30.8',
          loadDismissedVersion: () async => null,
        );
        autoOpenDesktopHowToUseTab(tabs);
        expect(tabs.state.activeId, id);
        expect(tabs.state.tabs.single.kind, kind);
      },
    );
  }
  test('help lookup failure never interrupts Home', () async {
    final tabs = DesktopTabsNotifier();
    addTearDown(tabs.dispose);
    expect(
      await maybeAutoOpenDesktopHowToUse(
        tabs: tabs,
        currentVersion: '22.30.8',
        loadDismissedVersion: () async => throw StateError('fixture'),
      ),
      isNull,
    );
    expect(tabs.state.isHomeVisible, isTrue);
    expect(tabs.state.tabs, isEmpty);
  });
}
