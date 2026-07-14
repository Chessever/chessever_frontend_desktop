import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';

void main() {
  test('local source selection clears stale import preview', () {
    String? selectedLocalPath;
    var folderSelectionCleared = false;
    var importPreviewCleared = false;

    syncLibraryLocalSelection(
      localState: const LocalChessLibraryState(selectedPath: '/db/local.pgn'),
      currentSelectedLocalPath: selectedLocalPath,
      selectLocalPath: (path) => selectedLocalPath = path,
      clearFolderSelection: () => folderSelectionCleared = true,
      hasImportPreview: true,
      clearImportPreview: () => importPreviewCleared = true,
    );

    expect(selectedLocalPath, '/db/local.pgn');
    expect(folderSelectionCleared, isTrue);
    expect(importPreviewCleared, isTrue);
  });

  test(
    'local source selection does not disturb explicit import without path',
    () {
      var selectedLocalPathChanged = false;
      var folderSelectionCleared = false;
      var importPreviewCleared = false;

      syncLibraryLocalSelection(
        localState: const LocalChessLibraryState(),
        currentSelectedLocalPath: null,
        selectLocalPath: (_) => selectedLocalPathChanged = true,
        clearFolderSelection: () => folderSelectionCleared = true,
        hasImportPreview: true,
        clearImportPreview: () => importPreviewCleared = true,
      );

      expect(selectedLocalPathChanged, isFalse);
      expect(folderSelectionCleared, isFalse);
      expect(importPreviewCleared, isFalse);
    },
  );

  test('local database workspace resolves synthetic single-file root', () {
    const filePath = '/db/local.pgn';
    final source = _singleFileSource(filePath);

    expect(localDatabaseWorkspacePath(source, source.root.path), filePath);
  });

  test('local database workspace opens the live preview while indexing', () {
    const filePath = '/db/local.pgn';
    final source = _singleFileSource(filePath);
    final state = LocalChessLibraryState(
      source: source,
      selectedPath: filePath,
      backgroundImports: <String, LocalChessScanProgress>{
        localChessInputPathKey(filePath): LocalChessScanProgress(
          fraction: 0.37,
          message: 'Indexing full PGN in the background...',
        ),
      },
    );

    final live = localDatabaseWorkspaceLiveSource(
      state,
      const LocalDatabaseWorkspaceKey(filePath),
    );

    expect(live.source, same(source));
    expect(live.isIndexing, isTrue);
  });

  test('workspace keeps its source when another database is selected', () {
    const firstPath = '/db/first.pgn';
    const secondPath = '/db/second.pgn';
    final first = _singleFileSource(firstPath);
    final second = _singleFileSource(secondPath);
    final state = LocalChessLibraryState(
      source: second,
      selectedPath: secondPath,
      sessionSources: <String, LocalChessSource>{
        localChessInputPathKey(firstPath): first,
        localChessInputPathKey(secondPath): second,
      },
      backgroundImports: <String, LocalChessScanProgress>{
        localChessInputPathKey(firstPath): LocalChessScanProgress(
          fraction: 0.42,
          message: 'Indexing full PGN in the background...',
        ),
      },
    );

    final retained = localDatabaseWorkspaceLiveSource(
      state,
      const LocalDatabaseWorkspaceKey(firstPath),
    );

    expect(retained.source, same(first));
    expect(retained.isIndexing, isTrue);
  });

  test('revisioned workspace reloads after background indexing finishes', () {
    const filePath = '/db/local.pgn';
    final source = _singleFileSource(filePath);

    final live = localDatabaseWorkspaceLiveSource(
      LocalChessLibraryState(source: source, selectedPath: filePath),
      const LocalDatabaseWorkspaceKey(filePath, revision: 1),
    );

    expect(live.source, isNull);
    expect(live.isIndexing, isFalse);
  });

  testWidgets(
    'folder rail remains usable when realtime folder sync times out',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: buildLibraryFolderRailForTest(
              error: Exception(
                'RealtimeSubscribeException(status: '
                'RealtimeSubscribeStatus.timedOut, details: null)',
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('Could not load folders'), findsNothing);
      expect(find.textContaining('RealtimeSubscribeException'), findsNothing);
      expect(find.text('Cloud folders unavailable'), findsOneWidget);
      expect(
        find.text('Sync timed out. Local databases are still available.'),
        findsOneWidget,
      );
      expect(
        find.text('Create one below, or import a PGN to get started.'),
        findsOneWidget,
      );
      expect(find.text('New folder'), findsOneWidget);
    },
  );
}

LocalChessSource _singleFileSource(String filePath) {
  return LocalChessSource(
    id: 'local',
    label: 'local.pgn',
    paths: <String>[filePath],
    rootPath: '/db',
    scannedAt: DateTime(2026),
    root: LocalChessFolderNode.fromChildren(
      name: 'local.pgn',
      path: 'local-file:abc123',
      relativePath: '',
      children: <LocalChessNode>[
        LocalChessFileNode(
          name: 'local.pgn',
          path: filePath,
          relativePath: 'local.pgn',
          extension: 'pgn',
          sizeBytes: 0,
          status: LocalChessFileStatus.parsed,
          games: <LocalChessGame>[],
        ),
      ],
    ),
  );
}
