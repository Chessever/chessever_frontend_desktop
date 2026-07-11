import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';

void main() {
  test(
    'deleting a cache-heavy player keeps the UI event loop responsive',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'chessever-player-delete-heartbeat-',
      );
      final databasePath = p.join(temp.path, 'local_chess.db');
      final db = await resqlite.Database.open(databasePath);
      await db.execute('PRAGMA foreign_keys=ON');
      await db.execute('PRAGMA journal_mode=WAL');
      await createLocalChessResqliteDatabaseSchema(db);

      const playerId = 'cache-heavy-player';
      final workspaceDirectory = Directory(
        p.join(temp.path, 'player-workspace', playerId),
      );
      final sourcePaths = <String>[
        p.join(workspaceDirectory.path, 'chessever.pgn'),
        p.join(workspaceDirectory.path, 'lichess.pgn'),
        p.join(workspaceDirectory.path, 'combined.pgn'),
      ];
      final player = PlayerWorkspacePlayer(
        id: playerId,
        displayName: 'Cache Heavy Player',
        createdAtMs: 1,
        accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
          PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chessever,
            username: 'Cache Heavy Player',
            pgnPath: sourcePaths[0],
            gameCount: 1,
          ),
          PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'cache-heavy',
            pgnPath: sourcePaths[1],
            gameCount: 1,
          ),
        },
        combinedPgnPath: sourcePaths[2],
        combinedGameCount: 1,
      );
      final workspaceRepository = _StoredSnapshotWorkspaceRepository(
        temp,
        PlayerWorkspaceSnapshot(players: <PlayerWorkspacePlayer>[player]),
      );
      final localRepository = LocalChessDatabaseRepository(
        database: () async => db,
        purgeDatabase: () async {
          final connection = await resqlite.Database.open(databasePath);
          await connection.execute('PRAGMA foreign_keys=ON');
          await connection.execute('PRAGMA journal_mode=WAL');
          return connection;
        },
      );
      final notifier = PlayerWorkspaceNotifier(
        workspaceRepository: workspaceRepository,
        gamebaseRepository: GamebaseRepository(Dio()),
        localRepository: localRepository,
      );

      try {
        await notifier.load();
        await workspaceDirectory.create(recursive: true);
        for (final sourcePath in sourcePaths) {
          await File(sourcePath).writeAsString('[Event "Delete"]\n\n*');
          await _seedDerivedCache(
            db,
            databasePath: sourcePath,
            rowCount: 40000,
          );
        }

        final stopwatch = Stopwatch()..start();
        var lastTickUs = stopwatch.elapsedMicroseconds;
        var maxTickGapUs = 0;
        var tickCount = 0;
        var measureHeartbeat = false;
        final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
          final nowUs = stopwatch.elapsedMicroseconds;
          if (measureHeartbeat) {
            final gapUs = nowUs - lastTickUs;
            if (gapUs > maxTickGapUs) maxTickGapUs = gapUs;
            tickCount++;
          }
          lastTickUs = nowUs;
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));

        measureHeartbeat = true;
        lastTickUs = stopwatch.elapsedMicroseconds;
        final visibleAction = Stopwatch()..start();
        await notifier.removePlayer(playerId);
        visibleAction.stop();
        final cleanup = Stopwatch()..start();
        await notifier.debugDrainPlayerCleanup();
        cleanup.stop();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        measureHeartbeat = false;
        heartbeat.cancel();

        // Keep the feedback-loop signal visible in CI/debug output even when
        // the threshold is green.
        // ignore: avoid_print
        print(
          'PLAYER_DELETE_HEARTBEAT '
          'visibleActionMs=${visibleAction.elapsedMilliseconds} '
          'cleanupMs=${cleanup.elapsedMilliseconds} '
          'ticks=$tickCount '
          'maxGapMs=${(maxTickGapUs / 1000).toStringAsFixed(1)}',
        );

        expect(notifier.state.players, isEmpty);
        expect(workspaceRepository.snapshot.players, isEmpty);
        expect(
          visibleAction.elapsed,
          lessThan(const Duration(milliseconds: 200)),
          reason: 'The trash action itself must return within one <5 FPS gap.',
        );
        expect(
          cleanup.elapsed,
          greaterThan(const Duration(milliseconds: 100)),
          reason: 'The fixture must exercise sustained background cleanup.',
        );
        expect(tickCount, greaterThan(10));
        expect(
          maxTickGapUs,
          lessThan(180000),
          reason:
              'Background player cleanup must never starve the UI isolate '
              'toward <5 FPS. Actual max heartbeat gap: '
              '${(maxTickGapUs / 1000).toStringAsFixed(1)} ms; cleanup: '
              '${cleanup.elapsedMilliseconds} ms.',
        );
        expect(await _count(db, 'local_chess_databases'), 0);
        expect(await _count(db, 'local_chess_tree_nodes'), 0);
        expect(await _count(db, 'local_chess_tree_moves'), 0);
        expect(await _count(db, 'local_chess_position_games'), 0);
      } finally {
        notifier.dispose();
        await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
        await db.close();
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _StoredSnapshotWorkspaceRepository extends PlayerWorkspaceRepository {
  _StoredSnapshotWorkspaceRepository(Directory root, this.snapshot)
    : super(supportDirectory: () async => root);

  PlayerWorkspaceSnapshot snapshot;

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }
}

