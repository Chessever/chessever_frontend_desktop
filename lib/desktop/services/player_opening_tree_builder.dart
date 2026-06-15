import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';

enum PlayerOpeningTreeStatus { idle, building, complete, canceled, error }

@immutable
class PlayerOpeningTreeProgress {
  const PlayerOpeningTreeProgress({
    this.status = PlayerOpeningTreeStatus.idle,
    this.currentPage = 0,
    this.fetchedGames = 0,
    this.processedGames = 0,
    this.skippedGames = 0,
    this.indexedPositions = 0,
    this.gamesDownloadComplete = false,
    this.totalGames,
    this.priorityColor,
    this.priorityFetchedGames,
    this.priorityTotalGames,
    this.error,
  });

  final PlayerOpeningTreeStatus status;
  final int currentPage;
  final int fetchedGames;
  final int processedGames;
  final int skippedGames;
  final int indexedPositions;
  final bool gamesDownloadComplete;
  final int? totalGames;
  final String? priorityColor;
  final int? priorityFetchedGames;
  final int? priorityTotalGames;
  final String? error;

  bool get isRunning => status == PlayerOpeningTreeStatus.building;

  PlayerOpeningTreeProgress copyWith({
    PlayerOpeningTreeStatus? status,
    int? currentPage,
    int? fetchedGames,
    int? processedGames,
    int? skippedGames,
    int? indexedPositions,
    bool? gamesDownloadComplete,
    int? totalGames,
    String? priorityColor,
    int? priorityFetchedGames,
    int? priorityTotalGames,
    String? error,
  }) {
    return PlayerOpeningTreeProgress(
      status: status ?? this.status,
      currentPage: currentPage ?? this.currentPage,
      fetchedGames: fetchedGames ?? this.fetchedGames,
      processedGames: processedGames ?? this.processedGames,
      skippedGames: skippedGames ?? this.skippedGames,
      indexedPositions: indexedPositions ?? this.indexedPositions,
      gamesDownloadComplete:
          gamesDownloadComplete ?? this.gamesDownloadComplete,
      totalGames: totalGames ?? this.totalGames,
      priorityColor: priorityColor ?? this.priorityColor,
      priorityFetchedGames: priorityFetchedGames ?? this.priorityFetchedGames,
      priorityTotalGames: priorityTotalGames ?? this.priorityTotalGames,
      error: error,
    );
  }
}

@immutable
class PlayerOpeningTreeState {
  const PlayerOpeningTreeState({
    this.playerId,
    this.treeId,
    this.progress = const PlayerOpeningTreeProgress(),
    this.index = const PlayerOpeningTreeIndex.empty(),
  });

  final String? playerId;
  final String? treeId;
  final PlayerOpeningTreeProgress progress;
  final PlayerOpeningTreeIndex index;

  bool get hasUsableIndex => index.positionCount > 0;
  bool get isReady => progress.status == PlayerOpeningTreeStatus.complete;

  PlayerOpeningTreeState copyWith({
    String? playerId,
    String? treeId,
    PlayerOpeningTreeProgress? progress,
    PlayerOpeningTreeIndex? index,
  }) {
    return PlayerOpeningTreeState(
      playerId: playerId ?? this.playerId,
      treeId: treeId ?? this.treeId,
      progress: progress ?? this.progress,
      index: index ?? this.index,
    );
  }
}

@immutable
class PlayerOpeningTreeIndex {
  const PlayerOpeningTreeIndex({
    required this.treeId,
    required this.playerId,
    required this.maxPly,
    required this.rootNodeId,
    required this.generatedAt,
    required this.nodesById,
    required this.nodesByFenKey,
    required this.gamesByFen,
    required this.gameRowsById,
  });

  const PlayerOpeningTreeIndex.empty()
    : treeId = null,
      playerId = null,
      maxPly = 0,
      rootNodeId = 0,
      generatedAt = null,
      nodesById = const <int, PlayerOpeningTreeNode>{},
      nodesByFenKey = const <String, PlayerOpeningTreeNode>{},
      gamesByFen = const <String, List<PlayerOpeningTreeGameRef>>{},
      gameRowsById = const <String, Map<String, dynamic>>{};

  final String? treeId;
  final String? playerId;
  final int maxPly;
  final int rootNodeId;
  final DateTime? generatedAt;
  final Map<int, PlayerOpeningTreeNode> nodesById;
  final Map<String, PlayerOpeningTreeNode> nodesByFenKey;
  final Map<String, List<PlayerOpeningTreeGameRef>> gamesByFen;
  final Map<String, Map<String, dynamic>> gameRowsById;

