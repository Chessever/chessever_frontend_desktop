import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/player_workspace_pane.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Players trash flow avoids sustained jank while Chess.com sync completes across lifecycle resume',
    (tester) async {
      final phaseWatch = Stopwatch()..start();
      final temp = await Directory.systemTemp.createTemp(
        'chessever-player-pane-delete-heartbeat-',
      );
      final databasePath = p.join(temp.path, 'local_chess.db');
      final db = await resqlite.Database.open(databasePath);
      await db.execute('PRAGMA foreign_keys=ON');
      await db.execute('PRAGMA journal_mode=WAL');
      await createLocalChessResqliteDatabaseSchema(db);
      // ignore: avoid_print
      print('[DELETE_PANE_LOOP] schema ${phaseWatch.elapsedMilliseconds}ms');

      const targetId = 'delete-target';
      const targetName = 'Delete Target';
      // Large enough to keep detached cleanup active across many frames while
      // remaining deterministic on slower Windows CI machines.
      const cacheRowsPerSource = 20000;
      final appDatabase = _MemoryAppDatabase();
      final workspaceRepository = _ConcurrentChessComWorkspaceRepository(
        appDatabase: appDatabase,
        root: temp,
        chessComPgn: _chessComDownloadPgn(4000),
      );
      final sourcePaths = <String>[
        await workspaceRepository.sourcePgnPath(
          playerId: targetId,
          playerName: targetName,
          source: PlayerWorkspaceSource.chessever,
        ),
        await workspaceRepository.sourcePgnPath(
          playerId: targetId,
          playerName: targetName,
          source: PlayerWorkspaceSource.lichess,
          username: 'delete-target-lichess',
        ),
        await workspaceRepository.sourcePgnPath(
          playerId: targetId,
          playerName: targetName,
          source: PlayerWorkspaceSource.chesscom,
          username: 'delete-target-chesscom',
        ),
      ];
      final target = PlayerWorkspacePlayer(
        id: targetId,
        displayName: targetName,
        createdAtMs: 100000,
        accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
          PlayerWorkspaceSource.chessever: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chessever,
            username: targetName,
            pgnPath: sourcePaths[0],
            gameCount: cacheRowsPerSource,
          ),
          PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.lichess,
            username: 'delete-target-lichess',
            pgnPath: sourcePaths[1],
            gameCount: cacheRowsPerSource,
          ),
          PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
            source: PlayerWorkspaceSource.chesscom,
            username: 'delete-target-chesscom',
            pgnPath: sourcePaths[2],
            gameCount: cacheRowsPerSource,
          ),
        },
      );
      final players = <PlayerWorkspacePlayer>[
        target,
        for (var index = 0; index < 24; index++)
          PlayerWorkspacePlayer(
            id: 'remaining-$index',
            displayName: 'Remaining Player ${index + 1}',
            createdAtMs: 99999 - index,
          ),
      ];
      await workspaceRepository.saveSnapshot(
        PlayerWorkspaceSnapshot(players: players, selectedPlayerId: targetId),
      );
      // ignore: avoid_print
      print('[DELETE_PANE_LOOP] snapshot ${phaseWatch.elapsedMilliseconds}ms');

      for (final sourcePath in sourcePaths) {
        await File(sourcePath).writeAsString('[Event "Delete"]\n\n*');
        await _seedDerivedCache(
          db,
          databasePath: sourcePath,
          rowCount: cacheRowsPerSource,
          positionRowCount: 1,
        );
      }
      // ignore: avoid_print
      print('[DELETE_PANE_LOOP] seeded ${phaseWatch.elapsedMilliseconds}ms');

      final registry = LocalLibraryRegistryNotifier(appDatabase);
      await registry.registerAll(
        sourcePaths,
        metadataByPath: <String, LocalLibraryEntryMetadata>{
          for (final path in sourcePaths)
            path: LocalLibraryEntryMetadata.playerWorkspace(
              playerId: targetId,
              playerName: targetName,
            ),
        },
      );
      // ignore: avoid_print
      print('[DELETE_PANE_LOOP] registry ${phaseWatch.elapsedMilliseconds}ms');
      final survivingRegistryPath = p.join(
        temp.path,
        'player-workspace',
        'remaining-1',
        'manual.pgn',
      );
      await registry.registerAll(
        <String>[survivingRegistryPath],
        metadataByPath: <String, LocalLibraryEntryMetadata>{
          survivingRegistryPath: LocalLibraryEntryMetadata.playerWorkspace(
            playerId: 'remaining-1',
            playerName: 'Remaining Player 2',
          ),
        },
      );

      final localRepository = _ObservedLocalChessDatabaseRepository(
        database: () async => db,
        purgeDatabase: () async {
          final connection = await resqlite.Database.open(databasePath);
          await connection.execute('PRAGMA foreign_keys=ON');
          await connection.execute('PRAGMA journal_mode=WAL');
          return connection;
        },
      );
      final localLibrary = LocalChessLibraryNotifier(
        registry: registry,
        localDatabaseRepository: localRepository,
      );
      final gamebaseRepository = GamebaseRepository(Dio());
      final probe = _FrameHeartbeatProbe();

      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() async {
        probe.stop();
        await tester.binding.setSurfaceSize(null);
        localLibrary.dispose();
        registry.dispose();
        await LocalChessDatabaseRepository.debugDrainBackgroundPurgeQueue();
        await db.close();
        if (await temp.exists()) await temp.delete(recursive: true);
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            playerWorkspaceRepositoryProvider.overrideWithValue(
              workspaceRepository,
            ),
            gamebaseRepositoryProvider.overrideWithValue(gamebaseRepository),
            localChessDatabaseRepositoryProvider.overrideWithValue(
              localRepository,
            ),
            localLibraryRegistryProvider.overrideWith((ref) => registry),
            localChessLibraryProvider.overrideWith((ref) => localLibrary),
            playerWorkspaceProvider.overrideWith(
              (ref) => PlayerWorkspaceNotifier(
                workspaceRepository: workspaceRepository,
                gamebaseRepository: gamebaseRepository,
                localRepository: localRepository,
                localDatabaseRegistrar:
                    (paths, {required metadataByPath}) => registry.registerAll(
                      paths,
                      metadataByPath: metadataByPath,
                    ),
                localDatabaseUnregistrar: registry.unregister,
                localDatabasePlayerUnregistrar:
                    (playerId, {required paths}) => registry
                        .unregisterPlayerWorkspace(playerId, paths: paths),
              ),
            ),
          ],
          child: MaterialApp(
            home: _ResponsiveTestHost(
              child: Stack(
                children: <Widget>[
                  const Positioned.fill(child: PlayerWorkspacePane()),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _FrameHeartbeat(controller: probe),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // ignore: avoid_print
      print('[DELETE_PANE_LOOP] pumped ${phaseWatch.elapsedMilliseconds}ms');

      final initialWait = Stopwatch()..start();
      while (find.text(targetName).evaluate().isEmpty &&
          initialWait.elapsed < const Duration(seconds: 5)) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text(targetName), findsOneWidget);
      // ignore: avoid_print
      print('[DELETE_PANE_LOOP] visible ${phaseWatch.elapsedMilliseconds}ms');
      expect(find.text('Remaining Player 1'), findsOneWidget);
      expect(registry.state.entries, hasLength(4));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerWorkspacePane)),
      );
      final notifier = container.read(playerWorkspaceProvider.notifier);
      expect(
        container.read(playerWorkspaceProvider).selectedPlayerId,
        targetId,
      );
      final chessComAccount =
          container
              .read(playerWorkspaceProvider)
              .selectedPlayer!
              .account(PlayerWorkspaceSource.chesscom)!;
      Object? syncError;
      var syncDone = false;
      final syncFuture = notifier.syncAccount(chessComAccount);
      unawaited(
        syncFuture.then<void>(
          (_) => syncDone = true,
          onError: (Object error, StackTrace _) {
            syncError = error;
            syncDone = true;
          },
        ),
      );
      await workspaceRepository.downloadStarted.future.timeout(
        const Duration(seconds: 5),
      );
      final scenarioWatch = Stopwatch()..start();
      probe.start();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      // Windows/macOS do not render while the app is backgrounded. Keep the
      // probe alive across the lifecycle transition, but exclude that expected
      // no-frame interval from active-frame cadence.
      probe.pauseForInactive();
      await tester.pump(const Duration(milliseconds: 80));
      workspaceRepository.finishDownload();
      await Future<void>.delayed(const Duration(milliseconds: 160));
      // Start the post-resume clock before dispatching the lifecycle callback,
      // so synchronous resume/sync work is included in the first frame gap.
      probe.resumeFromInactive();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        notifier.state.operations.values.any(
          (operation) => operation.source == PlayerWorkspaceSource.chesscom,
        ),
        isTrue,
      );

      final targetRow = find.ancestor(
        of: find.text(targetName),
        matching: find.byType(AnimatedContainer),
      );
      expect(targetRow, findsOneWidget);
      final trashButton = find.descendant(
        of: targetRow,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DesktopDialogIconButton &&
              widget.tooltip == 'Remove player',
        ),
      );
      expect(trashButton, findsOneWidget);
      await tester.tap(trashButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Remove $targetName'), findsOneWidget);
      // ignore: avoid_print
      print('[DELETE_PANE_LOOP] dialog ${phaseWatch.elapsedMilliseconds}ms');
      final confirmButton = find.widgetWithText(DesktopDialogButton, 'Remove');
      expect(confirmButton, findsOneWidget);

      await tester.tap(confirmButton);
      // Keep measuring the same heartbeat that began before the app went
      // inactive. This covers the exact Chrome-return window, replacement
      // sync cancellation, dialog interaction, and detached cleanup.
      var cleanupDone = false;
      Future<void>? cleanup;
      final cleanupWait = Stopwatch()..start();
      while ((!cleanupDone || !syncDone) &&
          cleanupWait.elapsed < const Duration(seconds: 20)) {
        await tester.pump(const Duration(milliseconds: 16));
        if (localRepository.cleanupStarted.isCompleted && cleanup == null) {
          cleanup = notifier.debugDrainPlayerCleanup();
          unawaited(cleanup.whenComplete(() => cleanupDone = true));
        }
      }
      expect(
        localRepository.cleanupStarted.isCompleted,
        isTrue,
        reason: 'The actual trash flow must reach generated-data cleanup.',
      );
      expect(
        cleanupDone,
        isTrue,
        reason: 'The cache-heavy fixture must complete within the test budget.',
      );
      expect(syncDone, isTrue);
      expect(syncError, isNull);

      for (var index = 0; index < 20; index++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      probe.stop();
      scenarioWatch.stop();

      // ignore: avoid_print
      print(
        'PLAYER_DELETE_PANE_HEARTBEAT '
        'scenarioMs=${scenarioWatch.elapsedMilliseconds} '
        'cleanupMs=${cleanupWait.elapsedMilliseconds} '
        'frames=${probe.frameCount} '
        'averageFrameMs='
        '${probe.averageGapMilliseconds.toStringAsFixed(1)} '
        'lifecycle=${probe.lifecycleStates.map((state) => state.name).join(',')} '
        'maxGapMs=${probe.maxGapMilliseconds.toStringAsFixed(1)}',
      );

      expect(find.text(targetName), findsNothing);
      expect(find.text('Remaining Player 1'), findsOneWidget);
      final state = container.read(playerWorkspaceProvider);
      expect(state.players, hasLength(24));
      expect(state.selectedPlayerId, isNull);
      expect(registry.state.entries.map((entry) => entry.path), <String>[
        survivingRegistryPath,
      ]);
      for (final sourcePath in sourcePaths) {
        expect(await File(sourcePath).exists(), isFalse);
      }
      expect(await _count(db, 'local_chess_databases'), 0);
      expect(await _count(db, 'local_chess_tree_nodes'), 0);
      expect(await _count(db, 'local_chess_tree_moves'), 0);
      expect(await _count(db, 'local_chess_position_games'), 0);
      expect(
        probe.lifecycleStates,
        containsAllInOrder(<AppLifecycleState>[
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]),
      );
      expect(probe.frameCount, greaterThan(20));
      expect(
        probe.averageGapMilliseconds,
        lessThan(50),
        reason:
            'Detached cleanup must sustain a responsive frame cadence instead '
            'of degrading toward the reported <5 FPS state.',
      );
      expect(
        probe.maxGapMilliseconds,
        lessThan(350),
        reason:
            'The real Players trash flow must not produce a sustained freeze. '
            'Actual maximum frame gap: '
            '${probe.maxGapMilliseconds.toStringAsFixed(1)} ms.',
      );
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

class _ResponsiveTestHost extends StatelessWidget {
  const _ResponsiveTestHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    ResponsiveHelper.init(context);
    return child;
  }
}

class _FrameHeartbeatProbe {
  bool recording = false;
  int frameCount = 0;
  final List<AppLifecycleState> lifecycleStates = <AppLifecycleState>[];
  int _lastFrameUs = 0;
  int _maxGapUs = 0;
  int _totalGapUs = 0;
  final Stopwatch _stopwatch = Stopwatch()..start();

  double get maxGapMilliseconds => _maxGapUs / 1000;
  double get averageGapMilliseconds =>
      frameCount == 0 ? 0 : _totalGapUs / frameCount / 1000;

  void start() {
    frameCount = 0;
    _maxGapUs = 0;
    _totalGapUs = 0;
    _lastFrameUs = _stopwatch.elapsedMicroseconds;
    recording = true;
  }

  void stop() => recording = false;

  void pauseForInactive() => recording = false;

  void resumeFromInactive() {
    _lastFrameUs = _stopwatch.elapsedMicroseconds;
    recording = true;
  }

  void recordFrame() {
    if (!recording) return;
    final nowUs = _stopwatch.elapsedMicroseconds;
    final gapUs = nowUs - _lastFrameUs;
    if (gapUs > _maxGapUs) _maxGapUs = gapUs;
    _totalGapUs += gapUs;
    _lastFrameUs = nowUs;
    frameCount++;
  }
}

class _FrameHeartbeat extends StatefulWidget {
  const _FrameHeartbeat({required this.controller});

  final _FrameHeartbeatProbe controller;

  @override
  State<_FrameHeartbeat> createState() => _FrameHeartbeatState();
}

class _FrameHeartbeatState extends State<_FrameHeartbeat>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.lifecycleStates.add(state);
  }

  void _onFrame(Duration _) {
    if (!mounted) return;
    widget.controller.recordFrame();
    SchedulerBinding.instance.scheduleFrame();
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _ConcurrentChessComWorkspaceRepository extends PlayerWorkspaceRepository {
  _ConcurrentChessComWorkspaceRepository({
    required AppDatabase appDatabase,
    required Directory root,
    required String chessComPgn,
  }) : _chessComPgn = chessComPgn,
       super(appDatabase: appDatabase, supportDirectory: () async => root);

  final String _chessComPgn;
  final Completer<void> downloadStarted = Completer<void>();
  final Completer<void> _finishDownload = Completer<void>();

  void finishDownload() {
    if (!_finishDownload.isCompleted) _finishDownload.complete();
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    bool forceRefresh = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    onProgress?.call(
      'Chess.com: downloading 1 monthly archive; 0 games received...',
      0.35,
    );
    if (!downloadStarted.isCompleted) downloadStarted.complete();
    if (cancellationToken == null) {
      await _finishDownload.future;
    } else {
      await Future.any<void>(<Future<void>>[
        _finishDownload.future,
        cancellationToken.whenCanceled.then((_) {
          throw const OperationCanceledException();
        }),
      ]);
    }
    cancellationToken?.throwIfCanceled();
    onProgress?.call('Chess.com: 1/1 archives done; 4000 games received...', 1);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chesscom,
      pgn: _chessComPgn,
      gameCount: 4000,
      replaceExistingSource: true,
    );
  }
}

