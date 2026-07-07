import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';

const String _workspaceStorageKey = 'desktop_player_workspace_v1';
const String _httpUserAgent =
    'ChessEverDesktop/1.0 (https://chessever.com; support@chessever.com)';
const int _chessComArchiveConcurrency = 8;
const int _chessEverPageSize = 1000;
const int _chessEverHydrateConcurrency = 16;

typedef PlayerWorkspaceProgress =
    void Function(String message, double? progress);

class PlayerWorkspaceRepository {
  PlayerWorkspaceRepository({AppDatabase? appDatabase, http.Client? client})
    : _appDatabase = appDatabase ?? AppDatabase.instance,
      _client = client ?? http.Client();

  final AppDatabase _appDatabase;
  final http.Client _client;

  Future<PlayerWorkspaceSnapshot> loadSnapshot() async {
    final raw = await _appDatabase.getJson<Object?>(_workspaceStorageKey);
    return PlayerWorkspaceSnapshot.fromJson(raw);
  }

  Future<void> saveSnapshot(PlayerWorkspaceSnapshot snapshot) async {
    await _appDatabase.setJson(_workspaceStorageKey, snapshot.toJson());
  }

  Future<String> sourcePgnPath({
    required String playerId,
    required PlayerWorkspaceSource source,
    String? username,
  }) async {
    final root = await _playerWorkspaceDirectory(playerId);
    final sourceName = source.storageKey;
    final suffix = _safeFilePart(username ?? source.label);
    return p.join(root.path, '$sourceName-$suffix.pgn');
  }

