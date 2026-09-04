import 'package:chessever/desktop/state/desktop_tabs.dart';

const desktopHowToUseDismissedVersionKey =
    'desktop_how_to_use_dismissed_version_v1';

bool shouldOpenDesktopHowToUse({
  required String currentVersion,
  required String? dismissedVersion,
}) {
  return currentVersion.trim().isNotEmpty && dismissedVersion != currentVersion;
}

bool shouldFocusDesktopHowToUse(DesktopTabsState tabs) {
  return tabs.tabs.length == 1 &&
      tabs.activeId == 'tournaments-default' &&
      tabs.active?.kind == TabKind.tournaments;
}

String autoOpenDesktopHowToUseTab(DesktopTabsNotifier tabs) {
  final focus = shouldFocusDesktopHowToUse(tabs.currentState);
  return tabs.open(TabKind.howToUse, focus: focus);
}

bool didCloseDesktopHowToUse(DesktopTabsState previous, DesktopTabsState next) {
  final liveTabIds = next.tabs.map((tab) => tab.id).toSet();
  return previous.tabs.any(
    (tab) => tab.kind == TabKind.howToUse && !liveTabIds.contains(tab.id),
  );
}

Future<String?> maybeAutoOpenDesktopHowToUse({
  required DesktopTabsNotifier tabs,
  required String currentVersion,
  required Future<String?> Function() loadDismissedVersion,
  bool Function()? isStillActive,
  bool Function()? wasDismissed,
}) async {
  try {
    final dismissedVersion = await loadDismissedVersion();
    if (!(isStillActive?.call() ?? true) ||
        (wasDismissed?.call() ?? false) ||
        !shouldOpenDesktopHowToUse(
          currentVersion: currentVersion,
          dismissedVersion: dismissedVersion,
        )) {
      return null;
    }
    return autoOpenDesktopHowToUseTab(tabs);
  } catch (_) {
    return null;
  }
}

Future<bool> persistDesktopHowToUseDismissalIfClosed({
  required DesktopTabsState previous,
  required DesktopTabsState next,
  required String currentVersion,
  required Future<void> Function(String version) persistDismissedVersion,
}) async {
  if (currentVersion.trim().isEmpty ||
      !didCloseDesktopHowToUse(previous, next)) {
    return false;
  }
  try {
    await persistDismissedVersion(currentVersion);
    return true;
  } catch (_) {
    return false;
  }
}
