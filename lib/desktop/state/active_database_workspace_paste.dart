import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_tabs.dart';

class ActiveDatabaseWorkspacePasteDispatcher {
  const ActiveDatabaseWorkspacePasteDispatcher({
    required this.tabId,
    required this.invoke,
    required this.isCurrent,
  });

  final String tabId;
  final ValueChanged<ActiveDatabaseWorkspacePasteOwnership> invoke;
  final bool Function() isCurrent;

  ActiveDatabaseWorkspacePasteOwnership captureOwnership() =>
      ActiveDatabaseWorkspacePasteOwnership._(isCurrent);
}

class ActiveDatabaseWorkspacePasteOwnership {
  const ActiveDatabaseWorkspacePasteOwnership._(this._isCurrent);

  final bool Function() _isCurrent;

  bool get isCurrent => _isCurrent();
}

final activeDatabaseWorkspacePasteDispatcherProvider =
    StateProvider<ActiveDatabaseWorkspacePasteDispatcher?>((_) => null);

void useActiveDatabaseWorkspacePasteDispatcher({
  required BuildContext context,
  required WidgetRef ref,
  required String? tabId,
  required ValueChanged<ActiveDatabaseWorkspacePasteOwnership> onPaste,
}) {
  final effectiveTabId = tabId?.trim();
  final isForeground = ref.watch(
    desktopTabsProvider.select(
      (tabs) =>
          effectiveTabId != null &&
          effectiveTabId.isNotEmpty &&
          tabs.activeId == effectiveTabId,
    ),
  );
  final latestPaste =
      useRef<ValueChanged<ActiveDatabaseWorkspacePasteOwnership>?>(null);
  latestPaste.value = onPaste;
  final ownedDispatcher = useRef<ActiveDatabaseWorkspacePasteDispatcher?>(null);
  final dispatcherNotifier = ref.read(
    activeDatabaseWorkspacePasteDispatcherProvider.notifier,
  );

  ActiveDatabaseWorkspacePasteDispatcher createDispatcher() {
    late final ActiveDatabaseWorkspacePasteDispatcher dispatcher;
    bool isCurrent() =>
        context.mounted &&
        dispatcherNotifier.mounted &&
        ref.read(desktopTabsProvider).activeId == effectiveTabId &&
        identical(dispatcherNotifier.state, dispatcher);
    dispatcher = ActiveDatabaseWorkspacePasteDispatcher(
      tabId: effectiveTabId!,
      invoke: (ownership) => latestPaste.value?.call(ownership),
      isCurrent: isCurrent,
    );
    return dispatcher;
  }

  void installDispatcher() {
    if (effectiveTabId == null || effectiveTabId.isEmpty || !context.mounted) {
      return;
    }
    if (!dispatcherNotifier.mounted ||
        ref.read(desktopTabsProvider).activeId != effectiveTabId) {
      return;
    }
    final currentOwned = ownedDispatcher.value;
    if (currentOwned != null &&
        identical(dispatcherNotifier.state, currentOwned)) {
      return;
    }
    final dispatcher = createDispatcher();
    ownedDispatcher.value = dispatcher;
    dispatcherNotifier.state = dispatcher;
  }

  ref.listen<String?>(desktopTabsProvider.select((tabs) => tabs.activeId), (
    previous,
    next,
  ) {
    if (previous == next) return;
    if (next == effectiveTabId) {
      installDispatcher();
      return;
    }
    final dispatcher = ownedDispatcher.value;
    if (previous != effectiveTabId || dispatcher == null) return;
    if (dispatcherNotifier.mounted &&
        identical(dispatcherNotifier.state, dispatcher)) {
      dispatcherNotifier.state = null;
    }
  });

  useEffect(() {
    if (!isForeground || effectiveTabId == null || effectiveTabId.isEmpty) {
      return null;
    }
    Future.microtask(installDispatcher);
    return () {
      final dispatcher = ownedDispatcher.value;
      if (dispatcher == null) return;
      if (identical(ownedDispatcher.value, dispatcher)) {
        ownedDispatcher.value = null;
      }
      Future.microtask(() {
        if (dispatcherNotifier.mounted &&
            identical(dispatcherNotifier.state, dispatcher)) {
          dispatcherNotifier.state = null;
        }
      });
    };
  }, [effectiveTabId, isForeground]);
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
  dispatcher!.invoke(dispatcher.captureOwnership());
  return DatabaseWorkspacePasteDispatch.dispatched;
}

ActiveDatabaseWorkspacePasteOwnership?
captureActiveDatabaseWorkspacePasteOwnership({
  required WidgetRef ref,
  required String? tabId,
}) {
  final effectiveTabId = tabId?.trim();
  if (effectiveTabId == null || effectiveTabId.isEmpty) return null;
  final dispatcher = ref.read(activeDatabaseWorkspacePasteDispatcherProvider);
  if (dispatcher?.tabId != effectiveTabId || !dispatcher!.isCurrent()) {
    return null;
  }
  return dispatcher.captureOwnership();
}
