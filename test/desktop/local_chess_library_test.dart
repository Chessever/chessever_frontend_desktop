import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_access.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_append.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';

void main() {
  group('local chess library state', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_local_state_');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test(
      'openPaths reports failure without replacing previous source',
      () async {
        final notifier = LocalChessLibraryNotifier();
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);

        final opened = await notifier.openPaths(<String>[file.path]);
        expect(opened, isTrue);
        final previousSource = notifier.state.source;
        final previousPath = notifier.state.selectedPath;
        expect(previousSource, isNotNull);
        expect(previousPath, isNotNull);

        final missing = await notifier.openPaths(<String>[
          '${temp.path}/missing-folder',
        ]);

        expect(missing, isFalse);
        expect(notifier.state.source, same(previousSource));
        expect(notifier.state.selectedPath, previousPath);
        expect(notifier.state.error, contains('couldn\'t find'));
        expect(notifier.state.isScanning, isFalse);
      },
    );

    test(
      'openPaths rejects generic picker gz without replacing previous source',
      () async {
        final notifier = LocalChessLibraryNotifier();
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final genericGzip = File('${temp.path}/notes.gz');
        await genericGzip.writeAsBytes(<int>[31, 139, 8, 0]);

        final opened = await notifier.openPaths(<String>[file.path]);
        expect(opened, isTrue);
        final previousSource = notifier.state.source;
        final previousPath = notifier.state.selectedPath;

        final genericOpened = await notifier.openPaths(<String>[
          genericGzip.path,
        ]);

        expect(genericOpened, isFalse);
        expect(notifier.state.source, same(previousSource));
        expect(notifier.state.selectedPath, previousPath);
        expect(notifier.state.error, contains('No recognized chess file'));
        expect(notifier.state.error, isNot(contains('Invalid argument')));
        expect(notifier.state.isScanning, isFalse);
      },
    );

    test(
      'openPaths falls back to scanning when local cache is unavailable',
      () async {
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final repo = _FailingLocalChessDatabaseRepository(
          failLoadFreshSource: true,
          failPersistSource: true,
          failPersistFileNode: true,
        );
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );

        final opened = await notifier.openPaths(<String>[file.path]);

        expect(opened, isTrue);
        expect(repo.loadFreshSourceCalls, 1);
        expect(repo.persistSourceCalls, 0);
        expect(notifier.state.error, isNull);
        expect(notifier.state.isScanning, isFalse);
        final loadedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(loadedFile.games, hasLength(1));
        expect(loadedFile.games.single.game.metadata['Event'], 'Candidates');
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(repo.rebuildOpeningTreeCalls, 0);
        expect(notifier.state.treeBuilds, isEmpty);
        notifier.clear();
      },
    );

    test(
      'file-access cache failure is not retried through the scanner',
      () async {
        final file = File('${temp.path}/stalled.pgn');
        await file.writeAsString(_samplePgn);
        var scanCalls = 0;
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: _FailingLocalChessDatabaseRepository(
            loadFreshSourceError: LocalChessFileAccessException.stalled(
              path: file.path,
            ),
          ),
          scanPathsWithProgress: (
            _, {
            sourceLabel,
            maxDecodedBytes = 64 * 1024 * 1024,
            maxGames = 200000,
            buildOpeningTree = false,
            onProgress,
          }) async {
            scanCalls += 1;
            throw StateError('scanner must not retry an inaccessible path');
          },
        );

        final opened = await notifier.openPaths(<String>[file.path]);

        expect(opened, isFalse);
        expect(scanCalls, 0);
        expect(notifier.state.error, contains('stopped receiving data'));
      },
    );

    test(
      'single-file import rejects an unreadable PGN with recovery guidance',
      () async {
        final file = File('${temp.path}/locked-in-chessbase.pgn');
        await file.writeAsString(_samplePgn);
        final failedNode = LocalChessFileNode(
          name: 'locked-in-chessbase.pgn',
          path: file.path,
          relativePath: 'locked-in-chessbase.pgn',
          extension: '.pgn',
          status: LocalChessFileStatus.failed,
          games: const <LocalChessGame>[],
          sizeBytes: await file.length(),
          modifiedAt: await file.lastModified(),
          message:
              'Could not read this file: FileSystemException: '
              'The process cannot access the file because it is being used '
              'by another process. (OS Error: Sharing violation, errno = 32)',
        );
        final failedSource = LocalChessSource(
          id: 'locked-source',
          label: 'locked-in-chessbase.pgn',
          paths: <String>[file.path],
          rootPath: temp.path,
          scannedAt: DateTime(2026),
          root: LocalChessFolderNode.fromChildren(
            name: 'locked-in-chessbase.pgn',
            path: 'local-file:locked-source',
            relativePath: '',
            children: <LocalChessNode>[failedNode],
          ),
        );
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: _FailingLocalChessDatabaseRepository(
            importedSource: failedSource,
          ),
          scanPgnCatalog: (_, {sourceLabel, maxGames = 200000}) async {
            return failedSource;
          },
        );

        final opened = await notifier.openPaths(<String>[file.path]);

        expect(opened, isFalse);
        expect(notifier.state.source, isNull);
        expect(notifier.state.isScanning, isFalse);
        expect(notifier.state.scanProgress, isNull);
        expect(notifier.state.error, contains('another app'));
        expect(notifier.state.error, contains('Close'));
        expect(notifier.state.error, contains('try again'));
      },
    );

    test('single-file import preserves compressed-PGN decode errors', () async {
      final file = File('${temp.path}/corrupt.pgn.bz2');
      await file.writeAsBytes(<int>[1, 2, 3], flush: true);
      final failedNode = LocalChessFileNode(
        name: 'corrupt.pgn.bz2',
        path: file.path,
        relativePath: 'corrupt.pgn.bz2',
        extension: '.pgn.bz2',
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: await file.length(),
        modifiedAt: await file.lastModified(),
        message: 'Could not decode compressed PGN (.pgn.bz2): invalid data',
      );
      final failedSource = LocalChessSource(
        id: 'corrupt-source',
        label: 'corrupt.pgn.bz2',
        paths: <String>[file.path],
        rootPath: temp.path,
        scannedAt: DateTime(2026),
        root: LocalChessFolderNode.fromChildren(
          name: 'corrupt.pgn.bz2',
          path: 'local-file:corrupt-source',
          relativePath: '',
          children: <LocalChessNode>[failedNode],
        ),
      );
      final notifier = LocalChessLibraryNotifier(
        localDatabaseRepository: _FailingLocalChessDatabaseRepository(
          importedSource: failedSource,
        ),
      );

      final opened = await notifier.openPaths(<String>[file.path]);

      expect(opened, isFalse);
      expect(notifier.state.error, contains('Could not decode compressed PGN'));
      expect(notifier.state.error, isNot(contains('Close it in other apps')));
    });

    test(
      'openPaths uses the direct PGN catalog without importing a cache',
      () async {
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final scanned = await scanLocalChessPaths(<String>[file.path]);
        final fullFile = scanned.root.singlePlayableDatabaseInSubtree!;
        final previewFile = LocalChessFileNode(
          name: fullFile.name,
          path: fullFile.path,
          relativePath: fullFile.relativePath,
          extension: fullFile.extension,
          status: fullFile.status,
          games: <LocalChessGame>[fullFile.games.first],
          gameCount: fullFile.gameCount,
          sizeBytes: fullFile.sizeBytes,
          modifiedAt: fullFile.modifiedAt,
          message: fullFile.message,
          pgnOffsetIndex: fullFile.pgnOffsetIndex,
        );
        final imported = LocalChessSource(
          id: scanned.id,
          label: scanned.label,
          paths: scanned.paths,
          rootPath: scanned.rootPath,
          scannedAt: scanned.scannedAt,
          root: LocalChessFolderNode.fromChildren(
            name: scanned.root.name,
            path: scanned.root.path,
            relativePath: scanned.root.relativePath,
            children: <LocalChessNode>[previewFile],
          ),
        );
        final repo = _FailingLocalChessDatabaseRepository(
          importedSource: imported,
        );
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );

        final opened = await notifier.openPaths(<String>[file.path]);

        expect(opened, isTrue);
        expect(repo.importSingleFileSourceCalls, 0);
        expect(repo.persistSourceCalls, 0);
        expect(notifier.state.isScanning, isFalse);
        final loadedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(loadedFile.games, hasLength(1));
        expect(loadedFile.gameCount, fullFile.gameCount);
        notifier.clear();
      },
    );

    test('large raw PGN opens fully before search indexing is requested', () async {
      final file = File('${temp.path}/instant.pgn');
      await file.writeAsString(_samplePgn);
      final scanned = await scanLocalChessPaths(<String>[file.path]);
      await file.writeAsBytes(
        List<int>.filled(600 * 1024, 0x20),
        mode: FileMode.append,
      );
      final catalog = await scanLocalChessPgnCatalog(file.path);
      final importStarted = Completer<void>();
      final releaseImport = Completer<void>();
      final repo = _FailingLocalChessDatabaseRepository(
        importedSource: scanned,
        importStarted: importStarted,
        releaseImport: releaseImport,
      );
      var catalogLimit = 0;
      var catalogCalls = 0;
      final notifier = LocalChessLibraryNotifier(
        localDatabaseRepository: repo,
        scanPgnCatalog: (_, {sourceLabel, maxGames = 200000}) async {
          catalogCalls++;
          catalogLimit = maxGames;
          return catalog;
        },
      );

      final opened = await notifier.openPaths(<String>[file.path]);

      expect(opened, isTrue);
      expect(importStarted.isCompleted, isFalse);
      expect(releaseImport.isCompleted, isFalse);
      expect(catalogLimit, 200000);
      expect(notifier.state.isScanning, isFalse);
      expect(notifier.state.source, isNotNull);
      expect(notifier.state.backgroundImportForPath(file.path), isNull);
      expect(catalogCalls, 1);

      expect(notifier.ensureSearchIndex(file.path), isTrue);
      expect(importStarted.isCompleted, isTrue);
      expect(notifier.state.backgroundImportForPath(file.path), isNotNull);

      final reopened = await notifier.openPaths(<String>[file.path]);

      expect(reopened, isTrue);
      expect(catalogCalls, 1);
      expect(notifier.state.isScanning, isFalse);
      expect(notifier.state.source, same(catalog));
      expect(notifier.state.backgroundImportForPath(file.path), isNotNull);

      final indexingFinished = notifier.stream.firstWhere(
        (state) => state.backgroundImportForPath(file.path) == null,
      );
      releaseImport.complete();
      await indexingFinished.timeout(const Duration(seconds: 2));

      expect(notifier.state.backgroundImportForPath(file.path), isNull);
      expect(notifier.state.warning, isNull);
      notifier.clear();
    });

    test(
      'openPaths imports each multi-file PGN through the cache worker path',
      () async {
        final first = File('${temp.path}/first.pgn');
        final second = File('${temp.path}/second.pgn');
        await first.writeAsString(_samplePgn);
        await second.writeAsString(_samplePgn);
        final combined = await scanLocalChessPaths(<String>[
          first.path,
          second.path,
        ], sourceLabel: '2 PGN files');
        final repo = _FailingLocalChessDatabaseRepository(
          importedSource: combined,
          multiFileLoadSource: combined,
        );
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );
        final progressMessages = <String>[];
        final subscription = notifier.stream.listen((state) {
          final message = state.scanProgress?.message;
          if (message != null && message.isNotEmpty) {
            progressMessages.add(message);
          }
        });
        addTearDown(subscription.cancel);

        final opened = await notifier.openPaths(<String>[
          first.path,
          second.path,
        ], sourceLabel: '2 PGN files');

        expect(opened, isTrue);
        expect(repo.importSingleFileSourceCalls, 2);
        expect(repo.importSingleFileSourcePaths, <String>[
          first.path,
          second.path,
        ]);
        expect(repo.loadFreshSourceCalls, greaterThanOrEqualTo(2));
        expect(repo.persistSourceCalls, 0);
        expect(progressMessages, anyElement(contains('Importing file 1 of 2')));
        expect(progressMessages, anyElement(contains('Importing file 2 of 2')));
        expect(notifier.state.source?.paths, hasLength(2));
        notifier.clear();
      },
    );

    test('multi-file import rejects a source when every PGN failed', () async {
      final first = File('${temp.path}/first-locked.pgn');
      final second = File('${temp.path}/second-locked.pgn');
      await first.writeAsString(_samplePgn);
      await second.writeAsString(_samplePgn);
      LocalChessFileNode failedNode(File file) => LocalChessFileNode(
        name: file.uri.pathSegments.last,
        path: file.path,
        relativePath: file.uri.pathSegments.last,
        extension: '.pgn',
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: 1,
        message:
            'FileSystemException: The process cannot access the file because '
            'it is being used by another process. (OS Error: Sharing '
            'violation, errno = 32)',
      );

      final failedSource = LocalChessSource(
        id: 'all-failed',
        label: 'Locked PGNs',
        paths: <String>[first.path, second.path],
        rootPath: temp.path,
        scannedAt: DateTime(2026),
        root: LocalChessFolderNode.fromChildren(
          name: 'Locked PGNs',
          path: 'local-batch:all-failed',
          relativePath: '',
          children: <LocalChessNode>[failedNode(first), failedNode(second)],
        ),
      );
      final notifier = LocalChessLibraryNotifier(
        localDatabaseRepository: _FailingLocalChessDatabaseRepository(
          importedSource: failedSource,
          multiFileLoadSource: failedSource,
        ),
      );

      final opened = await notifier.openPaths(<String>[
        first.path,
        second.path,
      ]);

      expect(opened, isFalse);
      expect(notifier.state.source, isNull);
      expect(notifier.state.error, contains('No PGN files could be opened'));
      expect(notifier.state.error, contains('ChessBase'));
      expect(notifier.state.warning, isNull);
    });

    test('partial multi-file import keeps playable PGNs and warns', () async {
      final playable = File('${temp.path}/playable.pgn');
      final locked = File('${temp.path}/locked.pgn');
      await playable.writeAsString(_samplePgn);
      await locked.writeAsString(_samplePgn);
      final scanned = await scanLocalChessPaths(<String>[playable.path]);
      final playableNode = scanned.root.singlePlayableDatabaseInSubtree!;
      final lockedNode = LocalChessFileNode(
        name: 'locked.pgn',
        path: locked.path,
        relativePath: 'locked.pgn',
        extension: '.pgn',
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: await locked.length(),
        message:
            'FileSystemException: The process cannot access the file because '
            'it is being used by another process. (OS Error: Sharing '
            'violation, errno = 32)',
      );
      final partialSource = LocalChessSource(
        id: 'partial',
        label: 'Two PGNs',
        paths: <String>[playable.path, locked.path],
        rootPath: temp.path,
        scannedAt: DateTime(2026),
        root: LocalChessFolderNode.fromChildren(
          name: 'Two PGNs',
          path: 'local-batch:partial',
          relativePath: '',
          children: <LocalChessNode>[playableNode, lockedNode],
        ),
      );
      final notifier = LocalChessLibraryNotifier(
        localDatabaseRepository: _FailingLocalChessDatabaseRepository(
          importedSource: partialSource,
          multiFileLoadSource: partialSource,
        ),
      );

      final opened = await notifier.openPaths(<String>[
        playable.path,
        locked.path,
      ]);

      expect(opened, isTrue);
      expect(notifier.state.source, same(partialSource));
      expect(notifier.state.error, isNull);
      expect(notifier.state.warning, contains('1 PGN database'));
      expect(notifier.state.warning, contains('ChessBase'));
    });

    test('folder scan error cannot install an empty source', () async {
      final folder = await Directory('${temp.path}/unavailable').create();
      final failedSource = LocalChessSource(
        id: 'folder-failed',
        label: 'Unavailable',
        paths: <String>[folder.path],
        rootPath: folder.path,
        scannedAt: DateTime(2026),
        root: LocalChessFolderNode.fromChildren(
          name: 'Unavailable',
          path: folder.path,
          relativePath: '',
          children: const <LocalChessNode>[],
          scanError:
              'FileSystemException: The network name is no longer available '
              '(OS Error: errno = 64)',
        ),
      );
      final notifier = LocalChessLibraryNotifier(
        scanPathsWithProgress:
            (
              _, {
              sourceLabel,
              maxDecodedBytes = 64 * 1024 * 1024,
              maxGames = 200000,
              buildOpeningTree = false,
              onProgress,
            }) async => failedSource,
      );

      final opened = await notifier.openPaths(<String>[folder.path]);

      expect(opened, isFalse);
      expect(notifier.state.source, isNull);
      expect(notifier.state.error, contains('isn\'t available'));
    });

    test(
      'refreshFile updates one local database tree and persisted cache',
      () async {
        final db = await resqlite.Database.open('${temp.path}/local_chess.db');
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        addTearDown(db.close);
        final repo = LocalChessDatabaseRepository(database: () async => db);
        final root = Directory('${temp.path}/workspace');
        final sub = Directory('${root.path}/lines');
        await sub.create(recursive: true);
        final file = File('${sub.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );

        final opened = await notifier.openPaths(<String>[root.path]);
        expect(opened, isTrue);
        notifier.selectPath(file.path);
        final initialFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(initialFile.games, hasLength(1));
        expect(initialFile.relativePath, p.join('lines', 'mini.pgn'));
        expect(await _count(db, 'local_chess_games'), 1);
        expect(notifier.rebuildOpeningTree(file.path), isTrue);
        await _waitForLocalTree(notifier, file.path);

        final added = await appendPgnTextToLocalChessFile(
          filePath: file.path,
          text: _secondSamplePgn,
          existingFingerprints: {
            for (final game in initialFile.games) game.pgnFingerprint,
          },
        );
        final refreshed = await notifier.refreshFile(file.path);

        expect(added, 1);
        expect(refreshed, isTrue);
        expect(notifier.state.selectedPath, file.path);
        final refreshedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(refreshedFile.games, hasLength(2));
        expect(refreshedFile.relativePath, p.join('lines', 'mini.pgn'));
        expect(await _count(db, 'local_chess_games'), 2);
        expect(refreshedFile.openingTreeIndex, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(notifier.state.treeBuildForPath(file.path), isNull);
        expect(notifier.rebuildOpeningTree(file.path), isTrue);
        final rebuiltFile = await _waitForLocalTree(notifier, file.path);
        expect(rebuiltFile.openingTreeIndex!.downloadedGameCount, 2);
        final restored = await repo.loadFreshFileNode(
          file.path,
          rootPath: root.path,
        );
        expect(restored, isNotNull);
        expect(restored!.games, hasLength(2));
        expect(restored.relativePath, p.join('lines', 'mini.pgn'));
        expect(restored.openingTreeIndex, isNull);
        expect(
          repo
              .loadCompactOpeningTreeIndexForDatabase(databasePath: file.path)!
              .downloadedGameCount,
          2,
        );
      },
    );

    test(
      'refreshFile falls back to scanning when cached file restore fails',
      () async {
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final repo = _FailingLocalChessDatabaseRepository(
          failLoadFreshFileNode: true,
          failPersistFileNode: true,
        );
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );

        final opened = await notifier.openPaths(<String>[file.path]);
        expect(opened, isTrue);
        final added = await appendPgnTextToLocalChessFile(
          filePath: file.path,
          text: _secondSamplePgn,
          existingFingerprints: {
            for (final game in notifier.state.source!.games)
              game.pgnFingerprint,
          },
        );
        final refreshed = await notifier.refreshFile(file.path);

        expect(added, 1);
        expect(refreshed, isTrue);
        expect(repo.loadFreshFileNodeCalls, greaterThanOrEqualTo(1));
        expect(repo.persistFileNodeCalls, greaterThanOrEqualTo(1));
        expect(notifier.state.error, isNull);
        expect(notifier.state.isScanning, isFalse);
        final refreshedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(refreshedFile.games, hasLength(2));
        expect(
          refreshedFile.games.map((game) => game.game.metadata['Event']),
          containsAll(<String>['Candidates', 'Training']),
        );
        notifier.clear();
      },
    );

    test('clear prevents stale on-demand tree build from installing', () async {
      final file = File('${temp.path}/mini.pgn');
      await file.writeAsString(_samplePgn);
      final treeStarted = Completer<void>();
      final releaseTree = Completer<void>();
      final repo = _FailingLocalChessDatabaseRepository(
        rebuildStarted: treeStarted,
        releaseRebuild: releaseTree,
      );
      final notifier = LocalChessLibraryNotifier(localDatabaseRepository: repo);

      final opened = await notifier.openPaths(<String>[file.path]);
      expect(opened, isTrue);
      final awaitedBuild = notifier.rebuildOpeningTreeAndWait(file.path);
      await treeStarted.future.timeout(const Duration(seconds: 2));
      notifier.clear();
      expect(await awaitedBuild, isNull);
      releaseTree.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.source, isNull);
      expect(notifier.state.treeBuilds, isEmpty);
      expect(repo.rebuildOpeningTreeCalls, 1);
    });

    test(
      'openPaths recovers persisted games without auto rebuilding a missing tree',
      () async {
        final db = await resqlite.Database.open('${temp.path}/recover_tree.db');
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        addTearDown(db.close);
        final repo = LocalChessDatabaseRepository(database: () async => db);
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final quickSource = await scanLocalChessPaths(<String>[
          file.path,
        ], buildOpeningTree: false);
        await repo.persistSource(quickSource);

        final cachedBefore = await repo.loadFreshFileNode(
          file.path,
          rootPath: temp.path,
        );
        expect(cachedBefore, isNotNull);
        expect(cachedBefore!.games, hasLength(1));
        expect(cachedBefore.openingTreeIndex, isNull);

        var treeBuildScans = 0;
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
          scanFileNodeWithProgress: ({
            required String path,
            required String rootPath,
            int maxDecodedBytes = 64 * 1024 * 1024,
            int maxGames = 200000,
            bool buildOpeningTree = true,
            void Function(LocalChessScanProgress progress)? onProgress,
          }) async {
            if (buildOpeningTree) treeBuildScans++;
            return scanLocalChessFileNodeWithProgress(
              path: path,
              rootPath: rootPath,
              maxDecodedBytes: maxDecodedBytes,
              maxGames: maxGames,
              buildOpeningTree: buildOpeningTree,
              onProgress: onProgress,
            );
          },
        );
        final opened = await notifier.openPaths(<String>[file.path]);

        expect(opened, isTrue);
        final loadedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(loadedFile.games, hasLength(1));
        expect(loadedFile.openingTreeIndex, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(notifier.state.treeBuilds, isEmpty);
        expect(treeBuildScans, 0);

        expect(notifier.rebuildOpeningTree(file.path), isTrue);
        final rebuiltFile = await _waitForLocalTree(notifier, file.path);
        expect(rebuiltFile.openingTreeIndex, isNotNull);
        expect(rebuiltFile.openingTreeIndex!.downloadedGameCount, 1);
        expect(treeBuildScans, 0);
        final compactAfter = repo.loadCompactOpeningTreeIndexForDatabase(
          databasePath: file.path,
        );
        expect(compactAfter, isNotNull);
      },
    );

    test(
      'openPaths restores the persisted compact tree without rebuilding',
      () async {
        final db = await resqlite.Database.open('${temp.path}/restore_tree.db');
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        addTearDown(db.close);
        final writeRepo = LocalChessDatabaseRepository(
          database: () async => db,
        );
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final buildNotifier = LocalChessLibraryNotifier(
          localDatabaseRepository: writeRepo,
        );

        final initiallyOpened = await buildNotifier.openPaths(<String>[
          file.path,
        ]);
        expect(initiallyOpened, isTrue);
        expect(buildNotifier.rebuildOpeningTree(file.path), isTrue);
        await _waitForLocalTree(buildNotifier, file.path);

        final readRepo = LocalChessDatabaseRepository(
          database: () async => db,
          eagerTreeMoveLoadLimit: 0,
          eagerPositionRefLoadLimit: 0,
        );
        final restoredIndex = readRepo.loadCompactOpeningTreeIndexForDatabase(
          databasePath: file.path,
        )!;
        expect(restoredIndex.positionCount, greaterThan(1));
        expect(restoredIndex.downloadedGameCount, 1);
        expect(restoredIndex.nodesById, isEmpty);

        var treeBuildScans = 0;
        final reopenNotifier = LocalChessLibraryNotifier(
          localDatabaseRepository: readRepo,
          scanPathsWithProgress: scanLocalChessPathsWithProgress,
          scanFileNodeWithProgress: ({
            required String path,
            required String rootPath,
            int maxDecodedBytes = 64 * 1024 * 1024,
            int maxGames = 200000,
            bool buildOpeningTree = true,
            void Function(LocalChessScanProgress progress)? onProgress,
          }) async {
            if (buildOpeningTree) treeBuildScans++;
            return scanLocalChessFileNodeWithProgress(
              path: path,
              rootPath: rootPath,
              maxDecodedBytes: maxDecodedBytes,
              maxGames: maxGames,
              buildOpeningTree: buildOpeningTree,
              onProgress: onProgress,
            );
          },
        );

        final reopened = await reopenNotifier.openPaths(<String>[file.path]);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(reopened, isTrue);
        final reopenedFile =
            reopenNotifier.state.source!.nodeForPath(file.path)
                as LocalChessFileNode;
        expect(reopenedFile.openingTreeIndex, isNotNull);
        expect(reopenedFile.openingTreeIndex!.nodesById, isEmpty);
        expect(reopenedFile.openingTreeIndex!.positionCount, greaterThan(1));
        expect(reopenNotifier.state.treeBuilds, isEmpty);
        expect(treeBuildScans, 0);
      },
    );

    test(
      'openPaths surfaces cache migration progress while restore waits',
      () async {
        final file = File('${temp.path}/migration-progress.pgn');
        await file.writeAsString(_samplePgn);
        final source = await scanLocalChessPaths(<String>[
          file.path,
        ], buildOpeningTree: false);
        final releaseRestore = Completer<void>();
        final repo = _ProgressLocalChessDatabaseRepository(
          source: source,
          releaseRestore: releaseRestore,
        );
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );

        final opened = notifier.openPaths(<String>[file.path]);
        await Future<void>.delayed(Duration.zero);

        expect(notifier.state.isScanning, isTrue);
        expect(
          notifier.state.scanProgress?.message,
          'Migrating existing local databases...',
        );
        expect(notifier.state.scanProgress?.fraction, 0.12);

        releaseRestore.complete();
        expect(await opened, isTrue);
        expect(notifier.state.isScanning, isFalse);
        expect(notifier.state.scanProgress, isNull);
        notifier.clear();
      },
    );

    test('rebuildOpeningTree coalesces dense worker progress', () async {
      final db = await resqlite.Database.open('${temp.path}/progress_tree.db');
      await db.execute('PRAGMA foreign_keys=ON');
      await createLocalChessResqliteDatabaseSchema(db);
      addTearDown(db.close);
      final repo = LocalChessDatabaseRepository(database: () async => db);
      final file = File('${temp.path}/mini.pgn');
      await file.writeAsString(_samplePgn);
      final quickSource = await scanLocalChessPaths(<String>[
        file.path,
      ], buildOpeningTree: false);
      await repo.persistSource(quickSource);

      final progressStates = <LocalChessTreeBuildProgress>[];
      final notifier = LocalChessLibraryNotifier(
        localDatabaseRepository: repo,
        scanFileNodeWithProgress: ({
          required String path,
          required String rootPath,
          int maxDecodedBytes = 64 * 1024 * 1024,
          int maxGames = 200000,
          bool buildOpeningTree = true,
          void Function(LocalChessScanProgress progress)? onProgress,
        }) async {
          if (buildOpeningTree) {
            for (var i = 0; i < 100; i++) {
              onProgress?.call(
                LocalChessScanProgress(
                  fraction: i / 10000,
                  message: 'Scanning PGN...',
                ),
              );
            }
          }
          return scanLocalChessFileNodeWithProgress(
            path: path,
            rootPath: rootPath,
            maxDecodedBytes: maxDecodedBytes,
            maxGames: maxGames,
            buildOpeningTree: buildOpeningTree,
            onProgress: onProgress,
          );
        },
      );
      final removeListener = notifier.addListener((state) {
        final progress = state.treeBuildForPath(file.path);
        if (progress != null) progressStates.add(progress);
      }, fireImmediately: false);
      addTearDown(removeListener);

      final opened = await notifier.openPaths(<String>[file.path]);
      expect(opened, isTrue);
      expect(notifier.rebuildOpeningTree(file.path), isTrue);

      final rebuilt = await _waitForLocalTree(notifier, file.path);

      expect(rebuilt.openingTreeIndex, isNotNull);
      expect(
        progressStates.map((progress) => progress.phase),
        contains(LocalChessTreeBuildPhase.persisting),
      );
      expect(progressStates.length, lessThan(30));
    });

    test(
      'on-demand tree build installs repository rebuild result without cache reload',
      () async {
        final file = File('${temp.path}/reload-fallback.pgn');
        await file.writeAsString(_samplePgn);
        final quickSource = await scanLocalChessPaths(<String>[
          file.path,
        ], buildOpeningTree: false);
        final repo = _FailingLocalChessDatabaseRepository(
          failLoadFreshFileNode: true,
        );
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
          scanPathsWithProgress: (
            paths, {
            sourceLabel,
            maxDecodedBytes = 64 * 1024 * 1024,
            maxGames = 200000,
            buildOpeningTree = true,
            onProgress,
          }) async {
            return quickSource;
          },
          scanFileNodeWithProgress: ({
            required String path,
            required String rootPath,
            int maxDecodedBytes = 64 * 1024 * 1024,
            int maxGames = 200000,
            bool buildOpeningTree = true,
            void Function(LocalChessScanProgress progress)? onProgress,
          }) {
            return scanLocalChessFileNodeWithProgress(
              path: path,
              rootPath: rootPath,
              maxDecodedBytes: maxDecodedBytes,
              maxGames: maxGames,
              buildOpeningTree: buildOpeningTree,
              onProgress: onProgress,
            );
          },
        );

        expect(await notifier.openPaths(<String>[file.path]), isTrue);
        final awaitedIndex = await notifier.rebuildOpeningTreeAndWait(
          file.path,
        );

        final rebuilt =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;

        expect(awaitedIndex, same(rebuilt.openingTreeIndex));
        expect(rebuilt.openingTreeIndex, isNotNull);
        expect(rebuilt.openingTreeIndex!.downloadedGameCount, 1);
        expect(repo.rebuildOpeningTreeCalls, 1);
        expect(repo.loadFreshFileNodeCalls, 0);
        expect(notifier.state.treeBuildForPath(file.path), isNull);
      },
    );

    test('click-to-stop cancels the active tree worker and waiter', () async {
      final file = File('${temp.path}/cancel-tree.pgn');
      await file.writeAsString(_samplePgn);
      final rebuildStarted = Completer<void>();
      final releaseRebuild = Completer<void>();
      final repo = _FailingLocalChessDatabaseRepository(
        rebuildStarted: rebuildStarted,
        releaseRebuild: releaseRebuild,
      );
      final notifier = LocalChessLibraryNotifier(localDatabaseRepository: repo);

      expect(await notifier.openPaths(<String>[file.path]), isTrue);
      final result = notifier.rebuildOpeningTreeAndWait(file.path);
      await rebuildStarted.future;

      expect(notifier.state.treeBuildForPath(file.path)?.isActive, isTrue);
      expect(notifier.cancelOpeningTreeBuild(file.path), isTrue);
      expect(await result.timeout(const Duration(seconds: 1)), isNull);
      expect(notifier.state.treeBuildForPath(file.path), isNull);
      expect(repo.rebuildOpeningTreeCalls, 1);
    });

    test('tree progress estimates compact remaining time', () {
      const progress = LocalChessTreeBuildProgress(
        path: 'nakamura.pgn',
        phase: LocalChessTreeBuildPhase.building,
        fraction: 0.93,
        message: 'Saving tree moves...',
        startedAtMs: 0,
        updatedAtMs: 93000,
      );

      expect(progress.compactEta, '~7s');
    });

    test(
      'refreshFile uses a fresh persisted cache before rescanning',
      () async {
        final db = await resqlite.Database.open('${temp.path}/cache_first.db');
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        addTearDown(db.close);
        final repo = LocalChessDatabaseRepository(database: () async => db);
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );

        final opened = await notifier.openPaths(<String>[file.path]);
        expect(opened, isTrue);
        await repo.importSingleFileSource(path: file.path);
        final initialFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(initialFile.games.single.game.metadata['Event'], 'Candidates');

        final cachedHeaders = Map<String, dynamic>.from(
          initialFile.games.single.game.metadata,
        )..['Event'] = 'Cached refresh';
        await db.execute(
          'UPDATE local_chess_games SET headers_json = ? WHERE database_id = ?',
          <Object?>[jsonEncode(cachedHeaders), _testDatabaseId(file.path)],
        );

        final refreshed = await notifier.refreshFile(file.path);

        expect(refreshed, isTrue);
        final refreshedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(
          refreshedFile.games.single.game.metadata['Event'],
          'Cached refresh',
        );
      },
    );

    test(
      'refreshFile clears persisted cache after deleting last game',
      () async {
        final db = await resqlite.Database.open('${temp.path}/delete_cache.db');
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);
        addTearDown(db.close);
        final repo = LocalChessDatabaseRepository(database: () async => db);
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );

        final opened = await notifier.openPaths(<String>[file.path]);
        expect(opened, isTrue);
        await repo.importSingleFileSource(path: file.path);
        notifier.selectPath(file.path);
        final initialFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(initialFile.games, hasLength(1));
        expect(await _count(db, 'local_chess_databases'), 1);
        expect(await _count(db, 'local_chess_games'), 1);

        final removed = await removeLocalPgnGamesFromFile(
          filePath: file.path,
          indexesInFile: {0},
        );
        final refreshed = await notifier.refreshFile(file.path);

        expect(removed, 1);
        expect(refreshed, isTrue);
        expect(notifier.state.selectedPath, file.path);
        final refreshedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(refreshedFile.status, LocalChessFileStatus.noGames);
        expect(refreshedFile.games, isEmpty);
        expect(await _count(db, 'local_chess_databases'), 0);
        expect(await _count(db, 'local_chess_games'), 0);
        expect(await _count(db, 'local_chess_tree_nodes'), 0);
      },
    );

    test(
      'openPaths opens a warm persisted source without the loading popup',
      () async {
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final source = await scanLocalChessPaths(<String>[
          file.path,
        ], buildOpeningTree: false);
        final repo = _CachedLocalChessDatabaseRepository(source: source);
        final notifier = LocalChessLibraryNotifier(
          localDatabaseRepository: repo,
        );
        final scanningStates = <bool>[];
        final removeListener = notifier.addListener(
          (state) => scanningStates.add(state.isScanning),
          fireImmediately: false,
        );
        addTearDown(removeListener);

        final opened = await notifier.openPaths(<String>[file.path]);

        expect(opened, isTrue);
        expect(repo.loadFreshSourceCalls, 1);
        expect(repo.persistSourceCalls, 0);
        expect(
          scanningStates,
          everyElement(isFalse),
          reason:
              'a source that was already imported and persisted must open '
              'instantly, never re-showing the loading popup',
        );
        expect(notifier.state.isScanning, isFalse);
        expect(notifier.state.source, isNotNull);
        notifier.clear();
      },
    );

    test('local open errors use user-facing messages', () {
      expect(
        localChessOpenErrorMessage(ArgumentError('Open a PGN file.')),
        'Open a PGN file.',
      );
      expect(
        localChessOpenErrorMessage(
          const FileSystemException('File or folder does not exist', '/tmp/db'),
        ),
        'ChessEver couldn\'t find "db". It may have been moved or deleted. '
        'Choose the file again.',
      );
    });
  });
}

