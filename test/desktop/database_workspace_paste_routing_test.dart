import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_database_workspace_paste.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

void main() {
  group('active database workspace paste routing', () {
    testWidgets(
      'tab switched before queued registration cannot publish stale owner',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final tabs = container.read(desktopTabsProvider.notifier);
        tabs.navigateActive(TabKind.databaseWorkspace, title: 'Database A');
        final tabA = container.read(desktopTabsProvider).activeId!;
        final tabB = tabs.open(
          TabKind.databaseWorkspace,
          title: 'Database B',
          reuseExisting: false,
          focus: false,
        );

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: _QueuedTabSwitchHarness(tabA: tabA, tabB: tabB),
            ),
          ),
        );

        expect(container.read(desktopTabsProvider).activeId, tabB);
        expect(
          container.read(activeDatabaseWorkspacePasteDispatcherProvider)?.tabId,
          isNot(tabA),
        );

        await tester.pump();

        expect(
          container.read(activeDatabaseWorkspacePasteDispatcherProvider)?.tabId,
          tabB,
        );
      },
    );

    test('matching database workspace dispatcher owns paste', () {
      var pasteCount = 0;
      final dispatcher = ActiveDatabaseWorkspacePasteDispatcher(
        tabId: 'database-tab',
        invoke: () => pasteCount++,
      );

      final result = dispatchActiveDatabaseWorkspacePaste(
        activeTabKind: TabKind.databaseWorkspace,
        activeTabId: 'database-tab',
        dispatcher: dispatcher,
      );

      expect(result, DatabaseWorkspacePasteDispatch.dispatched);
      expect(pasteCount, 1);
    });

    test(
      'database workspace consumes paste while dispatcher is unavailable',
      () {
        final result = dispatchActiveDatabaseWorkspacePaste(
          activeTabKind: TabKind.databaseWorkspace,
          activeTabId: 'database-tab',
          dispatcher: null,
        );

        expect(result, DatabaseWorkspacePasteDispatch.unavailable);
      },
    );

    test('dispatcher from another database tab cannot receive paste', () {
      var pasteCount = 0;
      final dispatcher = ActiveDatabaseWorkspacePasteDispatcher(
        tabId: 'background-database-tab',
        invoke: () => pasteCount++,
      );

      final result = dispatchActiveDatabaseWorkspacePaste(
        activeTabKind: TabKind.databaseWorkspace,
        activeTabId: 'foreground-database-tab',
        dispatcher: dispatcher,
      );

      expect(result, DatabaseWorkspacePasteDispatch.unavailable);
      expect(pasteCount, 0);
    });

    test('non-database routes retain generic clipboard PGN handling', () {
      final result = dispatchActiveDatabaseWorkspacePaste(
        activeTabKind: TabKind.library,
        activeTabId: 'library-tab',
        dispatcher: null,
      );

      expect(result, DatabaseWorkspacePasteDispatch.notDatabaseWorkspace);
    });
  });
}

class _QueuedTabSwitchHarness extends HookConsumerWidget {
  const _QueuedTabSwitchHarness({required this.tabA, required this.tabB});

  final String tabA;
  final String tabB;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useEffect(() {
      Future.microtask(
        () => ref.read(desktopTabsProvider.notifier).activate(tabB),
      );
      return null;
    }, const []);
    return Column(
      children: [
        _RetainedDatabasePasteRegistration(tabId: tabA),
        _RetainedDatabasePasteRegistration(tabId: tabB),
      ],
    );
  }
}

class _RetainedDatabasePasteRegistration extends HookConsumerWidget {
  const _RetainedDatabasePasteRegistration({required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useActiveDatabaseWorkspacePasteDispatcher(
      context: context,
      ref: ref,
      tabId: tabId,
      onPaste: () {},
    );
    return const SizedBox.shrink();
  }
}
