import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
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
        expect(notifier.state.error, contains('File or folder does not exist'));
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
        expect(repo.persistSourceCalls, 1);
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
      'openPaths uses worker import preview without persisting full source again',
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
        expect(repo.importSingleFileSourceCalls, 1);
        expect(repo.persistSourceCalls, 0);
        expect(notifier.state.isScanning, isFalse);
        final loadedFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(loadedFile.games, hasLength(1));
        expect(loadedFile.gameCount, fullFile.gameCount);
        notifier.clear();
      },
    );

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

        final opened = await notifier.openPaths(
          <String>[first.path, second.path],
          sourceLabel: '2 PGN files',
        );

        expect(opened, isTrue);
        expect(repo.importSingleFileSourceCalls, 2);
        expect(repo.importSingleFileSourcePaths, <String>[
          first.path,
          second.path,
        ]);
        expect(repo.loadFreshSourceCalls, greaterThanOrEqualTo(2));
        expect(repo.persistSourceCalls, 0);
        expect(
          progressMessages,
          anyElement(contains('Importing file 1 of 2')),
        );
        expect(
          progressMessages,
          anyElement(contains('Importing file 2 of 2')),
        );
        expect(notifier.state.source?.paths, hasLength(2));
        notifier.clear();
      },
    );

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
        expect(initialFile.relativePath, 'lines/mini.pgn');
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
        expect(refreshedFile.relativePath, 'lines/mini.pgn');
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
        expect(restored.relativePath, 'lines/mini.pgn');
        expect(restored.openingTreeIndex!.downloadedGameCount, 2);
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
      final treeRebuildReturned = Completer<void>();
      final repo = _FailingLocalChessDatabaseRepository(
        rebuildStarted: treeStarted,
        releaseRebuild: releaseTree,
        rebuildReturned: treeRebuildReturned,
      );
      final notifier = LocalChessLibraryNotifier(localDatabaseRepository: repo);

      final opened = await notifier.openPaths(<String>[file.path]);
      expect(opened, isTrue);
      expect(notifier.rebuildOpeningTree(file.path), isTrue);
      await treeStarted.future.timeout(const Duration(seconds: 2));
      notifier.clear();
      releaseTree.complete();
      await treeRebuildReturned.future.timeout(const Duration(seconds: 2));
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
        final cachedAfter = await repo.loadFreshFileNode(
          file.path,
          rootPath: temp.path,
        );
        expect(cachedAfter!.openingTreeIndex, isNotNull);
      },
    );

    test(
      'openPaths restores persisted SQL-backed tree without rebuilding',
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
        final restored = await readRepo.loadFreshFileNode(
          file.path,
          rootPath: temp.path,
        );
        expect(restored, isNotNull);
        final restoredIndex = restored!.openingTreeIndex!;
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
        expect(notifier.rebuildOpeningTree(file.path), isTrue);

        final rebuilt = await _waitForLocalTree(notifier, file.path);

        expect(rebuilt.openingTreeIndex, isNotNull);
        expect(rebuilt.openingTreeIndex!.downloadedGameCount, 1);
        expect(repo.rebuildOpeningTreeCalls, 1);
        expect(repo.loadFreshFileNodeCalls, 0);
        expect(notifier.state.treeBuildForPath(file.path), isNull);
      },
    );

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
        final initialFile =
            notifier.state.source!.nodeForPath(file.path) as LocalChessFileNode;
        expect(initialFile.games.single.game.metadata['Event'], 'Candidates');

        final cachedHeaders = Map<String, dynamic>.from(
          initialFile.games.single.game.metadata,
        )..['Event'] = 'Cached refresh';
        await db.execute(
          'UPDATE local_chess_games SET headers_json = ? WHERE database_id = ?',
          <Object?>[jsonEncode(cachedHeaders), file.path],
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
        'File or folder does not exist: /tmp/db',
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
    this.importedSource,
    this.multiFileLoadSource,
    this.rebuildStarted,
    this.releaseRebuild,
    this.rebuildReturned,
  }) : super(database: _unusedDatabase);

  final bool failLoadFreshSource;
  final bool failPersistSource;
  final bool failLoadFreshFileNode;
  final bool failPersistFileNode;
  final LocalChessSource? importedSource;
  final LocalChessSource? multiFileLoadSource;
  final Completer<void>? rebuildStarted;
  final Completer<void>? releaseRebuild;
  final Completer<void>? rebuildReturned;

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
    OperationCancellationToken? cancellationToken,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    importSingleFileSourceCalls++;
    importSingleFileSourcePaths.add(path);
    onProgress?.call(
      LocalChessScanProgress(
        fraction: 0.5,
        message: 'Importing ${sourceLabel ?? path}...',
      ),
    );
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
  rebuildOpeningTreeFromCachedGames({
    required String databasePath,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    rebuildOpeningTreeCalls++;
    if (rebuildStarted?.isCompleted == false) rebuildStarted!.complete();
    if (releaseRebuild != null) await releaseRebuild!.future;
    onProgress?.call(
      LocalChessScanProgress(fraction: 0.5, message: 'Building tree...'),
    );
    onProgress?.call(
      LocalChessScanProgress(fraction: 0.95, message: 'Saving tree...'),
    );
    if (rebuildReturned?.isCompleted == false) rebuildReturned!.complete();
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