  int get positionCount => nodesByFenKey.length;
  int get downloadedGameCount => gameRowsById.length;

  factory PlayerOpeningTreeIndex.fromSnapshot(
    PlayerOpeningTreeSnapshot snapshot,
  ) {
    return PlayerOpeningTreeIndex(
      treeId: snapshot.treeId,
      playerId: snapshot.playerId,
      maxPly: snapshot.maxPly,
      rootNodeId: snapshot.rootNodeId,
      generatedAt: snapshot.generatedAt,
      nodesById: Map<int, PlayerOpeningTreeNode>.unmodifiable({
        for (final node in snapshot.nodes) node.id: node,
      }),
      nodesByFenKey: Map<String, PlayerOpeningTreeNode>.unmodifiable({
        for (final node in snapshot.nodes) node.fenKey: node,
      }),
      gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
      gameRowsById: const <String, Map<String, dynamic>>{},
    );
  }

  PlayerOpeningTreeIndex copyWithGames(PlayerOpeningTreeGamesIndex games) {
    return PlayerOpeningTreeIndex(
      treeId: treeId,
      playerId: playerId,
      maxPly: maxPly,
      rootNodeId: rootNodeId,
      generatedAt: generatedAt,
      nodesById: nodesById,
      nodesByFenKey: nodesByFenKey,
      gamesByFen: games.gamesByFen,
      gameRowsById: games.gameRowsById,
    );
  }

  PlayerOpeningTreeGamesIndex toGamesIndex() {
    return PlayerOpeningTreeGamesIndex(
      gamesByFen: gamesByFen,
      gameRowsById: gameRowsById,
    );
  }

  List<MoveAggregate> movesForFen(
    String fen, {
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
  }) {
    final node = nodesByFenKey[_fenKey(fen)];
    if (node == null) return const <MoveAggregate>[];
    final moves = node.moves
      .map((move) => move.toMoveAggregate(filters: filters))
      .where((move) => move.total > 0)
      .toList(growable: false)..sort((a, b) => b.total.compareTo(a.total));
    return List<MoveAggregate>.unmodifiable(moves);
  }

  List<Map<String, dynamic>> gamesForFen(
    String fen, {
    String? uci,
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
    required GamebaseSortField sortBy,
    required GamebaseSortDirection sortDirection,
    required int pageNumber,
    required int pageSize,
  }) {
    final key = _fenKey(fen);
    var refs = _filteredRefsForKey(key, filters);
    final pinned = uci?.trim().toLowerCase();
    if (pinned != null && pinned.isNotEmpty) {
      refs = refs
          .where((ref) => _refContinuationStartsWith(ref, pinned))
          .toList(growable: false);
    }

    final sorted = refs
        .map(_rowForRef)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    sorted.sort((a, b) {
      final cmp = _compareRows(a, b, sortBy);
      return sortDirection == GamebaseSortDirection.asc ? cmp : -cmp;
    });

    final start = pageNumber * pageSize;
    if (start >= sorted.length) return const <Map<String, dynamic>>[];
    final end = (start + pageSize).clamp(0, sorted.length).toInt();
    return sorted.sublist(start, end);
  }

  int gamesCountForFen(
    String fen, {
    String? uci,
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
  }) {
    final refs = _filteredRefsForKey(_fenKey(fen), filters);
    final pinned = uci?.trim().toLowerCase();
    if (pinned == null || pinned.isEmpty) return refs.length;
    return refs.where((ref) => _refContinuationStartsWith(ref, pinned)).length;
  }

  List<PlayerOpeningTreeGameRef> _filteredRefsForKey(
    String key,
    PlayerOpeningTreeFilterCriteria filters,
  ) {
    final refs = gamesByFen[key] ?? const <PlayerOpeningTreeGameRef>[];
    if (!filters.hasFilters) return refs;
    return refs
        .where((ref) {
          final row = gameRowsById[ref.gameId];
          return row != null && filters.matches(row);
        })
        .toList(growable: false);
  }

  Map<String, dynamic>? _rowForRef(PlayerOpeningTreeGameRef ref) {
    final row = gameRowsById[ref.gameId];
    if (row == null) return null;
    return Map<String, dynamic>.unmodifiable(<String, dynamic>{
      ...row,
      'fen': ref.fen,
      'continuation': _continuationForRef(row, ref),
    });
  }