class _ObservedLocalChessDatabaseRepository
    extends LocalChessDatabaseRepository {
  _ObservedLocalChessDatabaseRepository({
    required super.database,
    required super.purgeDatabase,
  });

  final Completer<void> cleanupStarted = Completer<void>();

  @override
  Future<int> deleteCachedSourcesAwaitingPurge({
    required Iterable<String> sourcePaths,
    int batchSize = 4096,
    bool cleanupOrphanMetadata = false,
    bool checkpoint = false,
    void Function(LocalChessScanProgress progress)? onProgress,
  }) {
    if (!cleanupStarted.isCompleted) cleanupStarted.complete();
    return super.deleteCachedSourcesAwaitingPurge(
      sourcePaths: sourcePaths,
      batchSize: batchSize,
      cleanupOrphanMetadata: cleanupOrphanMetadata,
      checkpoint: checkpoint,
      onProgress: onProgress,
    );
  }
}

class _MemoryAppDatabase implements AppDatabase {
  final Map<String, Object?> _values = <String, Object?>{};

  @override
  Future<T?> getJson<T>(String key) async => _values[key] as T?;

  @override
  Future<void> setJson(String key, Object value) async {
    _values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _chessComDownloadPgn(int gameCount) {
  final buffer = StringBuffer();
  for (var index = 0; index < gameCount; index++) {
    buffer
      ..writeln('[Event "Concurrent Chess.com import $index"]')
      ..writeln('[Site "https://www.chess.com/game/live/$index"]')
      ..writeln('[Date "2026.07.11"]')
      ..writeln('[Round "${index + 1}"]')
      ..writeln('[White "delete-target-chesscom"]')
      ..writeln('[Black "Opponent $index"]')
      ..writeln('[TimeControl "300+0"]')
      ..writeln('[Result "1-0"]')
      ..writeln()
      ..writeln('1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0')
      ..writeln();
  }
  return buffer.toString();
}

Future<void> _seedDerivedCache(
  resqlite.Database db, {
  required String databasePath,
  required int rowCount,
  int? positionRowCount,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final gameId = '$databasePath#game';
  final positions = positionRowCount ?? rowCount;
  await db.execute(
    '''
    INSERT INTO local_chess_databases(
      id, path, label, extension, size_bytes, modified_at_ms, file_count,
      game_count, position_count, tree_max_ply, imported_at_ms, updated_at_ms
    ) VALUES (?, ?, 'Delete stress', '.pgn', 1, ?, 1, 1, ?, 50, ?, ?)
    ''',
    <Object?>[databasePath, databasePath, now, positions, now, now],
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
    <Object?>[positions, databasePath, '$databasePath#position-', gameId],
  );
}

Future<int> _count(resqlite.Database db, String table) async {
  final rows = await db.select('SELECT COUNT(*) AS count FROM $table');
  return (rows.single['count'] as num).toInt();
}
