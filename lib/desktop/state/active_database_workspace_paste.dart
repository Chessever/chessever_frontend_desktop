import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';

class ActiveDatabaseWorkspacePasteDispatcher {
  const ActiveDatabaseWorkspacePasteDispatcher({
    required this.tabId,
    required this.invoke,
  });

  final String tabId;
  final void Function() invoke;
}

final activeDatabaseWorkspacePasteDispatcherProvider =
    StateProvider<ActiveDatabaseWorkspacePasteDispatcher?>((_) => null);

void useActiveDatabaseWorkspacePasteDispatcher({
  required BuildContext context,
  required WidgetRef ref,
  required String? tabId,
  required VoidCallback onPaste,
}) {
  final isForeground = ref.watch(
    desktopTabsProvider.select((tabs) => tabs.activeId == tabId),
  );
  final latestPaste = useRef<VoidCallback?>(null);
  latestPaste.value = onPaste;
  useEffect(() {
    final effectiveTabId = tabId?.trim();
    if (!isForeground || effectiveTabId == null || effectiveTabId.isEmpty) {
      return null;
    }
    final dispatcher = ActiveDatabaseWorkspacePasteDispatcher(
      tabId: effectiveTabId,
      invoke: () => latestPaste.value?.call(),
    );
    final notifier = ref.read(
      activeDatabaseWorkspacePasteDispatcherProvider.notifier,
    );
    var assigned = false;
    Future.microtask(() {
      if (context.mounted &&
          notifier.mounted &&
          ref.read(desktopTabsProvider).activeId == effectiveTabId) {
        notifier.state = dispatcher;
        assigned = true;
      }
    });
    return () {
      if (!assigned ||
          !notifier.mounted ||
          !identical(notifier.state, dispatcher)) {
        return;
      }
      Future.microtask(() {
        if (notifier.mounted && identical(notifier.state, dispatcher)) {
          notifier.state = null;
        }
      });
    };
  }, [tabId, isForeground]);
}

enum DatabaseWorkspacePasteDispatch {
  notDatabaseWorkspace,
  unavailable,
  dispatched,
}

DatabaseWorkspacePasteDispatch dispatchActiveDatabaseWorkspacePaste({
  required TabKind? activeTabKind,
  required String? activeTabId,
  required ActiveDatabaseWorkspacePasteDispatcher? dispatcher,
}) {
  if (activeTabKind != TabKind.databaseWorkspace) {
    return DatabaseWorkspacePasteDispatch.notDatabaseWorkspace;
  }
  if (activeTabId == null || dispatcher?.tabId != activeTabId) {
    return DatabaseWorkspacePasteDispatch.unavailable;
  }
  dispatcher!.invoke();
  return DatabaseWorkspacePasteDispatch.dispatched;
}