  bool _refContinuationStartsWith(PlayerOpeningTreeGameRef ref, String uci) {
    final row = gameRowsById[ref.gameId];
    if (row == null) return false;
    return _nextUciForRef(row, ref) == uci;
  }

  static int _compareRows(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    GamebaseSortField sortBy,
  ) {
    Object? value(Map<String, dynamic> row) {
      switch (sortBy) {
        case GamebaseSortField.date:
          return DateTime.tryParse(row['date']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
        case GamebaseSortField.avgElo:
          final w = _readInt(row['whiteElo']);
          final bl = _readInt(row['blackElo']);
          if (w <= 0 && bl <= 0) return 0;
          if (w <= 0) return bl;
          if (bl <= 0) return w;
          return ((w + bl) / 2).round();
        case GamebaseSortField.whiteElo:
          return _readInt(row['whiteElo']);
        case GamebaseSortField.blackElo:
          return _readInt(row['blackElo']);
        case GamebaseSortField.whiteName:
          return row['white']?.toString().toLowerCase() ?? '';
        case GamebaseSortField.blackName:
          return row['black']?.toString().toLowerCase() ?? '';
        case GamebaseSortField.result:
          return row['result']?.toString() ?? '';
        case GamebaseSortField.eco:
          return row['eco']?.toString() ?? '';
        case GamebaseSortField.opening:
          return row['opening']?.toString() ?? '';
        case GamebaseSortField.event:
          return row['event']?.toString() ?? '';
        default:
          return row['date']?.toString() ?? '';
      }
    }

    final av = value(a);
    final bv = value(b);
    if (av is num && bv is num) return av.compareTo(bv);
    if (av is DateTime && bv is DateTime) return av.compareTo(bv);
    return av.toString().compareTo(bv.toString());
  }
}

@immutable
class PlayerOpeningTreeSnapshot {
  const PlayerOpeningTreeSnapshot({
    required this.treeId,
    required this.playerId,
    required this.maxPly,
    required this.rootNodeId,
    required this.generatedAt,
    required this.nodes,
  });

  final String treeId;
  final String playerId;
  final int maxPly;
  final int rootNodeId;
  final DateTime? generatedAt;
  final List<PlayerOpeningTreeNode> nodes;

  factory PlayerOpeningTreeSnapshot.fromJson(Map<String, dynamic> json) {
    return PlayerOpeningTreeSnapshot(
      treeId: json['treeId']?.toString() ?? '',
      playerId: json['playerId']?.toString() ?? '',
      maxPly: _readInt(json['maxPly']),
      rootNodeId: _readInt(json['rootNodeId']),
      generatedAt: DateTime.tryParse(json['generatedAt']?.toString() ?? ''),
      nodes: List<PlayerOpeningTreeNode>.unmodifiable(
        (json['nodes'] as List? ?? const []).whereType<Map>().map(
          (node) =>
              PlayerOpeningTreeNode.fromJson(Map<String, dynamic>.from(node)),
        ),
      ),
    );
  }
}

@immutable
class PlayerOpeningTreeNode {
  const PlayerOpeningTreeNode({
    required this.id,
    required this.fenKey,
    required this.ply,
    required this.moves,
  });

  final int id;
  final String fenKey;
  final int ply;
  final List<PlayerOpeningTreeMove> moves;

  factory PlayerOpeningTreeNode.fromJson(Map<String, dynamic> json) {
    return PlayerOpeningTreeNode(
      id: _readInt(json['id']),
      fenKey: json['fenKey']?.toString().trim() ?? '',
      ply: _readInt(json['ply']),
      moves: List<PlayerOpeningTreeMove>.unmodifiable(
        (json['moves'] as List? ?? const []).whereType<Map>().map(
          (move) =>
              PlayerOpeningTreeMove.fromJson(Map<String, dynamic>.from(move)),
        ),
      ),
    );
  }
}

@immutable
class PlayerOpeningTreeMove {
  const PlayerOpeningTreeMove({
    required this.uci,
    required this.childNodeId,
    required this.white,
    required this.black,
    required this.draws,
    required this.total,
    this.lastPlayed,
    this.sampleGameId,
    this.filterBuckets = const <String, PlayerOpeningTreeStats>{},
  });

