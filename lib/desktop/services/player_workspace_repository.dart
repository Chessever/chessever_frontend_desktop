import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/utils/eco_openings.dart';

const String _workspaceStorageKey = 'desktop_player_workspace_v1';
const String _httpUserAgent =
    'ChessEverDesktop/1.0 (https://chessever.com; support@chessever.com)';
const int _lichessRangeConcurrency = 4;
const int _lichessParallelRangeMinExpectedGames = 1500;
const int _lichessFirstFullExportYear = 2010;
const int _chessComArchiveConcurrency = 1;
const double _chessComArchiveProgressFloor = 0.08;
const int _chessEverPageSize = 1000;
const int _chessEverEmbeddedPgnBatchSize = 200;
const int _chessEverHydrateConcurrency = 16;
const Duration _chessEverHydrationTimeout = Duration(seconds: 20);
const Duration _importStatsTimeout = Duration(seconds: 8);
const double _externalSourceInitialProgress = 0.05;
const List<double> _sourceSnapshotWaitProgressSteps = <double>[
  0.18,
  0.28,
  0.35,
  0.38,
];

typedef PlayerWorkspaceProgress =
    void Function(String message, double? progress);
typedef PlayerWorkspaceSupportDirectoryResolver = Future<Directory> Function();

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
    Duration? chessEverHydrationTimeout,
    Duration? importStatsTimeout,
    GamebaseRepository? gamebaseRepository,
    PlayerWorkspaceSupportDirectoryResolver? supportDirectory,
  }) : chessEverHydrationTimeout =
           chessEverHydrationTimeout ?? _chessEverHydrationTimeout,
       importStatsTimeout = importStatsTimeout ?? _importStatsTimeout,
       _appDatabase = appDatabase ?? AppDatabase.instance,
       _client = client ?? http.Client(),
       _gamebaseRepository = gamebaseRepository,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final AppDatabase _appDatabase;
  final http.Client _client;
  final GamebaseRepository? _gamebaseRepository;
  final Duration chessEverHydrationTimeout;
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
      var playerChanged = false;
      final accounts = <PlayerWorkspaceSource, PlayerWorkspaceAccount>{};
      for (final entry in player.accounts.entries) {
        final normalized = await _normalizeGeneratedWorkspaceAccountPath(
          playerId: player.id,
          account: entry.value,
        );
        accounts[entry.key] = normalized;
        playerChanged = playerChanged || !identical(normalized, entry.value);
      }

      final additionalAccounts = <PlayerWorkspaceAccount>[];
      for (final account in player.additionalAccounts) {
        final normalized = await _normalizeGeneratedWorkspaceAccountPath(
          playerId: player.id,
          account: account,
        );
        additionalAccounts.add(normalized);
        playerChanged = playerChanged || !identical(normalized, account);
      }

      final combinedPgnPath = await _normalizeGeneratedWorkspacePath(
        playerId: player.id,
        storedPath: player.combinedPgnPath,
      );
      playerChanged =
          playerChanged || combinedPgnPath != player.combinedPgnPath;

      players.add(
        playerChanged
            ? player.copyWith(
              accounts: Map.unmodifiable(accounts),
              additionalAccounts: List.unmodifiable(additionalAccounts),
              combinedPgnPath: combinedPgnPath,
            )
            : player,
      );
      changed = changed || playerChanged;
    }

    if (!changed) return (snapshot: snapshot, changed: false);
    return (
      snapshot: PlayerWorkspaceSnapshot(
        players: List.unmodifiable(players),
        selectedPlayerId: snapshot.selectedPlayerId,
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
    if (!await root.exists()) return false;
    await root.delete(recursive: true);
    return true;
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
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    final exported = await _downloadExternalPlayerPgnExport(
      externalSource: GamebaseExternalPlayerSource.lichess,
      workspaceSource: PlayerWorkspaceSource.lichess,
      username: username,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
    if (exported != null) return exported;
    if (_gamebaseRepository != null) {
      throw StateError('Lichess source export is not available from gamebase.');
    }

    if (sinceMs == null &&
        expectedGameCount != null &&
        expectedGameCount >= _lichessParallelRangeMinExpectedGames) {
      return _downloadLichessGamesInRanges(
        username: username,
        expectedGameCount: expectedGameCount,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    }
    final query = <String, String>{
      'perfType': 'ultraBullet,bullet,blitz,rapid,classical,correspondence',
      'sort': 'dateAsc',
      'tags': 'true',
      'clocks': 'true',
      'opening': 'true',
      if (sinceMs != null && sinceMs > 0) 'since': sinceMs.toString(),
    };
    final uri = Uri.https(
      'lichess.org',
      '/api/games/user/${username.trim()}',
      query,
    );
    final progress = _LichessPgnStreamProgress(
      expectedGameCount: expectedGameCount,
      onProgress: onProgress,
    )..start();
    final pgn = await _downloadText(
      uri,
      accept: 'application/x-chess-pgn',
      onTextChunk: progress.addChunk,
      cancellationToken: cancellationToken,
    );
    cancellationToken?.throwIfCanceled();
    progress.finish();
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.lichess,
      pgn: pgn,
      gameCount:
          progress.receivedGames > 0
              ? progress.receivedGames
              : countPgnGames(pgn),
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> _downloadLichessGamesInRanges({
    required String username,
    required int expectedGameCount,
    required PlayerWorkspaceProgress? onProgress,
    required OperationCancellationToken? cancellationToken,
  }) async {
    final ranges = _lichessFullExportRanges(DateTime.now().toUtc());
    if (ranges.length <= 1) {
      return downloadLichessGames(
        username: username,
        expectedGameCount: null,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    }

    final rangeCounts = List<int>.filled(ranges.length, 0);
    final completedRanges = <int>{};
    final throttle = _ProgressThrottle();
    void report({bool force = false}) {
      final received = rangeCounts.fold<int>(0, (sum, count) => sum + count);
      if (!force && !throttle.shouldReport(received)) return;
      onProgress?.call(
        'Receiving Lichess games: $received of about $expectedGameCount '
        '(${completedRanges.length}/${ranges.length} date ranges done)...',
        (received / expectedGameCount).clamp(0.0, 1.0).toDouble(),
      );
    }

    onProgress?.call(
      'Opening Lichess download: ${ranges.length} date ranges '
      '(${_lichessRangeConcurrency.clamp(1, ranges.length)} at a time)...',
      0,
    );
    late final List<_IndexedPgn> downloads;
    try {
      downloads =
          await _mapConcurrentIndexed<_LichessDownloadRange, _IndexedPgn>(
            ranges,
            concurrency: _lichessRangeConcurrency,
            mapper: (range, index) async {
              cancellationToken?.throwIfCanceled();
              final query = <String, String>{
                'perfType':
                    'ultraBullet,bullet,blitz,rapid,classical,correspondence',
                'sort': 'dateAsc',
                'tags': 'true',
                'clocks': 'true',
                'opening': 'true',
                'since': range.sinceMs.toString(),
                'until': range.untilMs.toString(),
              };
              final counter = _PgnStreamGameCounter();
              final uri = Uri.https(
                'lichess.org',
                '/api/games/user/${username.trim()}',
                query,
              );
              final pgn = await _downloadText(
                uri,
                accept: 'application/x-chess-pgn',
                onTextChunk: (chunk) {
                  counter.addChunk(chunk);
                  rangeCounts[index] = counter.receivedGames;
                  report();
                },
                cancellationToken: cancellationToken,
              );
              cancellationToken?.throwIfCanceled();
              counter.finish();
              rangeCounts[index] =
                  counter.receivedGames > 0
                      ? counter.receivedGames
                      : countPgnGames(pgn);
              completedRanges.add(index);
              report(force: true);
              return _IndexedPgn(index, pgn);
            },
          );
    } on Object catch (error) {
      if (!isOperationCanceled(error) && error.toString().contains('(429)')) {
        onProgress?.call(
          'Lichess limited parallel export; falling back to one stream...',
          null,
        );
        return downloadLichessGames(
          username: username,
          expectedGameCount: null,
          onProgress: onProgress,
          cancellationToken: cancellationToken,
        );
      }
      rethrow;
    }
    cancellationToken?.throwIfCanceled();
    downloads.sort((a, b) => a.index.compareTo(b.index));
    final buffer = StringBuffer();
    for (final download in downloads) {
      final pgn = download.pgn.trim();
      if (pgn.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.writeln(pgn);
    }
    final text = buffer.toString();
    final gameCount = rangeCounts.fold<int>(0, (sum, count) => sum + count);
    onProgress?.call(
      'Lichess download complete: $gameCount games received.',
      1,
    );
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.lichess,
      pgn: text,
      gameCount: gameCount > 0 ? gameCount : countPgnGames(text),
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    final exported = await _downloadExternalPlayerPgnExport(
      externalSource: GamebaseExternalPlayerSource.chesscom,
      workspaceSource: PlayerWorkspaceSource.chesscom,
      username: username,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
    if (exported != null) return exported;
    if (_gamebaseRepository != null) {
      throw StateError(
        'Chess.com source export is not available from gamebase.',
      );
    }

    final clean = username.trim().toLowerCase();
    final archivesUri = Uri.https(
      'api.chess.com',
      '/pub/player/$clean/games/archives',
    );
    onProgress?.call('Chess.com: loading monthly archive list...', 0.05);
    cancellationToken?.throwIfCanceled();
    final response = await _client.get(
      archivesUri,
      headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': _httpUserAgent,
      },
    );
    _throwForBadResponse(response, 'Chess.com archives');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final archives = (json['archives'] as List? ?? const <Object?>[])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .where((value) => _archiveIsAfterSinceMonth(value, sinceMs))
        .toList(growable: false);
    if (archives.isEmpty) {
      onProgress?.call('Chess.com: no monthly archives to download.', 1);
    }
    var completedArchives = 0;
    var downloadedGames = 0;
    if (archives.isNotEmpty) {
      onProgress?.call(
        'Chess.com: downloading ${archives.length} monthly archives '
        '(${_chessComArchiveConcurrency.clamp(1, archives.length)} at a time)...',
        _chessComArchiveProgressFloor,
      );
    }
    final downloads = await _mapConcurrentIndexed<String, _IndexedPgn>(
      archives,
      concurrency: _chessComArchiveConcurrency,
      mapper: (archiveUrl, index) async {
        cancellationToken?.throwIfCanceled();
        final pgnUrl =
            archiveUrl.endsWith('/pgn') ? archiveUrl : '$archiveUrl/pgn';
        onProgress?.call(
          'Chess.com: started ${_chessComArchiveLabel(archiveUrl)} '
          '(${index + 1}/${archives.length}); $completedArchives done, '
          '$downloadedGames games received...',
          _chessComArchiveProgress(completedArchives, archives.length),
        );
        final pgn = await _downloadText(
          Uri.parse(pgnUrl),
          accept: 'application/x-chess-pgn',
          cancellationToken: cancellationToken,
        );
        cancellationToken?.throwIfCanceled();
        final gameCount = countPgnGames(pgn);
        completedArchives += 1;
        downloadedGames += gameCount;
        onProgress?.call(
          'Chess.com: $completedArchives/${archives.length} archives done; '
          '$downloadedGames games received...',
          _chessComArchiveProgress(completedArchives, archives.length),
        );
        return _IndexedPgn(index, pgn);
      },
    );
    cancellationToken?.throwIfCanceled();
    downloads.sort((a, b) => a.index.compareTo(b.index));
    final buffer = StringBuffer();
    for (final download in downloads) {
      final pgn = download.pgn.trim();
      if (pgn.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.writeln(pgn);
    }
    final text = buffer.toString();
    if (archives.isNotEmpty) {
      onProgress?.call(
        'Chess.com: parsing $downloadedGames received games...',
        1,
      );
    }
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chesscom,
      pgn: text,
      gameCount: downloadedGames > 0 ? downloadedGames : countPgnGames(text),
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
    final buffer = StringBuffer();
    final progress = _ChessEverDownloadProgress(
      onProgress: onProgress,
      expectedGameCount: expectedGameCount,
    );
    final dateFrom = _gamebaseDate(sinceDate);
    final exported = await _downloadChessEverPgnExport(
      repository: repository,
      playerId: playerId,
      fideId: fideId,
      progress: progress,
      expectedGameCount: expectedGameCount,
      cancellationToken: cancellationToken,
    );
    if (exported != null) return exported;

    var page = 0;
    int? totalCount;
    while (true) {
      cancellationToken?.throwIfCanceled();
      progress.loadingPage(page + 1);
      final response = await repository.getPlayerGames(
        playerId: playerId,
        pageNumber: page,
        pageSize: _chessEverPageSize,
        includeData: true,
        dateFrom: dateFrom,
      );
      cancellationToken?.throwIfCanceled();
      final rows = _rowsFromPlayerGamesResponse(response);
      if (rows.isEmpty) break;
      totalCount ??= _readTotalCount(response);
      progress.updateTotalCount(totalCount);
      final hasMore = _readHasMore(response);
      progress.pageReturned(
        pageNumber: page + 1,
        rowsOnPage: rows.length,
        hasMore: hasMore,
      );
      final pgns = await _chessEverPgnsForRows(
        repository: repository,
        rows: rows,
        onPageProgress:
            (pageProgress) => progress.pagePrepared(
              pageNumber: page + 1,
              pageProgress: pageProgress,
            ),
        cancellationToken: cancellationToken,
      );
      for (final pgn in pgns) {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln(pgn.trim());
      }
      progress.pageFinished(
        rowsOnPage: rows.length,
        readyOnPage: pgns.length,
        hasMore: hasMore,
      );
      if (hasMore != true) break;
      page++;
    }
    cancellationToken?.throwIfCanceled();
    final text = buffer.toString();
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: text,
      gameCount: countPgnGames(text),
    );
  }

  Future<PlayerWorkspaceDownloadedPgn?> _downloadChessEverPgnExport({
    required GamebaseRepository repository,
    required String playerId,
    required String? fideId,
    required _ChessEverDownloadProgress progress,
    required int? expectedGameCount,
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
      );
    } finally {
      exportWaitTimer?.cancel();
    }
    cancellationToken?.throwIfCanceled();
    if (export == null) return null;

    final gameCount =
        export.gameCount > 0 ? export.gameCount : countPgnGames(export.pgn);
    if (export.pgn.trim().isEmpty && gameCount > 0) return null;
    if (expectedGameCount != null &&
        expectedGameCount > 0 &&
        gameCount > 0 &&
        gameCount < expectedGameCount) {
      progress.exportShortfall(
        gameCount: gameCount,
        expectedGameCount: expectedGameCount,
      );
      return null;
    }

    progress.exportFinished(gameCount);
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: export.pgn,
      gameCount: gameCount,
      replaceExistingSource: true,
      remoteUnchanged: _pgnCacheStatusIsUnchanged(export.cacheStatus),
    );
  }

  Future<PlayerWorkspaceDownloadedPgn?> _downloadExternalPlayerPgnExport({
    required GamebaseExternalPlayerSource externalSource,
    required PlayerWorkspaceSource workspaceSource,
    required String username,
    PlayerWorkspaceProgress? onProgress,
    OperationCancellationToken? cancellationToken,
  }) async {
    final repository = _gamebaseRepository;
    if (repository == null) return null;

    cancellationToken?.throwIfCanceled();
    onProgress?.call(
      '${externalSource.label}: checking source cache...',
      _externalSourceInitialProgress,
    );
    final slowSnapshotTimer = _startSourceSnapshotWaitProgress(
      onProgress: onProgress,
      label: externalSource.label,
    );
    final GamebasePlayerPgnExport? export;
    try {
      export = await repository.getExternalPlayerGamesPgn(
        source: externalSource,
        username: username,
      );
    } finally {
      slowSnapshotTimer?.cancel();
    }
    cancellationToken?.throwIfCanceled();
    if (export == null) return null;

    final gameCount =
        export.gameCount > 0 ? export.gameCount : countPgnGames(export.pgn);
    final remoteUnchanged = _pgnCacheStatusIsUnchanged(export.cacheStatus);
    onProgress?.call(
      remoteUnchanged
          ? '${externalSource.label}: source cache is already current '
              '($gameCount games).'
          : '${externalSource.label}: received latest source snapshot '
              '($gameCount games).',
      1,
    );
    return PlayerWorkspaceDownloadedPgn(
      source: workspaceSource,
      pgn: export.pgn,
      gameCount: gameCount,
      replaceExistingSource: true,
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
    final pgn = _joinPgnChunks(_dedupePgnChunks(chunks));
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
    final existingDatabase =
        replaceExisting
            ? null
            : await localRepository.localDatabaseMatchingPgnFingerprints(
              databasePath: path,
              fingerprints: const <String>[],
            );
    cancellationToken?.throwIfCanceled();

    if (replaceExisting || !fileExists || existingDatabase == null) {
      await _writePgnText(file, pgn, onProgress: onProgress);
      cancellationToken?.throwIfCanceled();
      onProgress?.call(
        replaceExisting
            ? 'Reinstalling $sourceLabel...'
            : 'Importing $sourceLabel...',
        0.10,
      );
      // Yield so the import-phase progress can paint before the local cache
      // open / write-queue wait begins (these can take a long time on a warm
      // release cache and previously looked like a freeze at ~40%).
      await Future<void>.delayed(Duration.zero);
      final source = await localRepository.importSingleFileSource(
        path: path,
        sourceLabel: sourceLabel,
        cancellationToken: cancellationToken,
        onProgress:
            (progress) => onProgress?.call(
              progress.message,
              _mapImportWorkerProgress(progress.fraction),
            ),
      );
      cancellationToken?.throwIfCanceled();
      onProgress?.call('Finalizing $sourceLabel...', 0.99);
      final stats = await _statsForImportedLocalDatabase(
        localRepository: localRepository,
        path: path,
        playerAliases: playerAliases,
        playerFideId: playerFideId,
        fallbackGameCount: _sourceGameCount(
          source,
          fallback: countPgnGames(pgn),
        ),
        timeout: importStatsTimeout,
      );
      return PlayerWorkspaceImportResult(
        path: path,
        source: source,
        stats: PlayerWorkspaceImportStats(
          gameCount: stats.gameCount,
          newGameCount: stats.gameCount,
          winCount: stats.winCount,
          drawCount: stats.drawCount,
          lossCount: stats.lossCount,
        ),
      );
    }

    onProgress?.call('Preparing downloaded games...', 0.0);
    await Future<void>.delayed(Duration.zero);
    final prepared = await _preparePgnImport(
      pgn: pgn,
      playerAliases: playerAliases,
      playerFideId: playerFideId,
    );
    cancellationToken?.throwIfCanceled();
    onProgress?.call('Merging into local database...', 0.12);

    if (prepared.games.isEmpty) {
      final source = await localRepository.loadFreshSource(<String>[
        path,
      ], sourceLabel: sourceLabel);
      final stats = await _statsForImportedLocalDatabase(
        localRepository: localRepository,
        path: path,
        playerAliases: playerAliases,
        playerFideId: playerFideId,
        fallbackGameCount: _sourceGameCount(source),
        timeout: importStatsTimeout,
      );
      return PlayerWorkspaceImportResult(
        path: path,
        source: source,
        stats: PlayerWorkspaceImportStats(
          gameCount: stats.gameCount,
          winCount: stats.winCount,
          drawCount: stats.drawCount,
          lossCount: stats.lossCount,
        ),
      );
    }

    final existingHashes = await localRepository
        .localDatabaseMatchingPgnFingerprints(
          databasePath: path,
          fingerprints: prepared.fingerprints,
        );
    if (existingHashes == null) {
      return mergeIntoLocalDatabase(
        localRepository: localRepository,
        path: path,
        sourceLabel: sourceLabel,
        pgn: pgn,
        playerAliases: playerAliases,
        playerFideId: playerFideId,
        replaceExisting: true,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    }

    final seen = Set<String>.from(existingHashes);
    final appended = prepared.games
        .where((game) => seen.add(game.fingerprint))
        .toList(growable: false);
    if (appended.isNotEmpty) {
      await _appendPreparedPgnGames(file, appended);
      cancellationToken?.throwIfCanceled();
      await localRepository.persistAppendedPgnGames(
        databasePath: path,
        appendedPgns: [
          for (final game in appended) LocalChessAppendedPgn(rawPgn: game.pgn),
        ],
      );
    }
    cancellationToken?.throwIfCanceled();
    final source = await localRepository.loadFreshSource(<String>[
      path,
    ], sourceLabel: sourceLabel);
    onProgress?.call('Finalizing $sourceLabel...', 0.99);
    final stats = await _statsForImportedLocalDatabase(
      localRepository: localRepository,
      path: file.path,
      playerAliases: playerAliases,
      playerFideId: playerFideId,
      fallbackGameCount: _sourceGameCount(
        source,
        fallback: prepared.stats.gameCount,
      ),
      timeout: importStatsTimeout,
    );
    return PlayerWorkspaceImportResult(
      path: path,
      source: source,
      stats: PlayerWorkspaceImportStats(
        // Distinct games in this source (deduplicated by PGN fingerprint), the
        // same method the Combined count uses over the union, so the per-source
        // numbers partition Combined and sum to it.
        gameCount: stats.gameCount,
        newGameCount: appended.length,
        winCount: stats.winCount,
        drawCount: stats.drawCount,
        lossCount: stats.lossCount,
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
    final preparedInputs = uniqueInputs.values.toList(growable: false);
    final paths = preparedInputs
        .map((input) => input.path)
        .toList(growable: false);
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
    );
    cancellationToken?.throwIfCanceled();
    final source = await localRepository.importSingleFileSource(
      path: prepared.path,
      sourceLabel: '$playerName Combined',
      cancellationToken: cancellationToken,
      onProgress:
          (progress) => onProgress?.call(progress.message, progress.fraction),
    );
    cancellationToken?.throwIfCanceled();
    onProgress?.call('Finalizing combined database...', 0.99);
    // Compute the Combined numbers directly from the union of the player's
    // source databases (deduplicated by PGN fingerprint) rather than from the
    // freshly re-imported combined file. This is the same counting method the
    // per-source cards use on a single database, so Combined always equals the
    // number of distinct games across sources and — for disjoint sources —
    // sums the per-source counts, regardless of whether the physical combined
    // database is momentarily stale.
    final combinedStats = await _statsForLocalDatabases(
      localRepository: localRepository,
      databasePaths: paths,
      playerAliases: playerAliases,
      playerFideId: playerFideId,
      fallbackGameCount: _sourceGameCount(
        source,
        fallback: prepared.stats.gameCount,
      ),
      timeout: importStatsTimeout,
    );
    return PlayerWorkspaceImportResult(
      path: prepared.path,
      source: source,
      stats: PlayerWorkspaceImportStats(
        gameCount: combinedStats.gameCount,
        newGameCount: prepared.stats.gameCount,
        winCount: combinedStats.winCount,
        drawCount: combinedStats.drawCount,
        lossCount: combinedStats.lossCount,
      ),
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

  Future<String> _downloadText(
    Uri uri, {
    required String accept,
    void Function(String chunk)? onTextChunk,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    final request = http.Request('GET', uri)
      ..headers.addAll(<String, String>{
        'Accept': accept,
        'User-Agent': _httpUserAgent,
      });
    final response = await _client.send(request);
    cancellationToken?.throwIfCanceled();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw StateError(
        'Request failed (${response.statusCode}) for $uri: ${body.trim()}',
      );
    }
    final buffer = StringBuffer();
    final completer = Completer<String>();
    late final StreamSubscription<String> subscription;
    VoidCallback? removeCancelListener;
    subscription = response.stream
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            if (cancellationToken?.isCanceled == true) {
              unawaited(subscription.cancel());
              if (!completer.isCompleted) {
                completer.completeError(const OperationCanceledException());
              }
              return;
            }
            buffer.write(chunk);
            onTextChunk?.call(chunk);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete(buffer.toString());
          },
          cancelOnError: true,
        );
    removeCancelListener = cancellationToken?.addListener(() {
      unawaited(subscription.cancel());
      if (!completer.isCompleted) {
        completer.completeError(const OperationCanceledException());
      }
    });
    try {
      return await completer.future;
    } finally {
      removeCancelListener?.call();
    }
  }

  Future<List<String>> _chessEverPgnsForRows({
    required GamebaseRepository repository,
    required List<Map<String, dynamic>> rows,
    required void Function(_ChessEverPageProgress progress) onPageProgress,
    required OperationCancellationToken? cancellationToken,
  }) async {
    final embedded = await _embeddedChessEverPgnsForRows(
      rows: rows,
      onPageProgress: onPageProgress,
      cancellationToken: cancellationToken,
    );
    final outputByIndex = embedded.outputByIndex;
    final hydrateTargets = embedded.hydrateTargets;

    final embeddedCount = outputByIndex.length;
    if (hydrateTargets.isEmpty) {
      onPageProgress(
        _ChessEverPageProgress(
          readyOnPage: embeddedCount,
          processedWork: rows.length,
          totalWork: rows.length,
        ),
      );
      return <String>[
        for (var i = 0; i < rows.length; i++)
          if (outputByIndex[i] != null) outputByIndex[i]!,
      ];
    }

    onPageProgress(
      _ChessEverPageProgress(
        readyOnPage: embeddedCount,
        processedWork: rows.length,
        totalWork: rows.length + hydrateTargets.length,
      ),
    );
    var completedHydrations = 0;
    var hydratedPgnCount = 0;
    final hydrated =
        await _mapConcurrentIndexed<_ChessEverHydrationTarget, _IndexedPgn?>(
          hydrateTargets,
          concurrency: _chessEverHydrateConcurrency,
          mapper: (target, _) async {
            cancellationToken?.throwIfCanceled();
            final full = await _getChessEverHydratedGame(
              repository: repository,
              id: target.id,
              cancellationToken: cancellationToken,
            );
            cancellationToken?.throwIfCanceled();
            final pgn = _pgnFromGamebase(full, target.row);
            completedHydrations += 1;
            if (pgn == null || pgn.trim().isEmpty) {
              onPageProgress(
                _ChessEverPageProgress(
                  readyOnPage: embeddedCount + hydratedPgnCount,
                  processedWork: rows.length + completedHydrations,
                  totalWork: rows.length + hydrateTargets.length,
                ),
              );
              return null;
            }
            hydratedPgnCount += 1;
            onPageProgress(
              _ChessEverPageProgress(
                readyOnPage: embeddedCount + hydratedPgnCount,
                processedWork: rows.length + completedHydrations,
                totalWork: rows.length + hydrateTargets.length,
              ),
            );
            return _IndexedPgn(target.index, pgn.trim());
          },
        );
    for (final item in hydrated) {
      if (item == null) continue;
      outputByIndex[item.index] = item.pgn;
    }

    return <String>[
      for (var i = 0; i < rows.length; i++)
        if (outputByIndex[i] != null) outputByIndex[i]!,
    ];
  }

  Future<GamebaseGameWithPgn?> _getChessEverHydratedGame({
    required GamebaseRepository repository,
    required String id,
    required OperationCancellationToken? cancellationToken,
  }) {
    final request = repository
        .getGameWithPgn(id)
        .timeout(chessEverHydrationTimeout, onTimeout: () => null);
    if (cancellationToken == null) return request;
    return Future.any<GamebaseGameWithPgn?>(<Future<GamebaseGameWithPgn?>>[
      request,
      cancellationToken.whenCanceled.then<GamebaseGameWithPgn?>((_) {
        throw const OperationCanceledException();
      }),
    ]);
  }
}

Future<_ChessEverEmbeddedBuildResult> _embeddedChessEverPgnsForRows({
  required List<Map<String, dynamic>> rows,
  required void Function(_ChessEverPageProgress progress) onPageProgress,
  required OperationCancellationToken? cancellationToken,
}) async {
  final outputByIndex = <int, String>{};
  final hydrateTargets = <_ChessEverHydrationTarget>[];
  var processedRows = 0;
  final batches = <_ChessEverEmbeddedPgnBatch>[];
  for (var start = 0; start < rows.length;) {
    final end =
        start + _chessEverEmbeddedPgnBatchSize < rows.length
            ? start + _chessEverEmbeddedPgnBatchSize
            : rows.length;
    batches.add(
      _ChessEverEmbeddedPgnBatch(start: start, rows: rows.sublist(start, end)),
    );
    start = end;
  }

  for (final batch in batches) {
    cancellationToken?.throwIfCanceled();
    final pgns = _buildEmbeddedChessEverPgnBatchSync(batch.rows);
    cancellationToken?.throwIfCanceled();

    for (var batchIndex = 0; batchIndex < pgns.length; batchIndex++) {
      final rowIndex = batch.start + batchIndex;
      final pgn = pgns[batchIndex]?.trim();
      if (pgn != null && pgn.isNotEmpty) {
        outputByIndex[rowIndex] = pgn;
        continue;
      }
      final row = rows[rowIndex];
      final id = row['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      hydrateTargets.add(
        _ChessEverHydrationTarget(index: rowIndex, id: id, row: row),
      );
    }

    processedRows += batch.rows.length;
    onPageProgress(
      _ChessEverPageProgress(
        readyOnPage: outputByIndex.length,
        processedWork: processedRows,
        totalWork: rows.length * 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }
  cancellationToken?.throwIfCanceled();

  return _ChessEverEmbeddedBuildResult(
    outputByIndex: outputByIndex,
    hydrateTargets: hydrateTargets,
  );
}

List<String?> _buildEmbeddedChessEverPgnBatchSync(
  List<Map<String, dynamic>> rows,
) {
  return <String?>[for (final row in rows) _pgnFromGamebase(null, row)?.trim()];
}

Future<List<R>> _mapConcurrentIndexed<T, R>(
  List<T> items, {
  required int concurrency,
  required Future<R> Function(T item, int index) mapper,
}) async {
  if (items.isEmpty) return <R>[];
  final width = concurrency.clamp(1, items.length).toInt();
  final results = List<R?>.filled(items.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final index = nextIndex;
      nextIndex += 1;
      if (index >= items.length) return;
      results[index] = await mapper(items[index], index);
    }
  }

  await Future.wait<void>(<Future<void>>[
    for (var i = 0; i < width; i++) worker(),
  ]);
  return <R>[for (final result in results) result as R];
}

@immutable
class _IndexedPgn {
  const _IndexedPgn(this.index, this.pgn);

  final int index;
  final String pgn;
}

@immutable
class _ChessEverEmbeddedPgnBatch {
  const _ChessEverEmbeddedPgnBatch({required this.start, required this.rows});

  final int start;
  final List<Map<String, dynamic>> rows;
}

@immutable
class _LichessDownloadRange {
  const _LichessDownloadRange({required this.sinceMs, required this.untilMs});

  final int sinceMs;
  final int untilMs;
}

List<_LichessDownloadRange> _lichessFullExportRanges(DateTime nowUtc) {
  final endMs = nowUtc.millisecondsSinceEpoch;
  final ranges = <_LichessDownloadRange>[];
  for (var year = _lichessFirstFullExportYear; year <= nowUtc.year; year++) {
    final start = DateTime.utc(year).millisecondsSinceEpoch;
    final next = DateTime.utc(year + 1).millisecondsSinceEpoch;
    final until = (next - 1).clamp(start, endMs).toInt();
    if (start <= endMs && until >= start) {
      ranges.add(_LichessDownloadRange(sinceMs: start, untilMs: until));
    }
  }
  return List<_LichessDownloadRange>.unmodifiable(ranges);
}

@immutable
class _ChessEverHydrationTarget {
  const _ChessEverHydrationTarget({
    required this.index,
    required this.id,
    required this.row,
  });

  final int index;
  final String id;
  final Map<String, dynamic> row;
}

@immutable
class _ChessEverEmbeddedBuildResult {
  const _ChessEverEmbeddedBuildResult({
    required this.outputByIndex,
    required this.hydrateTargets,
  });

  final Map<int, String> outputByIndex;
  final List<_ChessEverHydrationTarget> hydrateTargets;
}

@immutable
class _ChessEverPageProgress {
  const _ChessEverPageProgress({
    required this.readyOnPage,
    required this.processedWork,
    required this.totalWork,
  });

  final int readyOnPage;
  final int processedWork;
  final int totalWork;

  double get workFraction {
    if (totalWork <= 0) return 0;
    return (processedWork / totalWork).clamp(0.0, 1.0).toDouble();
  }
}

class _ChessEverDownloadProgress {
  _ChessEverDownloadProgress({
    required this.onProgress,
    required int? expectedGameCount,
  }) : _expectedGameCount =
           expectedGameCount != null && expectedGameCount > 0
               ? expectedGameCount
               : null;

  final PlayerWorkspaceProgress? onProgress;
  final int? _expectedGameCount;
  final _ProgressThrottle _throttle = _ProgressThrottle();

  int? _totalCount;
  int _completedRows = 0;
  int _readyPgns = 0;
  int _currentPageRows = 0;
  bool? _currentHasMore;
  bool _finishedPages = false;

  void updateTotalCount(int? totalCount) {
    if (totalCount == null || totalCount <= 0) return;
    final current = _totalCount;
    _totalCount =
        current == null || totalCount > current ? totalCount : current;
  }

  void exportStarted() {
    _emit(
      'ChessEver: downloading PGN export...',
      _externalSourceInitialProgress,
      force: true,
    );
  }

  Timer? startExportWaitTimer() {
    if (onProgress == null) return null;
    var step = 0;
    return Timer.periodic(const Duration(seconds: 5), (_) {
      final index =
          step.clamp(0, _sourceSnapshotWaitProgressSteps.length - 1).toInt();
      _emit(
        'ChessEver: preparing source snapshot...',
        _sourceSnapshotWaitProgressSteps[index],
        force: true,
      );
      if (step < _sourceSnapshotWaitProgressSteps.length - 1) step += 1;
    });
  }

  void exportFinished(int gameCount) {
    _finishedPages = true;
    _completedRows = gameCount;
    _readyPgns = gameCount;
    _emit('ChessEver: downloaded $gameCount games as PGN.', 1, force: true);
  }

  void exportShortfall({
    required int gameCount,
    required int expectedGameCount,
  }) {
    _emit(
      'ChessEver: PGN export had $gameCount of $expectedGameCount games; '
      'loading pages instead...',
      _externalSourceInitialProgress,
      force: true,
    );
  }

  void loadingPage(int pageNumber) {
    _currentPageRows = 0;
    _currentHasMore = true;
    _emit(
      'ChessEver: loading page $pageNumber '
      '($_chessEverPageSize games per request)...',
      _fractionForPage(0),
      force: true,
    );
  }

  void pageReturned({
    required int pageNumber,
    required int rowsOnPage,
    required bool? hasMore,
  }) {
    _currentPageRows = rowsOnPage;
    _currentHasMore = hasMore;
    if (hasMore != true) _finishedPages = true;
    _emit(
      'ChessEver: page $pageNumber returned $rowsOnPage games; '
      'building PGNs...',
      _fractionForPage(0),
      force: true,
    );
  }

  void pagePrepared({
    required int pageNumber,
    required _ChessEverPageProgress pageProgress,
  }) {
    final readyTotal = _readyPgns + pageProgress.readyOnPage;
    final displayTotal = _displayTotalForReady(readyTotal);
    _emit(
      'ChessEver: page $pageNumber prepared '
      '${pageProgress.readyOnPage}/$_currentPageRows games; '
      '$readyTotal/$displayTotal ready...',
      _fractionForPage(pageProgress.workFraction),
    );
  }

  void pageFinished({
    required int rowsOnPage,
    required int readyOnPage,
    required bool? hasMore,
  }) {
    _completedRows += rowsOnPage;
    _readyPgns += readyOnPage;
    _currentPageRows = 0;
    _currentHasMore = hasMore;
    if (hasMore != true) _finishedPages = true;
    _emit(
      'ChessEver: fetched $_completedRows'
      '${_totalSuffix(_messageTotalCount)} games; '
      '$_readyPgns PGNs ready...',
      _fractionForPage(0),
      force: true,
    );
  }

  int? get _knownTotalCount {
    var total = 0;
    final expected = _expectedGameCount;
    if (expected != null && expected > total) total = expected;
    final responseTotal = _totalCount;
    if (responseTotal != null && responseTotal > total) total = responseTotal;
    return total > 0 ? total : null;
  }

  int? get _messageTotalCount {
    if (_finishedPages) return _completedRows > 0 ? _completedRows : null;
    return _knownTotalCount;
  }

  int? get _estimatedTotalCount {
    final knownRows = _completedRows + _currentPageRows;
    if (_finishedPages) return knownRows > 0 ? knownRows : null;
    final known = _knownTotalCount;
    if (known != null) return known > knownRows ? known : knownRows;
    if (knownRows <= 0) return null;
    if (_currentHasMore == false ||
        (_currentPageRows > 0 && _currentPageRows < _chessEverPageSize)) {
      return knownRows;
    }
    return knownRows + _chessEverPageSize;
  }

  int _displayTotalForReady(int ready) {
    final total = _estimatedTotalCount;
    if (total == null || total < ready) return ready;
    return total;
  }

  double? _fractionForPage(double pageFraction) {
    final total = _estimatedTotalCount;
    if (total == null || total <= 0) return null;
    final currentRows = _currentPageEquivalentRows(pageFraction);
    return ((_completedRows + currentRows) / total).clamp(0.0, 1.0).toDouble();
  }

  double _currentPageEquivalentRows(double pageFraction) {
    return _currentPageRows * pageFraction.clamp(0.0, 1.0);
  }

  void _emit(String message, double? progress, {bool force = false}) {
    if (!force && progress != null) {
      final scaled = (progress * 10000).round();
      if (!_throttle.shouldReport(scaled)) return;
    }
    onProgress?.call(message, progress);
  }
}

class _PgnStreamGameCounter {
  var _pendingLine = '';
  var _receivedGames = 0;
  var _finished = false;

  int get receivedGames => _receivedGames;

  void addChunk(String chunk) {
    final normalized = chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final text = _pendingLine + normalized;
    final lines = text.split('\n');
    _pendingLine = lines.removeLast();
    for (final line in lines) {
      if (line.trimLeft().startsWith('[Event "')) _receivedGames += 1;
    }
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    if (_pendingLine.trimLeft().startsWith('[Event "')) {
      _receivedGames += 1;
    }
    _pendingLine = '';
  }
}

class _ProgressThrottle {
  _ProgressThrottle() : _watch = Stopwatch()..start();

  static const int _minDelta = 25;
  static const Duration _minInterval = Duration(milliseconds: 180);
  final Stopwatch _watch;
  var _lastValue = -1;
  var _lastMs = 0;

  bool shouldReport(int value) {
    if (_lastValue < 0) {
      _lastValue = value;
      _lastMs = _watch.elapsedMilliseconds;
      return true;
    }
    final elapsed = _watch.elapsedMilliseconds;
    if (value != _lastValue && (value - _lastValue).abs() >= _minDelta) {
      _lastValue = value;
      _lastMs = elapsed;
      return true;
    }
    if (value != _lastValue &&
        elapsed - _lastMs >= _minInterval.inMilliseconds) {
      _lastValue = value;
      _lastMs = elapsed;
      return true;
    }
    return false;
  }
}

class _LichessPgnStreamProgress {
  _LichessPgnStreamProgress({
    required this.expectedGameCount,
    required this.onProgress,
  });

  final int? expectedGameCount;
  final PlayerWorkspaceProgress? onProgress;

  final _counter = _PgnStreamGameCounter();
  final _throttle = _ProgressThrottle();
  var _lastReportedGames = -1;
  var _finished = false;

  int get receivedGames => _counter.receivedGames;

  void start() {
    final expected = expectedGameCount;
    if (expected != null && expected > 0) {
      onProgress?.call(
        'Opening Lichess download: 0 of about $expected games received...',
        0,
      );
    } else {
      onProgress?.call('Opening Lichess download...', null);
    }
  }

  void addChunk(String chunk) {
    _counter.addChunk(chunk);
    _report();
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    _counter.finish();
    final expected = expectedGameCount;
    if (expected != null && expected > 0) {
      onProgress?.call(
        'Parsing Lichess PGN: $receivedGames of about $expected games received...',
        (receivedGames / expected).clamp(0.0, 1.0).toDouble(),
      );
    } else {
      onProgress?.call(
        receivedGames > 0
            ? 'Parsing Lichess PGN: $receivedGames games received...'
            : 'Parsing Lichess PGN...',
        null,
      );
    }
  }

  void _report() {
    if (receivedGames == _lastReportedGames) return;
    if (!_finished && !_throttle.shouldReport(receivedGames)) return;
    _lastReportedGames = receivedGames;
    final expected = expectedGameCount;
    if (expected != null && expected > 0) {
      onProgress?.call(
        'Receiving Lichess games: $receivedGames of about $expected...',
        (receivedGames / expected).clamp(0.0, 1.0).toDouble(),
      );
    } else {
      onProgress?.call(
        receivedGames > 0
            ? 'Receiving Lichess games: $receivedGames received...'
            : 'Receiving Lichess games...',
        null,
      );
    }
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
  final seen = <String>{};
  final games = <_PreparedPgnGame>[];
  for (final chunk in chunks) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
    final fingerprint = localChessPgnFingerprint(trimmed);
    if (!seen.add(fingerprint)) continue;
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
}) {
  final inputs = sources.toList(growable: false);
  final aliases = playerAliases.toList(growable: false);
  return Isolate.run(
    () => _prepareCombinedPgnImportSync(
      inputs,
      combinedPath,
      aliases,
      playerFideId,
    ),
  );
}

_PreparedCombinedPgnImport _prepareCombinedPgnImportSync(
  List<PlayerWorkspaceCombinedSource> inputs,
  String combinedPath,
  List<String> aliases,
  String? playerFideId,
) {
  final output = File(combinedPath);
  output.parent.createSync(recursive: true);
  final tempPath =
      '$combinedPath.tmp-${DateTime.now().microsecondsSinceEpoch}-${Isolate.current.hashCode}';
  final temp = File(tempPath);
  final writer = temp.openSync(mode: FileMode.write);
  final seen = <String>{};
  final stats = _PgnStatsCounter(aliases, playerFideId: playerFideId);
  var wroteAny = false;
  try {
    for (final input in inputs) {
      for (final chunk in _readPgnGamesFromFileSync(input.path)) {
        final trimmed = chunk.trim();
        if (trimmed.isEmpty) continue;
        final fingerprint = localChessPgnFingerprint(trimmed);
        if (!seen.add(fingerprint)) continue;
        if (wroteAny) writer.writeStringSync('\n\n');
        writer.writeStringSync(_withCombinedMetadata(trimmed, input.source));
        stats.add(trimmed);
        wroteAny = true;
      }
    }
    if (wroteAny) writer.writeStringSync('\n');
    writer.flushSync();
    writer.closeSync();
    if (output.existsSync()) output.deleteSync();
    temp.renameSync(combinedPath);
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

String _withCombinedMetadata(String pgn, PlayerWorkspaceSource source) {
  final headers = _pgnHeaders(pgn);
  final explicitOrInferred = classifyTimeControlCategory(
    headers['timecontrol'],
    event: headers['event'],
    site: headers['site'],
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

Future<PlayerWorkspaceImportStats> _statsForImportedLocalDatabase({
  required LocalChessDatabaseRepository localRepository,
  required String path,
  required Iterable<String> playerAliases,
  String? playerFideId,
  required int fallbackGameCount,
  required Duration timeout,
}) async {
  return _loadImportStatsWithFallback(
    contextPath: path,
    fallbackGameCount: fallbackGameCount,
    timeout: timeout,
    loadStats:
        () => localRepository.localDatabaseResultStats(
          databasePath: path,
          playerAliases: playerAliases,
          playerFideId: playerFideId,
        ),
  );
}

Future<PlayerWorkspaceImportStats> _statsForLocalDatabases({
  required LocalChessDatabaseRepository localRepository,
  required Iterable<String> databasePaths,
  required Iterable<String> playerAliases,
  String? playerFideId,
  required int fallbackGameCount,
  required Duration timeout,
}) {
  final paths = databasePaths.toList(growable: false);
  return _loadImportStatsWithFallback(
    contextPath: paths.join('|'),
    fallbackGameCount: fallbackGameCount,
    timeout: timeout,
    loadStats:
        () => localRepository.resultStatsForDatabases(
          databasePaths: paths,
          playerAliases: playerAliases,
          playerFideId: playerFideId,
        ),
  );
}

Future<PlayerWorkspaceImportStats> _loadImportStatsWithFallback({
  required String contextPath,
  required int fallbackGameCount,
  required Duration timeout,
  required Future<LocalChessDatabaseResultStats> Function() loadStats,
}) async {
  try {
    final stats = await loadStats().timeout(timeout);
    if (stats.gameCount <= 0 && fallbackGameCount > 0) {
      return PlayerWorkspaceImportStats(gameCount: fallbackGameCount);
    }
    return PlayerWorkspaceImportStats(
      gameCount: stats.gameCount,
      winCount: stats.winCount,
      drawCount: stats.drawCount,
      lossCount: stats.lossCount,
    );
  } catch (error, stackTrace) {
    if (fallbackGameCount <= 0) rethrow;
    localChessLog.warning(
      'Player workspace import stats unavailable; using fallback count',
      context: <String, Object?>{
        'path': contextPath,
        'fallbackGames': fallbackGameCount,
      },
      error: error,
      stackTrace: stackTrace,
    );
    return PlayerWorkspaceImportStats(gameCount: fallbackGameCount);
  }
}

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
    final headers = _pgnHeaders(chunk);
    final result = headers['result'] ?? '';
    final white = _normalizePlayerName(headers['white']);
    final black = _normalizePlayerName(headers['black']);
    final whiteFideId = _normalizeFideId(headers['whitefideid']);
    final blackFideId = _normalizeFideId(headers['blackfideid']);
    final hasAnyFideId = whiteFideId != null || blackFideId != null;
    final isWhite = _matchesPgnSide(name: white, fideId: whiteFideId);
    final isBlack = _matchesPgnSide(name: black, fideId: blackFideId);
    if (!isWhite && !isBlack) {
      if (_playerFideId != null && !hasAnyFideId) {
        _games++;
        if (_isDrawResult(result)) _draws++;
      }
      return;
    }
    _games++;
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

Iterable<String> _readPgnGamesFromFileSync(String path) sync* {
  final file = File(path);
  if (!file.existsSync()) return;
  final game = StringBuffer();
  var firstLine = true;
  var sawMoveText = false;
  var inComment = false;
  for (var line in _readUtf8LinesFromFileSync(file)) {
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

Iterable<String> _readUtf8LinesFromFileSync(File file) sync* {
  const chunkSize = 64 * 1024;
  final reader = file.openSync();
  final pending = BytesBuilder(copy: false);
  try {
    while (true) {
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

List<String> _dedupePgnChunks(Iterable<String> chunks) {
  final seen = <String>{};
  final unique = <String>[];
  for (final chunk in chunks) {
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) continue;
    final hash = localChessPgnFingerprint(trimmed);
    if (!seen.add(hash)) continue;
    unique.add(trimmed);
  }
  return unique;
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

List<Map<String, dynamic>> _rowsFromPlayerGamesResponse(
  Map<String, dynamic> response,
) {
  final data = response['data'];
  if (data is! List) return const <Map<String, dynamic>>[];
  return data
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .where((row) => (row['id']?.toString().trim() ?? '').isNotEmpty)
      .toList(growable: false);
}

bool? _readHasMore(Map<String, dynamic> response) {
  final metadata = response['metadata'];
  if (metadata is Map) {
    return _readBool(
      metadata['hasMore'] ?? metadata['has_more'] ?? metadata['hasNextPage'],
    );
  }
  return _readBool(
    response['hasMore'] ?? response['has_more'] ?? response['hasNextPage'],
  );
}

int? _readTotalCount(Map<String, dynamic> response) {
  final metadata = response['metadata'];
  if (metadata is Map) {
    final count =
        _readInt(metadata['totalCount']) ??
        _readInt(metadata['total_count']) ??
        _readInt(metadata['total']) ??
        _readInt(metadata['count']);
    if (count != null && count > 0) return count;
  }
  final count =
      _readInt(response['totalCount']) ??
      _readInt(response['total_count']) ??
      _readInt(response['total']) ??
      _readInt(response['count']);
  return count != null && count > 0 ? count : null;
}

String _totalSuffix(int? totalCount) {
  if (totalCount == null || totalCount <= 0) return '';
  return '/$totalCount';
}

bool? _readBool(Object? value) {
  if (value is bool) return value;
  final raw = value?.toString().toLowerCase().trim();
  if (raw == 'true' || raw == '1' || raw == 'yes') return true;
  if (raw == 'false' || raw == '0' || raw == 'no') return false;
  return null;
}

String? _pgnFromGamebase(GamebaseGameWithPgn? full, Map<String, dynamic> row) {
  final direct = full?.pgn?.trim();
  if (direct != null && direct.isNotEmpty && _pgnHasMoves(direct)) {
    return direct;
  }
  final rowDirect = row['pgn']?.toString().trim();
  if (rowDirect != null && rowDirect.isNotEmpty && _pgnHasMoves(rowDirect)) {
    return rowDirect;
  }
  final fullData = full?.data;
  if (fullData != null) {
    final built = buildPgnFromGamebaseData(fullData);
    if (built != null && _pgnHasMoves(built)) return built;
  }
  final rowData = row['data'];
  if (rowData is Map) {
    final built = buildPgnFromGamebaseData(Map<String, dynamic>.from(rowData));
    if (built != null && _pgnHasMoves(built)) return built;
  }
  return null;
}

bool _pgnHasMoves(String pgn) {
  final body =
      pgn.replaceAll(RegExp(r'^\s*\[[^\]]+\]\s*$', multiLine: true), '').trim();
  return body.isNotEmpty && body != '*';
}

int _sourceGameCount(LocalChessSource? source, {int fallback = 0}) {
  final root = source?.root;
  if (root == null) return fallback;
  return root.gameCount;
}

bool _archiveIsAfterSinceMonth(String archiveUrl, int? sinceMs) {
  if (sinceMs == null || sinceMs <= 0) return true;
  final match = RegExp(r'/games/(\d{4})/(\d{2})/?$').firstMatch(archiveUrl);
  if (match == null) return true;
  final year = int.tryParse(match.group(1) ?? '');
  final month = int.tryParse(match.group(2) ?? '');
  if (year == null || month == null) return true;
  final archiveStart = DateTime.utc(year, month).millisecondsSinceEpoch;
  final since = DateTime.fromMillisecondsSinceEpoch(sinceMs, isUtc: true);
  final sinceMonth =
      DateTime.utc(since.year, since.month).millisecondsSinceEpoch;
  return archiveStart >= sinceMonth;
}

double _chessComArchiveProgress(int completedArchives, int totalArchives) {
  if (totalArchives <= 0) return 1;
  final archiveFraction = (completedArchives / totalArchives).clamp(0.0, 1.0);
  return (_chessComArchiveProgressFloor +
          archiveFraction * (1 - _chessComArchiveProgressFloor))
      .clamp(_chessComArchiveProgressFloor, 1.0);
}

Timer? _startSourceSnapshotWaitProgress({
  required PlayerWorkspaceProgress? onProgress,
  required String label,
}) {
  if (onProgress == null) return null;
  var step = 0;
  return Timer.periodic(const Duration(seconds: 5), (_) {
    final index =
        step.clamp(0, _sourceSnapshotWaitProgressSteps.length - 1).toInt();
    onProgress(
      '$label: preparing source snapshot...',
      _sourceSnapshotWaitProgressSteps[index],
    );
    if (step < _sourceSnapshotWaitProgressSteps.length - 1) step += 1;
  });
}

String? _gamebaseDate(DateTime? date) {
  if (date == null) return null;
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

String _chessComArchiveLabel(String archiveUrl) {
  final match = RegExp(r'/games/(\d{4})/(\d{2})/?$').firstMatch(archiveUrl);
  if (match == null) return 'archive';
  return '${match.group(1)}/${match.group(2)}';
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

/// File name for the player's deduplicated combined database.
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