class _FailingLocalChessDatabaseRepository
    extends LocalChessDatabaseRepository {
  _FailingLocalChessDatabaseRepository({
    this.failLoadFreshSource = false,
    this.failPersistSource = false,
    this.failLoadFreshFileNode = false,
    this.failPersistFileNode = false,
    this.loadFreshSourceError,
    this.importedSource,
    this.multiFileLoadSource,
    this.rebuildStarted,
    this.releaseRebuild,
    this.importStarted,
    this.releaseImport,
  }) : super(database: _unusedDatabase);

  final bool failLoadFreshSource;
  final bool failPersistSource;
  final bool failLoadFreshFileNode;
  final bool failPersistFileNode;
  final Object? loadFreshSourceError;
  final LocalChessSource? importedSource;
  final LocalChessSource? multiFileLoadSource;
  final Completer<void>? rebuildStarted;
  final Completer<void>? releaseRebuild;
  final Completer<void>? importStarted;
  final Completer<void>? releaseImport;

  int loadFreshSourceCalls = 0;
  int persistSourceCalls = 0;
  int loadFreshFileNodeCalls = 0;
  int persistFileNodeCalls = 0;
  int importSingleFileSourceCalls = 0;
  int persistOpeningTreeIndexCalls = 0;
  int rebuildOpeningTreeCalls = 0;
  final List<String> importSingleFileSourcePaths = <String>[];

  @override
  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    loadFreshSourceCalls++;
    final configuredError = loadFreshSourceError;
    if (configuredError != null) throw configuredError;
    if (failLoadFreshSource) {
      throw StateError('cache restore failed');
    }
    // Only return the multi-file cache after imports have run; the initial
    // openPaths restore probe must still miss so the import path is exercised.
    if (paths.length > 1 &&
        multiFileLoadSource != null &&
        importSingleFileSourceCalls > 0) {
      return multiFileLoadSource;
    }
    return null;
  }

  @override
  Future<LocalChessSource?> importSingleFileSource({
    required String path,
    String? sourceLabel,
    bool deduplicateGames = true,
    bool preferDirectDatabase = false,
    OperationCancellationToken? cancellationToken,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    importSingleFileSourceCalls++;
    importSingleFileSourcePaths.add(path);
    if (importStarted?.isCompleted == false) importStarted!.complete();
    onProgress?.call(
      LocalChessScanProgress(
        fraction: 0.5,
        message: 'Importing ${sourceLabel ?? path}...',
      ),
    );
    final release = releaseImport;
    if (release != null) await release.future;
    return importedSource;
  }

  @override
  Future<void> persistSource(LocalChessSource source) async {
    persistSourceCalls++;
    if (failPersistSource) {
      throw StateError('cache persist failed');
    }
  }

  @override
  Future<LocalChessFileNode?> loadFreshFileNode(
    String path, {
    required String rootPath,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    loadFreshFileNodeCalls++;
    if (failLoadFreshFileNode) {
      throw StateError('file cache restore failed');
    }
    return null;
  }

  @override
  Future<void> persistFileNode(
    LocalChessFileNode file, {
    required String sourceLabel,
  }) async {
    persistFileNodeCalls++;
    if (failPersistFileNode) {
      throw StateError('file cache persist failed');
    }
  }

  @override
  Future<bool> persistOpeningTreeIndex({
    required String databasePath,
    required PlayerOpeningTreeIndex index,
  }) async {
    persistOpeningTreeIndexCalls++;
    return true;
  }

  @override
  Future<LocalChessOpeningTreeRebuildResult?>
  rebuildOpeningTreeFromPgnFile({
    required String databasePath,
    void Function(LocalChessScanProgress progress)? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    rebuildOpeningTreeCalls++;
    if (rebuildStarted?.isCompleted == false) rebuildStarted!.complete();
    if (releaseRebuild != null) {
      await Future.any<void>([
        releaseRebuild!.future,
        if (cancellationToken != null) cancellationToken.whenCanceled,
      ]);
      cancellationToken?.throwIfCanceled();
    }
    onProgress?.call(
      LocalChessScanProgress(fraction: 0.5, message: 'Building tree...'),
    );
    onProgress?.call(
      LocalChessScanProgress(fraction: 0.95, message: 'Saving tree...'),
    );
    return LocalChessOpeningTreeRebuildResult(
      index: _fakeOpeningTreeIndex(databasePath),
      skippedGames: 0,
    );
  }
}

class _ProgressLocalChessDatabaseRepository
    extends LocalChessDatabaseRepository {
  _ProgressLocalChessDatabaseRepository({
    required this.source,
    required this.releaseRestore,
  }) : super(database: _unusedDatabase);

  final LocalChessSource source;
  final Completer<void> releaseRestore;

  @override
  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      LocalChessScanProgress(
        fraction: 0.12,
        message: 'Migrating existing local databases...',
      ),
    );
    await releaseRestore.future;
    return source;
  }
}

