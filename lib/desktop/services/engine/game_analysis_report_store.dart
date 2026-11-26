import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/toby/toby_performance.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

/// Completed whole-game reports, cached per account.
///
/// Ported from the phone app's `GameAnalysisReportStore`, with one change:
/// every entry is scoped to the account that generated it (the `user_id`
/// column of the shared app cache table), so switching accounts never serves
/// another account's report and recovery after a restart only reads the
/// signed-in account's rows.
///
/// Two tiers:
/// * a bounded in-memory LRU ([hotEntries]) for the session;
/// * the app SQLite cache, bounded to [maxEntries] rows per account, which
///   survives restarts and works offline.
///
/// A cached report is served only after account-scoped admission; see
/// `GameReportRequestCoordinator`.
///
/// Toby's estimate of each side's level ([TobyPerformance]) is kept in the
/// same row, beside the report rather than inside it: the report model is
/// shared with the analysis Worker, and the estimate usually arrives after
/// the report is saved. It is kept with the [TobyPerformanceRequest.basis]
/// it was computed for (game facts and values included) and is only served
/// to a request with the same basis and the current [kTobyPerformanceModel],
/// so a re-analysed report or edited headers are read again.
class GameAnalysisReportStore {
  /// Production store on the already-open shared app database.
  GameAnalysisReportStore.sqlite([AppDatabase? database])
    : _database = database,
      _durableMemory = null,
      maxEntries = 48,
      hotEntries = 32;

  /// In-process durable tier for tests (no sqflite / path_provider).
  GameAnalysisReportStore.memory({this.maxEntries = 48, this.hotEntries = 32})
    : _database = null,
      _durableMemory = <String, _MemoryEntry>{};

  /// Shared production instance.
  static GameAnalysisReportStore instance = GameAnalysisReportStore.sqlite();

  final AppDatabase? _database;
  final Map<String, _MemoryEntry>? _durableMemory;

  /// Durable rows kept per account.
  final int maxEntries;

  /// Session entries kept in memory across all accounts.
  final int hotEntries;

  final LinkedHashMap<String, GameAnalysisReport> _hot =
      LinkedHashMap<String, GameAnalysisReport>();

  /// Toby estimates of the session tier, by the same scoped key as [_hot],
  /// evicted with it and capped at [hotEntries] like it.
  final LinkedHashMap<String, StoredTobyPerformance> _hotToby =
      LinkedHashMap<String, StoredTobyPerformance>();
  Future<void>? _writeChain;

  static const String keyPrefix = 'desktop_game_report:';

  /// Stable durable cache key for [fingerprint].
  static String cacheKeyForFingerprint(String fingerprint) =>
      '$keyPrefix${sha1.convert(utf8.encode(fingerprint))}';

  // Account ids are UUIDs, so the first `::` always ends the account part.
  static String _scopedKey(String accountId, String key) => '$accountId::$key';

  /// Session-only lookup. Never touches disk.
  GameAnalysisReport? peek(String accountId, String fingerprint) {
    if (accountId.isEmpty) return null;
    final key = _scopedKey(accountId, fingerprint);
    final report = _hot.remove(key);
    if (report == null) return null;
    _hot[key] = report;
    return report;
  }

  /// Memory first, then the account's durable rows. Null on miss or corrupt
  /// data; never throws.
  Future<GameAnalysisReport?> load(String accountId, String fingerprint) async {
    if (accountId.isEmpty) return null;
    final hot = peek(accountId, fingerprint);
    if (hot != null) return hot;
    try {
      final raw = await _readRaw(
        accountId,
        cacheKeyForFingerprint(fingerprint),
      );
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      final report = desktopGameReportFromJson(json);
      if (report == null || report.fingerprint != fingerprint) return null;
      _remember(accountId, report);
      final toby = desktopGameReportTobyPerformanceFromJson(json);
      if (toby != null) {
        _rememberToby(_scopedKey(accountId, fingerprint), toby);
      }
      return report;
    } catch (error, stackTrace) {
      debugPrint('GameAnalysisReportStore.load failed: $error\n$stackTrace');
      return null;
    }
  }

  /// Persists [report] for [accountId] and marks it most recent.
  Future<void> save(String accountId, GameAnalysisReport report) {
    if (accountId.isEmpty) return Future<void>.value();
    _remember(accountId, report);
    final previous = _writeChain ?? Future<void>.value();
    final done = previous
        .catchError((_) {})
        .then((_) => _saveUnlocked(accountId, report));
    _writeChain = done;
    return done;
  }

