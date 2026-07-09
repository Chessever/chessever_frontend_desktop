import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart'
    show LocalChessDatabaseRepository, LocalChessResqliteDatabase;
import 'package:chessever/desktop/state/player_stats_provider.dart'
    show PlayerStatsOutcomeFilter;
import 'package:chessever/repository/sqlite/local_chess_schema.dart'
    show localChessDatabasesTable, localChessGamesTable, localChessPlayersTable;
import 'package:chessever/utils/eco_openings.dart';

typedef PlayerStatsSelect =
    Future<List<Map<String, Object?>>> Function(
      resqlite.Database database,
      String sql,
      List<Object?> parameters,
    );

/// Computes rich per-player statistics locally from the player's combined
/// resqlite database.
///
/// Everything runs as GROUP BY aggregates against the single cached WAL
/// connection, scoped to one `database_id` (the normalized pgn path). No games
/// are pulled into Dart — SQLite does the counting, so a 6k-game database
/// resolves in a few milliseconds.
///
/// "The player" is identified by FIDE id when available, with normalized aliases
/// only for rows whose PGN side has no FIDE header.
class PlayerStatsRepository {
  PlayerStatsRepository({
    Future<resqlite.Database> Function()? database,
    LocalChessDatabaseRepository? localRepository,
    PlayerStatsSelect? select,
  }) : _database =
           database ?? (() => LocalChessResqliteDatabase.instance.database),
       _localRepository = localRepository,
       _select = select ?? _defaultSelect;

  final Future<resqlite.Database> Function() _database;
  final LocalChessDatabaseRepository? _localRepository;
  final PlayerStatsSelect _select;

  static Future<List<Map<String, Object?>>> _defaultSelect(
    resqlite.Database database,
    String sql,
    List<Object?> parameters,
  ) => database.select(sql, parameters);