/// A warm cache hit: [loadFreshSource] returns the persisted source
/// immediately and emits no progress, mirroring an already-open resqlite
/// database. Opening it must not flip the notifier into its scanning state.
class _CachedLocalChessDatabaseRepository extends LocalChessDatabaseRepository {
  _CachedLocalChessDatabaseRepository({required this.source})
    : super(database: _unusedDatabase);

  final LocalChessSource source;
  int loadFreshSourceCalls = 0;
  int persistSourceCalls = 0;

  @override
  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    loadFreshSourceCalls++;
    return source;
  }

  @override
  Future<void> persistSource(LocalChessSource source) async {
    persistSourceCalls++;
  }
}

PlayerOpeningTreeIndex _fakeOpeningTreeIndex(String databasePath) {
  return PlayerOpeningTreeIndex(
    treeId: 'local:test',
    playerId: databasePath,
    maxPly: 2,
    rootNodeId: 0,
    generatedAt: DateTime(2026),
    nodesById: const <int, PlayerOpeningTreeNode>{},
    nodesByFenKey: const <String, PlayerOpeningTreeNode>{},
    gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
    gameRowsById: const <String, Map<String, dynamic>>{},
    persistedPositionCount: 2,
    persistedGameCount: 1,
  );
}

Future<resqlite.Database> _unusedDatabase() async {
  throw UnsupportedError('unused test database');
}

