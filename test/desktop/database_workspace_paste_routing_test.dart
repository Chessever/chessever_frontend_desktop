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

    testWidgets('command ownership stays stale after switching away and back', (
      tester,
    ) async {
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
      ActiveDatabaseWorkspacePasteOwnership? ownership;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: _OwnershipHarness(
              tabId: tabA,
              onPaste: (value) => ownership = value,
            ),
          ),
        ),
      );
      await tester.pump();
      final dispatcher = container.read(
        activeDatabaseWorkspacePasteDispatcherProvider,
      );
      expect(dispatcher?.tabId, tabA);

      expect(
        dispatchActiveDatabaseWorkspacePaste(
          activeTabKind: TabKind.databaseWorkspace,
          activeTabId: tabA,
          dispatcher: dispatcher,
        ),
        DatabaseWorkspacePasteDispatch.dispatched,
      );
      expect(ownership?.isCurrent, isTrue);

      tabs.activate(tabB);
      await tester.pump();
      expect(ownership?.isCurrent, isFalse);

      tabs.activate(tabA);
      await tester.pump();
      expect(ownership?.isCurrent, isFalse);
    });

    testWidgets(
      'command ownership expires across a coalesced switch away and back',
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
        ActiveDatabaseWorkspacePasteOwnership? ownership;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: _OwnershipHarness(
                tabId: tabA,
                onPaste: (value) => ownership = value,
              ),
            ),
          ),
        );
        await tester.pump();
        final dispatcher = container.read(
          activeDatabaseWorkspacePasteDispatcherProvider,
        );
        expect(
          dispatchActiveDatabaseWorkspacePaste(
            activeTabKind: TabKind.databaseWorkspace,
            activeTabId: tabA,
            dispatcher: dispatcher,
          ),
          DatabaseWorkspacePasteDispatch.dispatched,
        );
        expect(ownership?.isCurrent, isTrue);
        final staleOwnership = ownership;

        tabs.activate(tabB);
        tabs.activate(tabA);

        expect(staleOwnership?.isCurrent, isFalse);
        final returnedDispatcher = container.read(
          activeDatabaseWorkspacePasteDispatcherProvider,
        );
        expect(returnedDispatcher?.tabId, tabA);
        expect(returnedDispatcher, isNot(same(dispatcher)));
        expect(
          dispatchActiveDatabaseWorkspacePaste(
            activeTabKind: TabKind.databaseWorkspace,
            activeTabId: tabA,
            dispatcher: returnedDispatcher,
          ),
          DatabaseWorkspacePasteDispatch.dispatched,
        );
        expect(ownership, isNot(same(staleOwnership)));
        expect(ownership?.isCurrent, isTrue);
      },
    );

    test('matching database workspace dispatcher owns paste', () {
      var pasteCount = 0;
      final dispatcher = ActiveDatabaseWorkspacePasteDispatcher(
        tabId: 'database-tab',
        invoke: (_) => pasteCount++,
        isCurrent: () => true,
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
        invoke: (_) => pasteCount++,
        isCurrent: () => true,
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
      onPaste: (_) {},
    );
    return const SizedBox.shrink();
  }
}

class _OwnershipHarness extends HookConsumerWidget {
  const _OwnershipHarness({required this.tabId, required this.onPaste});

  final String tabId;
  final ValueChanged<ActiveDatabaseWorkspacePasteOwnership> onPaste;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useActiveDatabaseWorkspacePasteDispatcher(
      context: context,
      ref: ref,
      tabId: tabId,
      onPaste: onPaste,
    );
    return const SizedBox.shrink();
  }
}