  Future<PlayerStatsSnapshot> computePlayerStats({
    required String databasePath,
    required Iterable<String> aliases,
    String? playerFideId,
    int? windowDays,
    String? timeControlCategory,
    String? preferredRatingTimeControl,
    String? unclassifiedTimeControlCategory,
    PlayerStatsOutcomeFilter playerOutcome = PlayerStatsOutcomeFilter.all,
    String? playerColor,
  }) async {
    final normalizedFideId = _normalizeFideId(playerFideId);
    final normalizedAliases =
        aliases.map(_normalizeName).where((name) => name.isNotEmpty).toSet();

    final databaseId = _databaseId(databasePath);
    final db = await _database();
    await _ensureLocalCache(databasePath: databasePath, databaseId: databaseId);

    final aliasSet = normalizedAliases.toSet();
    if (normalizedFideId == null) {
      // Fallback only for sources without a stable FIDE id. The workspace
      // database is built from one player's games, so the most frequent name
      // rescues spelling / word-order differences.
      final dominant = await _dominantPlayerName(db, databaseId);
      if (dominant != null) aliasSet.add(dominant);
      if (aliasSet.isEmpty) return PlayerStatsSnapshot.empty;
    }
    final matchAliases = aliasSet.toList(growable: false);

    // The base params identify the player, then scope to database_id —
    // identical for every query below. FIDE is primary when present, with an
    // alias fallback only for rows whose PGN side has no FIDE header.
    final dateModifier =
        (windowDays != null && windowDays > 0) ? '-$windowDays days' : null;
    final hasAliasFallback = matchAliases.isNotEmpty;
    final tcFilter = _normalizeTimeControlFilter(timeControlCategory);
    final preferredRating = _normalizeTimeControlFilter(
      preferredRatingTimeControl,
    );
    final unclassifiedTimeControl = _normalizeUnclassifiedTimeControlFallback(
      unclassifiedTimeControlCategory,
    );
    final baseParams = <Object?>[
      if (normalizedFideId != null) ...[
        normalizedFideId,
        normalizedFideId,
        if (hasAliasFallback) ...[...matchAliases, ...matchAliases],
      ] else ...[
        ...matchAliases,
        ...matchAliases,
      ],
      databaseId,
      if (dateModifier != null) ...[dateModifier, databaseId],
      // Time-control scope placeholders (empty when unscoped).
      ..._timeControlFilterParams(tcFilter),
    ];
    final colorFilter = _normalizePlayerColorFilter(playerColor);
    final cte = _cte(
      aliasPlaceholders: List.filled(matchAliases.length, '?').join(', '),
      fideScoped: normalizedFideId != null,
      hasAliasFallback: hasAliasFallback,
      windowed: dateModifier != null,
      timeControlFiltered: tcFilter != null,
      unclassifiedTimeControlCategory: unclassifiedTimeControl,
      playerOutcome: playerOutcome,
      playerColor: colorFilter,
    );

    // Rating ladder: when the dashboard is scoped to a TC, the series is just
    // rated games in that scope. When unscoped ("All"), pick the preferred
    // ladder (classical for Combined/ChessEver, blitz for online sources),
    // falling back to the most common rated TC.
    final ratingSql =
        tcFilter != null
            ? _ratingSqlScoped
            : _ratingSqlPreferred(preferredRating ?? 'classical');
    final ratingParams =
        tcFilter != null
            ? baseParams
            : <Object?>[
              ...baseParams,
              preferredRating ?? 'classical',
              preferredRating ?? 'classical',
            ];

    // Each aggregate scans the same player's database. Dispatching all ten at
    // once occupies every resqlite reader isolate and creates a short, severe
    // CPU burst while the Combined overview opens. Keep the reads serial: the
    // work still happens off the UI isolate, while one reader at a time leaves
    // enough CPU headroom for Flutter to keep presenting frames smoothly.
    final queries = <({String sql, List<Object?> parameters})>[
      (sql: '$cte\n$_overallSql', parameters: baseParams),
      (sql: '$cte\n$ratingSql', parameters: ratingParams),
      (sql: '$cte\n$_openingsSql', parameters: baseParams),
      (sql: '$cte\n$_opponentsSql', parameters: baseParams),
      (sql: '$cte\n$_yearsSql', parameters: baseParams),
      (sql: '$cte\n$_lengthSql', parameters: baseParams),
      // TC chip counts are always unscoped so the chip strip stays complete
      // while the rest of the dashboard filters.
      (
        sql:
            '${_cte(aliasPlaceholders: List.filled(matchAliases.length, '?').join(', '), fideScoped: normalizedFideId != null, hasAliasFallback: hasAliasFallback, windowed: dateModifier != null, timeControlFiltered: false, unclassifiedTimeControlCategory: unclassifiedTimeControl, playerOutcome: PlayerStatsOutcomeFilter.all, playerColor: null)}\n$_timeControlSql',
        parameters: <Object?>[
          if (normalizedFideId != null) ...[
            normalizedFideId,
            normalizedFideId,
            if (hasAliasFallback) ...[...matchAliases, ...matchAliases],
          ] else ...[
            ...matchAliases,
            ...matchAliases,
          ],
          databaseId,
          if (dateModifier != null) ...[dateModifier, databaseId],
        ],
      ),
      (sql: '$cte\n$_auxSql', parameters: baseParams),
      (sql: '$cte\n$_yearTimeControlSql', parameters: baseParams),
      (sql: '$cte\n$_yearSourceSql', parameters: baseParams),
    ];
    final results = <List<Map<String, Object?>>>[];
    for (final query in queries) {
      results.add(await _select(db, query.sql, query.parameters));
    }

    final overallRows = results[0];
    final ratingRows = results[1];
    final openingRows = results[2];
    final opponentRows = results[3];
    final yearRows = results[4];
    final lengthRows = results[5];
    final timeControlRows = results[6];
    final auxRows = results[7];
    final yearTimeControlRows = results[8];
    final yearSourceRows = results[9];

    final tallies = _talliesFromRows(overallRows);
    final rating = _ratingSeriesFromRows(ratingRows);
    final ratingSeries = rating.spots;

    final peak =
        ratingSeries.isEmpty
            ? null
            : ratingSeries.map((s) => s.rating).reduce(math.max);
    final latest = ratingSeries.isEmpty ? null : ratingSeries.last.rating;
    final avgOpponent = _intOrNull(
      auxRows.isEmpty ? null : auxRows.first['avg_opp'],
    );

    return PlayerStatsSnapshot(
      overall: tallies.overall,
      asWhite: tallies.white,
      asBlack: tallies.black,
      ratingSeries: ratingSeries,
      openings: _openingsFromRows(openingRows),
      opponents: _opponentsFromRows(opponentRows),
      years: _yearsFromRows(
        yearRows,
        yearTimeControls: yearTimeControlRows,
        yearSources: yearSourceRows,
      ),
      lengthBuckets: _lengthBucketsFromRows(lengthRows),
      timeControls: _timeControlsFromRows(timeControlRows),
      ratingTimeControlCategory: rating.timeControlCategory,
      peakRating: peak,
      latestRating: latest,
      averageOpponentRating: avgOpponent,
      performanceRating: _performanceRating(tallies.overall, avgOpponent),
    );
  }