  /// Toby's estimate saved beside the report for [fingerprint] for a request
  /// with [basis], or null. Never throws.
  Future<TobyPerformance?> loadTobyPerformance(
    String accountId,
    String fingerprint, {
    required String basis,
  }) async {
    if (accountId.isEmpty) return null;
    final scoped = _scopedKey(accountId, fingerprint);
    final hot = _hotToby[scoped];
    if (hot != null) return hot.basis == basis ? hot.performance : null;
    try {
      final json = await _readJson(accountId, fingerprint);
      if (json == null || json['fingerprint'] != fingerprint) return null;
      final toby = desktopGameReportTobyPerformanceFromJson(json);
      if (toby != null) _rememberToby(scoped, toby);
      return toby != null && toby.basis == basis ? toby.performance : null;
    } catch (error) {
      debugPrint('GameAnalysisReportStore.loadTobyPerformance failed: $error');
      return null;
    }
  }

  /// Keeps Toby's estimate beside the report for [fingerprint], computed for
  /// a request with [basis]. When the report is not saved yet, the estimate
  /// joins it when it is saved in this session.
  Future<void> saveTobyPerformance(
    String accountId,
    String fingerprint,
    TobyPerformance performance, {
    required String basis,
  }) {
    if (accountId.isEmpty) return Future<void>.value();
    final scoped = _scopedKey(accountId, fingerprint);
    final previous = _hotToby[scoped];
    if (previous != null &&
        previous.basis == basis &&
        previous.performance == performance) {
      return Future<void>.value();
    }
    final stored = (basis: basis, performance: performance);
    _rememberToby(scoped, stored);
    return _chain(() async {
      final json = await _readJson(accountId, fingerprint);
      if (json == null || json['fingerprint'] != fingerprint) return;
      _writeTobyJson(json, stored);
      await _writeRaw(
        accountId,
        cacheKeyForFingerprint(fingerprint),
        jsonEncode(json),
      );
    });
  }

  Future<void> _chain(Future<void> Function() write) {
    final previous = _writeChain ?? Future<void>.value();
    final done = previous.catchError((_) {}).then((_) => write());
    _writeChain = done;
    return done;
  }

  /// Awaits pending durable writes.
  Future<void> flush() async {
    final pending = _writeChain;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {}
  }

  /// Simulates a cold start: drops the session tier, keeps durable rows.
  @visibleForTesting
  void clearHotCacheForTest() {
    _hot.clear();
    _hotToby.clear();
  }

  void _remember(String accountId, GameAnalysisReport report) {
    final key = _scopedKey(accountId, report.fingerprint);
    _hot.remove(key);
    _hot[key] = report;
    while (_hot.length > hotEntries) {
      _hotToby.remove(_hot.keys.first);
      _hot.remove(_hot.keys.first);
    }
  }

  void _rememberToby(String key, StoredTobyPerformance toby) {
    _hotToby.remove(key);
    _hotToby[key] = toby;
    while (_hotToby.length > hotEntries) {
      _hotToby.remove(_hotToby.keys.first);
    }
  }

  Future<void> _saveUnlocked(
    String accountId,
    GameAnalysisReport report,
  ) async {
    final key = cacheKeyForFingerprint(report.fingerprint);
    // The same game keeps its Toby estimate, with the basis it was computed
    // for, when its report is saved again in this session. A re-analysis with
    // other values no longer matches that basis, so the estimate is then read
    // again rather than served.
    final toby = _hotToby[_scopedKey(accountId, report.fingerprint)];
    final payload = jsonEncode(desktopGameReportToJson(report, toby: toby));
    final memory = _durableMemory;
    if (memory != null) {
      memory[_scopedKey(accountId, key)] = _MemoryEntry(
        accountId: accountId,
        value: payload,
        cachedAt: DateTime.now().microsecondsSinceEpoch,
      );
      _evictMemory(memory, accountId);
      return;
    }
    final db = _database ?? AppDatabase.instance;
    await db.setCache(key: key, value: payload, userId: accountId);
    final rows = await db.getCacheByPrefixes(
      prefixes: const [keyPrefix],
      userId: accountId,
    );
    if (rows.length <= maxEntries) return;
    final ordered =
        rows.entries.toList()
          ..sort((a, b) => a.value.cachedAt.compareTo(b.value.cachedAt));
    for (var i = 0; i < ordered.length - maxEntries; i++) {
      await db.removeCache(key: ordered[i].key, userId: accountId);
    }
  }

