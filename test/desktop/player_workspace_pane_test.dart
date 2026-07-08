import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/player_workspace_pane.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('connects a Lichess account without framework exceptions', (
    tester,
  ) async {
    await _expectOnlineAccountConnects(
      tester,
      sourceButtonIndex: 1,
      username: 'DrNykterstein',
    );
  });

  testWidgets('connects a Chess.com account without framework exceptions', (
    tester,
  ) async {
    await _expectOnlineAccountConnects(
      tester,
      sourceButtonIndex: 2,
      username: 'Hikaru',
    );
  });

  testWidgets('shows determinate Lichess download progress while syncing', (
    tester,
  ) async {
    await _expectOnlineDownloadShowsProgress(
      tester,
      sourceButtonIndex: 1,
      username: 'DrNykterstein',
      expectedProgressMessage: 'Receiving Lichess games: 21 of about 42...',
    );
  });

  testWidgets('shows determinate Chess.com download progress while syncing', (
    tester,
  ) async {
    await _expectOnlineDownloadShowsProgress(
      tester,
      sourceButtonIndex: 2,
      username: 'Hikaru',
      expectedProgressMessage:
          'Chess.com: 1/2 archives done; 42 games received...',
    );
  });

  testWidgets('shows persisted tree actions for multiple player sources', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('chessever-player-pane-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final lichessPath = '${temp.path}/lichess.pgn';
    final chessComPath = '${temp.path}/chesscom.pgn';
    File(lichessPath).writeAsStringSync(_paneTestPgn('lichess_user'));
    File(chessComPath).writeAsStringSync(_paneTestPgn('chesscom_user'));

    final repository = _PaneFakePlayerWorkspaceRepository(
      snapshot: PlayerWorkspaceSnapshot(
        players: [
          PlayerWorkspacePlayer(
            id: 'player-1',
            displayName: 'Prep Target',
            createdAtMs: 1,
            accounts: {
              PlayerWorkspaceSource.lichess: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.lichess,
                username: 'lichess_user',
                pgnPath: lichessPath,
                gameCount: 2,
              ),
              PlayerWorkspaceSource.chesscom: PlayerWorkspaceAccount(
                source: PlayerWorkspaceSource.chesscom,
                username: 'chesscom_user',
                pgnPath: chessComPath,
                gameCount: 3,
              ),
            },
          ),
        ],
      ),
    );
    final localRepository = _PaneFakeLocalChessDatabaseRepository({
      lichessPath: _paneTreeIndex(path: lichessPath, gameCount: 2),
      chessComPath: _paneTreeIndex(path: chessComPath, gameCount: 3),
    });

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerWorkspaceRepositoryProvider.overrideWithValue(repository),
          localChessDatabaseRepositoryProvider.overrideWithValue(
            localRepository,
          ),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(
              localDatabaseRepository: localRepository,
            ),
          ),
        ],
        child: const MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 800,
            child: PlayerWorkspacePane(),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.tap(find.text('Prep Target').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('Build Tree').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(find.text('Opening trees'), findsOneWidget);
    expect(find.text('Tree'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _expectOnlineAccountConnects(
  WidgetTester tester, {
  required int sourceButtonIndex,
  required String username,
}) async {
  final repository = _PaneFakePlayerWorkspaceRepository();
  await _pumpAndConnectOnlineAccount(
    tester,
    repository: repository,
    sourceButtonIndex: sourceButtonIndex,
    username: username,
  );

  expect(find.text(username), findsWidgets);
  expect(tester.takeException(), isNull);
}

Future<void> _expectOnlineDownloadShowsProgress(
  WidgetTester tester, {
  required int sourceButtonIndex,
  required String username,
  required String expectedProgressMessage,
}) async {
  final repository =
      _PaneFakePlayerWorkspaceRepository()..holdNextOnlineDownload();
  await _pumpAndConnectOnlineAccount(
    tester,
    repository: repository,
    sourceButtonIndex: sourceButtonIndex,
    username: username,
  );

  await tester.tap(find.text('Download games').first);
  await tester.pump(const Duration(milliseconds: 250));
  await repository.onlineDownloadStarted.future.timeout(
    const Duration(seconds: 5),
  );
  await tester.pump();

  expect(find.text(expectedProgressMessage), findsWidgets);
  expect(find.text('23%'), findsWidgets);
  expect(tester.takeException(), isNull);

  repository.finishOnlineDownload();
  await repository.onlineImportFinished.future.timeout(
    const Duration(seconds: 5),
  );
  await tester.pump(const Duration(milliseconds: 250));
  expect(tester.takeException(), isNull);
}

Future<void> _pumpAndConnectOnlineAccount(
  WidgetTester tester, {
  required _PaneFakePlayerWorkspaceRepository repository,
  required int sourceButtonIndex,
  required String username,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerWorkspaceRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(
        home: SizedBox(width: 1200, height: 800, child: PlayerWorkspacePane()),
      ),
    ),
  );

  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(find.text('Prep Target'), findsOneWidget);

  await tester.tap(find.text('Prep Target').first);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);

  await tester.tap(find.text('Add account').at(sourceButtonIndex));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);

  await tester.enterText(find.byType(TextField), username);
  await tester.pump();
  expect(tester.takeException(), isNull);

  await tester.tap(find.text('Add').last);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);

  await tester.tap(find.text('Add 1 username'));
  await tester.pumpAndSettle();
}

