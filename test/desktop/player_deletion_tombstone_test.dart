import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';

void main() {
  late Directory temp;
  late resqlite.Database db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'chessever-player-delete-tombstone-',
    );
    db = await resqlite.Database.open(p.join(temp.path, 'local_chess.db'));
    await createLocalChessResqliteDatabaseSchema(db);
  });

  tearDown(() async {
    await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('removePlayer persists a tombstone before returning', () async {
    final harness = await _activeChessComSyncHarness(temp, db);
    final sync = harness.notifier.syncAccount(harness.account);
    await harness.repository.downloadStarted.future;

    try {
      await harness.notifier.removePlayer(harness.player.id);

      expect(harness.notifier.state.players, isEmpty);
      expect(harness.notifier.state.selectedPlayerId, isNull);
      expect(
        harness.repository.snapshot.pendingDeletions.map((item) => item.id),
        <String>[harness.player.id],
      );
      expect(harness.repository.sourceDeleteCalls, 0);
      expect(harness.repository.workspaceDeleteCalls, 0);
    } finally {
      harness.repository.finishDownload();
      await sync;
      await harness.notifier.debugDrainPlayerCleanup();
      harness.notifier.dispose();
    }
  });

  test(
    'physical cleanup never outruns a non-cooperative canceled sync',
    () async {
      final harness = await _activeChessComSyncHarness(temp, db);
      final sync = harness.notifier.syncAccount(harness.account);
      await harness.repository.downloadStarted.future;

      try {
        await harness.notifier.removePlayer(harness.player.id);
        await Future<void>.delayed(const Duration(milliseconds: 8250));

        expect(
          harness.repository.sourceDeleteCalls,
          0,
          reason:
              'A cancellation timeout must not delete a PGN that an active '
              'sync can still write.',
        );
        expect(harness.repository.workspaceDeleteCalls, 0);
      } finally {
        harness.repository.finishDownload();
        await sync;
        await harness.notifier.debugDrainPlayerCleanup();
        harness.notifier.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'physical cleanup waits for a superseded non-cooperative sync scope',
    () async {
      final player = await _playerWithGeneratedChessComFile(temp);
      final account = player.account(PlayerWorkspaceSource.chesscom)!;
      final repository = _SupersededSyncWorkspaceRepository(
        root: temp,
        snapshot: PlayerWorkspaceSnapshot(
          players: <PlayerWorkspacePlayer>[player],
          selectedPlayerId: player.id,
        ),
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: repository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );
      await notifier.load();

      final firstSync = notifier.syncAccount(account);
      await repository.firstDownloadStarted.future;
      final secondSync = notifier.syncAccount(account);
      await repository.secondDownloadStarted.future;

      try {
        await notifier.removePlayer(player.id);
        repository.finishSecondDownload();
        await secondSync;
        await Future<void>.delayed(const Duration(milliseconds: 350));

        expect(
          repository.sourceDeleteCalls,
          0,
          reason:
              'The superseded scope still owns the player file until its own '
              'finally block completes.',
        );
        expect(repository.workspaceDeleteCalls, 0);
      } finally {
        repository.finishFirstDownload();
        repository.finishSecondDownload();
        await firstSync;
        await secondSync;
        await notifier.debugDrainPlayerCleanup();
        notifier.dispose();
      }

      expect(repository.sourceDeleteCalls, 1);
      expect(repository.workspaceDeleteCalls, 1);
    },
  );

  test(
    'Library folder deletion persists a tombstone and detaches cleanup',
    () async {
      final harness = await _activeChessComSyncHarness(temp, db);
      final extraPath = p.join(
        temp.path,
        'player-workspace',
        harness.player.id,
        'legacy-source.pgn',
      );
      await File(extraPath).writeAsString('[Event "Legacy"]\n\n*');
      final unregisteredPaths = <String>{};
      Future<void> unregisterPlayer(
        String _, {
        required Iterable<String> paths,
      }) async {
        unregisteredPaths.addAll(paths);
      }

      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: harness.repository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
        localDatabasePlayerUnregistrar: unregisterPlayer,
      );
      await notifier.load();
      final account =
          notifier.state.selectedPlayer!.account(
            PlayerWorkspaceSource.chesscom,
          )!;
      final sync = notifier.syncAccount(account);
      await harness.repository.downloadStarted.future;

      var visibleActionCompleted = false;
      final folderDelete = notifier.syncDeletedLibraryPlayerFolder(
        harness.player.id,
        deletedPaths: <String>[account.pgnPath!, extraPath],
      );
      folderDelete.then((_) => visibleActionCompleted = true);
      await pumpEventQueue();

      try {
        expect(visibleActionCompleted, isTrue);
        expect(notifier.state.players, isEmpty);
        expect(
          harness.repository.snapshot.pendingDeletions.map((item) => item.id),
          <String>[harness.player.id],
        );
        expect(
          harness.repository.snapshot.pendingDeletionExtraPaths[harness
              .player
              .id],
          contains(extraPath),
        );
        expect(harness.repository.sourceDeleteCalls, 0);
        expect(harness.repository.workspaceDeleteCalls, 0);
      } finally {
        harness.repository.finishDownload();
        await folderDelete;
        await sync;
        await notifier.debugDrainPlayerCleanup();
        notifier.dispose();
        harness.notifier.dispose();
      }

      expect(unregisteredPaths, contains(extraPath));
      expect(harness.repository.snapshot.pendingDeletions, isEmpty);
      expect(harness.repository.snapshot.pendingDeletionExtraPaths, isEmpty);
    },
  );

  test('load resumes cleanup for a persisted pending deletion', () async {
    final player = await _playerWithGeneratedChessComFile(temp);
    final repository = _TrackingWorkspaceRepository(
      root: temp,
      snapshot: PlayerWorkspaceSnapshot(
        pendingDeletions: <PlayerWorkspacePlayer>[player],
      ),
    );
    final notifier = PlayerWorkspaceNotifier(
      workspaceRepository: repository,
      gamebaseRepository: GamebaseRepository(Dio()),
      localRepository: LocalChessDatabaseRepository(database: () async => db),
    );

    try {
      await notifier.load();
      await notifier.debugDrainPlayerCleanup();

      expect(notifier.state.players, isEmpty);
      expect(repository.sourceDeleteCalls, 1);
      expect(repository.workspaceDeleteCalls, 1);
      expect(repository.snapshot.pendingDeletions, isEmpty);
    } finally {
      notifier.dispose();
    }
  });

  test(
    'cleanup owns the exact player folder but preserves external and sibling paths',
    () async {
      const playerId = 'pending-delete-player';
      final workspace = Directory(
        p.join(temp.path, 'player-workspace', playerId),
      );
      final siblingWorkspace = Directory(
        p.join(temp.path, 'player-workspace', 'sibling-player'),
      );
      final externalDirectory = Directory(p.join(temp.path, 'user-library'));
      await workspace.create(recursive: true);
      await siblingWorkspace.create(recursive: true);
      await externalDirectory.create(recursive: true);

      final source = File(p.join(workspace.path, 'chesscom.pgn'));
      final stale = File(p.join(workspace.path, 'stale-legacy.pgn'));
      final sibling = File(p.join(siblingWorkspace.path, 'sibling.pgn'));
      final external = File(p.join(externalDirectory.path, 'personal.pgn'));
      for (final file in <File>[source, stale, sibling, external]) {
        await file.writeAsString('[Event "Owned path test"]\n\n*');
        await _seedCachedDatabase(db, file.path);
      }

      final player = PlayerWorkspacePlayer(
        id: playerId,
        displayName: 'Pending Delete',
        createdAtMs: 1,
        accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
          PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chesscom,
            username: 'pending-delete',
            pgnPath: source.path,
            gameCount: 1,
          ),
        },
        // Simulate corrupt/legacy state pointing at a PGN the player workspace
        // does not own. Cleanup must reject it before every destructive layer.
        additionalAccounts: <PlayerWorkspaceAccount>[
          PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.manual,
            username: 'external',
            pgnPath: external.path,
            gameCount: 1,
          ),
        ],
      );
      final repository = _TrackingWorkspaceRepository(
        root: temp,
        snapshot: PlayerWorkspaceSnapshot(
          pendingDeletions: <PlayerWorkspacePlayer>[player],
        ),
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: repository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: LocalChessDatabaseRepository(database: () async => db),
      );

      try {
        await notifier.load();
        await notifier.debugDrainPlayerCleanup();

        expect(await workspace.exists(), isFalse);
        expect(await source.exists(), isFalse);
        expect(await stale.exists(), isFalse);
        expect(await sibling.exists(), isTrue);
        expect(await external.exists(), isTrue);
        expect(repository.snapshot.pendingDeletions, isEmpty);
        expect(
          await db.select(
            'SELECT path FROM local_chess_databases ORDER BY path ASC',
          ),
          <Map<String, Object?>>[
            <String, Object?>{'path': sibling.path},
            <String, Object?>{'path': external.path},
          ]..sort(
            (left, right) =>
                (left['path']! as String).compareTo(right['path']! as String),
          ),
        );
      } finally {
        notifier.dispose();
      }
    },
  );

  test('failed cleanup keeps its tombstone and retries on load', () async {
    final player = await _playerWithGeneratedChessComFile(temp);
    final repository = _TrackingWorkspaceRepository(
      root: temp,
      snapshot: PlayerWorkspaceSnapshot(
        players: <PlayerWorkspacePlayer>[player],
        selectedPlayerId: player.id,
      ),
    );
    final localRepository = _FailOnceLocalRepository(db);
    final notifier = PlayerWorkspaceNotifier(
      workspaceRepository: repository,
      gamebaseRepository: GamebaseRepository(Dio()),
      localRepository: localRepository,
    );

    try {
      await notifier.load();
      await notifier.removePlayer(player.id);
      await notifier.debugDrainPlayerCleanup();

      expect(
        repository.snapshot.pendingDeletions.map((item) => item.id),
        <String>[player.id],
      );
      expect(repository.sourceDeleteCalls, 0);

      await notifier.load();
      await notifier.debugDrainPlayerCleanup();

      expect(repository.snapshot.pendingDeletions, isEmpty);
      expect(repository.sourceDeleteCalls, 1);
      expect(repository.workspaceDeleteCalls, 1);
    } finally {
      notifier.dispose();
    }
  });

  test('failed registry removal keeps its tombstone and retries', () async {
    final player = await _playerWithGeneratedChessComFile(temp);
    final sourcePath = player.account(PlayerWorkspaceSource.chesscom)!.pgnPath!;
    await _seedCachedDatabase(db, sourcePath);
    final repository = _TrackingWorkspaceRepository(
      root: temp,
      snapshot: PlayerWorkspaceSnapshot(
        players: <PlayerWorkspacePlayer>[player],
        selectedPlayerId: player.id,
      ),
    );
    var unregisterCalls = 0;
    final localRepository = LocalChessDatabaseRepository(
      database: () async => db,
    );
    final notifier = PlayerWorkspaceNotifier(
      workspaceRepository: repository,
      gamebaseRepository: GamebaseRepository(Dio()),
      localRepository: localRepository,
      localDatabasePlayerUnregistrar: (playerId, {required paths}) async {
        unregisterCalls += 1;
        if (unregisterCalls == 1) {
          throw StateError('Injected persisted registry failure');
        }
      },
    );

    try {
      await notifier.load();
      await notifier.removePlayer(player.id);
      await notifier.debugDrainPlayerCleanup();

      expect(repository.snapshot.pendingDeletions, hasLength(1));
      expect(await File(sourcePath).exists(), isTrue);
      final source = await scanLocalChessPaths(<String>[sourcePath]);
      await expectLater(
        localRepository.persistFileNode(
          source.root.singlePlayableDatabaseInSubtree!,
          sourceLabel: 'Stale writer',
        ),
        throwsA(isA<OperationCanceledException>()),
      );

      await notifier.load();
      await notifier.debugDrainPlayerCleanup();

      expect(unregisterCalls, 2);
      expect(repository.snapshot.pendingDeletions, isEmpty);
      expect(await File(sourcePath).exists(), isFalse);
    } finally {
      notifier.dispose();
    }
  });
}

