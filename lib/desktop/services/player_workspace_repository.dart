import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_diagnostics.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_source_deletion.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/time_control_classifier.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/utils/eco_openings.dart';

const String _workspaceStorageKey = 'desktop_player_workspace_v1';
const String _httpUserAgent =
    'ChessEverDesktop/1.0 (https://chessever.com; support@chessever.com)';
const Duration _importStatsTimeout = Duration(seconds: 8);
// The API may be building a shared 50k-game Lichess cache on a cold request.
const Duration _externalGamebaseSourceTimeout = Duration(hours: 3);
const double _chessEverExportInitialProgress = 0.05;
const List<double> _chessEverSnapshotWaitProgressSteps = <double>[
  0.18,
  0.28,
  0.35,
  0.38,
];

typedef PlayerWorkspaceProgress =
    void Function(String message, double? progress);
typedef PlayerWorkspaceSupportDirectoryResolver = Future<Directory> Function();

class PlayerWorkspaceCleanupTargets {
  const PlayerWorkspaceCleanupTargets({
    required this.sourcePaths,
    required this.workspaceDirectories,
    required this.rejectedPathCount,
  });

  final Set<String> sourcePaths;
  final Set<String> workspaceDirectories;
  final int rejectedPathCount;

  Set<String> get cacheScopes => workspaceDirectories;
}

const String playerWorkspaceCombinedFormatVersion = '2';
const String playerWorkspaceCombinedVersionTag = 'ChessEverCombinedVersion';
const String playerWorkspaceCombinedSourceTag = 'ChessEverSource';
const String playerWorkspaceCombinedTimeControlTag =
    'ChessEverTimeControlCategory';

@immutable
class PlayerWorkspaceCombinedSource {
  const PlayerWorkspaceCombinedSource({
    required this.path,
    required this.source,
  });

  final String path;
  final PlayerWorkspaceSource source;
}

class PlayerWorkspaceRepository {
  PlayerWorkspaceRepository({
    AppDatabase? appDatabase,
    http.Client? client,
    Duration? importStatsTimeout,
    GamebaseRepository? gamebaseRepository,
    PlayerWorkspaceSupportDirectoryResolver? supportDirectory,
  }) : importStatsTimeout = importStatsTimeout ?? _importStatsTimeout,
       _appDatabase = appDatabase ?? AppDatabase.instance,
       _client = client ?? http.Client(),
       _gamebaseRepository = gamebaseRepository,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final AppDatabase _appDatabase;
  final http.Client _client;
  final GamebaseRepository? _gamebaseRepository;
  final Duration importStatsTimeout;
  final PlayerWorkspaceSupportDirectoryResolver _supportDirectory;