class _PaneFakePlayerWorkspaceRepository extends PlayerWorkspaceRepository {
  _PaneFakePlayerWorkspaceRepository({PlayerWorkspaceSnapshot? snapshot})
    : snapshot =
          snapshot ??
          const PlayerWorkspaceSnapshot(
            players: [
              PlayerWorkspacePlayer(
                id: 'manual-1',
                displayName: 'Prep Target',
                createdAtMs: 1,
              ),
            ],
          );

  PlayerWorkspaceSnapshot snapshot;
  Completer<void> onlineDownloadStarted = Completer<void>();
  Completer<void> onlineImportFinished = Completer<void>();
  Completer<void>? _finishOnlineDownload;

  void holdNextOnlineDownload() {
    onlineDownloadStarted = Completer<void>();
    onlineImportFinished = Completer<void>();
    _finishOnlineDownload = Completer<void>();
  }

  void finishOnlineDownload() {
    _finishOnlineDownload?.complete();
    _finishOnlineDownload = null;
  }

  @override
  Future<PlayerWorkspaceSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    this.snapshot = snapshot;
  }

  @override
  Future<PlayerWorkspaceAccount> fetchLichessAccount(String username) async {
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.lichess,
      username: username.trim(),
      displayName: username.trim(),
      availableGameCount: 42,
      ratings: const {'Blitz': 3200},
    );
  }

  @override
  Future<PlayerWorkspaceAccount> fetchChessComAccount(String username) async {
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.chesscom,
      username: username.trim(),
      displayName: username.trim(),
      availableGameCount: 84,
      ratings: const {'Blitz': 3300},
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) {
    expect(expectedGameCount, 42);
    return _downloadOnlineGames(
      source: PlayerWorkspaceSource.lichess,
      message: 'Receiving Lichess games: 21 of about 42...',
      username: username,
      onProgress: onProgress,
    );
  }

  @override
  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) {
    return _downloadOnlineGames(
      source: PlayerWorkspaceSource.chesscom,
      message: 'Chess.com: 1/2 archives done; 42 games received...',
      username: username,
      onProgress: onProgress,
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> _downloadOnlineGames({
    required PlayerWorkspaceSource source,
    required String message,
    required String username,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    onProgress?.call(message, 0.5);
    if (!onlineDownloadStarted.isCompleted) {
      onlineDownloadStarted.complete();
    }
    final completer = _finishOnlineDownload;
    if (completer != null) await completer.future;
    return PlayerWorkspaceDownloadedPgn(
      source: source,
      pgn: _paneTestPgn(username),
      gameCount: 1,
    );
  }

  @override
  Future<String> sourcePgnPath({
    required String playerId,
    String? playerName,
    String? fideId,
    required PlayerWorkspaceSource source,
    String? username,
  }) async {
    return '/tmp/${source.storageKey}-${username ?? 'source'}.pgn';
  }

  @override
  Future<PlayerWorkspaceImportResult> mergeIntoLocalDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String path,
    required String sourceLabel,
    required String pgn,
    required Iterable<String> playerAliases,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    onProgress?.call('Importing $sourceLabel...', 0.75);
    return PlayerWorkspaceImportResult(
      path: path,
      stats: const PlayerWorkspaceImportStats(gameCount: 1, newGameCount: 1),
    );
  }

  @override
  Future<PlayerWorkspaceImportResult> rebuildCombinedDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String playerId,
    required String playerName,
    String? playerFideId,
    required Iterable<String> sourcePaths,
    required Iterable<String> playerAliases,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    onProgress?.call('Combining and deduplicating games...', 1);
    if (!onlineImportFinished.isCompleted) {
      onlineImportFinished.complete();
    }
    return const PlayerWorkspaceImportResult(
      path: '/tmp/combined.pgn',
      stats: PlayerWorkspaceImportStats(gameCount: 1),
    );
  }
}

class _PaneFakeLocalChessDatabaseRepository
    extends LocalChessDatabaseRepository {
  _PaneFakeLocalChessDatabaseRepository(this.indexes)
    : super(database: () async => throw StateError('unused test database'));

  final Map<String, PlayerOpeningTreeIndex> indexes;

  @override
  Future<LocalChessFileNode?> loadFreshFileNode(
    String path, {
    required String rootPath,
    LocalChessScanProgressSink? onProgress,
  }) async {
    final index = indexes[path];
    if (index == null) return null;
    return LocalChessFileNode(
      name: path.split('/').last,
      path: path,
      relativePath: path,
      extension: '.pgn',
      status: LocalChessFileStatus.parsed,
      games: const <LocalChessGame>[],
      gameCount: index.downloadedGameCount,
      sizeBytes: 1,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(1),
      openingTreeIndex: index,
    );
  }
}

PlayerOpeningTreeIndex _paneTreeIndex({
  required String path,
  required int gameCount,
}) {
  return PlayerOpeningTreeIndex(
    treeId: 'local:$path',
    playerId: path,
    maxPly: 50,
    rootNodeId: 0,
    generatedAt: DateTime.fromMillisecondsSinceEpoch(1),
    nodesById: const <int, PlayerOpeningTreeNode>{},
    nodesByFenKey: const <String, PlayerOpeningTreeNode>{},
    gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
    gameRowsById: const <String, Map<String, dynamic>>{},
    persistedPositionCount: 1,
    persistedGameCount: gameCount,
  );
}

String _paneTestPgn(String username) {
  return '''
[Event "Pane progress test"]
[Site "https://lichess.org/test"]
[Date "2026.07.07"]
[White "$username"]
[Black "Opponent"]
[Result "1-0"]

1. e4 e5 1-0
''';
}