  Future<void> _ensureLocalCache({
    required String databasePath,
    required String databaseId,
  }) async {
    final file = File(databasePath);
    if (!await file.exists()) return;

    final db = await _database();
    final rows = await db.select(
      '''
      SELECT
        d.game_count AS game_count,
        d.deleted_at_ms AS deleted_at_ms,
        COUNT(g.id) AS row_count
      FROM $localChessDatabasesTable d
      LEFT JOIN $localChessGamesTable g ON g.database_id = d.id
      WHERE d.id = ?
      GROUP BY d.id
      ''',
      <Object?>[databaseId],
    );
    if (rows.isNotEmpty) {
      final row = rows.single;
      final gameCount = _int(row['game_count']);
      final rowCount = _int(row['row_count']);
      final deletedAt = row['deleted_at_ms'];
      if (deletedAt == null && gameCount > 0 && rowCount == gameCount) {
        return;
      }
    }

    final repository =
        _localRepository ?? LocalChessDatabaseRepository(database: _database);
    await repository.importSingleFileSource(path: databasePath);
  }

  /// The most frequent player across White + Black in this database — for a
  /// single-player workspace database that is the player. Returned normalized
  /// to match the alias comparison.
  Future<String?> _dominantPlayerName(
    resqlite.Database db,
    String databaseId,
  ) async {
    final rows = await db.select(
      '''
      SELECT p.name AS name, COUNT(*) AS c
      FROM (
        SELECT white_id AS pid FROM $localChessGamesTable WHERE database_id = ?
        UNION ALL
        SELECT black_id AS pid FROM $localChessGamesTable WHERE database_id = ?
      ) t
      JOIN $localChessPlayersTable p ON p.id = t.pid
      WHERE p.name IS NOT NULL AND TRIM(p.name) <> '' AND p.name <> '?'
      GROUP BY t.pid
      ORDER BY c DESC
      LIMIT 1
      ''',
      [databaseId, databaseId],
    );
    if (rows.isEmpty) return null;
    final name = _normalizeName(rows.first['name']?.toString() ?? '');
    return name.isEmpty ? null : name;
  }

  // ------------------------------------------------------------------
  // Row → model mapping
  // ------------------------------------------------------------------

  ({
    PlayerResultTally overall,
    PlayerResultTally white,
    PlayerResultTally black,
  })
  _talliesFromRows(List<Map<String, Object?>> rows) {
    var wWins = 0, wDraws = 0, wLosses = 0;
    var bWins = 0, bDraws = 0, bLosses = 0;
    for (final row in rows) {
      final side = row['side']?.toString();
      final presult = row['presult']?.toString();
      final count = _int(row['c']);
      if (side == 'w') {
        if (presult == 'win') wWins += count;
        if (presult == 'draw') wDraws += count;
        if (presult == 'loss') wLosses += count;
      } else if (side == 'b') {
        if (presult == 'win') bWins += count;
        if (presult == 'draw') bDraws += count;
        if (presult == 'loss') bLosses += count;
      }
    }
    final white = PlayerResultTally(
      wins: wWins,
      draws: wDraws,
      losses: wLosses,
    );
    final black = PlayerResultTally(
      wins: bWins,
      draws: bDraws,
      losses: bLosses,
    );
    return (overall: white + black, white: white, black: black);
  }

  ({List<PlayerRatingSpot> spots, String? timeControlCategory})
  _ratingSeriesFromRows(List<Map<String, Object?>> rows) {
    // Keep the latest rating per calendar day (rows already ordered ascending),
    // preserving order, then cap the series so the chart stays crisp.
    final byDay = <String, PlayerRatingSpot>{};
    String? category;
    for (final row in rows) {
      final date = _dateFromDot(row['d']?.toString());
      final rating = _int(row['elo']);
      if (date == null || rating <= 0) continue;
      category ??= row['tc']?.toString().trim().toLowerCase();
      final key =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      byDay[key] = PlayerRatingSpot(date: date, rating: rating);
    }
    final spots = byDay.values.toList(growable: false)
      ..sort((a, b) => a.date.compareTo(b.date));
    return (
      spots: _downsample(spots, 400),
      timeControlCategory: category?.isEmpty == true ? null : category,
    );
  }

