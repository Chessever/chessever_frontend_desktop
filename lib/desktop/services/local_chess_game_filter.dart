import 'package:flutter/foundation.dart';

import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// Player-centric outcome relative to the workspace / profile player.
enum LocalPlayerOutcomeFilter { all, win, draw, loss }

/// Structured filters for local resqlite game lists (players Games tab + library).
///
/// Wraps the shared [GameFilter] dialog model plus an optional player-centric
/// win/draw/loss outcome used by the players Overview → Games handoff.
@immutable
class LocalChessGameFilter {
  LocalChessGameFilter({
    GameFilter? base,
    this.playerOutcome = LocalPlayerOutcomeFilter.all,
  }) : base = base ?? GameFilter.defaultFilter();

  final GameFilter base;
  final LocalPlayerOutcomeFilter playerOutcome;

  static LocalChessGameFilter get empty => LocalChessGameFilter();

  bool get hasActiveFilters =>
      base.hasActiveFilters || playerOutcome != LocalPlayerOutcomeFilter.all;

  int get activeFilterCount =>
      base.activeFilterCount +
      (playerOutcome != LocalPlayerOutcomeFilter.all ? 1 : 0);

  LocalChessGameFilter copyWith({
    GameFilter? base,
    LocalPlayerOutcomeFilter? playerOutcome,
  }) {
    return LocalChessGameFilter(
      base: base ?? this.base,
      playerOutcome: playerOutcome ?? this.playerOutcome,
    );
  }

  LocalChessGameFilter cleared() => LocalChessGameFilter();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LocalChessGameFilter &&
        other.base == base &&
        other.playerOutcome == playerOutcome;
  }

  @override
  int get hashCode => Object.hash(base, playerOutcome);
}

/// Facet kind for Overview stat taps.
enum PlayerOverviewFilterFacet {
  wins,
  draws,
  losses,
  asWhite,
  asBlack,
  eco,
  year,
  timeControl,
}

/// One overview surface the user can tap to seed the Games tab filter.
@immutable
class PlayerOverviewFilterRequest {
  const PlayerOverviewFilterRequest({
    required this.facet,
    this.ecoCode,
    this.year,
    this.timeControlCategory,
    this.sourcePath,
  });

  final PlayerOverviewFilterFacet facet;
  final String? ecoCode;
  final int? year;
  final String? timeControlCategory;

  /// Preferred Games-tab source database path (active stats source).
  final String? sourcePath;
}

/// Maps an overview facet tap into the [LocalChessGameFilter] Games will apply.
///
/// Production handoff for players Overview → Games. Tests drive this helper.
LocalChessGameFilter localChessGameFilterFromOverview(
  PlayerOverviewFilterRequest request,
) {
  final yearNow = DateTime.now().year;
  switch (request.facet) {
    case PlayerOverviewFilterFacet.wins:
      return LocalChessGameFilter(
        playerOutcome: LocalPlayerOutcomeFilter.win,
      );
    case PlayerOverviewFilterFacet.draws:
      return LocalChessGameFilter(
        playerOutcome: LocalPlayerOutcomeFilter.draw,
      );
    case PlayerOverviewFilterFacet.losses:
      return LocalChessGameFilter(
        playerOutcome: LocalPlayerOutcomeFilter.loss,
      );
    case PlayerOverviewFilterFacet.asWhite:
      return LocalChessGameFilter(
        base: GameFilter(color: GameColorFilter.white, maxYear: yearNow),
      );
    case PlayerOverviewFilterFacet.asBlack:
      return LocalChessGameFilter(
        base: GameFilter(color: GameColorFilter.black, maxYear: yearNow),
      );
    case PlayerOverviewFilterFacet.eco:
      final code = request.ecoCode?.trim().toUpperCase();
      if (code == null || code.isEmpty) return LocalChessGameFilter();
      return LocalChessGameFilter(
        base: GameFilter(eco: GameEcoFilter.forCode(code), maxYear: yearNow),
      );
    case PlayerOverviewFilterFacet.year:
      final y = request.year;
      if (y == null) return LocalChessGameFilter();
      return LocalChessGameFilter(
        base: GameFilter(minYear: y, maxYear: y),
      );
    case PlayerOverviewFilterFacet.timeControl:
      final tc = _timeControlFromCategory(request.timeControlCategory);
      if (tc == GameTimeControlFilter.all) return LocalChessGameFilter();
      return LocalChessGameFilter(
        base: GameFilter(timeControl: tc, maxYear: yearNow),
      );
  }
}

