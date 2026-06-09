import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
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
    this.progress = const PlayerOpeningTreeProgress(),
    this.index = const PlayerOpeningTreeIndex.empty(),
  });

  final String? playerId;
  final PlayerOpeningTreeProgress progress;
  final PlayerOpeningTreeIndex index;

  bool get hasUsableIndex => index.positionCount > 0;

  PlayerOpeningTreeState copyWith({
    String? playerId,
    PlayerOpeningTreeProgress? progress,
    PlayerOpeningTreeIndex? index,
  }) {
    return PlayerOpeningTreeState(
      playerId: playerId ?? this.playerId,
      progress: progress ?? this.progress,
      index: index ?? this.index,
    );
  }
}

@immutable
class PlayerOpeningTreeIndex {
  const PlayerOpeningTreeIndex({
    required this.movesByFen,
    required this.gamesByFen,
    required this.gameRowsById,
  });

  const PlayerOpeningTreeIndex.empty()
    : movesByFen = const <String, List<MoveAggregate>>{},
      gamesByFen = const <String, List<PlayerOpeningTreeGameRef>>{},
      gameRowsById = const <String, Map<String, dynamic>>{};

  final Map<String, List<MoveAggregate>> movesByFen;
  final Map<String, List<PlayerOpeningTreeGameRef>> gamesByFen;
  final Map<String, Map<String, dynamic>> gameRowsById;

  int get positionCount => movesByFen.length;