  Future<PlayerWorkspaceSnapshot> loadSnapshot() async {
    final raw = await _appDatabase.getJson<Object?>(_workspaceStorageKey);
    final snapshot = PlayerWorkspaceSnapshot.fromJson(raw);
    final support = await _supportDirectory();
    localChessLog.info(
      'Player workspace storage root',
      context: <String, Object?>{'root': support.path},
    );
    final normalized = await _normalizeGeneratedPathsForCurrentSupportRoot(
      snapshot,
    );
    if (normalized.changed) {
      await saveSnapshot(normalized.snapshot);
      localChessLog.info(
        'Player workspace generated paths rebased',
        context: <String, Object?>{'root': support.path},
      );
    }
    return normalized.snapshot;
  }

  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    await _appDatabase.setJson(_workspaceStorageKey, snapshot.toJson());
  }

  @visibleForTesting
  Future<PlayerWorkspaceSnapshot> normalizeGeneratedPathsForCurrentSupportRoot(
    PlayerWorkspaceSnapshot snapshot,
  ) async {
    return (await _normalizeGeneratedPathsForCurrentSupportRoot(
      snapshot,
    )).snapshot;
  }

  Future<({PlayerWorkspaceSnapshot snapshot, bool changed})>
  _normalizeGeneratedPathsForCurrentSupportRoot(
    PlayerWorkspaceSnapshot snapshot,
  ) async {
    var changed = false;
    final players = <PlayerWorkspacePlayer>[];
    for (final player in snapshot.players) {
      final normalized = await _normalizeGeneratedWorkspacePlayerPaths(player);
      players.add(normalized.player);
      changed = changed || normalized.changed;
    }

    if (!changed) return (snapshot: snapshot, changed: false);
    return (
      snapshot: PlayerWorkspaceSnapshot(
        players: List.unmodifiable(players),
        // A tombstone is an exact cleanup manifest, not live workspace state.
        // Rebasing it can copy deleted data to the new support root and lose
        // the only reference to cache rows/files at the original path.
        pendingDeletions: snapshot.pendingDeletions,
        pendingDeletionExtraPaths: snapshot.pendingDeletionExtraPaths,
        selectedPlayerId: snapshot.selectedPlayerId,
      ),
      changed: true,
    );
  }

  Future<({PlayerWorkspacePlayer player, bool changed})>
  _normalizeGeneratedWorkspacePlayerPaths(PlayerWorkspacePlayer player) async {
    var changed = false;
    final accounts = <PlayerWorkspaceSource, PlayerWorkspaceAccount>{};
    for (final entry in player.accounts.entries) {
      final normalized = await _normalizeGeneratedWorkspaceAccountPath(
        playerId: player.id,
        account: entry.value,
      );
      accounts[entry.key] = normalized;
      changed = changed || !identical(normalized, entry.value);
    }

    final additionalAccounts = <PlayerWorkspaceAccount>[];
    for (final account in player.additionalAccounts) {
      final normalized = await _normalizeGeneratedWorkspaceAccountPath(
        playerId: player.id,
        account: account,
      );
      additionalAccounts.add(normalized);
      changed = changed || !identical(normalized, account);
    }

    final combinedPgnPath = await _normalizeGeneratedWorkspacePath(
      playerId: player.id,
      storedPath: player.combinedPgnPath,
    );
    changed = changed || combinedPgnPath != player.combinedPgnPath;

    if (!changed) return (player: player, changed: false);
    return (
      player: player.copyWith(
        accounts: Map.unmodifiable(accounts),
        additionalAccounts: List.unmodifiable(additionalAccounts),
        combinedPgnPath: combinedPgnPath,
      ),
      changed: true,
    );
  }

  Future<PlayerWorkspaceAccount> _normalizeGeneratedWorkspaceAccountPath({
    required String playerId,
    required PlayerWorkspaceAccount account,
  }) async {
    final normalized = await _normalizeGeneratedWorkspacePath(
      playerId: playerId,
      storedPath: account.pgnPath,
    );
    if (normalized == account.pgnPath) return account;
    return account.copyWith(pgnPath: normalized);
  }

  Future<String?> _normalizeGeneratedWorkspacePath({
    required String playerId,
    required String? storedPath,
  }) async {
    final clean = storedPath?.trim();
    if (clean == null || clean.isEmpty) return storedPath;
    final relativeParts = _generatedWorkspaceRelativeParts(
      playerId: playerId,
      storedPath: clean,
    );
    if (relativeParts == null || relativeParts.isEmpty) return storedPath;

    final currentDir = await _playerWorkspaceDirectory(playerId, create: false);
    final nextPath = p.normalize(
      p.joinAll(<String>[currentDir.path, ...relativeParts]),
    );
    final currentPath = p.normalize(clean);
    if (_samePath(currentPath, nextPath)) return nextPath;

    final nextFile = File(nextPath);
    if (!await nextFile.exists()) {
      final currentFile = File(currentPath);
      if (await currentFile.exists()) {
        await nextFile.parent.create(recursive: true);
        await currentFile.copy(nextPath);
      }
    }
    return nextPath;
  }

  Future<String> sourcePgnPath({
    required String playerId,
    String? playerName,
    String? fideId,
    required PlayerWorkspaceSource source,
    String? username,
  }) async {
    final root = await _playerWorkspaceDirectory(playerId);
    return p.join(
      root.path,
      playerWorkspaceSourceFileName(
        source: source,
        username: username,
        playerName: playerName,
        fideId: fideId,
        playerId: playerId,
      ),
    );
  }

  Future<DateTime?> latestPgnGameDate(String path) {
    final clean = path.trim();
    if (clean.isEmpty) return Future<DateTime?>.value();
    return Isolate.run(() => _latestPgnGameDateSync(clean));
  }

  Future<String> combinedPgnPath({
    required String playerId,
    String? playerName,
    String? fideId,
  }) async {
    final root = await _playerWorkspaceDirectory(playerId);
    return p.join(
      root.path,
      playerWorkspaceCombinedFileName(
        playerId: playerId,
        playerName: playerName,
        fideId: fideId,
      ),
    );
  }

  Future<bool> deleteSourcePgnFile(String path) {
    return deleteLocalSourcePath(path);
  }

  Future<bool> deletePlayerWorkspaceDirectory(String playerId) async {
    final root = await _playerWorkspaceDirectory(playerId, create: false);
    return _deleteWorkspaceDirectoryWithoutFollowingLinks(root.path);
  }

  /// Resolves the only paths a persisted player tombstone may destroy.
  ///
  /// The current support-root directory is always owned by [playerId]. Stored
  /// source paths are accepted only when they are direct children of an exact
  /// `player-workspace/<safe player id>` directory. This both supports an old
  /// support root and prevents corrupt/legacy state from deleting a user's
  /// unrelated PGN.
  Future<PlayerWorkspaceCleanupTargets> playerWorkspaceCleanupTargets(
    String playerId, {
    required Iterable<String> storedPaths,
  }) async {
    final current = await _playerWorkspaceDirectory(playerId, create: false);
    final sourcePaths = <String>{};
    final workspaceDirectories = <String>{p.normalize(current.path)};
    var rejectedPathCount = 0;

    for (final storedPath in storedPaths) {
      final clean = storedPath.trim();
      if (clean.isEmpty) continue;
      final normalized = p.normalize(clean);
      final directory = _validatedStoredPlayerWorkspaceDirectory(
        playerId,
        normalized,
      );
      if (directory == null) {
        rejectedPathCount += 1;
        continue;
      }
      sourcePaths.add(normalized);
      workspaceDirectories.add(directory);
    }

    return PlayerWorkspaceCleanupTargets(
      sourcePaths: Set<String>.unmodifiable(sourcePaths),
      workspaceDirectories: Set<String>.unmodifiable(workspaceDirectories),
      rejectedPathCount: rejectedPathCount,
    );
  }

  /// Removes old support-root workspace folders referenced by a tombstone.
  ///
  /// Only a direct `player-workspace/<player id>/file` parent is accepted, so
  /// malformed persisted paths can never broaden a recursive delete.
  Future<int> deleteStoredPlayerWorkspaceDirectories(
    String playerId, {
    required Iterable<String> storedPaths,
  }) async {
    final directories = <String>{};
    for (final storedPath in storedPaths) {
      final clean = storedPath.trim();
      if (clean.isEmpty) continue;
      final directoryPath = _validatedStoredPlayerWorkspaceDirectory(
        playerId,
        p.normalize(clean),
      );
      if (directoryPath != null) directories.add(directoryPath);
    }

    var deleted = 0;
    for (final directoryPath in directories) {
      if (await _deleteWorkspaceDirectoryWithoutFollowingLinks(directoryPath)) {
        deleted += 1;
      }
    }
    return deleted;
  }

  String? _validatedStoredPlayerWorkspaceDirectory(
    String playerId,
    String storedPath,
  ) {
    final directoryPath = p.normalize(p.dirname(storedPath));
    if (p.basename(directoryPath).toLowerCase() !=
        _safeFilePart(playerId).toLowerCase()) {
      return null;
    }
    if (p.basename(p.dirname(directoryPath)).toLowerCase() !=
        'player-workspace') {
      return null;
    }
    return directoryPath;
  }

  Future<bool> _deleteWorkspaceDirectoryWithoutFollowingLinks(
    String path,
  ) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        return false;
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
        return true;
      case FileSystemEntityType.link:
        await Link(path).delete();
        return true;
      case FileSystemEntityType.file:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        return false;
    }
    return false;
  }

  Future<PlayerWorkspaceAccount> fetchLichessAccount(String username) async {
    final clean = username.trim();
    if (clean.isEmpty) throw ArgumentError('Lichess username is required.');
    final uri = Uri.https('lichess.org', '/api/user/$clean');
    final response = await _client.get(
      uri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': _httpUserAgent,
      },
    );
    if (response.statusCode == 404) {
      throw StateError('Lichess user "$clean" was not found.');
    }
    _throwForBadResponse(response, 'Lichess profile');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final perfs = _mapOrEmpty(json['perfs']);
    final ratings = <String, int>{};
    var perfGameTotal = 0;
    for (final entry in perfs.entries) {
      final perf = _mapOrEmpty(entry.value);
      final rating = _readInt(perf['rating']);
      if (rating != null) ratings[_perfLabel(entry.key)] = rating;
      perfGameTotal += _readInt(perf['games']) ?? 0;
    }
    final count = _mapOrEmpty(json['count']);
    final totalGames = _readInt(count['all']) ?? perfGameTotal;
    final profile = _mapOrEmpty(json['profile']);
    final id = json['username']?.toString().trim();
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.lichess,
      username: id?.isNotEmpty == true ? id! : clean,
      displayName: id?.isNotEmpty == true ? id : clean,
      country: _stringOrNull(profile['country']),
      title: _stringOrNull(json['title']),
      profileUrl: 'https://lichess.org/@/${id ?? clean}',
      ratings: Map.unmodifiable(ratings),
      rawStats: Map.unmodifiable(<String, Object?>{
        'count': count.isEmpty ? json['count'] : count,
        'perfs': perfs,
      }),
      profileFetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      availableGameCount: totalGames,
    );
  }

  Future<PlayerWorkspaceAccount> fetchChessComAccount(String username) async {
    final clean = username.trim().toLowerCase();
    if (clean.isEmpty) throw ArgumentError('Chess.com username is required.');
    final profileUri = Uri.https('api.chess.com', '/pub/player/$clean');
    final statsUri = Uri.https('api.chess.com', '/pub/player/$clean/stats');
    final profileResponse = await _client.get(
      profileUri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': _httpUserAgent,
      },
    );
    if (profileResponse.statusCode == 404) {
      throw StateError('Chess.com user "$clean" was not found.');
    }
    _throwForBadResponse(profileResponse, 'Chess.com profile');
    final statsResponse = await _client.get(
      statsUri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': _httpUserAgent,
      },
    );
    _throwForBadResponse(statsResponse, 'Chess.com stats');

    final profile = jsonDecode(profileResponse.body) as Map<String, dynamic>;
    final stats = jsonDecode(statsResponse.body) as Map<String, dynamic>;
    final ratings = <String, int>{};
    var wins = 0;
    var draws = 0;
    var losses = 0;
    for (final key in const <String>[
      'chess_bullet',
      'chess_blitz',
      'chess_rapid',
      'chess_daily',
    ]) {
      final bucket = _mapOrEmpty(stats[key]);
      final last = _mapOrEmpty(bucket['last']);
      final record = _mapOrEmpty(bucket['record']);
      final rating = _readInt(last['rating']);
      if (rating != null) ratings[_chessComPerfLabel(key)] = rating;
      wins += _readInt(record['win']) ?? 0;
      draws += _readInt(record['draw']) ?? 0;
      losses += _readInt(record['loss']) ?? 0;
    }
    final displayName =
        _stringOrNull(profile['name']) ??
        _stringOrNull(profile['username']) ??
        clean;
    return PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.chesscom,
      username: _stringOrNull(profile['username']) ?? clean,
      externalId: _stringOrNull(profile['player_id']),
      displayName: displayName,
      avatarUrl: _stringOrNull(profile['avatar']),
      country: _countryCodeFromChessComUrl(_stringOrNull(profile['country'])),
      title: _stringOrNull(profile['title']),
      profileUrl:
          _stringOrNull(profile['url']) ??
          'https://www.chess.com/member/$clean',
      ratings: Map.unmodifiable(ratings),
      rawStats: Map.unmodifiable(stats),
      profileFetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      availableGameCount: wins + draws + losses,
      winCount: wins,
      drawCount: draws,
      lossCount: losses,
    );
  }

  Future<List<GamebasePlayer>> searchChessEverPlayers(
    GamebaseRepository repository,
    String query,
  ) {
    final clean = query.trim();
    if (clean.length < 2) return Future.value(const <GamebasePlayer>[]);
    return repository.getPlayers(name: clean, pageSize: 20);
  }

  Future<GamebasePlayer?> findChessEverPlayerByFideId(
    GamebaseRepository repository,
    String fideId,
  ) async {
    final clean = fideId.trim();
    if (clean.isEmpty || clean == '?') return null;
    final players = await repository.getPlayers(fideId: clean, pageSize: 20);
    for (final player in players) {
      if (player.fideId.trim() == clean) return player;
    }
    return null;
  }

  PlayerWorkspacePlayer playerFromChessEver(GamebasePlayer player) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final account = PlayerWorkspaceAccount(
      source: PlayerWorkspaceSource.chessever,
      username: player.displayName,
      externalId: player.id,
      displayName: player.titleAndName,
      country: player.fed,
      title: player.title,
      ratings: Map.unmodifiable(<String, int>{
        if (player.ratingClassical != null)
          'Classical': player.ratingClassical!,
        if (player.ratingRapid != null) 'Rapid': player.ratingRapid!,
        if (player.ratingBlitz != null) 'Blitz': player.ratingBlitz!,
      }),
      profileFetchedAtMs: now,
    );
    return PlayerWorkspacePlayer(
      id: _playerWorkspaceId(
        createdAtMs: now,
        displayName: player.titleAndName,
        fallbackIdentity: player.id,
      ),
      displayName: player.titleAndName,
      createdAtMs: now,
      fideId: player.fideId,
      chesseverPlayerId: player.id,
      country: player.fed,
      title: player.title,
      accounts: <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
        PlayerWorkspaceSource.chessever: account,
      },
    );
  }

  PlayerWorkspacePlayer manualPlayer(String displayName) {
    final clean = displayName.trim();
    if (clean.isEmpty) throw ArgumentError('Player name is required.');
    final now = DateTime.now().millisecondsSinceEpoch;
    return PlayerWorkspacePlayer(
      id: _playerWorkspaceId(createdAtMs: now, displayName: clean),
      displayName: clean,
      createdAtMs: now,
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    bool forceRefresh = false,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    try {
      final exported = await _downloadExternalPlayerPgnExport(
        externalSource: GamebaseExternalPlayerSource.lichess,
        workspaceSource: PlayerWorkspaceSource.lichess,
        username: username,
        sinceMs: sinceMs,
        forceRefresh: forceRefresh,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
      if (exported != null) return exported;
    } on DioException catch (error) {
      if (error.response?.statusCode == 413) {
        throw const _PlayerWorkspaceDownloadException(
          _playerPgnDatasetLimitMessage,
        );
      }
      if (error.response?.statusCode == 429) {
        throw const _PlayerWorkspaceDownloadException(
          'Lichess is limiting downloads right now. Please wait one minute and try again.',
        );
      }
      if (!_isTransientGamebaseSourceFailure(error)) rethrow;
      throw const _PlayerWorkspaceDownloadException(
        'ChessEver could not load the shared Lichess game cache. '
        'Please try again shortly.',
      );
    }
    throw StateError(
      'Lichess games are only available through the ChessEver source cache.',
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    bool forceRefresh = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    try {
      final exported = await _downloadExternalPlayerPgnExport(
        externalSource: GamebaseExternalPlayerSource.chesscom,
        workspaceSource: PlayerWorkspaceSource.chesscom,
        username: username,
        sinceMs: sinceMs,
        forceRefresh: forceRefresh,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
      if (exported != null) return exported;
    } on DioException catch (error) {
      if (error.response?.statusCode == 413) {
        throw const _PlayerWorkspaceDownloadException(
          _playerPgnDatasetLimitMessage,
        );
      }
      if (!_isTransientGamebaseSourceFailure(error)) rethrow;
      throw const _PlayerWorkspaceDownloadException(
        'ChessEver could not load the shared Chess.com game cache. '
        'Please try again shortly.',
      );
    }
    throw StateError(
      'Chess.com games are only available through the ChessEver source cache.',
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> downloadChessEverGames({
    required GamebaseRepository repository,
    required String playerId,
    String? fideId,
    DateTime? sinceDate,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final progress = _ChessEverDownloadProgress(onProgress: onProgress);
    // Player ChessEver sources use one compact path only. Never silently fall
    // back to the paginated JSON endpoint: its embedded game payload is much
    // larger and caused severe I/O and UI stalls on desktop.
    final PlayerWorkspaceDownloadedPgn? exported;
    try {
      exported = await _downloadChessEverPgnExport(
        repository: repository,
        playerId: playerId,
        fideId: fideId,
        dateFrom: sinceDate?.toUtc().toIso8601String().substring(0, 10),
        progress: progress,
        cancellationToken: cancellationToken,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 413) {
        throw const _PlayerWorkspaceDownloadException(
          _playerPgnDatasetLimitMessage,
        );
      }
      rethrow;
    }
    if (exported == null) {
      throw StateError(
        'ChessEver PGN export is unavailable. Please try again.',
      );
    }
    return exported;
  }

  Future<PlayerWorkspaceDownloadedPgn?> _downloadChessEverPgnExport({
    required GamebaseRepository repository,
    required String playerId,
    required String? fideId,
    required String? dateFrom,
    required _ChessEverDownloadProgress progress,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    progress.exportStarted();
    final exportWaitTimer = progress.startExportWaitTimer();
    final GamebasePlayerPgnExport? export;
    try {
      export = await repository.getPlayerGamesPgn(
        playerId: playerId,
        fideId: fideId,
        dateFrom: dateFrom,
      );
    } finally {
      exportWaitTimer?.cancel();
    }
    cancellationToken?.throwIfCanceled();
    if (export == null) return null;

    final gameCount =
        export.gameCount > 0 ? export.gameCount : countPgnGames(export.pgn);
    if (export.pgn.trim().isEmpty && gameCount > 0) return null;

    progress.exportFinished(gameCount);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: export.pgn,
      gameCount: gameCount,
      replaceExistingSource: dateFrom == null,
      remoteUnchanged:
          dateFrom != null
              ? gameCount == 0 && export.pgn.trim().isEmpty
              : _pgnCacheStatusIsUnchanged(export.cacheStatus),
    );
  }

  Future<PlayerWorkspaceDownloadedPgn?> _downloadExternalPlayerPgnExport({
    required GamebaseExternalPlayerSource externalSource,
    required PlayerWorkspaceSource workspaceSource,
    required String username,
    required int? sinceMs,
    required bool forceRefresh,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final repository = _gamebaseRepository;
    if (repository == null) return null;

    cancellationToken?.throwIfCanceled();
    onProgress?.call('${externalSource.label}: checking source cache...', null);
    final export = await repository.getExternalPlayerGamesPgn(
      source: externalSource,
      username: username,
      refresh: forceRefresh,
      sinceMs: sinceMs,
      receiveTimeout: _externalGamebaseSourceTimeout,
    );
    cancellationToken?.throwIfCanceled();
    if (export == null) return null;

    final gameCount =
        export.gameCount > 0 ? export.gameCount : countPgnGames(export.pgn);
    final replaceExistingSource =
        export.snapshotStatus?.trim().toLowerCase() != 'delta';
    final remoteUnchanged =
        replaceExistingSource
            ? _pgnCacheStatusIsUnchanged(export.cacheStatus)
            : gameCount == 0 && export.pgn.trim().isEmpty;
    onProgress?.call(
      remoteUnchanged
          ? '${externalSource.label}: source cache is already current '
              '($gameCount games).'
          : replaceExistingSource
          ? '${externalSource.label}: received latest source snapshot '
              '($gameCount games).'
          : '${externalSource.label}: received incremental games '
              '($gameCount games).',
      1,
    );
    return PlayerWorkspaceDownloadedPgn(
      source: workspaceSource,
      pgn: export.pgn,
      gameCount: gameCount,
      replaceExistingSource: replaceExistingSource,
      remoteUnchanged: remoteUnchanged,
    );
  }

  bool _pgnCacheStatusIsUnchanged(String? cacheStatus) {
    return cacheStatus?.trim().toLowerCase() == 'hit';
  }

  Future<PlayerWorkspaceDownloadedPgn> readManualPgnPaths({
    required List<String> paths,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    final cleaned = paths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) {
      throw ArgumentError('Choose at least one PGN file or folder.');
    }
    onProgress?.call('Scanning manual PGN...', null);
    final source = await scanLocalChessPathsWithProgress(
      cleaned,
      sourceLabel: localChessDatabaseDisplayNameForPaths(cleaned),
      buildOpeningTree: false,
      onProgress:
          (progress) => onProgress?.call(progress.message, progress.fraction),
    );
    cancellationToken?.throwIfCanceled();
    final chunks = <String>[
      for (final game in source.games)
        if (game.rawPgn.trim().isNotEmpty) game.rawPgn.trim(),
    ];
    final pgn = _joinPgnChunks(chunks);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.manual,
      pgn: pgn,
      gameCount: countPgnGames(pgn),
    );
  }

  Future<PlayerWorkspaceImportResult> mergeIntoLocalDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String path,
    required String sourceLabel,
    required String pgn,
    required Iterable<String> playerAliases,
    String? playerFideId,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final file = File(path);
    cancellationToken?.throwIfCanceled();
    final fileExists = await file.exists();
    onProgress?.call('Preparing downloaded games...', 0.0);
    final prepared = await _preparePgnImport(
      pgn: pgn,
      playerAliases: playerAliases,
      playerFideId: playerFideId,
    );
    cancellationToken?.throwIfCanceled();

    if (replaceExisting || !fileExists) {
      await _writePgnText(file, pgn, onProgress: onProgress);
      cancellationToken?.throwIfCanceled();
      onProgress?.call('Finalizing $sourceLabel...', 0.99);
      return PlayerWorkspaceImportResult(
        path: path,
        stats: PlayerWorkspaceImportStats(
          gameCount: prepared.stats.gameCount,
          newGameCount: prepared.stats.gameCount,
          winCount: prepared.stats.winCount,
          drawCount: prepared.stats.drawCount,
          lossCount: prepared.stats.lossCount,
        ),
      );
    }

    // Player sources are file-backed. Keep same-source syncing idempotent by
    // comparing the incoming games with the existing PGN in a worker isolate,
    // instead of materializing both files into the large shared Library cache.
    onProgress?.call('Checking existing games...', 0.12);
    final existingPrepared = await _preparePgnImport(
      pgn: await file.readAsString(),
      playerAliases: playerAliases,
      playerFideId: playerFideId,
    );
    cancellationToken?.throwIfCanceled();
    final remainingExisting = <String, int>{};
    for (final fingerprint in existingPrepared.fingerprints) {
      remainingExisting.update(
        fingerprint,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final appended = <_PreparedPgnGame>[];
    for (final game in prepared.games) {
      final remaining = remainingExisting[game.fingerprint] ?? 0;
      if (remaining > 0) {
        remainingExisting[game.fingerprint] = remaining - 1;
      } else {
        appended.add(game);
      }
    }
    if (appended.isNotEmpty) {
      await _appendPreparedPgnGames(file, appended);
    }
    cancellationToken?.throwIfCanceled();
    onProgress?.call('Finalizing $sourceLabel...', 0.99);
    final appendedStats = analyzePgnStats(
      appended.map((game) => game.pgn),
      playerAliases,
      playerFideId: playerFideId,
    );
    return PlayerWorkspaceImportResult(
      path: path,
      stats: PlayerWorkspaceImportStats(
        // Source syncing remains idempotent within this account. Combined keeps
        // every source row, including games that overlap another provider.
        gameCount: existingPrepared.stats.gameCount + appendedStats.gameCount,
        newGameCount: appended.length,
        winCount: existingPrepared.stats.winCount + appendedStats.winCount,
        drawCount: existingPrepared.stats.drawCount + appendedStats.drawCount,
        lossCount: existingPrepared.stats.lossCount + appendedStats.lossCount,
      ),
    );
  }

  Future<PlayerWorkspaceImportResult> rebuildCombinedDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String playerId,
    required String playerName,
    String? playerFideId,
    required Iterable<String> sourcePaths,
    Iterable<PlayerWorkspaceCombinedSource> sources =
        const <PlayerWorkspaceCombinedSource>[],
    required Iterable<String> playerAliases,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final inputs = <PlayerWorkspaceCombinedSource>[
      for (final input in sources)
        if (input.path.trim().isNotEmpty)
          PlayerWorkspaceCombinedSource(
            path: input.path.trim(),
            source: input.source,
          ),
      for (final path in sourcePaths)
        if (path.trim().isNotEmpty)
          PlayerWorkspaceCombinedSource(
            path: path.trim(),
            source: PlayerWorkspaceSource.manual,
          ),
    ];
    final uniqueInputs = <String, PlayerWorkspaceCombinedSource>{};
    for (final input in inputs) {
      uniqueInputs.putIfAbsent(p.normalize(input.path), () => input);
    }
    // Keep the visible source-rail order in the generated Combined database.
    // Manual PGN intentionally comes after the connected providers.
    final preparedInputs = <PlayerWorkspaceCombinedSource>[
      for (final source in const <PlayerWorkspaceSource>[
        PlayerWorkspaceSource.chessever,
        PlayerWorkspaceSource.lichess,
        PlayerWorkspaceSource.chesscom,
        PlayerWorkspaceSource.manual,
        PlayerWorkspaceSource.combined,
      ])
        for (final input in uniqueInputs.values)
          if (input.source == source) input,
    ];
    final combinedPath = await combinedPgnPath(
      playerId: playerId,
      playerName: playerName,
      fideId: playerFideId,
    );
    onProgress?.call('Preparing combined database...', 0.02);
    final prepared = await _prepareCombinedPgnImport(
      sources: preparedInputs,
      combinedPath: combinedPath,
      playerAliases: playerAliases,
      playerFideId: playerFideId,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
    cancellationToken?.throwIfCanceled();
    var authoritativeStats = PlayerWorkspaceImportStats(
      gameCount: prepared.stats.gameCount,
      newGameCount: prepared.stats.gameCount,
      winCount: prepared.stats.winCount,
      drawCount: prepared.stats.drawCount,
      lossCount: prepared.stats.lossCount,
    );
    try {
      final cachedStats = await localRepository.localDatabaseResultStats(
        databasePath: prepared.path,
        playerAliases: playerAliases,
        playerFideId: playerFideId,
        preferDirectDatabase: true,
      );
      cancellationToken?.throwIfCanceled();
      if (cachedStats.gameCount > 0) {
        authoritativeStats = PlayerWorkspaceImportStats(
          gameCount: cachedStats.gameCount,
          newGameCount: cachedStats.gameCount,
          winCount: cachedStats.winCount,
          drawCount: cachedStats.drawCount,
          lossCount: cachedStats.lossCount,
        );
      }
    } catch (error) {
      if (isOperationCanceled(error)) rethrow;
      // The Players workspace is file-backed and intentionally does not
      // materialize a second Combined cache. A Library cache may nevertheless
      // already exist; when it does, its complete path is authoritative. On a
      // cold workspace, keep the stats prepared while writing the PGN.
    }
    onProgress?.call('Finalizing combined database...', 0.99);
    return PlayerWorkspaceImportResult(
      path: prepared.path,
      stats: authoritativeStats,
    );
  }

  Future<bool> isCombinedDatabaseCurrent(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) return false;
    final file = File(clean);
    if (!await file.exists()) return false;
    try {
      final raf = await file.open();
      try {
        final prefix = await raf.read(64 * 1024);
        return utf8
            .decode(prefix, allowMalformed: true)
            .contains(
              '[$playerWorkspaceCombinedVersionTag '
              '"$playerWorkspaceCombinedFormatVersion"]',
            );
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return false;
    }
  }

  Future<Directory> _playerWorkspaceDirectory(
    String playerId, {
    bool create = true,
  }) async {
    final support = await _supportDirectory();
    final dir = Directory(
      p.join(support.path, 'player-workspace', _safeFilePart(playerId)),
    );
    if (create && !await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

class _PlayerWorkspaceDownloadException implements Exception {
  const _PlayerWorkspaceDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _playerPgnDatasetLimitMessage =
    'This player dataset is larger than ChessEver currently supports. '
    'The limit is 50,000 games and 800 MiB of raw PGN per source.';

bool _isTransientGamebaseSourceFailure(DioException error) {
  final statusCode = error.response?.statusCode;
  if (statusCode != null) return statusCode >= 500 && statusCode <= 599;
  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout ||
    DioExceptionType.connectionError ||
    DioExceptionType.unknown => true,
    _ => false,
  };
}

class _ChessEverDownloadProgress {
  _ChessEverDownloadProgress({required this.onProgress});

  final PlayerWorkspaceProgress? onProgress;

  void exportStarted() {
    _emit(
      'ChessEver: downloading PGN export...',
      _chessEverExportInitialProgress,
      force: true,
    );
  }

  Timer? startExportWaitTimer() {
    if (onProgress == null) return null;
    var step = 0;
    return Timer.periodic(const Duration(seconds: 5), (_) {
      final index =
          step.clamp(0, _chessEverSnapshotWaitProgressSteps.length - 1).toInt();
      _emit(
        'ChessEver: preparing source snapshot...',
        _chessEverSnapshotWaitProgressSteps[index],
        force: true,
      );
      if (step < _chessEverSnapshotWaitProgressSteps.length - 1) step += 1;
    });
  }

  void exportFinished(int gameCount) {
    _emit('ChessEver: downloaded $gameCount games as PGN.', 1, force: true);
  }

  void _emit(String message, double? progress, {bool force = false}) {
    onProgress?.call(message, progress);
  }
}

@immutable
class PlayerWorkspaceDownloadedPgn {
  const PlayerWorkspaceDownloadedPgn({
    required this.source,
    required this.pgn,
    required this.gameCount,
    this.replaceExistingSource = false,
    this.remoteUnchanged = false,
  });

  final PlayerWorkspaceSource source;
  final String pgn;
  final int gameCount;

  /// True when the PGN is a complete source snapshot and should replace the
  /// previous per-player source file/database instead of appending to it.
  final bool replaceExistingSource;

  /// True when the server-side source probe says the origin data did not change
  /// since the cached snapshot. Callers can skip a local re-import when the
  /// existing local source file already has at least [gameCount] games.
  final bool remoteUnchanged;
}

@immutable
class PlayerWorkspaceImportResult {
  const PlayerWorkspaceImportResult({
    required this.path,
    required this.stats,
    this.source,
  });

  final String path;
  final PlayerWorkspaceImportStats stats;
  final LocalChessSource? source;
}

@immutable
class _PreparedPgnGame {
  const _PreparedPgnGame({required this.pgn, required this.fingerprint});

  final String pgn;
  final String fingerprint;
}

@immutable
class _PreparedPgnImport {
  const _PreparedPgnImport({required this.games, required this.stats});

  final List<_PreparedPgnGame> games;
  final PlayerWorkspaceImportStats stats;

  int get gameCount => games.length;

  List<String> get fingerprints =>
      games.map((game) => game.fingerprint).toList(growable: false);
}

@immutable
class _PreparedCombinedPgnImport {
  const _PreparedCombinedPgnImport({required this.path, required this.stats});

  final String path;
  final PlayerWorkspaceImportStats stats;
}

@immutable
class _CombinedPreparationRequest {
  const _CombinedPreparationRequest({
    required this.sendPort,
    required this.inputs,
    required this.combinedPath,
    required this.cancelSignalPath,
    required this.aliases,
    required this.playerFideId,
  });

  final SendPort sendPort;
  final List<PlayerWorkspaceCombinedSource> inputs;
  final String combinedPath;
  final String cancelSignalPath;
  final List<String> aliases;
  final String? playerFideId;
}

@immutable
class _CombinedPreparationProgress {
  const _CombinedPreparationProgress({
    required this.sourceIndex,
    required this.sourceCount,
    required this.source,
    required this.fraction,
    required this.gameCount,
  });

  final int sourceIndex;
  final int sourceCount;
  final PlayerWorkspaceSource source;
  final double fraction;
  final int gameCount;
}

@immutable
class _CombinedPreparationStarted {
  const _CombinedPreparationStarted(this.tempPath);

  final String tempPath;
}

@immutable
class _CombinedPreparationFailure {
  const _CombinedPreparationFailure(this.error, this.stackTrace);

  final String error;
  final String stackTrace;
}

@immutable
class _CombinedPreparationCanceled {
  const _CombinedPreparationCanceled();
}

Future<_PreparedPgnImport> _preparePgnImport({
  required String pgn,
  required Iterable<String> playerAliases,
  String? playerFideId,
}) {
  final aliases = playerAliases.toList(growable: false);
  return Isolate.run(() => _preparePgnImportSync(pgn, aliases, playerFideId));
}

_PreparedPgnImport _preparePgnImportSync(
  String pgn,
  List<String> aliases,
  String? playerFideId,
) {
  final chunks = splitPgnGames(pgn);
  final games = <_PreparedPgnGame>[];
  for (final chunk in chunks) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
    final fingerprint = localChessPgnFingerprint(trimmed);
    games.add(_PreparedPgnGame(pgn: trimmed, fingerprint: fingerprint));
  }
  final stats = analyzePgnStats(
    games.map((game) => game.pgn),
    aliases,
    playerFideId: playerFideId,
  );
  return _PreparedPgnImport(
    games: List<_PreparedPgnGame>.unmodifiable(games),
    stats: stats,
  );
}

Future<_PreparedCombinedPgnImport> _prepareCombinedPgnImport({
  required Iterable<PlayerWorkspaceCombinedSource> sources,
  required String combinedPath,
  required Iterable<String> playerAliases,
  String? playerFideId,
  PlayerWorkspaceProgress? onProgress,
  OperationCancellationToken? cancellationToken,
}) async {
  cancellationToken?.throwIfCanceled();
  final inputs = sources.toList(growable: false);
  final aliases = playerAliases.toList(growable: false);
  final cancelSignalPath =
      '$combinedPath.cancel-${DateTime.now().microsecondsSinceEpoch}-${Isolate.current.hashCode}';
  final receivePort = ReceivePort();
  final exitPort = ReceivePort();
  final completer = Completer<_PreparedCombinedPgnImport>();
  final isolateExited = Completer<void>();
  String? workerTempPath;
  final exitSubscription = exitPort.listen((_) {
    if (!isolateExited.isCompleted) isolateExited.complete();
  });
  late final StreamSubscription<Object?> subscription;
  subscription = receivePort.listen((message) {
    if (message is _CombinedPreparationStarted) {
      workerTempPath = message.tempPath;
    } else if (message is _CombinedPreparationProgress) {
      final detail =
          message.fraction >= 1
              ? '${message.gameCount} games'
              : message.source.label;
      onProgress?.call(
        'Combining source ${message.sourceIndex}/${message.sourceCount}: '
        '$detail...',
        (0.02 + (message.fraction * 0.08)).clamp(0.02, 0.10),
      );
    } else if (message is _PreparedCombinedPgnImport) {
      if (!completer.isCompleted) completer.complete(message);
    } else if (message is _CombinedPreparationFailure) {
      if (!completer.isCompleted) {
        completer.completeError(RemoteError(message.error, message.stackTrace));
      }
    } else if (message is _CombinedPreparationCanceled) {
      if (!completer.isCompleted) {
        completer.completeError(const OperationCanceledException());
      }
    }
  });
  Isolate? isolate;
  VoidCallback? removeCancellationListener;
  try {
    isolate = await Isolate.spawn(
      _prepareCombinedPgnImportWorker,
      _CombinedPreparationRequest(
        sendPort: receivePort.sendPort,
        inputs: inputs,
        combinedPath: combinedPath,
        cancelSignalPath: cancelSignalPath,
        aliases: aliases,
        playerFideId: playerFideId,
      ),
      onExit: exitPort.sendPort,
    );
    removeCancellationListener = cancellationToken?.addListener(() {
      try {
        File(cancelSignalPath).writeAsStringSync('cancel');
      } on FileSystemException catch (error, stackTrace) {
        isolate?.kill(priority: Isolate.immediate);
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return await completer.future;
  } finally {
    removeCancellationListener?.call();
    await subscription.cancel();
    receivePort.close();
    isolate?.kill(priority: Isolate.immediate);
    if (isolate != null && !isolateExited.isCompleted) {
      await isolateExited.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    await exitSubscription.cancel();
    exitPort.close();
    final tempPath = workerTempPath;
    if (tempPath != null) {
      await _deleteCombinedTempFileBestEffort(tempPath);
    }
    await _deleteCombinedTempFileBestEffort(cancelSignalPath);
  }
}

Future<void> _deleteCombinedTempFileBestEffort(String path) async {
  const retryDelays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 20),
    Duration(milliseconds: 80),
    Duration(milliseconds: 200),
  ];
  for (final delay in retryDelays) {
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      return;
    } on FileSystemException {
      // A killed Windows worker can retain its file handle for a few ticks.
    }
  }
}

void _prepareCombinedPgnImportWorker(_CombinedPreparationRequest request) {
  try {
    final result = _prepareCombinedPgnImportSync(
      request.inputs,
      request.combinedPath,
      request.aliases,
      request.playerFideId,
      cancelSignalPath: request.cancelSignalPath,
      onStarted:
          (tempPath) =>
              request.sendPort.send(_CombinedPreparationStarted(tempPath)),
      onProgress: request.sendPort.send,
    );
    request.sendPort.send(result);
  } on OperationCanceledException {
    request.sendPort.send(const _CombinedPreparationCanceled());
  } catch (error, stackTrace) {
    request.sendPort.send(
      _CombinedPreparationFailure(error.toString(), stackTrace.toString()),
    );
  }
}

_PreparedCombinedPgnImport _prepareCombinedPgnImportSync(
  List<PlayerWorkspaceCombinedSource> inputs,
  String combinedPath,
  List<String> aliases,
  String? playerFideId, {
  required String cancelSignalPath,
  void Function(String tempPath)? onStarted,
  void Function(_CombinedPreparationProgress progress)? onProgress,
}) {
  final output = File(combinedPath);
  output.parent.createSync(recursive: true);
  final sourceSizes = <int>[
    for (final input in inputs) File(input.path).lengthSync(),
  ];
  final tempPath =
      '$combinedPath.tmp-${DateTime.now().microsecondsSinceEpoch}-${Isolate.current.hashCode}';
  onStarted?.call(tempPath);
  final temp = File(tempPath);
  final writer = temp.openSync(mode: FileMode.write);
  final stats = _PgnStatsCounter(aliases, playerFideId: playerFideId);
  final totalBytes = sourceSizes.fold<int>(0, (sum, size) => sum + size);
  var completedBytes = 0;
  var gameCount = 0;
  var wroteAny = false;
  try {
    void throwIfCanceled() {
      if (File(cancelSignalPath).existsSync()) {
        throw const OperationCanceledException();
      }
    }

    for (var sourceOffset = 0; sourceOffset < inputs.length; sourceOffset++) {
      throwIfCanceled();
      final input = inputs[sourceOffset];
      final sourceBytes = sourceSizes[sourceOffset];
      var sourceCharactersRead = 0;
      var sourceGamesRead = 0;

      void reportProgress({required bool complete}) {
        final estimatedSourceBytes =
            complete ? sourceBytes : sourceCharactersRead.clamp(0, sourceBytes);
        final processedBytes = completedBytes + estimatedSourceBytes;
        final fraction =
            totalBytes <= 0
                ? (sourceOffset + (complete ? 1 : 0)) / inputs.length
                : processedBytes / totalBytes;
        onProgress?.call(
          _CombinedPreparationProgress(
            sourceIndex: sourceOffset + 1,
            sourceCount: inputs.length,
            source: input.source,
            fraction: fraction.clamp(0.0, 1.0).toDouble(),
            gameCount: gameCount,
          ),
        );
      }

      reportProgress(complete: false);
      for (final chunk in _readPgnGamesFromFileSync(
        input.path,
        isCanceled: () => File(cancelSignalPath).existsSync(),
      )) {
        final trimmed = chunk.trim();
        if (trimmed.isEmpty) continue;
        sourceCharactersRead += chunk.length;
        sourceGamesRead++;
        if (wroteAny) writer.writeStringSync('\n\n');
        writer.writeStringSync(_withCombinedMetadata(trimmed, input.source));
        stats.add(trimmed);
        gameCount++;
        wroteAny = true;
        if (sourceGamesRead % 128 == 0) reportProgress(complete: false);
      }
      reportProgress(complete: true);
      completedBytes += sourceBytes;
    }
    throwIfCanceled();
    if (wroteAny) writer.writeStringSync('\n');
    writer.flushSync();
    writer.closeSync();
    throwIfCanceled();
    _replaceCombinedOutputSync(temp: temp, output: output);
    return _PreparedCombinedPgnImport(
      path: combinedPath,
      stats: stats.toStats(),
    );
  } catch (_) {
    try {
      writer.closeSync();
    } catch (_) {}
    try {
      temp.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

void _replaceCombinedOutputSync({required File temp, required File output}) {
  if (!output.existsSync()) {
    temp.renameSync(output.path);
    return;
  }
  final backup = File(
    '${output.path}.backup-${DateTime.now().microsecondsSinceEpoch}',
  );
  output.renameSync(backup.path);
  try {
    temp.renameSync(output.path);
  } catch (_) {
    if (!output.existsSync() && backup.existsSync()) {
      backup.renameSync(output.path);
    }
    rethrow;
  }
  try {
    backup.deleteSync();
  } on FileSystemException {
    // The Combined output is already installed. A stale backup is preferable
    // to reporting failure after a successful replacement.
  }
}

String _withCombinedMetadata(String pgn, PlayerWorkspaceSource source) {
  final headers = _pgnHeaders(pgn);
  final explicitOrInferred = classifyTimeControlCategory(
    headers['timecontrol'],
    event: headers['event'],
    site: headers['site'],
    source: source.storageKey,
  );
  final category =
      explicitOrInferred ??
      (source == PlayerWorkspaceSource.chessever ? 'classical' : null);
  final storedOpening = headers['opening']?.trim();
  final normalizedOpening = storedOpening?.toLowerCase();
  final needsOpeningFallback =
      normalizedOpening == null ||
      normalizedOpening.isEmpty ||
      normalizedOpening == '?' ||
      normalizedOpening == '-' ||
      normalizedOpening == 'unknown' ||
      normalizedOpening == 'unknown opening';
  final opening =
      needsOpeningFallback
          ? EcoOpenings.getOpeningName(headers['eco']?.trim())
          : null;
  final derivedTags = <String>[
    '[$playerWorkspaceCombinedVersionTag '
        '"$playerWorkspaceCombinedFormatVersion"]',
    '[$playerWorkspaceCombinedSourceTag "${source.storageKey}"]',
    if (category != null)
      '[$playerWorkspaceCombinedTimeControlTag "$category"]',
    if (opening != null) '[Opening "${_escapePgnTagValue(opening)}"]',
  ].join('\n');
  final headerBoundary = RegExp(r'\n\s*\n').firstMatch(pgn);
  if (headerBoundary == null) return '$pgn\n$derivedTags';
  return '${pgn.substring(0, headerBoundary.start).trimRight()}\n'
      '$derivedTags${pgn.substring(headerBoundary.start)}';
}

String _escapePgnTagValue(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// Maps a 0–1 local-import worker fraction into the later part of the
/// player-workspace import phase after the PGN has already been saved.
///
/// Download→import handoff previously parked the overall bar at the import
/// phase start (~40% for ChessEver) while the worker still reported early
/// fractions like 0.02–0.18. Remapping keeps the UI climbing once import work
/// is actually underway.
@visibleForTesting
double mapPlayerWorkspaceImportWorkerProgress(double workerFraction) {
  return _mapImportWorkerProgress(workerFraction);
}

double _mapImportWorkerProgress(double workerFraction) {
  final clamped = workerFraction.clamp(0.0, 1.0).toDouble();
  // Reserve 0.00–0.10 for saving the PGN; map worker work onto 0.10–0.98.
  return (0.10 + (clamped * 0.88)).clamp(0.0, 0.98).toDouble();
}

const int _largePgnWriteIsolateThresholdBytes = 512 * 1024;

Future<void> _writePgnText(
  File file,
  String pgn, {
  PlayerWorkspaceProgress? onProgress,
}) async {
  await file.parent.create(recursive: true);
  final normalized = pgn.trim();
  final content = normalized.isEmpty ? '' : '$normalized\n';
  final sizeLabel = _formatByteCount(content.length);
  onProgress?.call(
    content.isEmpty
        ? 'Saving downloaded PGN...'
        : 'Saving downloaded PGN ($sizeLabel)...',
    0.0,
  );
  // Let the progress callback paint before a multi‑MB write blocks this
  // isolate (or before we schedule the worker isolate for large payloads).
  await Future<void>.delayed(Duration.zero);

  if (content.length >= _largePgnWriteIsolateThresholdBytes) {
    final path = file.path;
    await Isolate.run(() {
      File(path).writeAsStringSync(content, flush: true);
    });
  } else {
    await file.writeAsString(content, flush: true);
  }

  onProgress?.call('Downloaded PGN saved.', 0.08);
  await Future<void>.delayed(Duration.zero);
}

String _formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Future<void> _appendPreparedPgnGames(
  File file,
  List<_PreparedPgnGame> games,
) async {
  final sink = file.openWrite(mode: FileMode.append);
  try {
    for (final game in games) {
      sink.writeln();
      sink.writeln(game.pgn.trim());
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
}

List<String> splitPgnGames(String pgn) {
  final normalized = pgn.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return const <String>[];
  final starts = RegExp(
    r'^\s*\[Event\s+"',
    multiLine: true,
  ).allMatches(normalized).map((match) => match.start).toList(growable: false);
  if (starts.isEmpty) return <String>[normalized];
  final games = <String>[];
  for (var i = 0; i < starts.length; i++) {
    final start = starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : normalized.length;
    final chunk = normalized.substring(start, end).trim();
    if (chunk.isNotEmpty) games.add(chunk);
  }
  return games;
}

int countPgnGames(String pgn) {
  final normalized = pgn.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (normalized.isEmpty) return 0;
  final starts = RegExp(
    r'^\s*\[Event\s+"',
    multiLine: true,
  ).allMatches(normalized);
  var count = 0;
  for (final _ in starts) {
    count++;
  }
  return count == 0 ? 1 : count;
}

PlayerWorkspaceImportStats analyzePgnStats(
  Iterable<String> chunks,
  Iterable<String> aliases, {
  String? playerFideId,
}) {
  final counter = _PgnStatsCounter(aliases, playerFideId: playerFideId);
  for (final chunk in chunks) {
    counter.add(chunk);
  }
  return counter.toStats();
}

Future<PlayerWorkspaceImportStats> analyzePgnFileHeaderStats({
  required String path,
  required Iterable<String> aliases,
  String? playerFideId,
}) {
  final aliasList = aliases.toList(growable: false);
  return Isolate.run(
    () => _analyzePgnFileHeaderStatsSync(path, aliasList, playerFideId),
  );
}

PlayerWorkspaceImportStats _analyzePgnFileHeaderStatsSync(
  String path,
  List<String> aliases,
  String? playerFideId,
) {
  final counter = _PgnStatsCounter(aliases, playerFideId: playerFideId);
  final header = RegExp(r'^\s*\[([A-Za-z0-9_]+)\s+"((?:\\.|[^"\\])*)"\]\s*$');
  Map<String, String>? headers;

  void finishGame() {
    final current = headers;
    if (current == null) return;
    counter.addHeaders(current);
    headers = null;
  }

  for (final line in _readUtf8LinesFromFileSync(File(path))) {
    final match = header.firstMatch(line);
    if (match == null) continue;
    final key = match.group(1)?.trim().toLowerCase();
    final value = match.group(2)?.trim();
    if (key == null || key.isEmpty || value == null) continue;
    if (key == 'event') {
      finishGame();
      headers = <String, String>{};
    }
    headers?[key] = value;
  }
  finishGame();
  return counter.toStats();
}

class _PgnStatsCounter {
  _PgnStatsCounter(Iterable<String> aliases, {String? playerFideId})
    : _normalizedAliases =
          aliases
              .map(_normalizePlayerName)
              .where((name) => name.isNotEmpty)
              .toSet(),
      _playerFideId = _normalizeFideId(playerFideId);

  final Set<String> _normalizedAliases;
  final String? _playerFideId;
  var _games = 0;
  var _wins = 0;
  var _draws = 0;
  var _losses = 0;

  void add(String chunk) {
    addHeaders(_pgnHeaders(chunk));
  }

  void addHeaders(Map<String, String> headers) {
    final result = headers['result'] ?? '';
    _games++;
    final white = _normalizePlayerName(headers['white']);
    final black = _normalizePlayerName(headers['black']);
    final whiteFideId = _normalizeFideId(headers['whitefideid']);
    final blackFideId = _normalizeFideId(headers['blackfideid']);
    final hasAnyFideId = whiteFideId != null || blackFideId != null;
    final isWhite = _matchesPgnSide(name: white, fideId: whiteFideId);
    final isBlack = _matchesPgnSide(name: black, fideId: blackFideId);
    if (!isWhite && !isBlack) {
      if (_playerFideId != null && !hasAnyFideId) {
        if (_isDrawResult(result)) _draws++;
      }
      return;
    }
    if (_isDrawResult(result)) {
      _draws++;
    } else if ((result == '1-0' && isWhite) || (result == '0-1' && isBlack)) {
      _wins++;
    } else if ((result == '0-1' && isWhite) || (result == '1-0' && isBlack)) {
      _losses++;
    }
  }

  PlayerWorkspaceImportStats toStats() {
    return PlayerWorkspaceImportStats(
      gameCount: _games,
      winCount: _wins,
      drawCount: _draws,
      lossCount: _losses,
    );
  }

  bool _matchesPgnSide({required String name, required String? fideId}) {
    final targetFideId = _playerFideId;
    if (targetFideId != null) {
      return fideId == targetFideId ||
          (fideId == null && _normalizedAliases.contains(name));
    }
    return _normalizedAliases.isEmpty || _normalizedAliases.contains(name);
  }
}

bool _isDrawResult(String result) {
  return result == '1/2-1/2' || result == '1/2' || result == '½-½';
}

DateTime? _latestPgnGameDateSync(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final dateHeader = RegExp(
    r'^\s*\[Date\s+"(\d{4})\.(\d{2})\.(\d{2})"\s*\]',
    caseSensitive: false,
  );
  DateTime? latest;
  for (final line in _readUtf8LinesFromFileSync(file)) {
    final match = dateHeader.firstMatch(line);
    if (match == null) continue;
    final year = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final day = int.tryParse(match.group(3) ?? '');
    if (year == null || month == null || day == null) continue;
    final candidate = DateTime.utc(year, month, day);
    if (candidate.year != year ||
        candidate.month != month ||
        candidate.day != day) {
      continue;
    }
    if (latest == null || candidate.isAfter(latest)) latest = candidate;
  }
  return latest;
}

Iterable<String> _readPgnGamesFromFileSync(
  String path, {
  bool Function()? isCanceled,
}) sync* {
  final file = File(path);
  if (!file.existsSync()) return;
  final game = StringBuffer();
  var firstLine = true;
  var sawMoveText = false;
  var inComment = false;
  for (var line in _readUtf8LinesFromFileSync(file, isCanceled: isCanceled)) {
    if (firstLine) {
      firstLine = false;
      if (line.startsWith('\uFEFF')) line = line.substring(1);
    }
    final wasInComment = inComment;
    final isHeader = !wasInComment && _startsWithPgnHeader(line);
    if (isHeader && sawMoveText) {
      final current = game.toString().trim();
      if (current.isNotEmpty) yield current;
      game.clear();
      sawMoveText = false;
    } else if (!isHeader && line.trim().isNotEmpty) {
      sawMoveText = true;
    }
    game.write(line);
    inComment = _updatePgnCommentState(line, inComment);
  }
  final trailing = game.toString().trim();
  if (trailing.isNotEmpty) yield trailing;
}

Iterable<String> _readUtf8LinesFromFileSync(
  File file, {
  bool Function()? isCanceled,
}) sync* {
  const chunkSize = 64 * 1024;
  final reader = file.openSync();
  final pending = BytesBuilder(copy: false);
  try {
    while (true) {
      if (isCanceled?.call() ?? false) {
        throw const OperationCanceledException();
      }
      final chunk = reader.readSync(chunkSize);
      if (chunk.isEmpty) break;
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != 0x0A) continue;
        pending.add(chunk.sublist(start, i + 1));
        yield utf8.decode(pending.takeBytes(), allowMalformed: true);
        start = i + 1;
      }
      if (start < chunk.length) {
        pending.add(chunk.sublist(start));
      }
    }
    final trailing = pending.takeBytes();
    if (trailing.isNotEmpty) {
      yield utf8.decode(trailing, allowMalformed: true);
    }
  } finally {
    reader.closeSync();
  }
}

bool _startsWithPgnHeader(String line) {
  for (var i = 0; i < line.length; i++) {
    final code = line.codeUnitAt(i);
    if (code == 0x20 || code == 0x09) continue;
    return code == 0x5B;
  }
  return false;
}

bool _updatePgnCommentState(String line, bool inComment) {
  var inside = inComment;
  for (var i = 0; i < line.length; i++) {
    final code = line.codeUnitAt(i);
    if (code == 0x7B) {
      inside = true;
    } else if (code == 0x7D) {
      inside = false;
    }
  }
  return inside;
}

String _joinPgnChunks(Iterable<String> chunks) {
  return chunks
      .map((chunk) => chunk.trim())
      .where((chunk) => chunk.isNotEmpty)
      .join('\n\n');
}

Map<String, String> _pgnHeaders(String pgn) {
  final headers = <String, String>{};
  final regex = RegExp(
    r'^\s*\[([A-Za-z0-9_]+)\s+"((?:\\.|[^"\\])*)"\]\s*$',
    multiLine: true,
  );
  for (final match in regex.allMatches(pgn)) {
    final key = match.group(1)?.trim().toLowerCase();
    final value = match.group(2)?.trim();
    if (key != null && key.isNotEmpty && value != null) headers[key] = value;
  }
  return headers;
}

String _normalizePlayerName(String? name) {
  return (name ?? '').toLowerCase().replaceAll(RegExp(r'[\s,._-]+'), '').trim();
}

String? _normalizeFideId(String? value) {
  final clean = value?.trim().toLowerCase();
  if (clean == null || clean.isEmpty || clean == '?') return null;
  return clean;
}

void _throwForBadResponse(http.Response response, String label) {
  if (response.statusCode >= 200 && response.statusCode < 300) return;
  throw StateError(
    '$label request failed (${response.statusCode}): ${response.body.trim()}',
  );
}

Map<String, dynamic> _mapOrEmpty(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return <String, dynamic>{};
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

String? _stringOrNull(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

String _perfLabel(String key) {
  return switch (key) {
    'ultraBullet' => 'Ultra bullet',
    'bullet' => 'Bullet',
    'blitz' => 'Blitz',
    'rapid' => 'Rapid',
    'classical' => 'Classical',
    'correspondence' => 'Correspondence',
    _ => key,
  };
}

String _chessComPerfLabel(String key) {
  return switch (key) {
    'chess_bullet' => 'Bullet',
    'chess_blitz' => 'Blitz',
    'chess_rapid' => 'Rapid',
    'chess_daily' => 'Daily',
    _ => key,
  };
}

String? _countryCodeFromChessComUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final last = Uri.tryParse(url)?.pathSegments.last;
  return last?.trim().toUpperCase();
}

List<String>? _generatedWorkspaceRelativeParts({
  required String playerId,
  required String storedPath,
}) {
  final playerPart = _safeFilePart(playerId).toLowerCase();
  final parts = storedPath
      .split(RegExp(r'[\\/]+'))
      .where((part) => part.trim().isNotEmpty)
      .toList(growable: false);
  for (var i = 0; i < parts.length - 2; i++) {
    if (parts[i].toLowerCase() != 'player-workspace') continue;
    if (parts[i + 1].toLowerCase() != playerPart) continue;
    return parts.sublist(i + 2);
  }
  return null;
}

bool _samePath(String a, String b) {
  final normalizedA = p.normalize(a);
  final normalizedB = p.normalize(b);
  if (Platform.isWindows) {
    return normalizedA.toLowerCase() == normalizedB.toLowerCase();
  }
  return normalizedA == normalizedB;
}

String _safeFilePart(String value) {
  final cleaned = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return cleaned.isEmpty ? 'player' : cleaned;
}

String _playerWorkspaceId({
  required int createdAtMs,
  required String displayName,
  String? fallbackIdentity,
}) {
  final name = _safeFilePart(displayName);
  final fallback = _safeFilePart(fallbackIdentity ?? '');
  final identity = name == 'player' && fallback != 'player' ? fallback : name;
  return 'player-$createdAtMs-$identity';
}

/// File name for the player's combined database.
String playerWorkspaceCombinedFileName({
  String? playerId,
  String? playerName,
  String? fideId,
}) {
  final identity = _playerWorkspaceIdentityToken(
    playerId: playerId,
    playerName: playerName,
    fideId: fideId,
  );
  return 'COMBINED_${identity}_CHESSEVER.pgn';
}

/// File name for a generated player-source PGN.
///
/// Every generated player database carries the app token plus the strongest
/// available player identity: FIDE id first, then display name, then the
/// internal player id. The account handle is appended only when it adds useful
/// source-specific detail.
String playerWorkspaceSourceFileName({
  required PlayerWorkspaceSource source,
  String? username,
  String? playerId,
  String? playerName,
  String? fideId,
}) {
  final sourceToken = _workspaceFileToken(source.label);
  final identity = _playerWorkspaceIdentityToken(
    playerId: playerId,
    playerName: playerName,
    fideId: fideId,
  );
  final handle = _workspaceFileToken(username ?? '');
  final parts = <String>[sourceToken, identity, 'CHESSEVER'];
  if (handle.isNotEmpty && handle != sourceToken) parts.add(handle);
  return '${parts.join('_')}.pgn';
}

/// Preserves human casing and spacing while removing characters that are
/// illegal (Windows: `<>:"/\|?*` and control codes) or unsafe (trailing dots or
/// spaces) in a file name, collapsing the whitespace it introduces.
String _prettyWorkspaceFilePart(String value) {
  return value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
}

String _playerWorkspaceIdentityToken({
  String? playerId,
  String? playerName,
  String? fideId,
}) {
  final fide = _workspaceFileToken(fideId ?? '');
  if (fide.isNotEmpty) return fide;
  final name = _workspaceFileToken(playerName ?? '');
  if (name.isNotEmpty) return name;
  final id = _workspaceFileToken(playerId ?? '');
  return id.isEmpty ? 'PLAYER' : id;
}

String _workspaceFileToken(String value) {
  return _prettyWorkspaceFilePart(value)
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), ' ')
      .replaceAll(RegExp(r'[\s-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '')
      .toUpperCase();
}
