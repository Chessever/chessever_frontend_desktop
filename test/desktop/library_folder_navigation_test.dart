import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

void main() {
  group('Library folder navigation helpers', () {
    test('shows only direct children of the current folder', () {
      final folders = [
        _folder(id: 'root-a', name: 'Root A', orderIndex: 2),
        _folder(id: 'root-b', name: 'Root B', orderIndex: 1),
        _folder(id: 'child-a', name: 'Child A', parentId: 'root-a'),
        _folder(id: 'grandchild', name: 'Grandchild', parentId: 'child-a'),
      ];

      expect(
        libraryVisibleCloudFolders(
          folders: folders,
          parentId: null,
        ).map((folder) => folder.id),
        ['root-b', 'root-a'],
      );
      expect(
        libraryVisibleCloudFolders(
          folders: folders,
          parentId: 'root-a',
        ).map((folder) => folder.id),
        ['child-a'],
      );
      expect(
        libraryVisibleCloudFolders(
          folders: folders,
          parentId: 'child-a',
        ).map((folder) => folder.id),
        ['grandchild'],
      );
    });

    test('detects navigable folders and builds breadcrumb path', () {
      final folders = [
        _folder(id: 'chessbase', name: 'ChessBase'),
        _folder(id: 'openings', name: 'Openings', parentId: 'chessbase'),
        _folder(id: 'e4', name: '1.e4', parentId: 'openings'),
      ];

      expect(libraryFolderHasChildren(folders, 'chessbase'), isTrue);
      expect(libraryFolderHasChildren(folders, 'e4'), isFalse);
      expect(libraryFolderPath(folders, 'e4').map((folder) => folder.name), [
        'ChessBase',
        'Openings',
        '1.e4',
      ]);
    });

    test(
      'honors hidden ids without leaking grandchildren into parent folder',
      () {
        final folders = [
          _folder(id: 'parent', name: 'Parent'),
          _folder(id: 'hidden-child', name: 'Hidden', parentId: 'parent'),
          _folder(id: 'shown-child', name: 'Shown', parentId: 'parent'),
          _folder(
            id: 'grandchild',
            name: 'Grandchild',
            parentId: 'shown-child',
          ),
        ];

        expect(
          libraryVisibleCloudFolders(
            folders: folders,
            parentId: 'parent',
            hiddenIds: {'hidden-child'},
          ).map((folder) => folder.id),
          ['shown-child'],
        );
      },
    );
  });
}

LibraryFolder _folder({
  required String id,
  required String name,
  String? parentId,
  int orderIndex = 0,
}) {
  final now = DateTime(2026);
  return LibraryFolder(
    id: id,
    userId: 'user',
    name: name,
    color: '#0FB4E5',
    icon: 'folder',
    orderIndex: orderIndex,
    createdAt: now,
    updatedAt: now,
    parentId: parentId,
  );
}
