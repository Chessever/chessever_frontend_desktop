import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

void main() {
  group('Library folder navigation helpers', () {
    test('database catalog filtering is case-insensitive and source-aware', () {
      expect(
        libraryDatabaseCatalogMatches(
          title: 'ChessEver Master Database',
          details: '7.0M games',
          source: LibraryDatabaseCatalogSource.cloud,
          filter: LibraryDatabaseCatalogSourceFilter.all,
          query: 'master',
        ),
        isTrue,
      );
      expect(
        libraryDatabaseCatalogMatches(
          title: 'Students',
          details: '4 databases · 82 games',
          source: LibraryDatabaseCatalogSource.local,
          filter: LibraryDatabaseCatalogSourceFilter.cloud,
          query: '',
        ),
        isFalse,
      );
      expect(
        libraryDatabaseCatalogMatches(
          title: 'Sicilian preparation',
          details: '1,240 games',
          source: LibraryDatabaseCatalogSource.local,
          filter: LibraryDatabaseCatalogSourceFilter.local,
          query: '1,240',
        ),
        isTrue,
      );
    });

    test('database catalog progressively hides low-priority columns', () {
      final wide = libraryDatabaseCatalogColumns(980);
      expect(wide.showSource, isTrue);
      expect(wide.showLastOpened, isTrue);

      final medium = libraryDatabaseCatalogColumns(680);
      expect(medium.showSource, isTrue);
      expect(medium.showLastOpened, isFalse);

      final narrow = libraryDatabaseCatalogColumns(520);
      expect(narrow.showSource, isFalse);
      expect(narrow.showLastOpened, isFalse);

      final resized = libraryDatabaseCatalogColumns(
        980,
        savedWidths: const {'name': 240, 'games': 90},
      );
      expect(resized.nameWidth, 240);
      expect(resized.gamesWidth, 90);
    });

    test('catalog drag target supports moving to either end', () {
      expect(
        libraryCatalogReorderedKeys(
          const <String>['a', 'b', 'c'],
          draggedKey: 'a',
          targetKey: 'c',
        ),
        <String>['b', 'c', 'a'],
      );
      expect(
        libraryCatalogReorderedKeys(
          const <String>['a', 'b', 'c'],
          draggedKey: 'c',
          targetKey: 'a',
        ),
        <String>['c', 'a', 'b'],
      );
    });

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
      expect(
        libraryMyDatabasesBreadcrumbText(
          folders: folders,
          currentFolderId: 'e4',
        ),
        'Library Home › ChessBase › Openings › 1.e4',
      );
      expect(
        libraryMyDatabasesBreadcrumbText(
          folders: folders,
          currentFolderId: 'e4',
          localGroupLabel: 'Player sources',
        ),
        'Library Home › Player sources',
      );
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

    test('root catalog also exposes pinned descendant databases', () {
      final folders = [
        _folder(id: 'parent', name: 'Parent'),
        _folder(id: 'database', name: 'Database', parentId: 'parent'),
      ];

      expect(
        libraryVisibleCloudFolders(
          folders: folders,
          parentId: null,
          pinnedIds: const <String>{'database'},
        ).map((folder) => folder.id),
        containsAll(<String>['parent', 'database']),
      );
    });

    test('treats legacy liked games as a database, not a folder', () {
      final folders = [
        _folder(id: 'liked', name: 'Liked games', icon: 'folder_container'),
      ];

      expect(libraryFolderIsDatabase(folders.first, folders), isTrue);
    });

    test('identifies permanent built-in library folders by name', () {
      final liked = _folder(id: 'liked', name: 'Liked Games');
      expect(liked.isPermanentLibraryFolder, isTrue);
      expect(libraryCanRemoveCloudFolderFromBoard(liked), isFalse);
      expect(
        libraryCanRemoveCloudFolderFromBoard(
          _folder(id: 'prep', name: 'Opening Prep'),
        ),
        isTrue,
      );
      expect(isPermanentLibraryFolderName(' my database '), isTrue);
      expect(isPermanentLibraryFolderName('MY FOLDER'), isTrue);
      expect(isPermanentLibraryFolderName('Opening Prep'), isFalse);
    });

    test('keeps root folder containers as folders when they have children', () {
      final folders = [
        _folder(id: 'root', name: 'Root'),
        _folder(id: 'child', name: 'Child database', parentId: 'root'),
      ];

      expect(libraryFolderIsDatabase(folders.first, folders), isFalse);
      expect(libraryFolderIsDatabase(folders.last, folders), isTrue);
    });

    test('uses saved game count to identify legacy root databases', () {
      final folders = [_folder(id: 'legacy', name: 'Legacy database')];

      expect(
        libraryFolderIsDatabase(folders.first, folders, gameCount: 12),
        isTrue,
      );
      expect(libraryFolderIsDatabase(folders.first, folders), isFalse);
    });

    test('formats local database count and installed date', () {
      final entry = LocalLibraryEntry(
        path: '/tmp/classical.pgn',
        addedAt: DateTime(2026, 7, 7),
        gameCount: 12,
      );

      expect(localLibraryEntryStatusLine(entry), '12 games - 2026-07-07');
      expect(
        localLibraryEntryStatusLine(entry, count: 1),
        '1 game - 2026-07-07',
      );
    });

    test('formats old local database entries without count metadata', () {
      final entry = LocalLibraryEntry(
        path: '/tmp/legacy.pgn',
        addedAt: DateTime(2026, 7, 7),
      );

      expect(localLibraryEntryStatusLine(entry), 'Not indexed - 2026-07-07');
    });

    test('keeps local database registry metadata backward compatible', () {
      final legacy = LocalLibraryEntry.fromJson({
        'path': '/tmp/legacy.pgn',
        'addedAt': '2026-07-07T00:00:00.000',
      });
      expect(legacy.gameCount, isNull);
      expect(legacy.indexedAt, isNull);
      expect(legacy.playerWorkspaceSource, isNull);

      final indexedAt = DateTime(2026, 7, 7, 12, 30);
      final entry = LocalLibraryEntry(
        path: '/tmp/current.pgn',
        addedAt: DateTime(2026, 7, 6),
        gameCount: 42,
        indexedAt: indexedAt,
        playerWorkspaceSource: 'combined',
      );
      final roundTrip = LocalLibraryEntry.fromJson(entry.toJson());

      expect(roundTrip.path, entry.path);
      expect(roundTrip.addedAt, entry.addedAt);
      expect(roundTrip.gameCount, 42);
      expect(roundTrip.indexedAt, indexedAt);
      expect(roundTrip.playerWorkspaceSource, 'combined');
    });

    test('identifies Players local database entries and groups', () {
      final now = DateTime(2026, 7, 8);
      final explicit = LocalLibraryEntry(
        path: p.join('tmp', 'gm-vasif-durarbayli', 'chesscom.pgn'),
        addedAt: now,
        groupId: '${playerWorkspaceLocalLibraryGroupPrefix}player-1',
        groupLabel: 'GM Vasif Durarbayli',
      );
      final legacyPath = p.join(
        'tmp',
        'player-workspace',
        'player-2',
        'lichess.pgn',
      );
      final legacy = LocalLibraryEntry.fromJson({
        'path': legacyPath,
        'addedAt': now.toIso8601String(),
      });
      final normal = LocalLibraryEntry(
        path: p.join('tmp', 'opening-prep', 'repertoire.pgn'),
        addedAt: now,
        groupId: 'prep-folder',
      );

      expect(localLibraryEntryBelongsToPlayerWorkspace(explicit), isTrue);
      expect(localLibraryEntryBelongsToPlayerWorkspace(legacy), isTrue);
      expect(localLibraryEntryBelongsToPlayerWorkspace(normal), isFalse);
      expect(localLibraryPathBelongsToPlayerWorkspace(legacyPath), isTrue);
      expect(
        localLibraryPathBelongsToPlayerWorkspace(
          p.join('tmp', 'player-workspace'),
        ),
        isFalse,
      );
      expect(
        localLibraryGroupBelongsToPlayerWorkspace(
          groupId: explicit.groupId!,
          entries: [explicit],
        ),
        isTrue,
      );
      expect(
        localLibraryGroupBelongsToPlayerWorkspace(
          groupId: normal.groupId!,
          entries: [normal],
        ),
        isFalse,
      );
    });

    test('orders Combined first inside a Players Library folder', () {
      final now = DateTime(2026, 7, 10);
      final entries = <LocalLibraryEntry>[
        LocalLibraryEntry(
          path: '/tmp/CHESS.COM_13402935_CHESSEVER_DURARBAYLI.pgn',
          addedAt: now,
        ),
        LocalLibraryEntry(
          path: '/tmp/CHESSEVER_13402935_CHESSEVER_VASIF_DURARBAYLI.pgn',
          addedAt: now,
        ),
        LocalLibraryEntry(
          path: '/tmp/vasif-all-games.pgn',
          addedAt: now,
          playerWorkspaceSource: playerWorkspaceCombinedSourceKey,
        ),
        LocalLibraryEntry(
          path: '/tmp/LICHESS_13402935_CHESSEVER_DURARBAYLI.pgn',
          addedAt: now,
        ),
      ]..sort(comparePlayerWorkspaceLibraryEntries);

      expect(entries.map((entry) => p.basename(entry.path)), <String>[
        'vasif-all-games.pgn',
        'CHESS.COM_13402935_CHESSEVER_DURARBAYLI.pgn',
        'CHESSEVER_13402935_CHESSEVER_VASIF_DURARBAYLI.pgn',
        'LICHESS_13402935_CHESSEVER_DURARBAYLI.pgn',
      ]);

      final legacyCombined = LocalLibraryEntry(
        path: '/tmp/COMBINED_13402935_CHESSEVER.pgn',
        addedAt: now,
      );
      expect(
        localLibraryEntryIsPlayerWorkspaceCombined(legacyCombined),
        isTrue,
      );
      final legacyEntries = <LocalLibraryEntry>[entries[1], legacyCombined]
        ..sort(comparePlayerWorkspaceLibraryEntries);
      expect(legacyEntries.first, legacyCombined);
    });
  });
}

LibraryFolder _folder({
  required String id,
  required String name,
  String? parentId,
  String icon = 'folder',
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
  );
}
