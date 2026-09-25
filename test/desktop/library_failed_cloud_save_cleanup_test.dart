import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/library_folder_create_guard.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

void main() {
  group('libraryFailedSaveEmptyCloudDatabaseIds', () {
    test('removes the destination databases a zero-row save created', () {
      // The reported failure: the destination database is created first, then
      // the very first batch is rejected as a whole (an impossible date), so
      // nothing was written and the empty node is what refused every retry.
      expect(
        libraryFailedSaveEmptyCloudDatabaseIds(
          createdNodeIds: const <String>['db-1'],
          savedRows: 0,
          localFilesWritten: 0,
        ),
        <String>['db-1'],
      );
      expect(
        libraryFailedSaveEmptyCloudDatabaseIds(
          createdNodeIds: const <String>['db-1', 'db-2'],
          savedRows: 0,
          localFilesWritten: 0,
        ),
        <String>['db-1', 'db-2'],
      );
    });

    test('never removes a database that already received rows', () {
      expect(
        libraryFailedSaveEmptyCloudDatabaseIds(
          createdNodeIds: const <String>['db-1'],
          savedRows: 1,
          localFilesWritten: 0,
        ),
        isEmpty,
      );
      // A save that landed rows in the cloud and then failed locally keeps
      // everything: deleting the database would throw the committed rows away.
      expect(
        libraryFailedSaveEmptyCloudDatabaseIds(
          createdNodeIds: const <String>['db-1'],
          savedRows: 250,
          localFilesWritten: 1,
        ),
        isEmpty,
      );
    });

    test('a local write also keeps the destination database', () {
      expect(
        libraryFailedSaveEmptyCloudDatabaseIds(
          createdNodeIds: const <String>['db-1'],
          savedRows: 0,
          localFilesWritten: 3,
        ),
        isEmpty,
      );
    });

    test('nothing created means nothing to remove', () {
      expect(
        libraryFailedSaveEmptyCloudDatabaseIds(
          createdNodeIds: const <String>[],
          savedRows: 0,
          localFilesWritten: 0,
        ),
        isEmpty,
        reason: 'a failure before any node was created must not delete '
            'anything',
      );
    });
  });

  group('librarySaveToleratesOwnCloudName', () {
    test('a node the save did not create is still a clash', () {
      final existing = _folder(id: 'pre-existing', name: 'MY Games');

      expect(
        librarySaveToleratesOwnCloudName(
          clash: existing,
          ownNodeIds: const <String>{'created'},
        ),
        isFalse,
      );
    });

    test('the dialog\u2019s own failed-save database is not a clash', () {
      final own = _folder(id: 'created', name: 'MY Games');

      expect(
        librarySaveToleratesOwnCloudName(
          clash: own,
          ownNodeIds: const <String>{'created'},
        ),
        isTrue,
        reason: 'a retry fills that database instead of creating a duplicate',
      );
      expect(
        librarySaveToleratesOwnCloudName(
          clash: own,
          ownNodeIds: const <String>{'created-and-removed'},
        ),
        isFalse,
        reason: 'only the ids the dialog really owns are tolerated',
      );
      expect(
        librarySaveToleratesOwnCloudName(
          clash: null,
          ownNodeIds: const <String>{'created'},
        ),
        isTrue,
      );
    });
  });

  group('failed cloud save cleanup wiring', () {
    final source = File(
      'lib/desktop/widgets/library/library_save_to_folder_dialog.dart',
    ).readAsStringSync();

    test('a zero-row failure removes the empty database before reporting', () {
      final save = _region(source, 'Future<void> _save(', 'String _progressLabel({');

      // The created node ids are remembered for the whole attempt, and the
      // repository is captured before the await-heavy write so the cleanup can
      // still run after the dialog was dismissed mid-save.
      expect(save, contains('final createdCloudDatabaseIds = <String>[];'));
      expect(
        save,
        contains('final repo = ref.read(libraryRepositoryProvider);'),
      );
      expect(save, contains('_removeEmptyCloudDatabasesFromFailedSave('));
      expect(save, contains('createdCloudDatabaseIds,'));
      expect(
        save.indexOf('_removeEmptyCloudDatabasesFromFailedSave('),
        lessThan(save.indexOf("'Save failed: \$detail\$keptNote'")),
        reason: 'cleanup happens before the failure is reported',
      );
      // A save that wrote rows or already committed stays untouched.
      expect(save, contains('libraryFailedSaveEmptyCloudDatabaseIds('));
    });

    test('the cleanup deletes only this attempt\u2019s nodes', () {
      final cleanup = _region(
        source,
        'Future<List<String>> _removeEmptyCloudDatabasesFromFailedSave(',
        '/// Writes one batch of games',
      );

      expect(cleanup, contains('libraryFailedSaveEmptyCloudDatabaseIds('));
      expect(cleanup, contains('await repo.deleteFolder(id);'));
      expect(cleanup, contains('_removedCloudNodeIds.add(id);'));
      expect(cleanup, contains('_pendingCloudDatabases.removeAt(index);'));
      expect(
        cleanup,
        contains('if (removedAny && mounted)'),
        reason: 'the folder list is refreshed only when something was removed',
      );
    });

    test('the create loop tracks the destination for a retry', () {
      final create = _region(
        source,
        'final createdFolderIds = <String>[];',
        'await for (final batch in _gameBatches(effectiveGames))',
      );

      expect(create, contains('_pendingCloudDatabaseFor(parentKey, newName)'));
      expect(create, contains('createdFolderIds.add(pending.id);'));
      expect(create, contains('_pendingCloudDatabases.add('));
      expect(create, contains('createdCloudDatabaseIds.add(created.id);'));
      expect(create, contains('_createdCloudNodeIds.add(created.id);'));
    });

    test('a retry is not refused by the name guard for its own node', () {
      final guard = _region(
        source,
        'if (nameCtrl != null) {',
        'final parents = libraryNewDatabaseParents(',
      );

      expect(guard, contains('librarySaveToleratesOwnCloudName('));
      expect(
        guard,
        contains('clash: libraryCloudNodeNamed(newName, allFolders)'),
      );
      expect(guard, contains('ownNodeIds: _ownCloudNodeIds'));
      expect(
        guard,
        contains('libraryDuplicateCloudNodeMessage(newName)'),
        reason: 'a genuinely pre-existing clash keeps its exact wording',
      );
      // The tolerated ids are the ones this dialog created or removed.
      expect(source, contains('Set<String> get _ownCloudNodeIds'));
      expect(source, contains('..._createdCloudNodeIds,'));
      expect(source, contains('..._removedCloudNodeIds,'));
      expect(source, contains('for (final pending in _pendingCloudDatabases)'));
    });

    test('the failure toast explains a database it could not remove', () {
      final save = _region(source, 'Future<void> _save(', 'String _progressLabel({');

      expect(save, contains('final keptNames ='));
      expect(save, contains('keptNote'));
      expect(
        save,
        contains('The empty database '),
        reason: 'the user must be told what was left behind',
      );
      expect(
        save,
        contains('could not be removed and will be reused by the next save.'),
        reason: 'the user must know the retry reuses what was left behind',
      );
    });
  });
}

/// Source slice between two markers, failing loudly when a marker is gone.
String _region(String source, String start, String end) {
  final from = source.indexOf(start);
  final to = source.indexOf(end);
  expect(from, isNonNegative, reason: 'missing marker: $start');
  expect(to, greaterThan(from), reason: 'missing marker after: $end');
  return source.substring(from, to);
}

LibraryFolder _folder({required String id, required String name}) {
  return LibraryFolder(
    id: id,
    userId: 'user',
    name: name,
    color: '#0FB4E5',
    icon: 'database',
    orderIndex: 0,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    nodeType: kLibraryNodeTypeDatabase,
  );
}
