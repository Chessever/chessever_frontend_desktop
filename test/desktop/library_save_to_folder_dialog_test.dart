import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/library_folder_create_guard.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/local_library_writer.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

void main() {
  group('library save dialog copy', () {
    test('labels saved payloads as entries for games and positions', () {
      expect(librarySaveEntryLabel(1), 'entry');
      expect(librarySaveEntryLabel(2), 'entries');
      expect(librarySaveEntryLabel(0), 'entries');
    });

    test('reports update-original outcome as a save', () {
      const outcome = LibrarySaveOutcome(
        savedRows: 0,
        folderCount: 0,
        didUpdateOriginal: true,
      );

      expect(outcome.didSave, isTrue);
      expect(outcome.toToastMessage(), 'Updated existing game');
    });

    test('keeps update identity after one game is saved to one local PGN', () {
      const target = LocalLibraryGameUpdateTarget(
        sourcePath: r'C:\Games\prep.pgn',
        indexInFile: 3,
        fileGameCount: 4,
      );
      const writeOutcome = LocalLibraryWriteOutcome(
        folderPath: r'C:\Games\prep.pgn',
        writtenPaths: <String>[r'C:\Games\prep.pgn'],
        skipped: 0,
        updateTargets: <LocalLibraryGameUpdateTarget>[target],
      );

      expect(
        libraryLocalUpdateTargetForCompletedSave(
          gameCount: 1,
          selectedCloudFolderCount: 0,
          selectedLocalPathCount: 1,
          outcomes: const <LocalLibraryWriteOutcome>[writeOutcome],
        ),
        same(target),
      );
    });
  });

  group('destination mode', () {
    test('dialog titles match destination scope', () {
      expect(
        librarySaveDialogTitle(LibrarySaveDestinationMode.cloudOnly),
        'Save database to cloud',
      );
      expect(
        librarySaveDialogTitle(LibrarySaveDestinationMode.cloudAndLocal),
        'Save to library',
      );
      expect(
        librarySaveDialogTitle(LibrarySaveDestinationMode.localOnly),
        'Save to this computer',
      );
    });

    test(
      'cloud-only mode hides local destinations but keeps cloud folders',
      () {
        final folders = [
          _folder(id: 'my-database', name: 'My Database'),
          _folder(id: 'shared', name: 'Shared', isSubscribed: true),
        ];

        expect(
          librarySaveAllowsCloudDestinations(
            LibrarySaveDestinationMode.cloudOnly,
          ),
          isTrue,
        );
        expect(
          librarySaveAllowsLocalDestinations(
            LibrarySaveDestinationMode.cloudOnly,
          ),
          isFalse,
        );
        expect(
          librarySaveWritableCloudFolders(
            folders: folders,
            destinationMode: LibrarySaveDestinationMode.cloudOnly,
          ).map((folder) => folder.id),
          ['my-database'],
        );
      },
    );

    test('local-only mode hides every cloud folder', () {
      final folders = [
        _folder(id: 'my-database', name: 'My Database'),
        _folder(id: 'shared', name: 'Shared', isSubscribed: true),
      ];

      expect(
        librarySaveWritableCloudFolders(
          folders: folders,
          destinationMode: LibrarySaveDestinationMode.localOnly,
        ),
        isEmpty,
      );
    });

    test('cloud-and-local mode keeps writable cloud folders only', () {
      final folders = [
        _folder(id: 'my-database', name: 'My Database'),
        _folder(id: 'shared', name: 'Shared', isSubscribed: true),
      ];

      expect(
        librarySaveWritableCloudFolders(
          folders: folders,
          destinationMode: LibrarySaveDestinationMode.cloudAndLocal,
        ).map((folder) => folder.id),
        ['my-database'],
      );
    });
  });

  group('libraryGameDetailInputValue', () {
    test('hides PGN unknown placeholders from first-save inputs', () {
      expect(libraryGameDetailInputValue(null), '');
      expect(libraryGameDetailInputValue(''), '');
      expect(libraryGameDetailInputValue(' ? '), '');
      expect(libraryGameDetailInputValue('????'), '');
      expect(libraryGameDetailInputValue('??'), '');
    });

    test('keeps meaningful metadata text', () {
      expect(libraryGameDetailInputValue('Norway Chess'), 'Norway Chess');
      expect(libraryGameDetailInputValue('C45'), 'C45');
      expect(libraryGameDetailInputValue('1.2'), '1.2');
    });
  });

  group('splitPlayerName', () {
    test('splits surname-first PGN names on the comma', () {
      final parts = splitPlayerName('Kasparov, Garry');
      expect(parts.surname, 'Kasparov');
      expect(parts.firstName, 'Garry');
    });

    test('treats single-token names as surname only', () {
      final parts = splitPlayerName('Magnus');
      expect(parts.surname, 'Magnus');
      expect(parts.firstName, '');
    });

    test('coerces empty and placeholder values to empty parts', () {
      expect(splitPlayerName(null).surname, '');
      expect(splitPlayerName(null).firstName, '');
      expect(splitPlayerName('').surname, '');
      expect(splitPlayerName('?').surname, '');
    });
  });

  group('joinPlayerName', () {
    test('combines surname and first name with a comma', () {
      expect(joinPlayerName('Carlsen', 'Magnus'), 'Carlsen, Magnus');
    });

    test('returns a single component when the other is empty', () {
      expect(joinPlayerName('Carlsen', ''), 'Carlsen');
      expect(joinPlayerName('', 'Magnus'), 'Magnus');
    });

    test('falls back to "?" when both halves are blank', () {
      expect(joinPlayerName('', ''), '?');
      expect(joinPlayerName('   ', '\t'), '?');
    });
  });

  group('buildPgnDate', () {
    test('returns fully-unknown date when year is blank', () {
      expect(buildPgnDate(year: '', month: '5', day: '12'), '????.??.??');
    });

    test('pads month and day to two digits', () {
      expect(buildPgnDate(year: '2026', month: '5', day: '7'), '2026.05.07');
    });

    test('substitutes ?? for missing month or day', () {
      expect(buildPgnDate(year: '2026', month: '', day: ''), '2026.??.??');
      expect(buildPgnDate(year: '2026', month: '11', day: ''), '2026.11.??');
    });
  });

  group('buildEditedMetadata', () {
    test('overwrites editable PGN headers while preserving unrelated keys', () {
      final original = <String, dynamic>{
        'White': 'Old, Player',
        'Black': 'Other, Player',
        'Event': 'Old Event',
        'ECO': 'A00',
        'Result': '*',
        'WhiteElo': '2000',
        'BlackElo': '2100',
        'Round': '1',
        'Subround': '',
        'Date': '2020.01.01',
        'isLiveGame': false,
        'TimeControl': '90+30',
      };

      final merged = buildEditedMetadata(
        original: original,
        whiteSurname: 'Carlsen',
        whiteFirstName: 'Magnus',
        blackSurname: 'Caruana',
        blackFirstName: 'Fabiano',
        event: 'Norway Chess',
        eco: 'C50',
        whiteElo: '2839',
        blackElo: '2805',
        round: '7',
        subround: '1',
        result: '1-0',
        year: '2026',
        month: '5',
        day: '24',
      );

      expect(merged['White'], 'Carlsen, Magnus');
      expect(merged['Black'], 'Caruana, Fabiano');
      expect(merged['Event'], 'Norway Chess');
      expect(merged['ECO'], 'C50');
      expect(merged['WhiteElo'], '2839');
      expect(merged['BlackElo'], '2805');
      expect(merged['Round'], '7');
      expect(merged['Subround'], '1');
      expect(merged['Result'], '1-0');
      expect(merged['Date'], '2026.05.24');
      // Headers outside the editor's scope must stay intact.
      expect(merged['isLiveGame'], false);
      expect(merged['TimeControl'], '90+30');
    });

    test('clamps unsupported result codes back to "*"', () {
      final merged = buildEditedMetadata(
        original: const {},
        whiteSurname: 'A',
        whiteFirstName: '',
        blackSurname: 'B',
        blackFirstName: '',
        event: 'E',
        eco: '',
        whiteElo: '',
        blackElo: '',
        round: '1',
        subround: '',
        result: 'banana',
        year: '',
        month: '',
        day: '',
      );
      expect(merged['Result'], '*');
    });

    test(
      'substitutes "?" for empty White/Black/Event/Round so PGN stays valid',
      () {
        final merged = buildEditedMetadata(
          original: const {},
          whiteSurname: '',
          whiteFirstName: '',
          blackSurname: '',
          blackFirstName: '',
          event: '',
          eco: '',
          whiteElo: '',
          blackElo: '',
          round: '',
          subround: '',
          result: '*',
          year: '',
          month: '',
          day: '',
        );
        expect(merged['White'], '?');
        expect(merged['Black'], '?');
        expect(merged['Event'], '?');
        expect(merged['Round'], '?');
        expect(merged['Date'], '????.??.??');
      },
    );
  });
  group('saving a local database as a new cloud database', () {
    test('offers containers only, never an existing database', () {
      final folders = <LibraryFolder>[
        _folder(
          id: 'my-database',
          name: 'My Database',
          icon: 'folder_container',
          nodeType: kLibraryNodeTypeFolder,
        ),
        _folder(
          id: 'my-subdatabase',
          name: 'My Subdatabase',
          icon: 'database',
          parentId: 'my-database',
          nodeType: kLibraryNodeTypeDatabase,
        ),
      ];

      // Saving a whole local database creates a database inside the chosen
      // folder, so an existing database must not be offered as a destination:
      // selecting it used to dump every entry into that unrelated database.
      expect(
        librarySaveWritableCloudFolders(
          folders: folders,
          destinationMode: LibrarySaveDestinationMode.cloudOnly,
          foldersOnly: true,
        ).map((folder) => folder.id),
        ['my-database'],
      );
      // Every other flow keeps both kinds as destinations.
      expect(
        librarySaveWritableCloudFolders(
          folders: folders,
          destinationMode: LibrarySaveDestinationMode.cloudOnly,
        ).map((folder) => folder.id),
        ['my-database', 'my-subdatabase'],
      );
    });

    test('creates the database in the folder the user picked', () {
      final folders = <LibraryFolder>[
        _folder(
          id: 'my-database',
          name: 'My Database',
          icon: 'folder_container',
          nodeType: kLibraryNodeTypeFolder,
        ),
      ];

      expect(
        libraryNewDatabaseParents(
          selected: folders,
          allFolders: folders,
        ).map((parent) => parent?.id),
        ['my-database'],
      );
    });

    test('retargets a database destination to its folder exactly once', () {
      final folder = _folder(
        id: 'my-database',
        name: 'My Database',
        icon: 'folder_container',
        nodeType: kLibraryNodeTypeFolder,
      );
      final subdatabase = _folder(
        id: 'my-subdatabase',
        name: 'My Subdatabase',
        icon: 'database',
        parentId: 'my-database',
        nodeType: kLibraryNodeTypeDatabase,
      );

      // Selecting the folder and its own database resolves to one parent, so a
      // single database is created and no duplicate name is ever attempted.
      expect(
        libraryNewDatabaseParents(
          selected: <LibraryFolder>[folder, subdatabase],
          allFolders: <LibraryFolder>[folder, subdatabase],
        ).map((parent) => parent?.id),
        ['my-database'],
      );
    });

    test('a legacy folder node stays its own destination', () {
      final legacy = _folder(
        id: 'students',
        name: 'Students',
        icon: 'folder_container',
        nodeType: kLibraryNodeTypeDatabase,
      );

      expect(
        libraryNewDatabaseParents(
          selected: <LibraryFolder>[legacy],
          allFolders: <LibraryFolder>[legacy],
        ).map((parent) => parent?.id),
        ['students'],
      );
    });

    test('a nested folder is used as the create parent itself', () {
      final root = _folder(
        id: 'root',
        name: 'My Database',
        icon: 'folder_container',
        nodeType: kLibraryNodeTypeFolder,
      );
      final nested = _folder(
        id: 'nested',
        name: 'Prep',
        icon: 'folder_container',
        parentId: 'root',
        nodeType: kLibraryNodeTypeFolder,
      );

      expect(
        libraryNewDatabaseParents(
          selected: <LibraryFolder>[nested],
          allFolders: <LibraryFolder>[root, nested],
        ).map((parent) => parent?.id),
        ['nested'],
      );
    });

    test('names the created database in the save toast', () {
      const outcome = LibrarySaveOutcome(
        savedRows: 16,
        folderCount: 1,
        newDatabaseNames: <String>['Aadvik Prep'],
      );
      expect(
        outcome.toToastMessage(),
        'Saved 16 entries to new database "Aadvik Prep"',
      );

      // Every other flow keeps the original wording.
      const plain = LibrarySaveOutcome(savedRows: 16, folderCount: 1);
      expect(plain.toToastMessage(), 'Saved 16 entries to the cloud library');
      expect(plain.didSave, isTrue);
    });
  });

  group('whole-database save counts', () {
    test('targets every game of the database, not the loaded page', () {
      // 1 436 games into one new cloud database. The reported bug handed the
      // dialog the loaded page (200 rows), so its progress and quota described
      // 200; the whole-database save must describe all 1 436.
      expect(
        librarySaveEntryTarget(gameCount: 1436, destinationCount: 1),
        1436,
      );
      expect(
        librarySaveEntryTarget(gameCount: 200, destinationCount: 1),
        200,
        reason: 'one loaded page is what the old save offered',
      );
      expect(librarySaveEntryTarget(gameCount: 1436, destinationCount: 2), 2872);
      expect(librarySaveEntryTarget(gameCount: 1436, destinationCount: 0), 0);
      expect(librarySaveEntryTarget(gameCount: 0, destinationCount: 1), 0);
    });

    test('reads a paged source total instead of the empty games list', () {
      // A whole-database save passes `gameSource` and an empty `games` list.
      // Reading the list would say "nothing to save" and skip the dialog.
      expect(
        librarySaveDialogGameCount(materializedCount: 0, sourceTotal: 1436),
        1436,
      );
      expect(
        librarySaveDialogGameCount(materializedCount: 1436, sourceTotal: null),
        1436,
        reason: 'every existing flow keeps counting its materialized list',
      );
      expect(librarySaveDialogGameCount(materializedCount: 3, sourceTotal: null), 3);
    });
  });

  group('local database cloud names', () {
    test('derives the cloud database name from the file name', () {
      expect(
        localChessDatabaseStemForPath(r'C:\Prep\Aadvik Prep.pgn'),
        'Aadvik Prep',
      );
      expect(localChessDatabaseStemForLabel('Aadvik Prep.pgn'), 'Aadvik Prep');
      expect(localChessDatabaseStemForLabel('NoExtension'), 'NoExtension');
      expect(localChessDatabaseStemForLabel(''), '');
      expect(localChessDatabaseStemForLabel('.pgn'), '.pgn');
    });
  });

  group('new cloud database name hint', () {
    test('flags a name the account already had before Save', () {
      final existing = _folder(id: 'existing', name: 'Aadvik Prep');

      // The pre-save guard reads the same account-wide list, so a real clash
      // is still refused with exactly the wording the user knows.
      expect(libraryCloudNodeNamed('Aadvik Prep', [existing])?.id, 'existing');
      expect(
        libraryNewCloudDatabaseNameConflict('Aadvik Prep', [existing])?.id,
        'existing',
      );
      expect(
        libraryDuplicateCloudNodeMessage('Aadvik Prep'),
        'You already have a library item named "Aadvik Prep". '
        'Choose a different name.',
      );
    });

    test('never flags the database this save created itself', () {
      // A local-database save inserts its destination database before the
      // first game row, so the folders realtime stream publishes it while the
      // rows are still streaming. Matching the typed name against a list that
      // now contains that node printed the red "You already have a library
      // item named ..." text under a save that was succeeding.
      const name = 'CHESSEVER_4264312_CHESSEVER_STAVROULA_TSOLAKIDOU';
      final folders = <LibraryFolder>[
        _folder(
          id: 'parent',
          name: 'Prep',
          icon: 'folder_container',
          nodeType: kLibraryNodeTypeFolder,
        ),
        _folder(id: 'created', name: name),
      ];

      expect(
        libraryNewCloudDatabaseNameConflict(
          name,
          folders,
          createdIds: const <String>['created'],
        ),
        isNull,
      );
      expect(
        libraryNewCloudDatabaseNameConflict(
          name,
          folders,
          createdNames: const <String>[name],
        ),
        isNull,
        reason: 'the create response and the realtime payload name one node',
      );
    });

    test('excludes every database one save created, not just the first', () {
      final folders = <LibraryFolder>[
        _folder(id: 'kept', name: 'Aadvik Prep'),
        _folder(id: 'created-a', name: 'Aadvik Prep', parentId: 'kept'),
        _folder(id: 'created-b', name: 'Aadvik Prep', parentId: 'kept'),
      ];

      expect(
        libraryNewCloudDatabaseNameConflict(
          'Aadvik Prep',
          folders,
          createdIds: const <String>['created-a', 'created-b'],
        )?.id,
        'kept',
        reason: 'a node the save did not create is still a real clash',
      );
      expect(
        libraryNewCloudDatabaseNameConflict(
          'Aadvik Prep',
          folders,
          createdIds: const <String>['kept', 'created-a', 'created-b'],
        ),
        isNull,
      );
    });

    test('keeps the hint quiet for the whole write', () {
      final existing = _folder(id: 'existing', name: 'Aadvik Prep');

      expect(
        libraryNewCloudDatabaseNameConflict(
          'Aadvik Prep',
          [existing],
          saveInFlight: true,
        ),
        isNull,
        reason: 'a running save already had its name accepted before the first insert; only the pre-save guard can refuse it',
      );
      expect(
        libraryNewCloudDatabaseNameConflict('Aadvik Prep', [existing])?.id,
        'existing',
        reason: 'outside a save the same clash is reported exactly as before',
      );
    });

    test('mirrors the account-wide UNIQUE rule for the live hint too', () {
      // UNIQUE (user_id, name) is case-sensitive and account-wide, and a
      // followed book belongs to another account, so it can never collide.
      expect(
        libraryNewCloudDatabaseNameConflict(
          'aadvik prep',
          [_folder(id: 'a', name: 'Aadvik Prep')],
        ),
        isNull,
      );
      expect(
        libraryNewCloudDatabaseNameConflict(
          'Aadvik Prep',
          [_folder(id: 'book', name: 'Aadvik Prep', isSubscribed: true)],
        ),
        isNull,
      );
      expect(
        libraryNewCloudDatabaseNameConflict(
          '  Aadvik Prep  ',
          [_folder(id: 'a', name: 'Aadvik Prep')],
        )?.id,
        'a',
      );
      expect(
        libraryNewCloudDatabaseNameConflict(
          '',
          [_folder(id: 'a', name: 'Aadvik Prep')],
        ),
        isNull,
      );
    });

    test('the dialog evaluates the hint against the pre-save nodes', () {
      // Source guard: the widget owns the state, so the wiring is asserted
      // where it lives. Reverting the hint to the raw account list (the
      // reported bug) or dropping the in-flight suppression fails here.
      final source = File(
        'lib/desktop/widgets/library/library_save_to_folder_dialog.dart',
      ).readAsStringSync();
      final hint = _region(
        source,
        'Widget _buildNewDatabaseSection(',
        'final destinations = <String>{',
      );
      expect(hint, contains('libraryNewCloudDatabaseNameConflict('));
      expect(hint, contains('createdIds: _createdCloudNodeIds'));
      expect(hint, contains('createdNames: _createdCloudNodeNames'));
      expect(hint, contains('saveInFlight: _isSaving'));
      expect(
        hint,
        isNot(contains('libraryCloudNodeNamed(typed, allFolders)')),
        reason: 'the live hint must not match the database the save created',
      );

      // The pre-save guard keeps refusing a genuinely pre-existing clash. It
      // tolerates only nodes this dialog created for its own saves (a failed
      // attempt whose cleanup did not complete, or whose removal the live
      // folder list has not caught up with); see
      // library_failed_cloud_save_cleanup_test.dart.
      final beforeCreate = _region(
        source,
        'if (nameCtrl != null) {',
        'final parents = libraryNewDatabaseParents(',
      );
      expect(beforeCreate, contains('librarySaveToleratesOwnCloudName('));
      expect(
        beforeCreate,
        contains('clash: libraryCloudNodeNamed(newName, allFolders)'),
      );
      expect(beforeCreate, contains('ownNodeIds: _ownCloudNodeIds'));
      expect(
        beforeCreate,
        contains('libraryDuplicateCloudNodeMessage(newName)'),
      );

      // The created node is remembered next to the write material.
      final create = _region(
        source,
        'final created = await repo.createFolder(',
        'await for (final batch in _gameBatches(effectiveGames))',
      );
      expect(create, contains('_createdCloudNodeIds.add(created.id)'));
      expect(
        create,
        contains('_createdCloudNodeNames.add(created.name.trim())'),
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

LibraryFolder _folder({
  required String id,
  required String name,
  bool isSubscribed = false,
  String icon = 'database',
  String? parentId,
  String? nodeType,
}) {
  return LibraryFolder(
    id: id,
    userId: 'user',
    name: name,
    color: '#0FB4E5',
    icon: icon,
    orderIndex: 0,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    isSubscribed: isSubscribed,
    parentId: parentId,
    nodeType: nodeType,
  );
}
