import 'package:flutter/foundation.dart';

import 'package:chessever/screens/gamebase/models/models.dart';

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
  });

  const PlayerOpeningTreeIndex.empty()
    : treeId = null,
      playerId = null,
      maxPly = 0,
      rootNodeId = 0,
      generatedAt = null,
      nodesById = const <int, PlayerOpeningTreeNode>{},
      nodesByFenKey = const <String, PlayerOpeningTreeNode>{};

  final String? treeId;
  final String? playerId;
  final int maxPly;
  final int rootNodeId;
  final DateTime? generatedAt;
  final Map<int, PlayerOpeningTreeNode> nodesById;
  final Map<String, PlayerOpeningTreeNode> nodesByFenKey;

  int get positionCount => nodesByFenKey.length;

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
}

String _fenKey(String fen) =>
    fen.trim().split(RegExp(r'\s+')).take(4).join(' ');

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

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
