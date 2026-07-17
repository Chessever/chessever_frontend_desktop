import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/time_control_classifier.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// Player-centric outcome relative to the workspace / profile player.
enum LocalPlayerOutcomeFilter { all, win, draw, loss }

/// Structured filters for local resqlite game lists (players Games tab + library).
///
/// Wraps the shared [GameFilter] dialog model plus player-centric outcome,
/// opponent name, and exact local time-control category (including bullet).
@immutable
class LocalChessGameFilter {
  LocalChessGameFilter({
    GameFilter? base,
    this.playerOutcome = LocalPlayerOutcomeFilter.all,
    this.opponentName,
    this.timeControlCategory,
  }) : base = base ?? GameFilter.defaultFilter();

  final GameFilter base;
  final LocalPlayerOutcomeFilter playerOutcome;

  /// Opponent display name (substring match, case-insensitive) when set.
  final String? opponentName;

  /// Exact local category (`classical` / `rapid` / `blitz` / `bullet` / …).
  /// When set, overrides [GameFilter.timeControl] for the SQL path.
  final String? timeControlCategory;

  static LocalChessGameFilter get empty => LocalChessGameFilter();

  bool get hasActiveFilters =>
      base.hasActiveFilters ||
      playerOutcome != LocalPlayerOutcomeFilter.all ||
      (opponentName != null && opponentName!.trim().isNotEmpty) ||
      (timeControlCategory != null && timeControlCategory!.trim().isNotEmpty);

  int get activeFilterCount {
    var count = base.activeFilterCount;
    if (playerOutcome != LocalPlayerOutcomeFilter.all) count++;
    if (opponentName != null && opponentName!.trim().isNotEmpty) count++;
    // Prefer explicit category over the dialog enum when both set.
    if (timeControlCategory != null && timeControlCategory!.trim().isNotEmpty) {
      if (base.timeControl == GameTimeControlFilter.all) count++;
    }
    return count;
  }

  LocalChessGameFilter copyWith({
    GameFilter? base,
    LocalPlayerOutcomeFilter? playerOutcome,
    String? opponentName,
    String? timeControlCategory,
    bool clearOpponentName = false,
    bool clearTimeControlCategory = false,
  }) {
    return LocalChessGameFilter(
      base: base ?? this.base,
      playerOutcome: playerOutcome ?? this.playerOutcome,
      opponentName:
          clearOpponentName ? null : (opponentName ?? this.opponentName),
      timeControlCategory:
          clearTimeControlCategory
              ? null
              : (timeControlCategory ?? this.timeControlCategory),
    );
  }

  LocalChessGameFilter cleared() => LocalChessGameFilter();

  /// Applies a filter-dialog result. Clears sticky [timeControlCategory] so the
  /// dialog's [GameFilter.timeControl] is what SQL honors (Overview handoffs
  /// set exact categories that would otherwise shadow the dialog).
  LocalChessGameFilter applyingDialog(GameFilter dialogResult) {
    return copyWith(base: dialogResult, clearTimeControlCategory: true);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LocalChessGameFilter &&
        other.base == base &&
        other.playerOutcome == playerOutcome &&
        other.opponentName == opponentName &&
        other.timeControlCategory == timeControlCategory;
  }

  @override
  int get hashCode =>
      Object.hash(base, playerOutcome, opponentName, timeControlCategory);
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
  opponent,
}

/// One overview surface the user can tap to seed the Games tab filter.
@immutable
class PlayerOverviewFilterRequest {
  const PlayerOverviewFilterRequest({
    required this.facet,
    this.ecoCode,
    this.year,
    this.timeControlCategory,
    this.opponentName,
    this.sourcePath,
  });

