import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/services/library_save_destination_recency.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

void main() {
  group('save destination ordering', () {
    test(
      'promotes recent cloud destinations without mixing the cloud group',
      () {
        final folders = <LibraryFolder>[
          _folder(id: 'cloud-a', orderIndex: 0),
          _folder(id: 'cloud-b', orderIndex: 1),
          _folder(id: 'cloud-c', orderIndex: 2),
        ];

        final ordered = orderLibrarySaveCloudFolders(
          folders: folders,
          recentFolderIds: const <String>['cloud-b', 'cloud-a'],
        );

        expect(ordered.map((folder) => folder.id), <String>[
          'cloud-b',
          'cloud-a',
          'cloud-c',
        ]);
      },
    );

    test(
      'keeps cloud hierarchy while promoting the recent database branch',
      () {
        final folders = <LibraryFolder>[
          _folder(id: 'other', orderIndex: 0),
          _folder(id: 'parent', orderIndex: 1),
          _folder(id: 'child-a', parentId: 'parent', orderIndex: 0),
          _folder(id: 'child-b', parentId: 'parent', orderIndex: 1),
        ];

        final ordered = orderLibrarySaveCloudFolders(
          folders: folders,
          recentFolderIds: const <String>['child-b'],
        );

        expect(ordered.map((folder) => folder.id), <String>[
          'parent',
          'child-b',
          'child-a',
          'other',
        ]);
      },
    );

    test('promotes recent local destinations only within the local list', () {
      final ordered = orderLibrarySaveDestinationsByRecent<String>(
        values: const <String>['local-a', 'local-b', 'local-c'],
        recentKeys: const <String>['local-c', 'local-a'],
        keyOf: (path) => path,
      );

      expect(ordered, const <String>['local-c', 'local-a', 'local-b']);
    });

    test('ignores stale recent keys and preserves the remaining order', () {
      final ordered = orderLibrarySaveDestinationsByRecent<String>(
        values: const <String>['a', 'b', 'c'],
        recentKeys: const <String>['gone', 'b'],
        keyOf: (value) => value,
      );

      expect(ordered, const <String>['b', 'a', 'c']);
    });
  });

  test(
    'successful saves persist independent cloud and local recency',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      const store = LibrarySaveDestinationRecencyStore();

      await store.recordSuccessfulSave(
        cloudFolderIds: const <String>['cloud-a'],
        localPathKeys: const <String>['local-a'],
      );
      await store.recordSuccessfulSave(
        cloudFolderIds: const <String>['cloud-b'],
        localPathKeys: const <String>[],
      );
      await store.recordSuccessfulSave(
        cloudFolderIds: const <String>[],
        localPathKeys: const <String>['local-b'],
      );

      final restored = await const LibrarySaveDestinationRecencyStore().load();
      expect(restored.cloudFolderIds, const <String>['cloud-b', 'cloud-a']);
      expect(restored.localPathKeys, const <String>['local-b', 'local-a']);
    },
  );
}

LibraryFolder _folder({
  required String id,
  required int orderIndex,
  String? parentId,
}) {
  return LibraryFolder(
    id: id,
    userId: 'user',
    name: id,
    color: '#0FB4E5',
    icon: 'database',
    orderIndex: orderIndex,
    parentId: parentId,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}