  final String uci;
  final int childNodeId;
  final int white;
  final int black;
  final int draws;
  final int total;
  final DateTime? lastPlayed;
  final String? sampleGameId;
  final Map<String, PlayerOpeningTreeStats> filterBuckets;

  factory PlayerOpeningTreeMove.fromJson(Map<String, dynamic> json) {
    final buckets = <String, PlayerOpeningTreeStats>{};
    final rawBuckets = json['filterBuckets'];
    if (rawBuckets is Map) {
      for (final entry in rawBuckets.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        buckets[entry.key.toString()] = PlayerOpeningTreeStats.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    }

    return PlayerOpeningTreeMove(
      uci: json['uci']?.toString().trim().toLowerCase() ?? '',
      childNodeId: _readInt(json['childNodeId']),
      white: _readInt(json['white']),
      black: _readInt(json['black']),
      draws: _readInt(json['draws']),
      total: _readInt(json['total']),
      lastPlayed: DateTime.tryParse(json['lastPlayed']?.toString() ?? ''),
      sampleGameId: json['sampleGameId']?.toString().trim(),
      filterBuckets: Map<String, PlayerOpeningTreeStats>.unmodifiable(buckets),
    );
  }

  MoveAggregate toMoveAggregate({
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
  }) {
    final stats = filters.hasFilters ? _filteredStats(filters) : null;
    final resolved =
        stats ??
        PlayerOpeningTreeStats(
          white: white,
          black: black,
          draws: draws,
          total: total,
        );
    return MoveAggregate(
      uci: uci,
      white: resolved.white,
      black: resolved.black,
      draws: resolved.draws,
      total: resolved.total,
      gameId: sampleGameId,
      lastPlayed: lastPlayed,
    );
  }

  PlayerOpeningTreeStats _filteredStats(PlayerOpeningTreeFilterCriteria f) {
    var white = 0;
    var black = 0;
    var draws = 0;
    var total = 0;
    for (final entry in filterBuckets.entries) {
      final bucket = _parseBucketKey(entry.key);
      if (!_bucketMatches(bucket, f)) continue;
      white += entry.value.white;
      black += entry.value.black;
      draws += entry.value.draws;
      total += entry.value.total;
    }
    return PlayerOpeningTreeStats(
      white: white,
      black: black,
      draws: draws,
      total: total,
    );
  }
}

@immutable
class PlayerOpeningTreeStats {
  const PlayerOpeningTreeStats({
    required this.white,
    required this.black,
    required this.draws,
    required this.total,
  });

  final int white;
  final int black;
  final int draws;
  final int total;

  factory PlayerOpeningTreeStats.fromJson(Map<String, dynamic> json) {
    return PlayerOpeningTreeStats(
      white: _readInt(json['white']),
      black: _readInt(json['black']),
      draws: _readInt(json['draws']),
      total: _readInt(json['total']),
    );
  }
}

@immutable
class PlayerOpeningTreeFilterCriteria {
  const PlayerOpeningTreeFilterCriteria({
    this.playerId,
    this.timeControl,
    this.minRating,
    this.maxRating,
    this.color,
    this.result,
    this.isOnline,
    this.yearFrom,
    this.yearTo,
  });

  final String? playerId;
  final TimeControl? timeControl;
  final int? minRating;
  final int? maxRating;
  final String? color;
  final String? result;
  final bool? isOnline;
  final int? yearFrom;
  final int? yearTo;

  bool get hasFilters =>
      timeControl != null ||
      minRating != null ||
      maxRating != null ||
      color != null ||
      result != null ||
      isOnline != null ||
      yearFrom != null ||
      yearTo != null;

  bool matches(Map<String, dynamic> row) {
    final wantedColor = color?.trim().toLowerCase();
    if (wantedColor == 'white' || wantedColor == 'black') {
      final id = playerId?.trim();
      if (id != null && id.isNotEmpty) {
        final actualColor = _playerColorForRow(row, id);
        if (actualColor != null && actualColor != wantedColor) return false;
        if (actualColor == null) return false;
      }
    }

    if (timeControl != null &&
        !_timeControlMatches(row['timeControl'], timeControl!)) {
      return false;
    }

    final wantedResult = result?.trim().toUpperCase();
    if (wantedResult != null &&
        wantedResult.isNotEmpty &&
        _resultCode(row['result']) != wantedResult) {
      return false;
    }

    if (isOnline != null && _readBool(row['isOnline']) != isOnline) {
      return false;
    }

    final year = _yearForRow(row);
    if (yearFrom != null && (year == null || year < yearFrom!)) return false;
    if (yearTo != null && (year == null || year > yearTo!)) return false;

    final rating = _ratingForFilter(row, playerId: playerId, color: color);
    if (minRating != null && (rating == null || rating < minRating!)) {
      return false;
    }
    if (maxRating != null && (rating == null || rating > maxRating!)) {
      return false;
    }

    return true;
  }
}

@immutable
class PlayerOpeningTreeGameRef {
  const PlayerOpeningTreeGameRef({
    required this.gameId,
    required this.fen,
    required this.ply,
  });