Future<
  ({
    PlayerWorkspaceNotifier notifier,
    _TrackingWorkspaceRepository repository,
    PlayerWorkspacePlayer player,
    PlayerWorkspaceAccount account,
  })
>
_activeChessComSyncHarness(Directory root, resqlite.Database db) async {
  final player = await _playerWithGeneratedChessComFile(root);
  final account = player.account(PlayerWorkspaceSource.chesscom)!;
  final repository = _TrackingWorkspaceRepository(
    root: root,
    snapshot: PlayerWorkspaceSnapshot(
      players: <PlayerWorkspacePlayer>[player],
      selectedPlayerId: player.id,
    ),
  );
  final notifier = PlayerWorkspaceNotifier(
    workspaceRepository: repository,
    gamebaseRepository: GamebaseRepository(Dio()),
    localRepository: LocalChessDatabaseRepository(database: () async => db),
  );
  await notifier.load();
  return (
    notifier: notifier,
    repository: repository,
    player: player,
    account: account,
  );
}

Future<PlayerWorkspacePlayer> _playerWithGeneratedChessComFile(
  Directory root,
) async {
  const playerId = 'pending-delete-player';
  final workspace = Directory(p.join(root.path, 'player-workspace', playerId));
  await workspace.create(recursive: true);
  final path = p.join(workspace.path, 'chesscom.pgn');
  await File(path).writeAsString('[Event "Pending delete"]\n\n*');
  return PlayerWorkspacePlayer(
    id: playerId,
    displayName: 'Pending Delete',
    createdAtMs: 1,
    accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
      PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
        source: PlayerWorkspaceSource.chesscom,
        username: 'pending-delete',
        pgnPath: path,
        gameCount: 1,
      ),
    },
  );
}

