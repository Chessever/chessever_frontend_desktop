import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/widgets/library/local_chess_files_rail.dart';

void main() {
  test(
    'registered local folders remain visible before a source is scanned',
    () {
      final entries = [
        LocalLibraryEntry(
          path: '/Users/vasif/chess/db',
          addedAt: DateTime(2026),
        ),
      ];

      expect(
        showRegisteredLocalEntriesForRail(source: null, entries: entries),
        isTrue,
      );
    },
  );

  test('registered folders do not replace the active scanned local tree', () {
    final entries = [
      LocalLibraryEntry(path: '/Users/vasif/chess/db', addedAt: DateTime(2026)),
    ];

    expect(
      showRegisteredLocalEntriesForRail(
        source: _fakeLocalChessSource(),
        entries: entries,
      ),
      isFalse,
    );
  });

  test('empty registry keeps the open-folder hint visible', () {
    expect(
      showRegisteredLocalEntriesForRail(
        source: null,
        entries: const <LocalLibraryEntry>[],
      ),
      isFalse,
    );
  });
}

LocalChessSource _fakeLocalChessSource() {
  return LocalChessSource(
    id: 'fake',
    label: 'Fake',
    paths: const ['/tmp/fake'],
    rootPath: '/tmp/fake',
    scannedAt: DateTime(2026),
    root: const LocalChessFolderNode(
      name: 'fake',
      path: '/tmp/fake',
      relativePath: '',
      children: <LocalChessNode>[],
      gameCount: 0,
      fileCount: 0,
      unsupportedCount: 0,
    ),
  );
}