  List<PlayerOpeningStat> _openingsFromRows(List<Map<String, Object?>> rows) {
    return rows
        .map((row) {
          final eco = (row['eco']?.toString().trim() ?? '').toUpperCase();
          final storedName = row['name']?.toString().trim();
          final name =
              _isMeaningfulOpeningName(storedName)
                  ? storedName
                  : EcoOpenings.getOpeningName(eco);
          return PlayerOpeningStat(
            eco: eco,
            name: (name == null || name.isEmpty) ? null : name,
            tally: PlayerResultTally(
              wins: _int(row['w']),
              draws: _int(row['d']),
              losses: _int(row['l']),
            ),
          );
        })
        .where((opening) => opening.eco.isNotEmpty && opening.tally.games > 0)
        .toList(growable: false);
  }

  List<PlayerOpponentStat> _opponentsFromRows(List<Map<String, Object?>> rows) {
    return rows
        .map((row) {
          return PlayerOpponentStat(
            name: row['name']?.toString().trim() ?? '',
            averageRating: _intOrNull(row['avg_elo']),
            tally: PlayerResultTally(
              wins: _int(row['w']),
              draws: _int(row['d']),
              losses: _int(row['l']),
            ),
          );
        })
        .where((opp) => opp.name.isNotEmpty && opp.tally.games > 0)
        .toList(growable: false);
  }

  List<PlayerYearStat> _yearsFromRows(
    List<Map<String, Object?>> rows, {
    List<Map<String, Object?>> yearTimeControls = const [],
    List<Map<String, Object?>> yearSources = const [],
  }) {
    final tcsByYear = <int, List<PlayerTimeControlStat>>{};
    for (final row in yearTimeControls) {
      final year = int.tryParse(row['yr']?.toString() ?? '');
      if (year == null) continue;
      final count = _int(row['c']);
      if (count <= 0) continue;
      final cat =
          row['cat']?.toString().trim().isEmpty ?? true
              ? 'Unknown'
              : row['cat']!.toString().trim();
      tcsByYear
          .putIfAbsent(year, () => <PlayerTimeControlStat>[])
          .add(PlayerTimeControlStat(category: cat, count: count));
    }

    final sourcesByYear = <int, List<PlayerSourceStat>>{};
    for (final row in yearSources) {
      final year = int.tryParse(row['yr']?.toString() ?? '');
      if (year == null) continue;
      final count = _int(row['c']);
      if (count <= 0) continue;
      final label =
          row['src']?.toString().trim().isEmpty ?? true
              ? 'Unknown'
              : row['src']!.toString().trim();
      sourcesByYear
          .putIfAbsent(year, () => <PlayerSourceStat>[])
          .add(PlayerSourceStat(label: label, count: count));
    }

    return rows
        .map((row) {
          final year = int.tryParse(row['yr']?.toString() ?? '');
          if (year == null || year < 1500 || year > 3000) return null;
          return PlayerYearStat(
            year: year,
            tally: PlayerResultTally(
              wins: _int(row['w']),
              draws: _int(row['d']),
              losses: _int(row['l']),
            ),
            total: _int(row['total']),
            timeControls: List<PlayerTimeControlStat>.unmodifiable(
              tcsByYear[year] ?? const <PlayerTimeControlStat>[],
            ),
            sources: List<PlayerSourceStat>.unmodifiable(
              sourcesByYear[year] ?? const <PlayerSourceStat>[],
            ),
          );
        })
        .whereType<PlayerYearStat>()
        .where((year) => year.games > 0)
        .toList(growable: false);
  }

  List<PlayerLengthBucket> _lengthBucketsFromRows(
    List<Map<String, Object?>> rows,
  ) {
    if (rows.isEmpty) return const <PlayerLengthBucket>[];
    final row = rows.first;
    const labels = ['0–20', '21–30', '31–40', '41–50', '50+'];
    final keys = ['b1', 'b2', 'b3', 'b4', 'b5'];
    return <PlayerLengthBucket>[
      for (var i = 0; i < labels.length; i++)
        PlayerLengthBucket(label: labels[i], count: _int(row[keys[i]])),
    ];
  }

  List<PlayerTimeControlStat> _timeControlsFromRows(
    List<Map<String, Object?>> rows,
  ) {
    return rows
        .map(
          (row) => PlayerTimeControlStat(
            category:
                row['cat']?.toString().trim().isEmpty ?? true
                    ? 'Unknown'
                    : row['cat']!.toString().trim(),
            count: _int(row['c']),
          ),
        )
        .where((tc) => tc.count > 0)
        .toList(growable: false);
  }

  // ------------------------------------------------------------------
  // SQL
  // ------------------------------------------------------------------