GameTimeControlFilter _timeControlFromCategory(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'classical':
    case 'standard':
      return GameTimeControlFilter.classical;
    case 'rapid':
      return GameTimeControlFilter.rapid;
    case 'blitz':
    case 'bullet':
      return GameTimeControlFilter.blitz;
    default:
      return GameTimeControlFilter.all;
  }
}

/// Appends SQL predicates for [filter] onto an existing WHERE starting with
/// `g.database_id = ?` (joins: wp/bp players as in [localDatabaseGamesPage]).
///
/// When [playerFideId] / [playerAliases] are set, colour and player-outcome
/// filters resolve sides relative to that player (same idea as profile filters).
void appendLocalChessGameFilter(
  StringBuffer where,
  List<Object?> parameters,
  LocalChessGameFilter filter, {
  String? playerFideId,
  List<String> playerAliases = const <String>[],
}) {
  final base = filter.base;
  final fide = playerFideId?.trim().toLowerCase();
  final aliases =
      playerAliases
          .map(_normalizePlayerName)
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList(growable: false);

  // Absolute result (1-0 / 0-1 / draw) — dialog "Result" chips.
  switch (base.result) {
    case GameResultFilter.all:
      break;
    case GameResultFilter.whiteWins:
      where.write(" AND g.result IN ('1-0')");
    case GameResultFilter.blackWins:
      where.write(" AND g.result IN ('0-1')");
    case GameResultFilter.draw:
      where.write(
        " AND g.result IN ('1/2-1/2', '1/2', '0.5-0.5', '½-½')",
      );
  }

  // Player-centric outcome (Overview W/D/L taps). Side expression is used
  // once so bound FIDE/alias parameters stay 1:1 with placeholders.
  if (filter.playerOutcome != LocalPlayerOutcomeFilter.all &&
      ((fide != null && fide.isNotEmpty) || aliases.isNotEmpty)) {
    final sideSql = _playerSidePredicateSql(
      fideId: fide,
      aliases: aliases,
      parameters: parameters,
    );
    switch (filter.playerOutcome) {
      case LocalPlayerOutcomeFilter.win:
        where.write('''
 AND (
  CASE ($sideSql)
    WHEN 'w' THEN CASE WHEN g.result = '1-0' THEN 1 ELSE 0 END
    WHEN 'b' THEN CASE WHEN g.result = '0-1' THEN 1 ELSE 0 END
    ELSE 0
  END
) = 1''');
      case LocalPlayerOutcomeFilter.loss:
        where.write('''
 AND (
  CASE ($sideSql)
    WHEN 'w' THEN CASE WHEN g.result = '0-1' THEN 1 ELSE 0 END
    WHEN 'b' THEN CASE WHEN g.result = '1-0' THEN 1 ELSE 0 END
    ELSE 0
  END
) = 1''');
      case LocalPlayerOutcomeFilter.draw:
        where.write('''
 AND ($sideSql) IS NOT NULL
 AND g.result IN ('1/2-1/2', '1/2', '0.5-0.5', '½-½')''');
      case LocalPlayerOutcomeFilter.all:
        break;
    }
  }

  // Colour relative to the player when identity is known; otherwise no-op.
  if (base.color != GameColorFilter.all &&
      ((fide != null && fide.isNotEmpty) || aliases.isNotEmpty)) {
    final sideSql = _playerSidePredicateSql(
      fideId: fide,
      aliases: aliases,
      parameters: parameters,
    );
    final want = base.color == GameColorFilter.white ? 'w' : 'b';
    where.write(' AND ($sideSql) = ?');
    parameters.add(want);
  }

  // Time control category column.
  switch (base.timeControl) {
    case GameTimeControlFilter.all:
      break;
    case GameTimeControlFilter.classical:
      where.write(
        " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) "
        "IN ('classical', 'standard')",
      );
    case GameTimeControlFilter.rapid:
      where.write(
        " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) = 'rapid'",
      );
    case GameTimeControlFilter.blitz:
      where.write(
        " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) "
        "IN ('blitz', 'bullet')",
      );
  }

  // Online / OTB when column is populated.
  switch (base.online) {
    case GameOnlineFilter.all:
      break;
    case GameOnlineFilter.online:
      where.write(' AND g.is_online = 1');
    case GameOnlineFilter.otb:
      where.write(' AND (g.is_online = 0 OR g.is_online IS NULL)');
  }

  // ECO prefix (B90 matches B90, B90a, …).
  if (!base.eco.isAll && base.eco.code != null) {
    where.write(" AND UPPER(TRIM(COALESCE(g.eco, ''))) LIKE ? ESCAPE '\\'");
    parameters.add('${_escapeLike(base.eco.code!)}%');
  }

  // Year range on PGN date prefix.
  final yearActive =
      base.minYear != GameFilter.defaultMinYear ||
      base.maxYear != DateTime.now().year;
  if (yearActive) {
    where.write('''
 AND g.date IS NOT NULL
 AND length(g.date) >= 4
 AND CAST(substr(g.date, 1, 4) AS INTEGER) >= ?
 AND CAST(substr(g.date, 1, 4) AS INTEGER) <= ?
''');
    parameters
      ..add(base.minYear)
      ..add(base.maxYear);
  }

  // Average of available side Elos within range.
  if (base.minRating != GameFilter.defaultMinRating ||
      base.maxRating != GameFilter.absoluteMaxRating) {
    where.write('''
 AND (
  (COALESCE(g.white_elo, 0) > 0 OR COALESCE(g.black_elo, 0) > 0)
  AND (
    CASE
      WHEN COALESCE(g.white_elo, 0) > 0 AND COALESCE(g.black_elo, 0) > 0
        THEN (g.white_elo + g.black_elo) / 2
      WHEN COALESCE(g.white_elo, 0) > 0 THEN g.white_elo
      ELSE g.black_elo
    END
  ) BETWEEN ? AND ?
)
''');
    parameters
      ..add(base.minRating)
      ..add(base.maxRating);
  }

  // Finish length via ply_count (move N ≈ ceil(ply/2)).
  final maxMove = base.finish.maxMoveNumber;
  if (maxMove != null) {
    where.write(
      ' AND g.ply_count IS NOT NULL AND g.ply_count > 0 '
      'AND ((g.ply_count + 1) / 2) <= ?',
    );
    parameters.add(maxMove);
  }
}