Future<void> _seedDerivedCache(
  resqlite.Database db, {
  required String databasePath,
  required int rowCount,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final gameId = '$databasePath#game';
  await db.execute(
    '''
    INSERT INTO local_chess_databases(
      id, path, label, extension, size_bytes, modified_at_ms, file_count,
      game_count, position_count, tree_max_ply, imported_at_ms, updated_at_ms
    ) VALUES (?, ?, 'Delete stress', '.pgn', 1, ?, 1, 1, ?, 50, ?, ?)
    ''',
    <Object?>[databasePath, databasePath, now, rowCount, now, now],
  );
  await db.execute(
    '''
    INSERT INTO local_chess_games(
      id, database_id, raw_pgn, source_path, source_relative_path, file_name,
      index_in_file, file_game_count
    ) VALUES (?, ?, '*', ?, ?, ?, 0, 1)
    ''',
    <Object?>[
      gameId,
      databasePath,
      databasePath,
      p.basename(databasePath),
      p.basename(databasePath),
    ],
  );
  await db.execute(
    '''
    WITH RECURSIVE seq(i) AS (
      VALUES(0)
      UNION ALL
      SELECT i + 1 FROM seq WHERE i + 1 < ?
    )
    INSERT INTO local_chess_tree_nodes(database_id, node_id, fen_key, ply)
    SELECT ?, i, ? || i, i % 51 FROM seq
    ''',
    <Object?>[rowCount, databasePath, '$databasePath#fen-'],
  );
  await db.execute(
    '''
    WITH RECURSIVE seq(i) AS (
      VALUES(0)
      UNION ALL
      SELECT i + 1 FROM seq WHERE i + 1 < ?
    )
    INSERT INTO local_chess_tree_moves(
      database_id, node_id, uci, child_node_id, total
    )
    SELECT ?, i, 'e2e4', i + 1, 1 FROM seq
    ''',
    <Object?>[rowCount - 1, databasePath],
  );
  await db.execute(
    '''
    WITH RECURSIVE seq(i) AS (
      VALUES(0)
      UNION ALL
      SELECT i + 1 FROM seq WHERE i + 1 < ?
    )
    INSERT INTO local_chess_position_games(
      database_id, fen_key, fen, game_id, ply, next_uci
    )
    SELECT ?, ? || i, '8/8/8/8/8/8/8/8 w - -', ?, i % 51, 'e2e4'
    FROM seq
    ''',
    <Object?>[rowCount, databasePath, '$databasePath#position-', gameId],
  );
}

Future<int> _count(resqlite.Database db, String table) async {
  final rows = await db.select('SELECT COUNT(*) AS count FROM $table');
  return (rows.single['count'] as num).toInt();
}