  final String gameId;
  final String fen;
  final int ply;
}

@immutable
class PlayerOpeningTreeGamesIndex {
  const PlayerOpeningTreeGamesIndex({
    required this.gamesByFen,
    required this.gameRowsById,
  });

  const PlayerOpeningTreeGamesIndex.empty()
    : gamesByFen = const <String, List<PlayerOpeningTreeGameRef>>{},
      gameRowsById = const <String, Map<String, dynamic>>{};

  final Map<String, List<PlayerOpeningTreeGameRef>> gamesByFen;
  final Map<String, Map<String, dynamic>> gameRowsById;

  int get gameCount => gameRowsById.length;
  int get positionCount => gamesByFen.length;
}

String _fenKey(String fen) =>
    fen.trim().split(RegExp(r'\s+')).take(4).join(' ');

Future<PlayerOpeningTreeGamesIndex> buildPlayerOpeningGamesIndexBatchAsync(
  List<Map<String, dynamic>> rows,
) {
  return compute(_buildPlayerOpeningGamesIndexBatch, rows);
}

PlayerOpeningTreeGamesIndex mergePlayerOpeningGamesIndexes(
  PlayerOpeningTreeGamesIndex left,
  PlayerOpeningTreeGamesIndex right,
) {
  if (left.gameRowsById.isEmpty) return right;
  if (right.gameRowsById.isEmpty) return left;

  final mergedRefs = Map<String, List<PlayerOpeningTreeGameRef>>.from(
    left.gamesByFen,
  );
  for (final entry in right.gamesByFen.entries) {
    final refs = <String, PlayerOpeningTreeGameRef>{
      for (final ref
          in left.gamesByFen[entry.key] ?? const <PlayerOpeningTreeGameRef>[])
        ref.gameId: ref,
      for (final ref in entry.value) ref.gameId: ref,
    };
    mergedRefs[entry.key] = List<PlayerOpeningTreeGameRef>.unmodifiable(
      refs.values,
    );
  }

  return PlayerOpeningTreeGamesIndex(
    gamesByFen: Map<String, List<PlayerOpeningTreeGameRef>>.unmodifiable(
      mergedRefs,
    ),
    gameRowsById: Map<String, Map<String, dynamic>>.unmodifiable(
      <String, Map<String, dynamic>>{
        ...left.gameRowsById,
        ...right.gameRowsById,
      },
    ),
  );
}

PlayerOpeningTreeGamesIndex _buildPlayerOpeningGamesIndexBatch(
  List<Map<String, dynamic>> rows,
) {
  final gamesByFen = <String, Map<String, PlayerOpeningTreeGameRef>>{};
  final gameRowsById = <String, Map<String, dynamic>>{};

  for (final row in rows) {
    final pgn = _pgnForRow(row);
    if (pgn == null) continue;

    late final ChessGame game;
    try {
      game = ChessGame.fromPgn(row['id']?.toString() ?? 'game', pgn);
    } catch (_) {
      continue;
    }
    if (game.mainline.isEmpty) continue;

    final result = _resultForRow(row, game);
    final date = _dateForRow(row, game);
    final normalizedRow = _normalizedRow(row, game, date, result);
    final gameId = normalizedRow['id']?.toString().trim();
    if (gameId == null || gameId.isEmpty) continue;
    final line = <String>[
      for (final move in game.mainline) move.uci.trim().toLowerCase(),
    ].where((m) => m.isNotEmpty).toList(growable: false);
    gameRowsById[gameId] = _compactGameRow(normalizedRow, line);

    var previousFen =
        game.startingFen.trim().isEmpty ? Chess.initial.fen : game.startingFen;
    for (var i = 0; i < game.mainline.length; i++) {
      final key = _fenKey(previousFen);
      gamesByFen.putIfAbsent(
        key,
        () => <String, PlayerOpeningTreeGameRef>{},
      )[gameId] = PlayerOpeningTreeGameRef(
        gameId: gameId,
        fen: previousFen,
        ply: i,
      );

      previousFen = game.mainline[i].fen;
    }

    final finalKey = _fenKey(previousFen);
    gamesByFen.putIfAbsent(
      finalKey,
      () => <String, PlayerOpeningTreeGameRef>{},
    )[gameId] = PlayerOpeningTreeGameRef(
      gameId: gameId,
      fen: previousFen,
      ply: line.length,
    );
  }

  final frozenGames = <String, List<PlayerOpeningTreeGameRef>>{};
  for (final entry in gamesByFen.entries) {
    frozenGames[entry.key] = List<PlayerOpeningTreeGameRef>.unmodifiable(
      entry.value.values,
    );
  }

  final frozenRows = <String, Map<String, dynamic>>{};
  for (final entry in gameRowsById.entries) {
    frozenRows[entry.key] = Map<String, dynamic>.unmodifiable(entry.value);
  }

  return PlayerOpeningTreeGamesIndex(
    gamesByFen: Map<String, List<PlayerOpeningTreeGameRef>>.unmodifiable(
      frozenGames,
    ),
    gameRowsById: Map<String, Map<String, dynamic>>.unmodifiable(frozenRows),
  );
}

GamebaseSearchQueryResponse localPlayerTreeGamesResponse({
  required PlayerOpeningTreeIndex index,
  required String fen,
  required String? uci,
  PlayerOpeningTreeFilterCriteria filters =
      const PlayerOpeningTreeFilterCriteria(),
  required GamebaseSortField sortBy,
  required GamebaseSortDirection sortDirection,
  required int pageNumber,
  required int pageSize,
}) {
  final total = index.gamesCountForFen(fen, uci: uci, filters: filters);
  final rows = index.gamesForFen(
    fen,
    uci: uci,
    filters: filters,
    sortBy: sortBy,
    sortDirection: sortDirection,
    pageNumber: pageNumber,
    pageSize: pageSize,
  );
  return GamebaseSearchQueryResponse(
    status: 'success',
    data: rows,
    metadata: GamebasePaginationMetadata(
      pageNumber: pageNumber,
      pageSize: pageSize,
      totalCount: total,
      hasMoreValue: (pageNumber + 1) * pageSize < total,
    ),
  );
}

Map<String, String> _parseBucketKey(String key) {
  final bucket = <String, String>{};
  for (final part in key.split('|')) {
    final index = part.indexOf('=');
    if (index <= 0 || index == part.length - 1) continue;
    bucket[part.substring(0, index)] = part.substring(index + 1);
  }
  return bucket;
}

bool _bucketMatches(
  Map<String, String> bucket,
  PlayerOpeningTreeFilterCriteria f,
) {
  final color = f.color?.trim().toLowerCase();
  if (color != null && color.isNotEmpty && bucket['color'] != color) {
    return false;
  }

  final timeControl = f.timeControl?.name.toUpperCase();
  if (timeControl != null && bucket['timeControl'] != timeControl) {
    return false;
  }

  if (f.isOnline != null && bucket['isOnline'] != f.isOnline.toString()) {
    return false;
  }

  final result = f.result?.trim().toUpperCase();
  if (result != null && result.isNotEmpty && bucket['result'] != result) {
    return false;
  }

  final year = int.tryParse(bucket['year'] ?? '');
  if (f.yearFrom != null && (year == null || year < f.yearFrom!)) return false;
  if (f.yearTo != null && (year == null || year > f.yearTo!)) return false;

  final rating = int.tryParse(bucket['rating'] ?? '0') ?? 0;
  if (f.minRating != null && rating + 99 < f.minRating!) return false;
  if (f.maxRating != null && rating > f.maxRating!) return false;

  return true;
}

String? _pgnForRow(Map<String, dynamic> row) {
  final pgn = row['pgn']?.toString().trim();
  if (pgn != null && pgn.isNotEmpty && pgn.contains(RegExp(r'\d+\s*\.'))) {
    return pgn;
  }
  final data = row['data'];
  if (data is Map) {
    return buildPgnFromGamebaseData(Map<String, dynamic>.from(data));
  }
  return null;
}

Map<String, dynamic> _normalizedRow(
  Map<String, dynamic> row,
  ChessGame game,
  DateTime? date,
  String result,
) {
  String pick(String key, String fallback) {
    final raw = row[key]?.toString().trim();
    if (raw != null && raw.isNotEmpty) return raw;
    final md = game.metadata[key]?.toString().trim();
    if (md != null && md.isNotEmpty) return md;
    return fallback;
  }

  int pickInt(String key) {
    final parsed = _readInt(row[key]);
    if (parsed > 0) return parsed;
    return _readInt(game.metadata[key]);
  }

  final id = row['id']?.toString().trim();
  return <String, dynamic>{
    ...row,
    'id': id == null || id.isEmpty ? game.gameId : id,
    'whitePlayerId':
        row['whitePlayerId'] ?? row['white_player_id'] ?? row['whiteId'],
    'blackPlayerId':
        row['blackPlayerId'] ?? row['black_player_id'] ?? row['blackId'],
    'white': pick('white', pick('White', 'White')),
    'black': pick('black', pick('Black', 'Black')),
    'whiteTitle': pick('whiteTitle', pick('WhiteTitle', '')),
    'blackTitle': pick('blackTitle', pick('BlackTitle', '')),
    'whiteFed': pick('whiteFed', pick('WhiteFed', '')),
    'blackFed': pick('blackFed', pick('BlackFed', '')),
    'whiteElo': pickInt('whiteElo') > 0 ? pickInt('whiteElo') : null,
    'blackElo': pickInt('blackElo') > 0 ? pickInt('blackElo') : null,
    'whiteFideId': row['whiteFideId'] ?? game.metadata['WhiteFideId'],
    'blackFideId': row['blackFideId'] ?? game.metadata['BlackFideId'],
    'result': result,
    'date': date?.toIso8601String() ?? row['date']?.toString(),
    'timeControl':
        row['timeControl'] ??
        row['time_control'] ??
        row['timeControlType'] ??
        game.metadata['TimeControl'],
    'isOnline': row['isOnline'] ?? row['is_online'] ?? row['online'],
    'eco': pick('eco', pick('ECO', '')),
    'opening': pick('opening', pick('Opening', '')),
    'variation': pick('variation', pick('Variation', '')),
    'broadcastName':
        row['broadcastName'] ??
        row['broadcast_name'] ??
        row['groupBroadcastName'] ??
        row['group_broadcast_name'],
    'broadcast_name':
        row['broadcast_name'] ??
        row['broadcastName'] ??
        row['group_broadcast_name'] ??
        row['groupBroadcastName'],
    'event': pick('event', pick('Event', 'Gamebase')),
    'site': pick('site', pick('Site', '')),
    'pgn': row['pgn'] ?? _pgnForRow(row),
  };
}

Map<String, dynamic> _compactGameRow(
  Map<String, dynamic> row,
  List<String> line,
) {
  final compact = <String, dynamic>{
    'id': row['id'],
    'whitePlayerId': row['whitePlayerId'],
    'blackPlayerId': row['blackPlayerId'],
    'white': row['white'],
    'black': row['black'],
    'whiteTitle': row['whiteTitle'],
    'blackTitle': row['blackTitle'],
    'whiteFed': row['whiteFed'],
    'blackFed': row['blackFed'],
    'whiteElo': row['whiteElo'],
    'blackElo': row['blackElo'],
    'whiteFideId': row['whiteFideId'],
    'blackFideId': row['blackFideId'],
    'result': row['result'],
    'date': row['date'],
    'timeControl': row['timeControl'],
    'isOnline': row['isOnline'],
    'eco': row['eco'],
    'opening': row['opening'],
    'variation': row['variation'],
    'broadcastName': row['broadcastName'],
    'broadcast_name': row['broadcast_name'],
    'groupBroadcastName': row['groupBroadcastName'],
    'group_broadcast_name': row['group_broadcast_name'],
    'event': row['event'],
    'site': row['site'],
    'line': List<String>.unmodifiable(line),
  };
  compact.removeWhere((_, value) => value == null);
  return compact;
}

String _resultForRow(Map<String, dynamic> row, ChessGame game) {
  final raw = row['result']?.toString().trim();
  if (raw != null && raw.isNotEmpty) return _normalizeResult(raw);
  final md = game.metadata['Result']?.toString().trim();
  if (md != null && md.isNotEmpty) return _normalizeResult(md);
  return '*';
}

String _normalizeResult(String raw) {
  switch (raw.replaceAll('½', '1/2').trim()) {
    case 'W':
    case '1-0':
      return '1-0';
    case 'B':
    case '0-1':
      return '0-1';
    case 'D':
    case '1/2-1/2':
      return '1/2-1/2';
    default:
      return '*';
  }
}

DateTime? _dateForRow(Map<String, dynamic> row, ChessGame game) {
  final direct = DateTime.tryParse(row['date']?.toString() ?? '');
  if (direct != null) return direct;
  final pgnDate = game.metadata['Date']?.toString().trim();
  if (pgnDate == null || pgnDate.isEmpty) return null;
  return DateTime.tryParse(pgnDate.replaceAll('.', '-'));
}

List<String> _lineForRow(Map<String, dynamic> row) {
  final raw = row['line'];
  if (raw is! List) return const <String>[];
  return raw
      .map((m) => m.toString().trim().toLowerCase())
      .where((m) => m.isNotEmpty)
      .toList(growable: false);
}

List<String> _continuationForRef(
  Map<String, dynamic> row,
  PlayerOpeningTreeGameRef ref,
) {
  final line = _lineForRow(row);
  if (ref.ply >= line.length) return const <String>[];
  return List<String>.unmodifiable(line.sublist(ref.ply));
}

String? _nextUciForRef(Map<String, dynamic> row, PlayerOpeningTreeGameRef ref) {
  final line = _lineForRow(row);
  if (ref.ply < 0 || ref.ply >= line.length) return null;
  return line[ref.ply];
}

String? _playerColorForRow(Map<String, dynamic> row, String playerId) {
  final normalized = playerId.trim().toLowerCase();
  if (normalized.isEmpty) return null;
  final whiteId = row['whitePlayerId']?.toString().trim().toLowerCase();
  if (whiteId == normalized) return 'white';
  final blackId = row['blackPlayerId']?.toString().trim().toLowerCase();
  if (blackId == normalized) return 'black';
  return null;
}

bool _timeControlMatches(Object? rawValue, TimeControl wanted) {
  final raw = rawValue?.toString().trim().toLowerCase();
  if (raw == null || raw.isEmpty) return false;
  final wantedName = wanted.name.toLowerCase();
  return raw == wantedName ||
      raw == wanted.displayName.toLowerCase() ||
      raw == 'timecontrol.$wantedName';
}

String _resultCode(Object? value) {
  switch (_normalizeResult(value?.toString() ?? '*')) {
    case '1-0':
      return 'W';
    case '0-1':
      return 'B';
    case '1/2-1/2':
      return 'D';
    default:
      return '';
  }
}

int? _yearForRow(Map<String, dynamic> row) {
  final date = DateTime.tryParse(row['date']?.toString() ?? '');
  if (date != null) return date.year;
  final raw = row['year']?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  return int.tryParse(raw.length >= 4 ? raw.substring(0, 4) : raw);
}

int? _ratingForFilter(
  Map<String, dynamic> row, {
  String? playerId,
  String? color,
}) {
  final wantedColor = color?.trim().toLowerCase();
  if (wantedColor == 'white') {
    final rating = _readInt(row['whiteElo']);
    return rating > 0 ? rating : null;
  }
  if (wantedColor == 'black') {
    final rating = _readInt(row['blackElo']);
    return rating > 0 ? rating : null;
  }

  final id = playerId?.trim();
  if (id != null && id.isNotEmpty) {
    final playerColor = _playerColorForRow(row, id);
    if (playerColor == 'white') {
      final rating = _readInt(row['whiteElo']);
      return rating > 0 ? rating : null;
    }
    if (playerColor == 'black') {
      final rating = _readInt(row['blackElo']);
      return rating > 0 ? rating : null;
    }
  }

  final white = _readInt(row['whiteElo']);
  final black = _readInt(row['blackElo']);
  if (white <= 0 && black <= 0) return null;
  if (white <= 0) return black;
  if (black <= 0) return white;
  return ((white + black) / 2).round();
}

bool? _readBool(Object? value) {
  if (value is bool) return value;
  final raw = value?.toString().trim().toLowerCase();
  if (raw == null || raw.isEmpty) return null;
  if (raw == 'true' || raw == '1' || raw == 'yes' || raw == 'online') {
    return true;
  }
  if (raw == 'false' || raw == '0' || raw == 'no' || raw == 'otb') {
    return false;
  }
  return null;
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