/// SQL expression returning `'w'`, `'b'`, or NULL for the player's side.
/// Appends bound parameters for FIDE/aliases as needed.
String _playerSidePredicateSql({
  required String? fideId,
  required List<String> aliases,
  required List<Object?> parameters,
}) {
  final parts = <String>[];
  if (fideId != null && fideId.isNotEmpty) {
    parts.add(
      "CASE "
      "WHEN LOWER(TRIM(COALESCE(json_extract(g.headers_json, '\$.WhiteFideId'), ''))) = ? THEN 'w' "
      "WHEN LOWER(TRIM(COALESCE(json_extract(g.headers_json, '\$.BlackFideId'), ''))) = ? THEN 'b' "
      "ELSE NULL END",
    );
    parameters
      ..add(fideId)
      ..add(fideId);
  }
  if (aliases.isNotEmpty) {
    final placeholders = List.filled(aliases.length, '?').join(', ');
    final whiteNorm = _normalizedNameSql(
      "COALESCE(wp.name, json_extract(g.headers_json, '\$.White'), '')",
    );
    final blackNorm = _normalizedNameSql(
      "COALESCE(bp.name, json_extract(g.headers_json, '\$.Black'), '')",
    );
    if (fideId != null && fideId.isNotEmpty) {
      parts.add(
        "CASE "
        "WHEN TRIM(COALESCE(json_extract(g.headers_json, '\$.WhiteFideId'), '')) = '' "
        " AND $whiteNorm IN ($placeholders) THEN 'w' "
        "WHEN TRIM(COALESCE(json_extract(g.headers_json, '\$.BlackFideId'), '')) = '' "
        " AND $blackNorm IN ($placeholders) THEN 'b' "
        "ELSE NULL END",
      );
      parameters
        ..addAll(aliases)
        ..addAll(aliases);
    } else {
      parts.add(
        "CASE "
        "WHEN $whiteNorm IN ($placeholders) THEN 'w' "
        "WHEN $blackNorm IN ($placeholders) THEN 'b' "
        "ELSE NULL END",
      );
      parameters
        ..addAll(aliases)
        ..addAll(aliases);
    }
  }
  if (parts.isEmpty) return 'NULL';
  if (parts.length == 1) return parts.single;
  return 'COALESCE(${parts.join(', ')})';
}

String _normalizePlayerName(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'[\s,._-]+'), '').trim();
}

String _normalizedNameSql(String expression) {
  var sql = 'LOWER(TRIM(COALESCE($expression, \'\')))';
  for (final token in const <String>[',', ' ', '_', '.', '-']) {
    sql = "REPLACE($sql, '$token', '')";
  }
  return sql;
}

String _escapeLike(String value) {
  final out = StringBuffer();
  for (final codePoint in value.runes) {
    final char = String.fromCharCode(codePoint);
    if (char == r'\' || char == '%' || char == '_') {
      out.write(r'\');
    }
    out.write(char);
  }
  return out.toString();
}