  String _cte({
    required String aliasPlaceholders,
    required bool fideScoped,
    required bool hasAliasFallback,
    bool windowed = false,
    bool timeControlFiltered = false,
    String? unclassifiedTimeControlCategory,
    PlayerStatsOutcomeFilter playerOutcome = PlayerStatsOutcomeFilter.all,
    String? playerColor,
  }) {
    // Chronological window relative to the newest game in this database. PGN
    // dates are stored as 'YYYY.MM.DD' strings; converting the dots to dashes
    // yields ISO dates whose lexicographic order matches chronological order,
    // so `date(..., '-N days')` and a string `>=` compare correctly. Hits
    // idx_local_chess_games_db_date.
    final dateClause =
        windowed
            ? '''
    AND g.date LIKE '____.__.__'
    AND REPLACE(g.date, '.', '-') >= (
      SELECT date(REPLACE(MAX(g2.date), '.', '-'), ?)
      FROM $localChessGamesTable g2
      WHERE g2.database_id = ? AND g2.date LIKE '____.__.__'
    )'''
            : '';
    final timeControlValueSql = '''
      CASE
        WHEN LOWER(TRIM(COALESCE(g.time_control_category, '')))
          IN ('', 'unknown', 'unclassified')
          THEN '${unclassifiedTimeControlCategory ?? ''}'
        ELSE g.time_control_category
      END''';
    final canonicalTimeControlSql = '''
      CASE LOWER(TRIM(COALESCE(($timeControlValueSql), '')))
        WHEN 'standard' THEN 'classical'
        WHEN 'ultra bullet' THEN 'ultrabullet'
        WHEN 'ultra_bullet' THEN 'ultrabullet'
        WHEN 'ultra-bullet' THEN 'ultrabullet'
        ELSE LOWER(TRIM(COALESCE(($timeControlValueSql), '')))
      END''';
    // Overview time-control chip scope. Explicit stored categories win; only
    // an empty category uses the trusted source-level fallback above.
    final tcClause =
        timeControlFiltered
            ? '''
    AND ($canonicalTimeControlSql) = ?'''
            : '';
    final outcomeClause = switch (playerOutcome) {
      PlayerStatsOutcomeFilter.win => " AND presult = 'win'",
      PlayerStatsOutcomeFilter.draw => " AND presult = 'draw'",
      PlayerStatsOutcomeFilter.loss => " AND presult = 'loss'",
      PlayerStatsOutcomeFilter.all => '',
    };
    final colorClause = playerColor == null ? '' : " AND side = '$playerColor'";
    final sideSql =
        fideScoped
            ? '''
      WHEN LOWER(TRIM(COALESCE(json_extract(g.headers_json, '\$.WhiteFideId'), ''))) = ? THEN 'w'
      WHEN LOWER(TRIM(COALESCE(json_extract(g.headers_json, '\$.BlackFideId'), ''))) = ? THEN 'b'
      ${hasAliasFallback ? '''
      WHEN TRIM(COALESCE(json_extract(g.headers_json, '\$.WhiteFideId'), '')) = ''
        AND ${_normalizedNameSql('wp.name')} IN ($aliasPlaceholders) THEN 'w'
      WHEN TRIM(COALESCE(json_extract(g.headers_json, '\$.BlackFideId'), '')) = ''
        AND ${_normalizedNameSql('bp.name')} IN ($aliasPlaceholders) THEN 'b'
      ''' : ''}
    '''
            : '''
      WHEN ${_normalizedNameSql('wp.name')} IN ($aliasPlaceholders) THEN 'w'
      WHEN ${_normalizedNameSql('bp.name')} IN ($aliasPlaceholders) THEN 'b'
    ''';
    return '''
WITH base AS (
  SELECT
    g.result AS result,
    g.eco AS eco,
    g.date AS date,
    g.ply_count AS ply,
    $timeControlValueSql AS tcc,
    g.white_elo AS white_elo,
    g.black_elo AS black_elo,
    wp.name AS white_name,
    bp.name AS black_name,
    json_extract(g.headers_json, '\$.Opening') AS opening,
    json_extract(g.headers_json, '\$.Site') AS site,
    json_extract(g.headers_json, '\$.ChessEverSource') AS source,
    CASE
      $sideSql
    END AS side
  FROM $localChessGamesTable g
  LEFT JOIN $localChessPlayersTable wp ON wp.id = g.white_id
  LEFT JOIN $localChessPlayersTable bp ON bp.id = g.black_id
  WHERE g.database_id = ?$dateClause$tcClause
),
pv AS (
  SELECT
    side, eco, date, ply, tcc, opening, site, source,
    CASE side WHEN 'w' THEN white_elo WHEN 'b' THEN black_elo END AS my_elo,
    CASE side WHEN 'w' THEN black_name WHEN 'b' THEN white_name END AS opp_name,
    CASE side WHEN 'w' THEN black_elo WHEN 'b' THEN white_elo END AS opp_elo,
    CASE
      WHEN result IN ('1/2-1/2', '1/2', '0.5-0.5') THEN 'draw'
      WHEN side = 'w' AND result = '1-0' THEN 'win'
      WHEN side = 'w' AND result = '0-1' THEN 'loss'
      WHEN side = 'b' AND result = '0-1' THEN 'win'
      WHEN side = 'b' AND result = '1-0' THEN 'loss'
    END AS presult
  FROM base
  WHERE side IS NOT NULL
),
scoped AS (
  SELECT * FROM pv
  WHERE 1=1$outcomeClause$colorClause
)''';
  }