class _TrackingWorkspaceRepository extends PlayerWorkspaceRepository {
  _TrackingWorkspaceRepository({required this.root, required this.snapshot})
    : super(supportDirectory: () async => root);

  final Directory root;
  PlayerWorkspaceSnapshot snapshot;
  final downloadStarted = Completer<void>();
  final _finishDownload = Completer<void>();
  int sourceDeleteCalls = 0;
  int workspaceDeleteCalls = 0;

  void finishDownload() {
    if (!_finishDownload.isCompleted) _finishDownload.complete();
  }

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    onProgress?.call('Downloading Chess.com games...', 0.5);
    if (!downloadStarted.isCompleted) downloadStarted.complete();
    // Deliberately ignore cancellation until the external operation releases.
    // The delete pipeline must not turn its timeout into permission to remove
    // files that this operation still owns.
    await _finishDownload.future;
    cancellationToken?.throwIfCanceled();
    return const PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chesscom,
      pgn: '[Event "Downloaded"]\n\n*',
      gameCount: 1,
      replaceExistingSource: true,
    );
  }

  @override
  Future<bool> deleteSourcePgnFile(String path) async {
    sourceDeleteCalls += 1;
    final file = File(path);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }

  @override
  Future<bool> deletePlayerWorkspaceDirectory(String playerId) async {
    workspaceDeleteCalls += 1;
    final directory = Directory(
      p.join(root.path, 'player-workspace', playerId),
    );
    if (!await directory.exists()) return false;
    await directory.delete(recursive: true);
    return true;
  }
}