  List<MoveAggregate> movesForFen(
    String fen, {
    PlayerOpeningTreeFilterCriteria filters =
        const PlayerOpeningTreeFilterCriteria(),
  }) {
    if (!filters.hasFilters) {
      return movesByFen[_positionKey(fen)] ?? const <MoveAggregate>[];
    }
    final key = _positionKey(fen);
    final refs = _filteredRefsForKey(key, filters);
    final builders = <String, _MutableMoveAggregate>{};
    for (final ref in refs) {
      final row = gameRowsById[ref.gameId];
      if (row == null) continue;
      final uci = _nextUciForRef(row, ref);
      if (uci == null) continue;
      builders
          .putIfAbsent(uci, () => _MutableMoveAggregate(uci))
          .addGame(
            result: row['result']?.toString() ?? '*',
            gameId: ref.gameId,
            date: _dateForRowValue(row['date']),
          );
    }
    final moves =
        builders.values.map((b) => b.toAggregate()).toList()
          ..sort((a, b) => b.total.compareTo(a.total));
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
    final key = _positionKey(fen);
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
    final key = _positionKey(fen);
    final refs = _filteredRefsForKey(key, filters);
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

Future<PlayerOpeningTreeIndex> buildPlayerOpeningTreeBatchAsync(
  List<Map<String, dynamic>> rows,
) {
  return compute(_buildPlayerOpeningTreeBatch, rows);
}

PlayerOpeningTreeIndex mergePlayerOpeningTreeIndexes(
  PlayerOpeningTreeIndex left,
  PlayerOpeningTreeIndex right,
) {
  if (left.positionCount == 0 && left.gameRowsById.isEmpty) return right;
  if (right.positionCount == 0 && right.gameRowsById.isEmpty) return left;

  final mergedMoves = Map<String, List<MoveAggregate>>.from(left.movesByFen);
  for (final entry in right.movesByFen.entries) {
    final builders = <String, _MutableMoveAggregate>{};
    for (final move in left.movesByFen[entry.key] ?? const <MoveAggregate>[]) {
      builders
          .putIfAbsent(move.uci, () => _MutableMoveAggregate(move.uci))
          .addAggregate(move);
    }
    for (final move in entry.value) {
      builders
          .putIfAbsent(move.uci, () => _MutableMoveAggregate(move.uci))
          .addAggregate(move);
    }
    final moves = builders.values
      .map((m) => m.toAggregate())
      .toList(growable: false)..sort((a, b) => b.total.compareTo(a.total));
    mergedMoves[entry.key] = List<MoveAggregate>.unmodifiable(moves);
  }

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

  return PlayerOpeningTreeIndex(
    movesByFen: Map<String, List<MoveAggregate>>.unmodifiable(mergedMoves),
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

PlayerOpeningTreeIndex _buildPlayerOpeningTreeBatch(
  List<Map<String, dynamic>> rows,
) {
  final movesByFen = <String, Map<String, _MutableMoveAggregate>>{};
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
      final move = game.mainline[i];
      final key = _positionKey(previousFen);
      final uci = move.uci.trim().toLowerCase();
      if (uci.isEmpty) {
        previousFen = move.fen;
        continue;
      }

      movesByFen
          .putIfAbsent(key, () => <String, _MutableMoveAggregate>{})
          .putIfAbsent(uci, () => _MutableMoveAggregate(uci))
          .addGame(result: result, gameId: gameId, date: date);

      gamesByFen.putIfAbsent(
        key,
        () => <String, PlayerOpeningTreeGameRef>{},
      )[gameId] = PlayerOpeningTreeGameRef(
        gameId: gameId,
        fen: previousFen,
        ply: i,
      );

      previousFen = move.fen;
    }

    final finalKey = _positionKey(previousFen);
    gamesByFen.putIfAbsent(
      finalKey,
      () => <String, PlayerOpeningTreeGameRef>{},
    )[gameId] = PlayerOpeningTreeGameRef(
      gameId: gameId,
      fen: previousFen,
      ply: line.length,
    );
  }

  return _freezeIndex(movesByFen, gamesByFen, gameRowsById);
}

PlayerOpeningTreeIndex _freezeIndex(
  Map<String, Map<String, _MutableMoveAggregate>> movesByFen,
  Map<String, Map<String, PlayerOpeningTreeGameRef>> gamesByFen,
  Map<String, Map<String, dynamic>> gameRowsById,
) {
  final frozenMoves = <String, List<MoveAggregate>>{};
  for (final entry in movesByFen.entries) {
    final moves = entry.value.values
      .map((m) => m.toAggregate())
      .toList(growable: false)..sort((a, b) => b.total.compareTo(a.total));
    frozenMoves[entry.key] = List<MoveAggregate>.unmodifiable(moves);
  }

  final frozenGames = <String, List<PlayerOpeningTreeGameRef>>{};
  for (final entry in gamesByFen.entries) {
    frozenGames[entry.key] = List<PlayerOpeningTreeGameRef>.unmodifiable(
      entry.value.values,
    );
  }

  final frozenGameRows = <String, Map<String, dynamic>>{};
  for (final entry in gameRowsById.entries) {
    frozenGameRows[entry.key] = Map<String, dynamic>.unmodifiable(entry.value);
  }

  return PlayerOpeningTreeIndex(
    movesByFen: Map<String, List<MoveAggregate>>.unmodifiable(frozenMoves),
    gamesByFen: Map<String, List<PlayerOpeningTreeGameRef>>.unmodifiable(
      frozenGames,
    ),
    gameRowsById: Map<String, Map<String, dynamic>>.unmodifiable(
      frozenGameRows,
    ),
  );
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

DateTime? _dateForRowValue(Object? value) {
  return DateTime.tryParse(value?.toString() ?? '');
}

String _positionKey(String fen) =>
    normalizeFenForGamebase(fen).split(RegExp(r'\s+')).take(4).join(' ');

int _readInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool? _readBool(dynamic value) {
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

class _MutableMoveAggregate {
  _MutableMoveAggregate(this.uci);

  final String uci;
  int white = 0;
  int black = 0;
  int draws = 0;
  final Set<String> gameIds = <String>{};
  DateTime? lastPlayed;

  int get total => white + black + draws;

  void addGame({
    required String result,
    required Object? gameId,
    DateTime? date,
  }) {
    switch (_normalizeResult(result)) {
      case '1-0':
        white += 1;
        break;
      case '0-1':
        black += 1;
        break;
      case '1/2-1/2':
        draws += 1;
        break;
      default:
        draws += 1;
    }
    final id = gameId?.toString().trim();
    if (id != null && id.isNotEmpty) gameIds.add(id);
    if (date != null && (lastPlayed == null || date.isAfter(lastPlayed!))) {
      lastPlayed = date;
    }
  }

  void addAggregate(MoveAggregate aggregate) {
    white += aggregate.white;
    black += aggregate.black;
    draws += aggregate.draws;
    final id = aggregate.gameId?.trim();
    if (id != null && id.isNotEmpty) gameIds.add(id);
    final date = aggregate.lastPlayed;
    if (date != null && (lastPlayed == null || date.isAfter(lastPlayed!))) {
      lastPlayed = date;
    }
  }

  MoveAggregate toAggregate() {
    return MoveAggregate(
      uci: uci,
      white: white,
      black: black,
      draws: draws,
      total: total,
      gameId: total == 1 && gameIds.length == 1 ? gameIds.first : null,
      lastPlayed: lastPlayed,
    );
  }
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