  static const _overallSql = '''
SELECT side, presult, COUNT(*) AS c
FROM scoped
WHERE presult IS NOT NULL
GROUP BY side, presult''';

  /// Rating series when the overview is already scoped to one time control.
  static const _ratingSqlScoped = '''
SELECT date AS d, my_elo AS elo,
  CASE LOWER(TRIM(COALESCE(tcc, '')))
    WHEN 'standard' THEN 'classical'
    WHEN 'bullet' THEN 'blitz'
    ELSE LOWER(TRIM(COALESCE(tcc, '')))
  END AS tc
FROM scoped
WHERE my_elo IS NOT NULL AND my_elo > 0
  AND date IS NOT NULL AND date LIKE '____.__.__'
ORDER BY date ASC''';

  /// Rating series for "All" — prefer the bound ladder (`?`), then the most
  /// common rated classical/rapid/blitz series. If the chosen ladder would
  /// start after older Elo-tagged games, return the full rated history instead.
  static String _ratingSqlPreferred(String preferredTc) {
    assert(preferredTc.isNotEmpty);
    return '''
, rating_all AS (
  SELECT date AS d, my_elo AS elo,
    CASE LOWER(TRIM(COALESCE(tcc, '')))
      WHEN 'standard' THEN 'classical'
      WHEN 'bullet' THEN 'blitz'
      ELSE LOWER(TRIM(COALESCE(tcc, '')))
    END AS tc
  FROM scoped
  WHERE my_elo IS NOT NULL AND my_elo > 0
    AND date IS NOT NULL AND date LIKE '____.__.__'
),
rating_bucket AS (
  SELECT
    tc,
    COUNT(*) AS c,
    MIN(d) AS first_d
  FROM rating_all
  WHERE tc IN ('classical', 'rapid', 'blitz')
  GROUP BY tc
  ORDER BY
    CASE WHEN tc = ? THEN 0 ELSE 1 END ASC,
    c DESC,
    CASE tc
      WHEN 'classical' THEN 0
      WHEN 'rapid' THEN 1
      WHEN 'blitz' THEN 2
      ELSE 3
    END ASC
  LIMIT 1
),
rating_scope AS (
  SELECT
    (SELECT tc FROM rating_bucket) AS tc,
    CASE
      WHEN (SELECT tc FROM rating_bucket) IS NULL THEN 0
      WHEN ? <> 'classical' THEN 1
      WHEN (SELECT MIN(d) FROM rating_all) < (SELECT first_d FROM rating_bucket) THEN 0
      ELSE 1
    END AS bucket_only
)
SELECT d, elo,
  CASE WHEN (SELECT bucket_only FROM rating_scope) = 1 THEN tc ELSE NULL END AS tc
FROM rating_all
WHERE (SELECT bucket_only FROM rating_scope) = 0
  OR tc = (SELECT tc FROM rating_scope)
ORDER BY d ASC''';
  }

  static const _openingsSql = '''
SELECT eco,
  MAX(opening) AS name,
  SUM(CASE WHEN presult = 'win' THEN 1 ELSE 0 END) AS w,
  SUM(CASE WHEN presult = 'draw' THEN 1 ELSE 0 END) AS d,
  SUM(CASE WHEN presult = 'loss' THEN 1 ELSE 0 END) AS l,
  COUNT(*) AS total
FROM scoped
WHERE eco IS NOT NULL AND eco <> '' AND eco <> '?'
GROUP BY eco
ORDER BY total DESC, eco ASC
LIMIT 10''';

