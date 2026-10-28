import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/library_folder_create_guard.dart';
import 'package:chessever/repository/api_utils/api_exceptions.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId;

/// Regression coverage for `user_folders` node creation in a cloud folder.
///
/// The reported symptom was "I cannot create a database inside the folder" plus
/// the generic toast `Failed to create folder. Please try again.`. The server is
/// the authority for what a node may contain:
///
/// * `user_folders` carries `UNIQUE (user_id, name)` for the whole account;
/// * `ensure_parent_node_is_folder()` accepts children only under a `folder`
///   node and raises `23514` when the parent is still a `database` that holds
///   games (a legacy node whose `icon` is `folder_container` but whose
///   `node_type` is the column default).
///
/// The Desktop used to guess the kind from `icon` and had no way to report the
/// rejection, so these sources pin the classification, the create parent, the
/// duplicate-name pre-check and the rejection wording.
void main() {
  group('cloud node kind classification', () {
    test('uses node_type before any icon heuristic', () {
      // A legacy folder created by an old desktop build: it *looks* like a
      // folder, but the server still stores it as a database.
      final legacy = _folder(
        id: 'legacy',
        name: 'Students',
        icon: 'folder_container',
        nodeType: kLibraryNodeTypeDatabase,
      );
      expect(
        libraryFolderIsDatabase(legacy, <LibraryFolder>[legacy], gameCount: 3),
        isTrue,
        reason: 'node_type is authoritative for what may contain children',
      );

      final folder = _folder(
        id: 'students',
        name: 'Students',
        icon: 'folder_container',
        nodeType: kLibraryNodeTypeFolder,
      );
      expect(libraryFolderIsDatabase(folder, <LibraryFolder>[folder]), isFalse);
    });

    test('a mixed legacy database node with children stays navigable', () {
      // The container guard forbids creating this state, and the server's
      // repair promotes such a node to a folder — so the children must stay
      // reachable rather than becoming unreachable behind a database view.
      final parent = _folder(
        id: 'parent',
        name: 'Mehmet',
        icon: 'folder_container',
        nodeType: kLibraryNodeTypeDatabase,
      );
      final child = _folder(
        id: 'child',
        name: 'Sicilian',
        parentId: 'parent',
        icon: 'folder',
        nodeType: kLibraryNodeTypeDatabase,
      );
      expect(
        libraryFolderIsDatabase(parent, <LibraryFolder>[parent, child]),
        isFalse,
      );
    });

    test('a childless node the client typed as a database stays one', () {
      final database = _folder(
        id: 'mehmet',
        name: 'Mehmet',
        icon: 'database',
        nodeType: kLibraryNodeTypeDatabase,
      );
      expect(
        libraryFolderIsDatabase(database, <LibraryFolder>[database]),
        isTrue,
      );
    });

    test('an empty legacy container keeps the folder it was created as', () {
      // Builds up to 20.32.16 wrote the container icon but never `node_type`,
      // so the column default is the only thing calling this a database. It
      // holds no games, the server accepts a child under it and promotes the
      // row, and demoting it here would lock an empty folder out of the insert
      // that repairs it.
      final legacy = _folder(
        id: 'students',
        name: 'Students',
        icon: 'folder_container',
        nodeType: kLibraryNodeTypeDatabase,
      );
      expect(
        libraryFolderIsDatabase(legacy, <LibraryFolder>[legacy]),
        isFalse,
      );
      expect(
        libraryCurrentChildCreateParent('students', <LibraryFolder>[legacy])?.id,
        'students',
        reason: 'creation stays inside the folder the user is standing in',
      );

      // The same row once it is known to hold games is a database, and the
      // create guard must move the new node up to the top level.
      expect(
        libraryFolderIsDatabase(legacy, <LibraryFolder>[legacy], gameCount: 12),
        isTrue,
      );
    });

    test('falls back to the legacy heuristics when node_type is absent', () {
      // Synthetic/client-only rows (TWIC, fixtures) carry no node_type, so the
      // previous behaviour must be unchanged for them.
      final liked = _folder(
        id: 'liked',
        name: 'Liked games',
        icon: 'folder_container',
      );
      expect(libraryFolderIsDatabase(liked, <LibraryFolder>[liked]), isTrue);

      final root = _folder(id: 'root', name: 'Root');
      final child = _folder(
        id: 'child',
        name: 'Child database',
        parentId: 'root',
      );
      final folders = <LibraryFolder>[root, child];
      expect(libraryFolderIsDatabase(root, folders), isFalse);
      expect(libraryFolderIsDatabase(child, folders), isTrue);

      final legacyRoot = _folder(id: 'legacy', name: 'Legacy database');
      expect(
        libraryFolderIsDatabase(
          legacyRoot,
          <LibraryFolder>[legacyRoot],
          gameCount: 12,
        ),
        isTrue,
      );
    });

    test('normalizes node_type rows', () {
      expect(libraryNodeTypeFromRow('folder'), kLibraryNodeTypeFolder);
      expect(libraryNodeTypeFromRow(' DATABASE '), kLibraryNodeTypeDatabase);
      expect(libraryNodeTypeFromRow(null), isNull);
      expect(libraryNodeTypeFromRow('book'), isNull);
    });
  });

  group('child create target', () {
    test('creates inside the folder the user is standing in', () {
      final folders = <LibraryFolder>[
        _folder(
          id: 'students',
          name: 'Students',
          icon: 'folder_container',
          nodeType: kLibraryNodeTypeFolder,
        ),
      ];
      final target = libraryCurrentChildCreateParent('students', folders);
      expect(target?.id, 'students');
    });

    test('never creates inside a database node', () {
      final parent = _folder(
        id: 'sources',
        name: 'Sources',
        nodeType: kLibraryNodeTypeFolder,
      );
      // A database holds games only, so there is no legal place inside it for a
      // new folder: the create moves one level up instead of failing.
      final database = _folder(
        id: 'mehmet',
        name: 'Mehmet',
        parentId: 'sources',
        icon: 'database',
        nodeType: kLibraryNodeTypeDatabase,
      );
      final folders = <LibraryFolder>[parent, database];

      expect(libraryCurrentChildCreateParent('mehmet', folders)?.id, 'sources');
      expect(libraryCurrentChildCreateParent(null, folders), isNull);
      expect(libraryCurrentChildCreateParent('missing', folders), isNull);
    });

    test('a root-level database node falls back to the top level', () {
      final rootDatabase = _folder(
        id: 'root-db',
        name: 'My Database',
        icon: 'database',
        nodeType: kLibraryNodeTypeDatabase,
      );
      final folders = <LibraryFolder>[rootDatabase];
      expect(libraryCurrentChildCreateParent('root-db', folders), isNull);
    });

    test('resolves the parent through the shared target helper', () {
      final folder = _folder(
        id: 'students',
        name: 'Students',
        nodeType: kLibraryNodeTypeFolder,
      );
      final target = libraryChildCreateTarget(
        current: folder,
        folders: <LibraryFolder>[folder],
        currentIsDatabase: false,
      );
      expect(target.parent?.id, 'students');
      expect(target.retargetedFromDatabase, isFalse);

      final database = _folder(
        id: 'mehmet',
        name: 'Mehmet',
        nodeType: kLibraryNodeTypeDatabase,
      );
      final retargeted = libraryChildCreateTarget(
        current: database,
        folders: <LibraryFolder>[database],
        currentIsDatabase: true,
      );
      expect(retargeted.parent, isNull);
      expect(retargeted.retargetedFromDatabase, isTrue);
      expect(retargeted.parentName, 'Library Home');
    });
  });

  group('duplicate node names', () {
    test('matches the account-wide UNIQUE(user_id, name) constraint', () {
      final folders = <LibraryFolder>[
        _folder(
          id: 'students',
          name: 'Students',
          nodeType: kLibraryNodeTypeFolder,
        ),
        _folder(
          id: 'mehmet',
          name: 'Mehmet',
          parentId: 'students',
          nodeType: kLibraryNodeTypeDatabase,
        ),
        _folder(id: 'twic', name: 'ChessEver', icon: 'twic'),
      ];

      // Case-sensitive exactly like the constraint, and account-wide rather
      // than scoped to the folder being browsed.
      expect(libraryCloudNodeNamed('Mehmet', folders)?.id, 'mehmet');
      expect(libraryCloudNodeNamed('mehmet', folders), isNull);
      expect(libraryCloudNodeNamed(' Savio ', folders), isNull);
      expect(libraryCloudNodeNamed('', folders), isNull);
    });

    test('ignores followed books and the synthetic TWIC book', () {
      final folders = <LibraryFolder>[
        _folder(
          id: kTwicBookId,
          name: 'ChessEver',
          icon: 'twic',
        ),
        _folder(
          id: 'followed',
          name: 'Shared Book',
          isSubscribed: true,
        ),
      ];
      expect(libraryCloudNodeNamed('ChessEver', folders), isNull);
      expect(libraryCloudNodeNamed('Shared Book', folders), isNull);
    });
  });

  group('create rejection wording', () {
    test('names a duplicate name instead of a generic failure', () {
      final message = libraryCreateFolderRejectionMessage(
        _postgrest(
          code: '23505',
          message:
              'duplicate key value violates unique constraint "user_folders_user_id_name_key"',
        ),
        name: 'Mehmet',
      );
      expect(message, contains('Mehmet'));
      expect(message, contains('already have'));
    });

    test('explains the database-parent guard', () {
      final message = libraryCreateFolderRejectionMessage(
        _postgrest(
          code: '23514',
          message: 'Databases can only contain games; create child nodes under a folder',
        ),
        name: 'Savio',
        parentName: 'Mehmet',
      );
      expect(message, contains('Mehmet'));
      expect(message, contains('inside a folder'));
    });

    test('leaves unrelated failures to the generic path', () {
      expect(
        libraryCreateFolderRejectionMessage(
          _postgrest(code: '42P01', message: 'relation does not exist'),
          name: 'X',
        ),
        isNull,
      );
      expect(
        libraryCreateFolderRejectionMessage(
          StateError('offline'),
          name: 'X',
        ),
        isNull,
      );
    });
  });
  group('the save dialog reports the mapped duplicate rejection', () {
    test('translates the mapped 23505 into actionable copy', () {
      // `LibraryRepository.createFolder` runs through `handleApiCall`, which
      // maps 23505 to `GenericApiException('Duplicate entry')`; the save dialog
      // used to print that raw string ("Failed to create folder: Duplicate
      // entry") instead of a user-facing sentence.
      final message = libraryCreateFolderRejectionMessage(
        GenericApiException('Duplicate entry'),
        name: 'Aadvik Prep',
      );
      expect(message, contains('Aadvik Prep'));
      expect(message, contains('already have'));
      expect(message, isNot(contains('Duplicate entry')));
    });

    test('keeps the raw PostgrestException path working', () {
      expect(
        libraryCreateFolderRejectionMessage(
          _postgrest(code: '23505', message: 'duplicate key value'),
          name: 'Mehmet',
        ),
        libraryDuplicateCloudNodeMessage('Mehmet'),
      );
    });

    test('the shared duplicate copy trims the typed name', () {
      expect(
        libraryDuplicateCloudNodeMessage('  Savio  '),
        'You already have a library item named "Savio". '
        'Choose a different name.',
      );
    });
  });

}

PostgrestException _postgrest({required String code, required String message}) {
  return PostgrestException(message: message, code: code);
}

LibraryFolder _folder({
  required String id,
  required String name,
  String? parentId,
  String icon = 'folder',
  String? nodeType,
  bool isSubscribed = false,
  int orderIndex = 0,
}) {
  final now = DateTime(2026);
  return LibraryFolder(
    id: id,
    userId: 'user',
    name: name,
    color: '#0FB4E5',
    icon: icon,
    orderIndex: orderIndex,
    createdAt: now,
    updatedAt: now,
    parentId: parentId,
    nodeType: nodeType,
    isSubscribed: isSubscribed,
  );
}