class _FailOnceLocalRepository extends LocalChessDatabaseRepository {
  _FailOnceLocalRepository(resqlite.Database db)
    : super(database: () async => db);

  var _shouldFail = true;

  @override
  Future<int> markCachedSourcesDeleted(Iterable<String> sourcePaths) {
    if (_shouldFail) {
      _shouldFail = false;
      return Future<int>.error(StateError('Injected cleanup failure'));
    }
    return super.markCachedSourcesDeleted(sourcePaths);
  }
}

class _SupersededSyncWorkspaceRepository extends _TrackingWorkspaceRepository {
  _SupersededSyncWorkspaceRepository({
    required super.root,
    required super.snapshot,
  });

  final firstDownloadStarted = Completer<void>();
  final secondDownloadStarted = Completer<void>();
  final _finishFirstDownload = Completer<void>();
  final _finishSecondDownload = Completer<void>();
  var _downloadCalls = 0;

  void finishFirstDownload() {
    if (!_finishFirstDownload.isCompleted) _finishFirstDownload.complete();
  }

  void finishSecondDownload() {
    if (!_finishSecondDownload.isCompleted) _finishSecondDownload.complete();
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    _downloadCalls += 1;
    onProgress?.call('Downloading Chess.com games...', 0.5);
    if (_downloadCalls == 1) {
      firstDownloadStarted.complete();
      await _finishFirstDownload.future;
    } else {
      secondDownloadStarted.complete();
      await _finishSecondDownload.future;
    }
    cancellationToken?.throwIfCanceled();
    return const PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chesscom,
      pgn: '[Event "Downloaded"]\n\n*',
      gameCount: 1,
      replaceExistingSource: true,
    );
  }
}

Future<void> _seedCachedDatabase(
  resqlite.Database db,
  String databasePath,
) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.execute(
    '''
    INSERT INTO local_chess_databases(
      id, path, label, extension, size_bytes, modified_at_ms, file_count,
      game_count, position_count, imported_at_ms, updated_at_ms
    ) VALUES (?, ?, 'Cleanup ownership', '.pgn', 1, ?, 1, 0, 0, ?, ?)
    ''',
    <Object?>[databasePath, databasePath, now, now, now],
  );
}
