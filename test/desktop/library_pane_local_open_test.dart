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
    final source = LocalChessSource(
      id: 'local',
      label: 'local.pgn',
      paths: const <String>[filePath],
      rootPath: '/db',
      scannedAt: DateTime(2026),
      root: LocalChessFolderNode.fromChildren(
        name: 'local.pgn',
        path: 'local-file:abc123',
        relativePath: '',
        children: const <LocalChessNode>[
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

    expect(localDatabaseWorkspacePath(source, source.root.path), filePath);
  });
}