  static const _opponentsSql = '''
SELECT opp_name AS name,
  SUM(CASE WHEN presult = 'win' THEN 1 ELSE 0 END) AS w,
  SUM(CASE WHEN presult = 'draw' THEN 1 ELSE 0 END) AS d,
  SUM(CASE WHEN presult = 'loss' THEN 1 ELSE 0 END) AS l,
  AVG(CASE WHEN opp_elo > 0 THEN opp_elo END) AS avg_elo,
  COUNT(*) AS total
FROM scoped
WHERE opp_name IS NOT NULL AND opp_name <> '' AND opp_name <> '?'
GROUP BY opp_name
ORDER BY total DESC, w DESC
LIMIT 10''';

  static const _yearsSql = '''
SELECT substr(date, 1, 4) AS yr,
  SUM(CASE WHEN presult = 'win' THEN 1 ELSE 0 END) AS w,
  SUM(CASE WHEN presult = 'draw' THEN 1 ELSE 0 END) AS d,
  SUM(CASE WHEN presult = 'loss' THEN 1 ELSE 0 END) AS l,
  COUNT(*) AS total
FROM scoped
WHERE date IS NOT NULL AND length(date) >= 4
GROUP BY yr
ORDER BY yr ASC''';

  static const _lengthSql = '''
SELECT
  SUM(CASE WHEN ply BETWEEN 1 AND 40 THEN 1 ELSE 0 END) AS b1,
  SUM(CASE WHEN ply BETWEEN 41 AND 60 THEN 1 ELSE 0 END) AS b2,
  SUM(CASE WHEN ply BETWEEN 61 AND 80 THEN 1 ELSE 0 END) AS b3,
  SUM(CASE WHEN ply BETWEEN 81 AND 100 THEN 1 ELSE 0 END) AS b4,
  SUM(CASE WHEN ply > 100 THEN 1 ELSE 0 END) AS b5
FROM scoped
WHERE ply > 0''';

  static const _timeControlSql = '''
SELECT COALESCE(NULLIF(TRIM(tcc), ''), 'Unknown') AS cat, COUNT(*) AS c
FROM scoped
GROUP BY cat
ORDER BY c DESC''';

  static const _yearTimeControlSql = '''
SELECT substr(date, 1, 4) AS yr,
  COALESCE(NULLIF(TRIM(tcc), ''), 'Unknown') AS cat,
  COUNT(*) AS c
FROM scoped
WHERE date IS NOT NULL AND length(date) >= 4
GROUP BY yr, cat
ORDER BY yr ASC, c DESC''';

  /// Bucket PGN Site into known online origins for the year-chart hover card.
  static const _yearSourceSql = '''
SELECT substr(date, 1, 4) AS yr,
  CASE
    WHEN LOWER(TRIM(COALESCE(source, ''))) = 'chessever' THEN 'ChessEver'
    WHEN LOWER(TRIM(COALESCE(source, ''))) = 'lichess' THEN 'Lichess'
    WHEN LOWER(TRIM(COALESCE(source, ''))) = 'chesscom' THEN 'Chess.com'
    WHEN LOWER(TRIM(COALESCE(source, ''))) = 'manual' THEN 'Manual PGN'
    WHEN LOWER(COALESCE(site, '')) LIKE '%lichess%' THEN 'Lichess'
    WHEN LOWER(COALESCE(site, '')) LIKE '%chess.com%' THEN 'Chess.com'
    WHEN LOWER(COALESCE(site, '')) LIKE '%chess24%' THEN 'Chess24'
    WHEN LOWER(COALESCE(site, '')) LIKE '%chessbase%' THEN 'ChessBase'
    WHEN NULLIF(TRIM(site), '') IS NULL OR TRIM(site) = '?' THEN 'Unknown'
    ELSE 'Other'
  END AS src,
  COUNT(*) AS c
FROM scoped
WHERE date IS NOT NULL AND length(date) >= 4
GROUP BY yr, src
ORDER BY yr ASC, c DESC''';

  static const _auxSql = '''
SELECT AVG(CASE WHEN opp_elo > 0 THEN opp_elo END) AS avg_opp
FROM scoped''';
}

bool _isMeaningfulOpeningName(String? value) {
  final normalized = value?.trim().toLowerCase();
  return normalized != null &&
      normalized.isNotEmpty &&
      normalized != '?' &&
      normalized != '-' &&
      normalized != 'unknown' &&
      normalized != 'unknown opening';
}