  Future<Map<String, dynamic>?> _readJson(
    String accountId,
    String fingerprint,
  ) async {
    final raw = await _readRaw(accountId, cacheKeyForFingerprint(fingerprint));
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  /// Rewrites an existing row in place (eviction is unchanged: the row
  /// already counts).
  Future<void> _writeRaw(String accountId, String key, String value) async {
    final memory = _durableMemory;
    if (memory != null) {
      memory[_scopedKey(accountId, key)] = _MemoryEntry(
        accountId: accountId,
        value: value,
        cachedAt: DateTime.now().microsecondsSinceEpoch,
      );
      return;
    }
    final db = _database ?? AppDatabase.instance;
    await db.setCache(key: key, value: value, userId: accountId);
  }

  Future<String?> _readRaw(String accountId, String key) async {
    final memory = _durableMemory;
    if (memory != null) return memory[_scopedKey(accountId, key)]?.value;
    final db = _database ?? AppDatabase.instance;
    return (await db.getCache(key: key, userId: accountId))?.value;
  }

  void _evictMemory(Map<String, _MemoryEntry> memory, String accountId) {
    final mine =
        memory.entries.where((e) => e.value.accountId == accountId).toList()
          ..sort((a, b) => a.value.cachedAt.compareTo(b.value.cachedAt));
    for (var i = 0; i < mine.length - maxEntries; i++) {
      memory.remove(mine[i].key);
    }
  }
}

class _MemoryEntry {
  const _MemoryEntry({
    required this.accountId,
    required this.value,
    required this.cachedAt,
  });

