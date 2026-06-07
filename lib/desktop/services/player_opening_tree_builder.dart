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
    this.error,
  });

  final PlayerOpeningTreeStatus status;
  final int currentPage;
  final int fetchedGames;
  final int processedGames;
  final int skippedGames;
  final int indexedPositions;
  final int? totalGames;
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
  });

  const PlayerOpeningTreeIndex.empty()
    : movesByFen = const <String, List<MoveAggregate>>{},
      gamesByFen = const <String, List<Map<String, dynamic>>>{};

  final Map<String, List<MoveAggregate>> movesByFen;
  final Map<String, List<Map<String, dynamic>>> gamesByFen;

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
    final rows = _filteredRowsForKey(key, filters);
    final builders = <String, _MutableMoveAggregate>{};
    for (final row in rows) {
      final continuation = _continuationForRow(row);
      if (continuation.isEmpty) continue;
      final uci = continuation.first;
      builders
          .putIfAbsent(uci, () => _MutableMoveAggregate(uci))
          .addGame(
            result: row['result']?.toString() ?? '*',
            gameId: row['id'],
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
    var rows = _filteredRowsForKey(key, filters);
    final pinned = uci?.trim().toLowerCase();
    if (pinned != null && pinned.isNotEmpty) {
      rows = rows
          .where((row) => _continuationStartsWith(row, pinned))
          .toList(growable: false);
    }

    final sorted = List<Map<String, dynamic>>.from(rows);
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
    final rows = _filteredRowsForKey(key, filters);
    final pinned = uci?.trim().toLowerCase();
    if (pinned == null || pinned.isEmpty) return rows.length;
    return rows.where((row) => _continuationStartsWith(row, pinned)).length;
  }

  List<Map<String, dynamic>> _filteredRowsForKey(
    String key,
    PlayerOpeningTreeFilterCriteria filters,
  ) {
    final rows = gamesByFen[key] ?? const <Map<String, dynamic>>[];
    if (!filters.hasFilters) return rows;
    return rows.where(filters.matches).toList(growable: false);
  }

  static bool _continuationStartsWith(Map<String, dynamic> row, String uci) {
    final continuation = _continuationForRow(row);
    return continuation.isNotEmpty && continuation.first == uci;
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
  final moveBuilders = <String, Map<String, _MutableMoveAggregate>>{};
  final gameBuilders = <String, Map<String, Map<String, dynamic>>>{};

  void absorb(PlayerOpeningTreeIndex index) {
    for (final entry in index.movesByFen.entries) {
      final moves = moveBuilders.putIfAbsent(
        entry.key,
        () => <String, _MutableMoveAggregate>{},
      );
      for (final move in entry.value) {
        moves
            .putIfAbsent(move.uci, () => _MutableMoveAggregate(move.uci))
            .addAggregate(move);
      }
    }

    for (final entry in index.gamesByFen.entries) {
      final games = gameBuilders.putIfAbsent(
        entry.key,
        () => <String, Map<String, dynamic>>{},
      );
      for (final row in entry.value) {
        final id = row['id']?.toString().trim();
        if (id == null || id.isEmpty) continue;
        games[id] = row;
      }
    }
  }

  absorb(left);
  absorb(right);

  return _freezeIndex(moveBuilders, gameBuilders);
}

PlayerOpeningTreeIndex _buildPlayerOpeningTreeBatch(
  List<Map<String, dynamic>> rows,
) {
  final movesByFen = <String, Map<String, _MutableMoveAggregate>>{};
  final gamesByFen = <String, Map<String, Map<String, dynamic>>>{};

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
          .addGame(result: result, gameId: normalizedRow['id'], date: date);

      final continuation = <String>[
        for (final next in game.mainline.skip(i)) next.uci.trim().toLowerCase(),
      ].where((m) => m.isNotEmpty).toList(growable: false);
      gamesByFen.putIfAbsent(
        key,
        () => <String, Map<String, dynamic>>{},
      )[normalizedRow['id']] = <String, dynamic>{
        ...normalizedRow,
        'fen': previousFen,
        'continuation': continuation,
      };

      previousFen = move.fen;
    }

    final finalKey = _positionKey(previousFen);
    gamesByFen.putIfAbsent(
      finalKey,
      () => <String, Map<String, dynamic>>{},
    )[normalizedRow['id']] = <String, dynamic>{
      ...normalizedRow,
      'fen': previousFen,
      'continuation': const <String>[],
    };
  }

  return _freezeIndex(movesByFen, gamesByFen);
}

PlayerOpeningTreeIndex _freezeIndex(
  Map<String, Map<String, _MutableMoveAggregate>> movesByFen,
  Map<String, Map<String, Map<String, dynamic>>> gamesByFen,
) {
  final frozenMoves = <String, List<MoveAggregate>>{};
  for (final entry in movesByFen.entries) {
    final moves = entry.value.values
      .map((m) => m.toAggregate())
      .toList(growable: false)..sort((a, b) => b.total.compareTo(a.total));
    frozenMoves[entry.key] = List<MoveAggregate>.unmodifiable(moves);
  }

  final frozenGames = <String, List<Map<String, dynamic>>>{};
  for (final entry in gamesByFen.entries) {
    frozenGames[entry.key] = List<Map<String, dynamic>>.unmodifiable(
      entry.value.values.map(Map<String, dynamic>.unmodifiable),
    );
  }

  return PlayerOpeningTreeIndex(
    movesByFen: Map<String, List<MoveAggregate>>.unmodifiable(frozenMoves),
    gamesByFen: Map<String, List<Map<String, dynamic>>>.unmodifiable(
      frozenGames,
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
    'event': pick('event', pick('Event', 'Gamebase')),
    'site': pick('site', pick('Site', '')),
    'pgn': row['pgn'] ?? _pgnForRow(row),
  };
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

List<String> _continuationForRow(Map<String, dynamic> row) {
  final raw = row['continuation'];
  if (raw is! List) return const <String>[];
  return raw
      .map((m) => m.toString().trim().toLowerCase())
      .where((m) => m.isNotEmpty)
      .toList(growable: false);
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