/// Normalize a UI / source default TC into a canonical filter key.
String? _normalizeTimeControlFilter(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case '':
    case 'all':
      return null;
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
    default:
      final clean = raw!.trim().toLowerCase();
      return clean.isEmpty ? null : clean;
  }
}

String? _normalizeUnclassifiedTimeControlFallback(String? raw) {
  final normalized = _normalizeTimeControlFilter(raw);
  return switch (normalized) {
    'classical' ||
    'rapid' ||
    'blitz' ||
    'bullet' ||
    'ultrabullet' => normalized,
    _ => null,
  };
}

String? _normalizePlayerColorFilter(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'w':
    case 'white':
      return 'w';
    case 'b':
    case 'black':
      return 'b';
    default:
      return null;
  }
}

List<Object?> _timeControlFilterParams(String? normalized) {
  if (normalized == null) return const <Object?>[];
  return <Object?>[normalized];
}

/// Default overview time-control for a player source:
/// online (Lichess/Chess.com) → blitz; Combined / ChessEver / manual → classical.
String defaultPlayerStatsTimeControl({required bool isOnlineSource}) =>
    isOnlineSource ? 'blitz' : 'classical';

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

/// Normalization must match [PlayerStatsRepository._cte]'s SQL side so aliases
/// and stored names compare on equal footing.
String _normalizeName(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'[\s,._-]+'), '').trim();
}

String _normalizedNameSql(String expression) {
  var sql = 'LOWER(TRIM(COALESCE($expression, \'\')))';
  for (final token in const <String>[',', ' ', '_', '.', '-']) {
    sql = "REPLACE($sql, '$token', '')";
  }
  return sql;
}

String? _normalizeFideId(String? value) {
  final clean = value?.trim().toLowerCase();
  if (clean == null || clean.isEmpty) return null;
  return clean;
}

/// Mirrors `LocalChessDatabaseRepository`'s path→id normalization so a query
/// scopes to the exact `database_id` the import wrote.
String _databaseId(String path) {
  final normalized = p.normalize(path.trim());
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

DateTime? _dateFromDot(String? raw) {
  if (raw == null) return null;
  final parts = raw.split('.');
  if (parts.length < 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (year < 1500 || year > 3000) return null;
  return DateTime(year, month, day);
}

List<PlayerRatingSpot> _downsample(
  List<PlayerRatingSpot> spots,
  int maxPoints,
) {
  if (spots.length <= maxPoints) return spots;
  final step = spots.length / maxPoints;
  final out = <PlayerRatingSpot>[];
  for (var i = 0; i < maxPoints; i++) {
    out.add(spots[(i * step).floor()]);
  }
  // Always keep the final point so the latest rating is exact.
  if (out.last != spots.last) out.add(spots.last);
  return out;
}

/// FIDE-style performance rating: average opponent + a rating difference
/// derived from the score percentage.
int? _performanceRating(PlayerResultTally tally, int? averageOpponent) {
  if (averageOpponent == null || tally.games == 0) return null;
  final percent = (tally.score * 100).round().clamp(0, 100);
  return averageOpponent + _dpTable[percent];
}

int _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.round();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

int? _intOrNull(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.round();
  return int.tryParse(raw.toString());
}

/// FIDE "dp" rating-difference lookup indexed by score percentage (0..100).
const List<int> _dpTable = [
  -800,
  -677,
  -589,
  -538,
  -501,
  -470,
  -444,
  -422,
  -401,
  -383,
  -366,
  -351,
  -336,
  -322,
  -309,
  -296,
  -284,
  -273,
  -262,
  -251,
  -240,
  -230,
  -220,
  -211,
  -202,
  -193,
  -184,
  -175,
  -166,
  -158,
  -149,
  -141,
  -133,
  -125,
  -117,
  -110,
  -102,
  -95,
  -87,
  -80,
  -72,
  -65,
  -57,
  -50,
  -43,
  -36,
  -29,
  -21,
  -14,
  -7,
  0,
  7,
  14,
  21,
  29,
  36,
  43,
  50,
  57,
  65,
  72,
  80,
  87,
  95,
  102,
  110,
  117,
  125,
  133,
  141,
  149,
  158,
  166,
  175,
  184,
  193,
  202,
  211,
  220,
  230,
  240,
  251,
  262,
  273,
  284,
  296,
  309,
  322,
  336,
  351,
  366,
  383,
  401,
  422,
  444,
  470,
  501,
  538,
  589,
  677,
  800,
];