  final PlayerOverviewFilterFacet facet;
  final String? ecoCode;
  final int? year;
  final String? timeControlCategory;
  final String? opponentName;

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
      return LocalChessGameFilter(playerOutcome: LocalPlayerOutcomeFilter.win);
    case PlayerOverviewFilterFacet.draws:
      return LocalChessGameFilter(playerOutcome: LocalPlayerOutcomeFilter.draw);
    case PlayerOverviewFilterFacet.losses:
      return LocalChessGameFilter(playerOutcome: LocalPlayerOutcomeFilter.loss);
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
      return LocalChessGameFilter(base: GameFilter(minYear: y, maxYear: y));
    case PlayerOverviewFilterFacet.timeControl:
      final raw = request.timeControlCategory?.trim().toLowerCase();
      if (raw == null || raw.isEmpty) return LocalChessGameFilter();
      final enumTc = _timeControlFromCategory(raw);
      return LocalChessGameFilter(
        base: GameFilter(timeControl: enumTc, maxYear: yearNow),
        timeControlCategory: raw,
      );
    case PlayerOverviewFilterFacet.opponent:
      final name = request.opponentName?.trim();
      if (name == null || name.isEmpty) return LocalChessGameFilter();
      return LocalChessGameFilter(opponentName: name);
  }
}

/// Applies the same filters as [appendLocalChessGameFilter] to a header-only
/// PGN catalog row. Player Games uses this path so browsing and filtering do
/// not require a full SQLite import.
bool localChessGameMatchesFilter(
  LocalChessGame game,
  LocalChessGameFilter filter, {
  String? playerFideId,
  List<String> playerAliases = const <String>[],
}) {
  if (!filter.hasActiveFilters) return true;
  final metadata = game.game.metadata;
  String header(String key) => metadata[key]?.toString().trim() ?? '';
  int number(String key) => int.tryParse(header(key)) ?? 0;
  final base = filter.base;
  final result = header('Result').toLowerCase();

  switch (base.result) {
    case GameResultFilter.all:
      break;
    case GameResultFilter.whiteWins:
      if (result != '1-0') return false;
    case GameResultFilter.blackWins:
      if (result != '0-1') return false;
    case GameResultFilter.draw:
      if (!_isLocalDrawResult(result)) return false;
  }

  final side = _localCatalogPlayerSide(
    metadata,
    playerFideId: playerFideId,
    playerAliases: playerAliases,
  );
  switch (filter.playerOutcome) {
    case LocalPlayerOutcomeFilter.all:
      break;
    case LocalPlayerOutcomeFilter.win:
      if (!((side == 'w' && result == '1-0') ||
          (side == 'b' && result == '0-1'))) {
        return false;
      }
    case LocalPlayerOutcomeFilter.loss:
      if (!((side == 'w' && result == '0-1') ||
          (side == 'b' && result == '1-0'))) {
        return false;
      }
    case LocalPlayerOutcomeFilter.draw:
      if (side == null || !_isLocalDrawResult(result)) return false;
  }

  switch (base.color) {
    case GameColorFilter.all:
      break;
    case GameColorFilter.white:
      if (side != 'w') return false;
    case GameColorFilter.black:
      if (side != 'b') return false;
  }

  final exactTimeControl = filter.timeControlCategory?.trim().toLowerCase();
  final classified = _localCatalogTimeControl(metadata);
  if (exactTimeControl != null && exactTimeControl.isNotEmpty) {
    final expected = _canonicalLocalTimeControl(exactTimeControl);
    if (classified != expected) return false;
  } else {
    switch (base.timeControl) {
      case GameTimeControlFilter.all:
        break;
      case GameTimeControlFilter.classical:
        if (classified != 'classical') return false;
      case GameTimeControlFilter.rapid:
        if (classified != 'rapid') return false;
      case GameTimeControlFilter.blitz:
        if (classified != null &&
            !const <String>{
              'blitz',
              'bullet',
              'ultrabullet',
            }.contains(classified)) {
          return false;
        }
    }
  }

  final isOnline = _localCatalogIsOnline(metadata);
  switch (base.online) {
    case GameOnlineFilter.all:
      break;
    case GameOnlineFilter.online:
      if (!isOnline) return false;
    case GameOnlineFilter.otb:
      if (isOnline) return false;
  }

  if (!base.eco.matches(header('ECO'))) return false;
  final hasYearFilter =
      base.minYear != GameFilter.defaultMinYear ||
      base.maxYear != DateTime.now().year;
  if (hasYearFilter) {
    final date = header('Date');
    final year = date.length >= 4 ? int.tryParse(date.substring(0, 4)) : null;
    if (year == null || year < base.minYear || year > base.maxYear) {
      return false;
    }
  }

  if (base.minRating != GameFilter.defaultMinRating ||
      base.maxRating != GameFilter.absoluteMaxRating) {
    final whiteElo = number('WhiteElo');
    final blackElo = number('BlackElo');
    if (whiteElo <= 0 && blackElo <= 0) return false;
    final average =
        whiteElo <= 0
            ? blackElo
            : blackElo <= 0
            ? whiteElo
            : (whiteElo + blackElo) ~/ 2;
    if (average < base.minRating || average > base.maxRating) return false;
  }

  final maxMove = base.finish.maxMoveNumber;
  if (maxMove != null) {
    final plyCount = number('PlyCount');
    final finalMove =
        plyCount > 0
            ? (plyCount + 1) ~/ 2
            : _estimateLocalCatalogFinalMove(game.rawPgn);
    if (finalMove == null || finalMove > maxMove) return false;
  }

  final opponent = filter.opponentName?.trim().toLowerCase();
  if (opponent != null && opponent.isNotEmpty) {
    if (!header('White').toLowerCase().contains(opponent) &&
        !header('Black').toLowerCase().contains(opponent)) {
      return false;
    }
  }
  return true;
}