  final String accountId;
  final String value;
  final int cachedAt;
}

/// Payload version. Bump whenever a change alters what a report says about the
/// same game, so reports produced under old classification rules become
/// misses instead of being replayed.
const int desktopGameReportCacheSchemaVersion = 3;

/// Toby's estimate kept beside a report, with the
/// [TobyPerformanceRequest.basis] of the request it was computed for.
typedef StoredTobyPerformance = ({String basis, TobyPerformance performance});

/// [toby] is written beside the report when known.
Map<String, dynamic> desktopGameReportToJson(
  GameAnalysisReport report, {
  StoredTobyPerformance? toby,
}) {
  final json = <String, dynamic>{
    'v': desktopGameReportCacheSchemaVersion,
    'fingerprint': report.fingerprint,
    'whiteAccuracy': report.whiteAccuracy,
    'blackAccuracy': report.blackAccuracy,
    'whiteEstimatedRating': report.whiteEstimatedRating,
    'blackEstimatedRating': report.blackEstimatedRating,
    'generatedAt': report.generatedAt.toUtc().toIso8601String(),
    'positions': report.positions.map(_positionToJson).toList(),
    'moves': report.moves.map(_moveToJson).toList(),
  };
  if (toby != null) _writeTobyJson(json, toby);
  return json;
}

void _writeTobyJson(Map<String, dynamic> json, StoredTobyPerformance toby) {
  json['tobyPerformance'] = toby.performance.toJson();
  json['tobyPerformanceBasis'] = toby.basis;
}

/// Toby's estimate saved beside a report, or null when there is none, it
/// has no basis, or it is from a model other than [kTobyPerformanceModel].
/// Independent of the report's schema version: the estimate depends on the
/// game, not on how the report classified it.
StoredTobyPerformance? desktopGameReportTobyPerformanceFromJson(
  Map<String, dynamic> json,
) {
  final basis = json['tobyPerformanceBasis'];
  final performance = TobyPerformance.fromJson(json['tobyPerformance']);
  if (basis is! String ||
      basis.isEmpty ||
      performance == null ||
      performance.model != kTobyPerformanceModel) {
    return null;
  }
  return (basis: basis, performance: performance);
}

GameAnalysisReport? desktopGameReportFromJson(Map<String, dynamic> json) {
  try {
    if ((json['v'] as num?)?.toInt() != desktopGameReportCacheSchemaVersion) {
      return null;
    }
    final fingerprint = json['fingerprint'] as String?;
    final positionsRaw = json['positions'];
    final movesRaw = json['moves'];
    if (fingerprint == null ||
        fingerprint.isEmpty ||
        positionsRaw is! List ||
        movesRaw is! List) {
      return null;
    }
    final positions = <GameReportPosition>[];
    for (final item in positionsRaw) {
      if (item is! Map) return null;
      final position = _positionFromJson(Map<String, dynamic>.from(item));
      if (position == null) return null;
      positions.add(position);
    }
    final moves = <GameReportMove>[];
    for (final item in movesRaw) {
      if (item is! Map) return null;
      final move = _moveFromJson(Map<String, dynamic>.from(item));
      if (move == null) return null;
      moves.add(move);
    }
    final generatedAt =
        DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return GameAnalysisReport(
      fingerprint: fingerprint,
      positions: List.unmodifiable(positions),
      moves: List.unmodifiable(moves),
      whiteAccuracy: (json['whiteAccuracy'] as num?)?.toDouble() ?? 0,
      blackAccuracy: (json['blackAccuracy'] as num?)?.toDouble() ?? 0,
      whiteEstimatedRating: (json['whiteEstimatedRating'] as num?)?.toInt(),
      blackEstimatedRating: (json['blackEstimatedRating'] as num?)?.toInt(),
      generatedAt: generatedAt.toUtc(),
    );
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _positionToJson(GameReportPosition position) => {
  'fen': position.fen,
  'lines': position.lines.map(_lineToJson).toList(),
  if (position.search case final search?)
    'search': {
      'engineId': search.engineId,
      'searchId': search.searchId,
      'complete': search.complete,
    },
  if (position.uncertainty != null) 'uncertainty': position.uncertainty,
};

GameReportPosition? _positionFromJson(Map<String, dynamic> json) {
  final fen = json['fen'] as String?;
  final linesRaw = json['lines'];
  if (fen == null || linesRaw is! List || linesRaw.isEmpty) return null;
  final lines = <GameReportLine>[];
  for (final item in linesRaw) {
    if (item is! Map) return null;
    final line = _lineFromJson(Map<String, dynamic>.from(item));
    if (line == null) return null;
    lines.add(line);
  }
  final rawSearch = json['search'];
  return GameReportPosition(
    fen: fen,
    lines: List.unmodifiable(lines),
    search:
        rawSearch is Map &&
                rawSearch['engineId'] is String &&
                rawSearch['searchId'] is String &&
                rawSearch['complete'] is bool
            ? GameReportSearchEvidence(
              engineId: rawSearch['engineId'] as String,
              searchId: rawSearch['searchId'] as String,
              complete: rawSearch['complete'] as bool,
            )
            : null,
    uncertainty: json['uncertainty'] as String?,
  );
}

Map<String, dynamic> _lineToJson(GameReportLine line) => {
  'moves': line.moves,
  'depth': line.depth,
  if (line.centipawns != null) 'cp': line.centipawns,
  if (line.mate != null) 'mate': line.mate,
};

GameReportLine? _lineFromJson(Map<String, dynamic> json) {
  final movesRaw = json['moves'];
  if (movesRaw is! List) return null;
  return GameReportLine(
    moves: movesRaw.map((e) => e.toString()).toList(growable: false),
    depth: (json['depth'] as num?)?.toInt() ?? 0,
    centipawns: (json['cp'] as num?)?.toInt(),
    mate: (json['mate'] as num?)?.toInt(),
  );
}

Map<String, dynamic> _moveToJson(GameReportMove move) => {
  'ply': move.ply,
  'san': move.san,
  'uci': move.uci,
  'isWhite': move.isWhite,
  if (move.classification != null) 'classification': move.classification!.name,
  'evaluation': _lineToJson(move.evaluation),
  if (move.bestAlternative != null) 'bestAlternative': move.bestAlternative,
};

GameReportMove? _moveFromJson(Map<String, dynamic> json) {
  final ply = (json['ply'] as num?)?.toInt();
  final san = json['san'] as String?;
  final uci = json['uci'] as String?;
  final isWhite = json['isWhite'] as bool?;
  final evaluationRaw = json['evaluation'];
  if (ply == null ||
      san == null ||
      uci == null ||
      isWhite == null ||
      evaluationRaw is! Map) {
    return null;
  }
  final evaluation = _lineFromJson(Map<String, dynamic>.from(evaluationRaw));
  if (evaluation == null) return null;
  final className = json['classification'] as String?;
  GameMoveClassification? classification;
  for (final value in GameMoveClassification.values) {
    if (value.name == className) classification = value;
  }
  return GameReportMove(
    ply: ply,
    san: san,
    uci: uci,
    isWhite: isWhite,
    classification: classification,
    evaluation: evaluation,
    bestAlternative: json['bestAlternative'] as String?,
  );
}