String _testDatabaseId(String path) {
  final normalized = p.normalize(path.trim());
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

Future<int> _count(resqlite.Database db, String table) async {
  final rows = await db.select('SELECT COUNT(*) AS count FROM $table');
  return rows.single['count'] as int;
}

Future<LocalChessFileNode> _waitForLocalTree(
  LocalChessLibraryNotifier notifier,
  String path,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  String? lastError;
  while (DateTime.now().isBefore(deadline)) {
    final node = notifier.state.source?.nodeForPath(path);
    if (node is LocalChessFileNode && node.openingTreeIndex != null) {
      return node;
    }
    final progress = notifier.state.treeBuildForPath(path);
    if (progress?.phase == LocalChessTreeBuildPhase.failed) {
      lastError = progress?.error ?? progress?.message;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail(
    'Timed out waiting for local opening tree for $path'
    '${lastError == null ? '' : ': $lastError'}',
  );
}

const _samplePgn = '''
[Event "Candidates"]
[Site "Toronto"]
[Date "2024.04.04"]
[Round "1"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 1-0
''';

const _secondSamplePgn = '''
[Event "Training"]
[Site "Budapest"]
[Date "2024.05.05"]
[Round "2"]
[White "Polgar, Judit"]
[Black "Anand, Viswanathan"]
[Result "0-1"]

1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 0-1
''';