  Future<String> combinedPgnPath({required String playerId}) async {
    final root = await _playerWorkspaceDirectory(playerId);
    return p.join(root.path, 'combined.pgn');
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
      id: 'player-$now-${_safeFilePart(player.id)}',
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
      id: 'player-$now-${_safeFilePart(clean)}',
      displayName: clean,
      createdAtMs: now,
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> downloadLichessGames({
    required String username,
    int? sinceMs,
    int? expectedGameCount,
    PlayerWorkspaceProgress? onProgress,
  }) async {
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
    );
    progress.finish();
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.lichess,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> downloadChessComGames({
    required String username,
    int? sinceMs,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    final clean = username.trim().toLowerCase();
    final archivesUri = Uri.https(
      'api.chess.com',
      '/pub/player/$clean/games/archives',
    );
    onProgress?.call('Chess.com: loading monthly archive list...', null);
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
        0,
      );
    }
    final downloads = await _mapConcurrentIndexed<String, _IndexedPgn>(
      archives,
      concurrency: _chessComArchiveConcurrency,
      mapper: (archiveUrl, index) async {
        final pgnUrl =
            archiveUrl.endsWith('/pgn') ? archiveUrl : '$archiveUrl/pgn';
        onProgress?.call(
          'Chess.com: started ${_chessComArchiveLabel(archiveUrl)} '
          '(${index + 1}/${archives.length}); $completedArchives done, '
          '$downloadedGames games received...',
          completedArchives / archives.length,
        );
        final pgn = await _downloadText(
          Uri.parse(pgnUrl),
          accept: 'application/x-chess-pgn',
        );
        final gameCount = splitPgnGames(pgn).length;
        completedArchives += 1;
        downloadedGames += gameCount;
        onProgress?.call(
          'Chess.com: $completedArchives/${archives.length} archives done; '
          '$downloadedGames games received...',
          completedArchives / archives.length,
        );
        return _IndexedPgn(index, pgn);
      },
    );
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
      gameCount: splitPgnGames(text).length,
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> downloadChessEverGames({
    required GamebaseRepository repository,
    required String playerId,
    DateTime? sinceDate,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    final buffer = StringBuffer();
    var page = 0;
    var total = 0;
    int? totalCount;
    while (true) {
      onProgress?.call(
        'ChessEver: loading page ${page + 1} '
        '($_chessEverPageSize games per request)...',
        totalCount == null || totalCount <= 0
            ? null
            : (total / totalCount).clamp(0.0, 1.0).toDouble(),
      );
      final response = await repository.getPlayerGames(
        playerId: playerId,
        pageNumber: page,
        pageSize: _chessEverPageSize,
        includeData: true,
        dateFrom: _gamebaseDate(sinceDate),
      );
      final rows = _rowsFromPlayerGamesResponse(response);
      if (rows.isEmpty) break;
      totalCount ??= _readTotalCount(response);
      onProgress?.call(
        'ChessEver: page ${page + 1} returned ${rows.length} games; '
        'building PGNs...',
        totalCount == null || totalCount <= 0
            ? null
            : (total / totalCount).clamp(0.0, 1.0).toDouble(),
      );
      final pgns = await _chessEverPgnsForRows(
        repository: repository,
        rows: rows,
        pageNumber: page + 1,
        onProgress: onProgress,
      );
      for (final pgn in pgns) {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln(pgn.trim());
      }
      total += rows.length;
      onProgress?.call(
        'ChessEver: fetched $total${_totalSuffix(totalCount)} games; '
        '${splitPgnGames(buffer.toString()).length} PGNs ready...',
        totalCount == null || totalCount <= 0
            ? null
            : (total / totalCount).clamp(0.0, 1.0).toDouble(),
      );
      final hasMore = _readHasMore(response);
      if (hasMore != true) break;
      page++;
    }
    final text = buffer.toString();
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.chessever,
      pgn: text,
      gameCount: splitPgnGames(text).length,
    );
  }

  Future<PlayerWorkspaceDownloadedPgn> readManualPgnPaths({
    required List<String> paths,
    PlayerWorkspaceProgress? onProgress,
  }) async {
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
    final chunks = <String>[
      for (final game in source.games)
        if (game.rawPgn.trim().isNotEmpty) game.rawPgn.trim(),
    ];
    final pgn = _joinPgnChunks(_dedupePgnChunks(chunks));
    return PlayerWorkspaceDownloadedPgn(
      source: PlayerWorkspaceSource.manual,
      pgn: pgn,
      gameCount: splitPgnGames(pgn).length,
    );
  }

  Future<PlayerWorkspaceImportResult> mergeIntoLocalDatabase({
    required LocalChessDatabaseRepository localRepository,
    required String path,
    required String sourceLabel,
    required String pgn,
    required Iterable<String> playerAliases,
    bool replaceExisting = false,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    final chunks = splitPgnGames(pgn);
    final file = File(path);
    final unique = _dedupePgnChunks(chunks);
    if (replaceExisting) {
      await file.parent.create(recursive: true);
      await file.writeAsString(_joinPgnChunks(unique), flush: true);
      onProgress?.call('Reinstalling $sourceLabel...', null);
      final source = await localRepository.importSingleFileSource(
        path: path,
        sourceLabel: sourceLabel,
        onProgress:
            (progress) => onProgress?.call(progress.message, progress.fraction),
      );
      final stats = analyzePgnStats(unique, playerAliases);
      return PlayerWorkspaceImportResult(
        path: path,
        source: source,
        stats: PlayerWorkspaceImportStats(
          gameCount: _sourceGameCount(source, fallback: unique.length),
          newGameCount: unique.length,
          winCount: stats.winCount,
          drawCount: stats.drawCount,
          lossCount: stats.lossCount,
        ),
      );
    }

    if (unique.isEmpty) {
      final source = await localRepository.loadFreshSource(<String>[
        path,
      ], sourceLabel: sourceLabel);
      return PlayerWorkspaceImportResult(
        path: path,
        source: source,
        stats: PlayerWorkspaceImportStats(gameCount: _sourceGameCount(source)),
      );
    }

    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      await file.writeAsString(_joinPgnChunks(unique), flush: true);
      onProgress?.call('Importing $sourceLabel...', null);
      final source = await localRepository.importSingleFileSource(
        path: path,
        sourceLabel: sourceLabel,
        onProgress:
            (progress) => onProgress?.call(progress.message, progress.fraction),
      );
      final stats = analyzePgnStats(
        splitPgnGames(await file.readAsString()),
        playerAliases,
      );
      return PlayerWorkspaceImportResult(
        path: path,
        source: source,
        stats: PlayerWorkspaceImportStats(
          gameCount: _sourceGameCount(source, fallback: unique.length),
          newGameCount: unique.length,
          winCount: stats.winCount,
          drawCount: stats.drawCount,
          lossCount: stats.lossCount,
        ),
      );
    }

    final hashes = unique.map(localChessPgnFingerprint).toList(growable: false);
    final existingHashes = await localRepository
        .localDatabaseMatchingPgnFingerprints(
          databasePath: path,
          fingerprints: hashes,
        );
    if (existingHashes == null) {
      await file.writeAsString(_joinPgnChunks(unique), flush: true);
      final source = await localRepository.importSingleFileSource(
        path: path,
        sourceLabel: sourceLabel,
        onProgress:
            (progress) => onProgress?.call(progress.message, progress.fraction),
      );
      final stats = analyzePgnStats(unique, playerAliases);
      return PlayerWorkspaceImportResult(
        path: path,
        source: source,
        stats: PlayerWorkspaceImportStats(
          gameCount: _sourceGameCount(source, fallback: unique.length),
          newGameCount: unique.length,
          winCount: stats.winCount,
          drawCount: stats.drawCount,
          lossCount: stats.lossCount,
        ),
      );
    }

    final appended = <String>[];
    final seen = Set<String>.from(existingHashes);
    for (final chunk in unique) {
      final hash = localChessPgnFingerprint(chunk);
      if (!seen.add(hash)) continue;
      appended.add(chunk);
    }
    if (appended.isNotEmpty) {
      final sink = file.openWrite(mode: FileMode.append);
      try {
        for (final chunk in appended) {
          sink.writeln();
          sink.writeln(chunk.trim());
        }
      } finally {
        await sink.close();
      }
      await localRepository.persistAppendedPgnGames(
        databasePath: path,
        appendedPgns: [
          for (final chunk in appended) LocalChessAppendedPgn(rawPgn: chunk),
        ],
      );
    }
    final source = await localRepository.loadFreshSource(<String>[
      path,
    ], sourceLabel: sourceLabel);
    final allChunks =
        await file.exists() ? splitPgnGames(await file.readAsString()) : unique;
    final stats = analyzePgnStats(allChunks, playerAliases);
    return PlayerWorkspaceImportResult(
      path: path,
      source: source,
      stats: PlayerWorkspaceImportStats(
        gameCount: _sourceGameCount(source, fallback: allChunks.length),
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
    required Iterable<String> sourcePaths,
    required Iterable<String> playerAliases,
    PlayerWorkspaceProgress? onProgress,
  }) async {
    final chunks = <String>[];
    for (final path in sourcePaths) {
      final file = File(path);
      if (!await file.exists()) continue;
      chunks.addAll(splitPgnGames(await file.readAsString()));
    }
    final unique = _dedupePgnChunks(chunks);
    final combinedPath = await combinedPgnPath(playerId: playerId);
    await File(combinedPath).parent.create(recursive: true);
    await File(combinedPath).writeAsString(_joinPgnChunks(unique), flush: true);
    final source = await localRepository.importSingleFileSource(
      path: combinedPath,
      sourceLabel: '$playerName Combined',
      onProgress:
          (progress) => onProgress?.call(progress.message, progress.fraction),
    );
    final stats = analyzePgnStats(unique, playerAliases);
    return PlayerWorkspaceImportResult(
      path: combinedPath,
      source: source,
      stats: PlayerWorkspaceImportStats(
        gameCount: _sourceGameCount(source, fallback: unique.length),
        newGameCount: unique.length,
        winCount: stats.winCount,
        drawCount: stats.drawCount,
        lossCount: stats.lossCount,
      ),
    );
  }

  Future<Directory> _playerWorkspaceDirectory(String playerId) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(
      p.join(support.path, 'player-workspace', _safeFilePart(playerId)),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> _downloadText(
    Uri uri, {
    required String accept,
    void Function(String chunk)? onTextChunk,
  }) async {
    final request = http.Request('GET', uri)
      ..headers.addAll(<String, String>{
        'Accept': accept,
        'User-Agent': _httpUserAgent,
      });
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw StateError(
        'Request failed (${response.statusCode}) for $uri: ${body.trim()}',
      );
    }
    final buffer = StringBuffer();
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer.write(chunk);
      onTextChunk?.call(chunk);
    }
    return buffer.toString();
  }

  Future<List<String>> _chessEverPgnsForRows({
    required GamebaseRepository repository,
    required List<Map<String, dynamic>> rows,
    required int pageNumber,
    required PlayerWorkspaceProgress? onProgress,
  }) async {
    final outputByIndex = <int, String>{};
    final hydrateTargets = <_ChessEverHydrationTarget>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final rowPgn = _pgnFromGamebase(null, row);
      if (rowPgn != null && rowPgn.trim().isNotEmpty) {
        outputByIndex[i] = rowPgn.trim();
        continue;
      }
      final id = row['id']?.toString().trim() ?? '';
      if (id.isEmpty) continue;
      hydrateTargets.add(_ChessEverHydrationTarget(index: i, id: id, row: row));
    }

    final embeddedCount = outputByIndex.length;
    if (hydrateTargets.isEmpty) {
      onProgress?.call(
        'ChessEver: page $pageNumber has embedded PGN data for all '
        '${rows.length} games.',
        1,
      );
      return <String>[
        for (var i = 0; i < rows.length; i++)
          if (outputByIndex[i] != null) outputByIndex[i]!,
      ];
    }

    onProgress?.call(
      'ChessEver: $embeddedCount/${rows.length} PGNs embedded; hydrating '
      '${hydrateTargets.length} missing PGNs '
      '(${_chessEverHydrateConcurrency.clamp(1, hydrateTargets.length)} at a time)...',
      rows.isEmpty ? null : embeddedCount / rows.length,
    );
    var completedHydrations = 0;
    var hydratedPgnCount = 0;
    final hydrated = await _mapConcurrentIndexed<
      _ChessEverHydrationTarget,
      _IndexedPgn?
    >(
      hydrateTargets,
      concurrency: _chessEverHydrateConcurrency,
      mapper: (target, _) async {
        final full = await repository.getGameWithPgn(target.id);
        final pgn = _pgnFromGamebase(full, target.row);
        completedHydrations += 1;
        if (pgn == null || pgn.trim().isEmpty) {
          onProgress?.call(
            'ChessEver: hydrated $completedHydrations/'
            '${hydrateTargets.length} missing PGNs; '
            '${embeddedCount + hydratedPgnCount}/${rows.length} ready on page '
            '$pageNumber...',
            rows.isEmpty
                ? null
                : ((embeddedCount + hydratedPgnCount) / rows.length)
                    .clamp(0.0, 1.0)
                    .toDouble(),
          );
          return null;
        }
        hydratedPgnCount += 1;
        onProgress?.call(
          'ChessEver: hydrated $completedHydrations/'
          '${hydrateTargets.length} missing PGNs; '
          '${embeddedCount + hydratedPgnCount}/${rows.length} ready on page '
          '$pageNumber...',
          rows.isEmpty
              ? null
              : ((embeddedCount + hydratedPgnCount) / rows.length)
                  .clamp(0.0, 1.0)
                  .toDouble(),
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

class _LichessPgnStreamProgress {
  _LichessPgnStreamProgress({
    required this.expectedGameCount,
    required this.onProgress,
  });

  final int? expectedGameCount;
  final PlayerWorkspaceProgress? onProgress;

  var _pendingLine = '';
  var _receivedGames = 0;
  var _lastReportedGames = -1;
  var _finished = false;

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
    final normalized = chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final text = _pendingLine + normalized;
    final lines = text.split('\n');
    _pendingLine = lines.removeLast();
    for (final line in lines) {
      if (line.trimLeft().startsWith('[Event "')) _receivedGames += 1;
    }
    _report();
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    if (_pendingLine.trimLeft().startsWith('[Event "')) {
      _receivedGames += 1;
      _pendingLine = '';
    }
    final expected = expectedGameCount;
    if (expected != null && expected > 0) {
      onProgress?.call(
        'Parsing Lichess PGN: $_receivedGames of about $expected games received...',
        (_receivedGames / expected).clamp(0.0, 1.0).toDouble(),
      );
    } else {
      onProgress?.call(
        _receivedGames > 0
            ? 'Parsing Lichess PGN: $_receivedGames games received...'
            : 'Parsing Lichess PGN...',
        null,
      );
    }
  }

  void _report() {
    if (_receivedGames == _lastReportedGames) return;
    _lastReportedGames = _receivedGames;
    final expected = expectedGameCount;
    if (expected != null && expected > 0) {
      onProgress?.call(
        'Receiving Lichess games: $_receivedGames of about $expected...',
        (_receivedGames / expected).clamp(0.0, 1.0).toDouble(),
      );
    } else {
      onProgress?.call(
        _receivedGames > 0
            ? 'Receiving Lichess games: $_receivedGames received...'
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
  });

  final PlayerWorkspaceSource source;
  final String pgn;
  final int gameCount;
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

PlayerWorkspaceImportStats analyzePgnStats(
  Iterable<String> chunks,
  Iterable<String> aliases,
) {
  final normalizedAliases =
      aliases
          .map(_normalizePlayerName)
          .where((name) => name.isNotEmpty)
          .toSet();
  var games = 0;
  var wins = 0;
  var draws = 0;
  var losses = 0;
  for (final chunk in chunks) {
    final headers = _pgnHeaders(chunk);
    final result = headers['result'] ?? '';
    final white = _normalizePlayerName(headers['white']);
    final black = _normalizePlayerName(headers['black']);
    if (white.isEmpty && black.isEmpty) continue;
    games++;
    final isWhite =
        normalizedAliases.isEmpty || normalizedAliases.contains(white);
    final isBlack = normalizedAliases.contains(black);
    if (result == '1/2-1/2' || result == '1/2' || result == '½-½') {
      draws++;
    } else if ((result == '1-0' && isWhite) || (result == '0-1' && isBlack)) {
      wins++;
    } else if ((result == '0-1' && isWhite) || (result == '1-0' && isBlack)) {
      losses++;
    }
  }
  return PlayerWorkspaceImportStats(
    gameCount: games,
    winCount: wins,
    drawCount: draws,
    lossCount: losses,
  );
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
  return (name ?? '')
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(',', '')
      .trim();
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

String _safeFilePart(String value) {
  final cleaned = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return cleaned.isEmpty ? 'player' : cleaned;
}
