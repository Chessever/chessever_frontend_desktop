import 'dart:async';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/widgets/library/local_chess_files_view.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('pending open title never borrows a different preview source label', () {
    expect(localDatabaseWorkspaceTitle(_source('/a.pgn'), '/b.pgn'), 'b.pgn');
  });

  testWidgets('out of order opens stay source-owned and never reselect a tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PendingRepository();
    final container = ProviderContainer(
      overrides: [
        localChessLibraryProvider.overrideWith(
          (ref) => LocalChessLibraryNotifier(),
        ),
        localChessDatabaseRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    const a = DatabaseWorkspaceArgs.local(localPath: '/a.pgn', title: 'A');
    const b = DatabaseWorkspaceArgs.local(localPath: '/b.pgn', title: 'B');
    final aId = openDatabaseWorkspaceTabForContainer(container, a);
    final bId = openDatabaseWorkspaceTabForContainer(container, b);
    expect(openDatabaseWorkspaceTabForContainer(container, b), bId);
    Future<void> render(String id) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: IndexedStack(
              index: id == aId ? 0 : 1,
              children: [
                DatabaseWorkspacePane(key: ValueKey(aId), tabId: aId),
                DatabaseWorkspacePane(key: ValueKey(bId), tabId: bId),
              ],
            ),
          ),
        ),
      ),
    );
    await render(bId);
    expect(repository.pending.length, 2);
    repository.pending['/b.pgn']!.complete(_source('/b.pgn'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<LocalChessFilesView>(find.byType(LocalChessFilesView))
          .stateOverride!
          .source!
          .paths,
      ['/b.pgn'],
    );
    repository.pending['/a.pgn']!.complete(_source('/a.pgn'));
    await tester.pump();
    await tester.pump();
    expect(container.read(desktopTabsProvider).activeId, bId);
    expect(
      tester
          .widget<LocalChessFilesView>(find.byType(LocalChessFilesView))
          .stateOverride!
          .source!
          .paths,
      ['/b.pgn'],
    );
    container.read(desktopTabsProvider.notifier).activate(aId);
    await render(aId);
    expect(
      tester
          .widget<LocalChessFilesView>(find.byType(LocalChessFilesView))
          .stateOverride!
          .source!
          .paths,
      ['/a.pgn'],
    );
    expect(repository.pending.length, 2);
    expect(tester.takeException(), isNull);
  });

  test(
    'closing during a cache lookup cannot resurrect or reselect the tab',
    () async {
      final repository = _PendingRepository();
      final container = ProviderContainer(
        overrides: [
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
          localChessDatabaseRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      final tabId = openDatabaseWorkspaceTabForContainer(
        container,
        const DatabaseWorkspaceArgs.local(
          localPath: '/missing-large.pgn',
          title: 'Pending',
        ),
      );
      final provider = localDatabaseWorkspaceSourceProvider(
        const LocalDatabaseWorkspaceKey('/missing-large.pgn'),
      );
      final sub = container.listen(provider, (_, __) {});
      final future = container.read(provider.future);
      // Observe errors to make detached asynchronous failure visible to the test.
      final result = future.then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      container.read(desktopTabsProvider.notifier).close(tabId);
      final activeAfterClose = container.read(desktopTabsProvider).activeId;
      sub.close();
      await container.pump();
      final source = _source('/missing-large.pgn');
      repository.pending['/missing-large.pgn']!.complete(source);
      expect(
        await result,
        same(source),
        reason: 'completion must not touch a disposed provider ref',
      );
      expect(
        container.read(desktopTabsProvider).tabs.any((tab) => tab.id == tabId),
        isFalse,
      );
      expect(container.read(desktopTabsProvider).activeId, activeAfterClose);
      expect(
        repository.persists,
        0,
        reason: 'closed owner must not start fallback indexing',
      );
    },
  );

  testWidgets(
    'single click previews; Enter opens without awaiting global scan',
    (tester) async {
      final pending = Completer<bool>();
      final library = _DelayedLibrary(pending);
      final container = ProviderContainer(
        overrides: [localChessLibraryProvider.overrideWith((ref) => library)],
      );
      addTearDown(container.dispose);
      var previews = 0;
      final entry = LocalLibraryEntry(
        path: '/large.pgn',
        addedAt: DateTime(2026),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  return buildLibraryDatabaseCatalogRowForTest(
                    title: 'Large database',
                    onSelect: () {
                      previews++;
                    },
                    onOpen:
                        () => activateLibraryLocalEntry(entry, (path) {
                          openDatabaseWorkspaceTab(
                            ref,
                            DatabaseWorkspaceArgs.local(
                              localPath: path,
                              title: 'Large database',
                            ),
                          );
                        }),
                    onContextMenu: (_) {},
                  );
                },
              ),
            ),
          ),
        ),
      );
      final before = container.read(desktopTabsProvider).tabs.length;
      await tester.tap(find.text('Large database'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(previews, 1);
      expect(container.read(desktopTabsProvider).tabs.length, before);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(container.read(desktopTabsProvider).tabs.length, before + 1);
      expect(
        library.opens,
        0,
        reason: 'workspace owns its load, not global preview',
      );
      final openedId = container.read(desktopTabsProvider).activeId;
      container
          .read(desktopTabsProvider.notifier)
          .activate('tournaments-default');
      await tester.tap(find.text('Large database'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('Large database'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(container.read(desktopTabsProvider).activeId, openedId);
      expect(container.read(desktopTabsProvider).tabs.length, before + 1);
      expect(library.opens, 0);
      pending.complete(false);
    },
  );

  testWidgets('failed open stays in its tab and Retry restarts loading', (
    tester,
  ) async {
    var pending = Completer<LocalChessSource>();
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        localChessLibraryProvider.overrideWith(
          (ref) => LocalChessLibraryNotifier(),
        ),
        localDatabaseWorkspaceSourceProvider.overrideWith((ref, key) {
          reads++;
          return pending.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final id = openDatabaseWorkspaceTabForContainer(
      container,
      const DatabaseWorkspaceArgs.local(
        localPath: '/large.pgn',
        title: 'Large database',
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: DatabaseWorkspacePane(tabId: id)),
        ),
      ),
    );
    pending.completeError(ArgumentError('Check the file is available.'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Could not open local database'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    pending = Completer<LocalChessSource>();
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(reads, 2);
    expect(find.text('Opening database…'), findsOneWidget);
    expect(container.read(desktopTabsProvider).activeId, id);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('detached'));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('delayed database opens in its tab with named loading feedback', (
    tester,
  ) async {
    final pending = Completer<LocalChessSource>();
    final container = ProviderContainer(
      overrides: [
        localChessLibraryProvider.overrideWith(
          (ref) => LocalChessLibraryNotifier(),
        ),
        localDatabaseWorkspaceSourceProvider.overrideWith(
          (ref, key) => pending.future,
        ),
      ],
    );
    addTearDown(container.dispose);
    final id = openDatabaseWorkspaceTabForContainer(
      container,
      const DatabaseWorkspaceArgs.local(
        localPath: '/large.pgn',
        title: 'Large database',
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: DatabaseWorkspacePane(tabId: id)),
        ),
      ),
    );
    expect(container.read(desktopTabsProvider).activeId, id);
    expect(find.text('Opening database…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('detached'));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

LocalChessSource _source(String path) => LocalChessSource(
  id: path,
  label: path,
  paths: [path],
  rootPath: '/',
  scannedAt: DateTime(2026),
  root: LocalChessFolderNode.fromChildren(
    name: path,
    path: 'root:$path',
    relativePath: '',
    children: [
      LocalChessFileNode(
        name: path,
        path: path,
        relativePath: path,
        extension: 'pgn',
        sizeBytes: 0,
        status: LocalChessFileStatus.noGames,
        isWritableEmptyDatabase: true,
        games: const [],
      ),
    ],
  ),
);

class _PendingRepository extends LocalChessDatabaseRepository {
  _PendingRepository()
    : super(
        database: () async => throw StateError('No disk database in tests'),
      );
  final pending = <String, Completer<LocalChessSource?>>{};
  int persists = 0;
  @override
  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
    LocalChessScanProgressSink? onProgress,
  }) {
    final completer = Completer<LocalChessSource?>();
    pending[paths.single] = completer;
    return completer.future;
  }

  @override
  Future<void> persistSource(LocalChessSource source) async {
    persists++;
  }
}

class _DelayedLibrary extends LocalChessLibraryNotifier {
  _DelayedLibrary(this.pending);
  final Completer<bool> pending;
  int opens = 0;
  @override
  Future<bool> openPaths(
    List<String> paths, {
    String? sourceLabel,
    LocalLibraryEntryMetadata? registryMetadata,
    bool forceRefresh = false,
  }) {
    opens++;
    return pending.future;
  }
}