String? _localCatalogPlayerSide(
  Map<String, dynamic> metadata, {
  required String? playerFideId,
  required List<String> playerAliases,
}) {
  String header(String key) => metadata[key]?.toString().trim() ?? '';
  final fide = playerFideId?.trim().toLowerCase();
  final whiteFide =
      (header('WhiteFideId').isNotEmpty
              ? header('WhiteFideId')
              : header('WhiteFideID'))
          .toLowerCase();
  final blackFide =
      (header('BlackFideId').isNotEmpty
              ? header('BlackFideId')
              : header('BlackFideID'))
          .toLowerCase();
  if (fide != null && fide.isNotEmpty) {
    if (whiteFide == fide) return 'w';
    if (blackFide == fide) return 'b';
  }
  final aliases = playerAliases
      .map(_normalizePlayerName)
      .where((name) => name.isNotEmpty)
      .toSet();
  if ((fide == null || fide.isEmpty || whiteFide.isEmpty) &&
      aliases.contains(_normalizePlayerName(header('White')))) {
    return 'w';
  }
  if ((fide == null || fide.isEmpty || blackFide.isEmpty) &&
      aliases.contains(_normalizePlayerName(header('Black')))) {
    return 'b';
  }
  return null;
}

String? _localCatalogTimeControl(Map<String, dynamic> metadata) {
  Object? value(String key) => metadata[key];
  return _canonicalLocalTimeControl(
        value('ChessEverTimeControlCategory')?.toString(),
      ) ??
      _canonicalLocalTimeControl(
        classifyTimeControlCategory(
          value('TimeControl'),
          event: value('Event'),
          site: value('Site'),
          source: value('ChessEverSource'),
        ),
      );
}

String? _canonicalLocalTimeControl(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'classical':
    case 'standard':
      return 'classical';
    case 'rapid':
      return 'rapid';
    case 'blitz':
      return 'blitz';
    case 'bullet':
      return 'bullet';
    case 'ultrabullet':
    case 'ultra_bullet':
    case 'ultra-bullet':
    case 'ultra bullet':
      return 'ultrabullet';
    case 'correspondence':
      return 'correspondence';
    default:
      return null;
  }
}

bool _localCatalogIsOnline(Map<String, dynamic> metadata) {
  final value =
      '${metadata['Site'] ?? ''} ${metadata['ChessEverSource'] ?? ''}'
          .toLowerCase();
  return value.contains('lichess') ||
      value.contains('chess.com') ||
      value.contains('chesscom') ||
      value.contains('chess24');
}

bool _isLocalDrawResult(String result) =>
    result == '1/2-1/2' ||
    result == '1/2' ||
    result == '0.5-0.5' ||
    result == '½-½';

int? _estimateLocalCatalogFinalMove(String pgn) {
  final cleaned = pgn
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
      .replaceAll(RegExp(r'\([^)]*\)'), ' ');
  int? maximum;
  for (final match in RegExp(r'\b(\d{1,3})\s*\.{1,3}').allMatches(cleaned)) {
    final move = int.tryParse(match.group(1) ?? '');
    if (move != null && (maximum == null || move > maximum)) maximum = move;
  }
  return maximum;
}

GameTimeControlFilter _timeControlFromCategory(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'classical':
    case 'standard':
      return GameTimeControlFilter.classical;
    case 'rapid':
      return GameTimeControlFilter.rapid;
    case 'blitz':
      return GameTimeControlFilter.blitz;
    case 'bullet':
    case 'ultrabullet':
    case 'ultra_bullet':
    case 'ultra-bullet':
    case 'ultra bullet':
      // Dialog enum has no bullet; keep blitz as nearest chip, exact category
      // is applied via [LocalChessGameFilter.timeControlCategory].
      return GameTimeControlFilter.blitz;
    default:
      return GameTimeControlFilter.all;
  }
}

/// Appends SQL predicates for [filter] onto an existing WHERE starting with
/// `g.database_id = ?` (joins: wp/bp players as in [localDatabaseGamesPage]).
///
/// Search terms are applied separately via [_appendLocalGameSearch] — both
/// compose with AND so filters + search always stack.
void appendLocalChessGameFilter(
  StringBuffer where,
  List<Object?> parameters,
  LocalChessGameFilter filter, {
  String? playerFideId,
  List<String> playerAliases = const <String>[],
}) {
  final base = filter.base;
  final fide = playerFideId?.trim().toLowerCase();
  final aliases = playerAliases
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
      where.write(" AND g.result IN ('1/2-1/2', '1/2', '0.5-0.5', '½-½')");
  }

  // Player-centric outcome (Overview W/D/L).
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

  // Colour relative to the player when identity is known.
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

  // Time control — exact local category wins over dialog enum.
  final exactTc = filter.timeControlCategory?.trim().toLowerCase();
  if (exactTc != null && exactTc.isNotEmpty) {
    switch (exactTc) {
      case 'classical':
      case 'standard':
        where.write(
          " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) "
          "IN ('classical', 'standard')",
        );
      case 'rapid':
        where.write(
          " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) = 'rapid'",
        );
      case 'blitz':
        where.write(
          " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) = 'blitz'",
        );
      case 'bullet':
        where.write(
          " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) = 'bullet'",
        );
      case 'ultrabullet':
      case 'ultra_bullet':
      case 'ultra-bullet':
      case 'ultra bullet':
        where.write(
          " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) "
          "IN ('ultrabullet', 'ultra_bullet', 'ultra-bullet', 'ultra bullet')",
        );
      default:
        where.write(
          " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) = ?",
        );
        parameters.add(exactTc);
    }
  } else {
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
        // Dialog "Blitz" still includes bullet when no exact category is set.
        where.write(
          " AND LOWER(TRIM(COALESCE(g.time_control_category, ''))) "
          "IN ('blitz', 'bullet', 'ultrabullet', 'ultra bullet')",
        );
    }
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

  // Opponent name — either side matches (substring, case-insensitive).
  final opp = filter.opponentName?.trim();
  if (opp != null && opp.isNotEmpty) {
    final like = '%${_escapeLike(opp.toLowerCase())}%';
    where.write('''
 AND (
  LOWER(COALESCE(wp.name, json_extract(g.headers_json, '\$.White'), '')) LIKE ? ESCAPE '\\'
  OR LOWER(COALESCE(bp.name, json_extract(g.headers_json, '\$.Black'), '')) LIKE ? ESCAPE '\\'
)
''');
    parameters
      ..add(like)
      ..add(like);
  }
}

/// SQL expression returning `'w'`, `'b'`, or NULL for the player's side.
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
