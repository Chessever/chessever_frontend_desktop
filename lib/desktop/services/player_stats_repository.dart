import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart'
    show LocalChessDatabaseRepository, LocalChessResqliteDatabase;
import 'package:chessever/desktop/services/local_chess_file_scanner.dart'
    show LocalChessGame;
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_pgn_catalog.dart';
import 'package:chessever/desktop/state/player_stats_provider.dart'
    show PlayerStatsOutcomeFilter;
import 'package:chessever/desktop/services/time_control_classifier.dart';
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
  Future<void> _statsComputationTail = Future<void>.value();

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
    OperationCancellationToken? cancellationToken,
  }) async {
    return _runStatsComputationQueued(
      cancellationToken,
      () => _computePlayerStatsUnlocked(
        databasePath: databasePath,
        aliases: aliases,
        playerFideId: playerFideId,
        windowDays: windowDays,
        timeControlCategory: timeControlCategory,
        preferredRatingTimeControl: preferredRatingTimeControl,
        unclassifiedTimeControlCategory: unclassifiedTimeControlCategory,
        playerOutcome: playerOutcome,
        playerColor: playerColor,
        cancellationToken: cancellationToken,
      ),
    );
  }

  Future<PlayerStatsSnapshot> _computePlayerStatsUnlocked({
    required String databasePath,
    required Iterable<String> aliases,
    String? playerFideId,
    int? windowDays,
    String? timeControlCategory,
    String? preferredRatingTimeControl,
    String? unclassifiedTimeControlCategory,
    PlayerStatsOutcomeFilter playerOutcome = PlayerStatsOutcomeFilter.all,
    String? playerColor,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    final normalizedFideId = _normalizeFideId(playerFideId);
    final normalizedAliases =
        aliases.map(_normalizeName).where((name) => name.isNotEmpty).toSet();

    final sourceFile = File(databasePath);
    if (p.extension(databasePath).toLowerCase() == '.pgn' &&
        await sourceFile.exists()) {
      final source = await PlayerPgnCatalog.instance.load(databasePath);
      cancellationToken?.throwIfCanceled();
      return _computePlayerStatsFromCatalog(
        source.games,
        normalizedAliases: normalizedAliases,
        normalizedFideId: normalizedFideId,
        windowDays: windowDays,
        timeControlCategory: timeControlCategory,
        preferredRatingTimeControl: preferredRatingTimeControl,
        unclassifiedTimeControlCategory: unclassifiedTimeControlCategory,
        playerOutcome: playerOutcome,
        playerColor: playerColor,
        cancellationToken: cancellationToken,
      );
    }

    final databaseId = _databaseId(databasePath);
    final db = await _database();
    cancellationToken?.throwIfCanceled();
    await _ensureLocalCache(
      databasePath: databasePath,
      databaseId: databaseId,
      cancellationToken: cancellationToken,
    );
    cancellationToken?.throwIfCanceled();

    final aliasSet = normalizedAliases.toSet();
    if (normalizedFideId == null) {
      // Fallback only for sources without a stable FIDE id. The workspace
      // database is built from one player's games, so the most frequent name
      // rescues spelling / word-order differences.
      final dominant = await _dominantPlayerName(db, databaseId);
      cancellationToken?.throwIfCanceled();
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
      timeControlCategory: tcFilter,
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
            '${_cte(aliasPlaceholders: List.filled(matchAliases.length, '?').join(', '), fideScoped: normalizedFideId != null, hasAliasFallback: hasAliasFallback, windowed: dateModifier != null, unclassifiedTimeControlCategory: unclassifiedTimeControl, playerOutcome: PlayerStatsOutcomeFilter.all, playerColor: null)}\n$_timeControlSql',
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
      cancellationToken?.throwIfCanceled();
      results.add(await _select(db, query.sql, query.parameters));
      cancellationToken?.throwIfCanceled();
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

  Future<PlayerStatsSnapshot> _computePlayerStatsFromCatalog(
    List<LocalChessGame> games, {
    required Set<String> normalizedAliases,
    required String? normalizedFideId,
    int? windowDays,
    String? timeControlCategory,
    String? preferredRatingTimeControl,
    String? unclassifiedTimeControlCategory,
    PlayerStatsOutcomeFilter playerOutcome = PlayerStatsOutcomeFilter.all,
    String? playerColor,
    OperationCancellationToken? cancellationToken,
  }) async {
    final fallbackTimeControl = _normalizeUnclassifiedTimeControlFallback(
      unclassifiedTimeControlCategory,
    );
    final direct = <_DirectPlayerGame>[];
    DateTime? newestDate;
    for (var i = 0; i < games.length; i++) {
      final game = _directPlayerGame(
        games[i],
        order: i,
        normalizedAliases: normalizedAliases,
        normalizedFideId: normalizedFideId,
        unclassifiedTimeControlCategory: fallbackTimeControl,
      );
      if (game != null) {
        direct.add(game);
        final date = game.date;
        if (date != null && (newestDate == null || date.isAfter(newestDate))) {
          newestDate = date;
        }
      }
      if (i > 0 && i % 2048 == 0) {
        cancellationToken?.throwIfCanceled();
        await Future<void>.delayed(Duration.zero);
      }
    }
    cancellationToken?.throwIfCanceled();
    if (direct.isEmpty) return PlayerStatsSnapshot.empty;

    final cutoff =
        windowDays != null && windowDays > 0 && newestDate != null
            ? newestDate.subtract(Duration(days: windowDays))
            : null;
    bool inWindow(_DirectPlayerGame game) {
      final date = game.date;
      return cutoff == null || (date != null && !date.isBefore(cutoff));
    }

    final normalizedTimeControl = _normalizeTimeControlFilter(
      timeControlCategory,
    );
    final normalizedColor = _normalizePlayerColorFilter(playerColor);
    final windowed = direct.where(inWindow).toList(growable: false);
    final scoped = <_DirectPlayerGame>[];
    for (var i = 0; i < windowed.length; i++) {
      final game = windowed[i];
      if (normalizedTimeControl != null &&
          game.timeControl != normalizedTimeControl) {
        continue;
      }
      if (normalizedColor != null && game.side != normalizedColor) continue;
      if (!_directOutcomeMatches(game.outcome, playerOutcome)) continue;
      scoped.add(game);
      if (i > 0 && i % 4096 == 0) {
        cancellationToken?.throwIfCanceled();
        await Future<void>.delayed(Duration.zero);
      }
    }
    cancellationToken?.throwIfCanceled();

    final white = _DirectTally();
    final black = _DirectTally();
    final openingGroups = <String, _DirectOpeningGroup>{};
    final opponentGroups = <String, _DirectOpponentGroup>{};
    final yearGroups = <int, _DirectYearGroup>{};
    final lengthCounts = List<int>.filled(5, 0);
    var opponentRatingTotal = 0;
    var opponentRatingCount = 0;
    for (var i = 0; i < scoped.length; i++) {
      final game = scoped[i];
      final tally = game.side == 'w' ? white : black;
      tally.add(game.outcome);

      if (game.eco.isNotEmpty && game.outcome != null) {
        openingGroups
            .putIfAbsent(
              game.eco,
              () => _DirectOpeningGroup(game.eco, game.opening),
            )
            .tally
            .add(game.outcome);
      }
      if (game.opponentName.isNotEmpty && game.opponentName != '?') {
        final group = opponentGroups.putIfAbsent(
          game.opponentName,
          () => _DirectOpponentGroup(game.opponentName),
        );
        group.tally.add(game.outcome);
        if (game.opponentElo > 0) {
          group.ratingTotal += game.opponentElo;
          group.ratingCount++;
          opponentRatingTotal += game.opponentElo;
          opponentRatingCount++;
        }
      } else if (game.opponentElo > 0) {
        opponentRatingTotal += game.opponentElo;
        opponentRatingCount++;
      }
      final year = game.date?.year;
      if (year != null) {
        final group = yearGroups.putIfAbsent(year, _DirectYearGroup.new);
        group.total++;
        group.tally.add(game.outcome);
        group.timeControls.update(
          game.timeControl ?? 'Unknown',
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        group.sources.update(
          game.source,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      final ply = game.plyCount;
      if (ply != null && ply > 0) {
        final bucket =
            ply <= 40
                ? 0
                : ply <= 60
                ? 1
                : ply <= 80
                ? 2
                : ply <= 100
                ? 3
                : 4;
        lengthCounts[bucket]++;
      }
      if (i > 0 && i % 4096 == 0) {
        cancellationToken?.throwIfCanceled();
        await Future<void>.delayed(Duration.zero);
      }
    }

    final overall = white.value + black.value;
    final rating = _directRatingSeries(
      scoped,
      scopedTimeControl: normalizedTimeControl,
      preferredTimeControl: _normalizeTimeControlFilter(
        preferredRatingTimeControl,
      ),
    );
    final openings = openingGroups.values
        .where((group) => group.tally.value.games > 0)
        .toList()
      ..sort((a, b) {
        final byGames = b.tally.value.games.compareTo(a.tally.value.games);
        return byGames != 0 ? byGames : a.eco.compareTo(b.eco);
      });
    final opponents = opponentGroups.values
        .where((group) => group.tally.value.games > 0)
        .toList()
      ..sort((a, b) {
        final byGames = b.tally.value.games.compareTo(a.tally.value.games);
        if (byGames != 0) return byGames;
        return b.tally.wins.compareTo(a.tally.wins);
      });
    final years = yearGroups.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final timeControlCounts = <String, int>{};
    for (final game in windowed) {
      timeControlCounts.update(
        game.timeControl ?? 'Unknown',
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final timeControls = timeControlCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final averageOpponent =
        opponentRatingCount == 0
            ? null
            : (opponentRatingTotal / opponentRatingCount).round();
    const lengthLabels = <String>['0–20', '21–30', '31–40', '41–50', '50+'];
    final peak =
        rating.spots.isEmpty
            ? null
            : rating.spots.map((spot) => spot.rating).reduce(math.max);

    return PlayerStatsSnapshot(
      overall: overall,
      asWhite: white.value,
      asBlack: black.value,
      ratingSeries: rating.spots,
      openings: <PlayerOpeningStat>[
        for (final group in openings.take(10))
          PlayerOpeningStat(
            eco: group.eco,
            name:
                _isMeaningfulOpeningName(group.name)
                    ? group.name
                    : EcoOpenings.getOpeningName(group.eco),
            tally: group.tally.value,
          ),
      ],
      opponents: <PlayerOpponentStat>[
        for (final group in opponents.take(10))
          PlayerOpponentStat(
            name: group.name,
            tally: group.tally.value,
            averageRating:
                group.ratingCount == 0
                    ? null
                    : (group.ratingTotal / group.ratingCount).round(),
          ),
      ],
      years: <PlayerYearStat>[
        for (final entry in years)
          PlayerYearStat(
            year: entry.key,
            tally: entry.value.tally.value,
            total: entry.value.total,
            timeControls: <PlayerTimeControlStat>[
              for (final tc in (entry.value.timeControls.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value))))
                PlayerTimeControlStat(category: tc.key, count: tc.value),
            ],
            sources: <PlayerSourceStat>[
              for (final source in (entry.value.sources.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value))))
                PlayerSourceStat(label: source.key, count: source.value),
            ],
          ),
      ],
      lengthBuckets: <PlayerLengthBucket>[
        for (var i = 0; i < lengthLabels.length; i++)
          PlayerLengthBucket(label: lengthLabels[i], count: lengthCounts[i]),
      ],
      timeControls: <PlayerTimeControlStat>[
        for (final entry in timeControls)
          PlayerTimeControlStat(category: entry.key, count: entry.value),
      ],
      ratingTimeControlCategory: rating.timeControlCategory,
      peakRating: peak,
      latestRating: rating.spots.isEmpty ? null : rating.spots.last.rating,
      averageOpponentRating: averageOpponent,
      performanceRating: _performanceRating(overall, averageOpponent),
    );
  }

  /// resqlite 0.7 lets a dispatched read finish; it does not expose a safe
  /// per-query interrupt. Keep one Players stats computation active per
  /// repository so a source switch waits for the obsolete read to finish
  /// instead of saturating another reader in parallel. Cancellation checks
  /// then discard the obsolete request before it can dispatch its next query.
  Future<T> _runStatsComputationQueued<T>(
    OperationCancellationToken? cancellationToken,
    Future<T> Function() operation,
  ) async {
    final release = await _enterStatsComputationQueue(cancellationToken);
    try {
      return await operation();
    } finally {
      release();
    }
  }

  Future<void Function()> _enterStatsComputationQueue(
    OperationCancellationToken? cancellationToken,
  ) async {
    final previous = _statsComputationTail;
    final released = Completer<void>();
    _statsComputationTail = released.future;
    var didRelease = false;

    void release() {
      if (didRelease) return;
      didRelease = true;
      released.complete();
    }

    try {
      await previous;
      cancellationToken?.throwIfCanceled();
      return release;
    } catch (_) {
      release();
      rethrow;
    }
  }

  Future<void> _ensureLocalCache({
    required String databasePath,
    required String databaseId,
    OperationCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCanceled();
    final file = File(databasePath);
    if (!await file.exists()) return;

    final db = await _database();
    cancellationToken?.throwIfCanceled();
    final rows = await db.select(
      '''
      SELECT
        d.game_count AS game_count,
        d.deleted_at_ms AS deleted_at_ms,
        COUNT(g.rowid) AS row_count
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
    await repository.importSingleFileSource(
      path: databasePath,
      cancellationToken: cancellationToken,
    );
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
    String? timeControlCategory,
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
    // Keep the filter on the stored column so SQLite can use the full
    // (database_id, time_control_category) index. Imports/backfills canonicalize
    // categories; the small legacy aliases stay in the indexed IN list.
    final storedTimeControlValues = switch (timeControlCategory) {
      'classical' => const <String>['standard'],
      'ultrabullet' => const <String>[
        'ultra bullet',
        'ultra_bullet',
        'ultra-bullet',
      ],
      _ => const <String>[],
    };
    final includeUnclassified =
        timeControlCategory != null &&
        unclassifiedTimeControlCategory == timeControlCategory;
    final tcClause =
        timeControlCategory == null
            ? ''
            : '''
    AND (
      g.time_control_category IN (
        ?
        ${storedTimeControlValues.map((value) => ", '$value'").join()}
        ${includeUnclassified ? ", '', 'unknown', 'unclassified'" : ''}
      )
      ${includeUnclassified ? 'OR g.time_control_category IS NULL' : ''}
    )''';
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
    g.rowid AS game_row_id,
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
    side, game_row_id, eco, date, ply, tcc, opening, site, source,
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
, rating_daily AS (
  SELECT date AS d, my_elo AS elo,
    CASE LOWER(TRIM(COALESCE(tcc, '')))
      WHEN 'standard' THEN 'classical'
      ELSE LOWER(TRIM(COALESCE(tcc, '')))
    END AS tc,
    ROW_NUMBER() OVER (
      PARTITION BY date
      ORDER BY game_row_id DESC
    ) AS day_rank
  FROM scoped
  WHERE my_elo IS NOT NULL AND my_elo > 0
    AND date IS NOT NULL AND date LIKE '____.__.__'
)
SELECT d, elo, tc
FROM rating_daily
WHERE day_rank = 1
ORDER BY d ASC''';

  /// Rating series for "All" — prefer the bound ladder (`?`), then the most
  /// common rated classical/rapid/blitz series. If the chosen ladder would
  /// start after older Elo-tagged games, return the full rated history instead.
  static String _ratingSqlPreferred(String preferredTc) {
    assert(preferredTc.isNotEmpty);
    return '''
, rating_all AS (
  SELECT date AS d, game_row_id, my_elo AS elo,
      CASE LOWER(TRIM(COALESCE(tcc, '')))
        WHEN 'standard' THEN 'classical'
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
),
rating_filtered AS (
  SELECT d, game_row_id, elo,
    CASE
      WHEN (SELECT bucket_only FROM rating_scope) = 1 THEN tc
      ELSE NULL
    END AS tc
  FROM rating_all
  WHERE (SELECT bucket_only FROM rating_scope) = 0
    OR tc = (SELECT tc FROM rating_scope)
),
rating_daily AS (
  SELECT d, elo, tc,
    ROW_NUMBER() OVER (
      PARTITION BY d
      ORDER BY game_row_id DESC
    ) AS day_rank
  FROM rating_filtered
)
SELECT d, elo, tc
FROM rating_daily
WHERE day_rank = 1
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

class _DirectPlayerGame {
  const _DirectPlayerGame({
    required this.side,
    required this.outcome,
    required this.date,
    required this.myElo,
    required this.opponentName,
    required this.opponentElo,
    required this.eco,
    required this.opening,
    required this.timeControl,
    required this.source,
    required this.plyCount,
    required this.order,
  });

  final String side;
  final String? outcome;
  final DateTime? date;
  final int myElo;
  final String opponentName;
  final int opponentElo;
  final String eco;
  final String? opening;
  final String? timeControl;
  final String source;
  final int? plyCount;
  final int order;
}

class _DirectTally {
  int wins = 0;
  int draws = 0;
  int losses = 0;

  void add(String? outcome) {
    switch (outcome) {
      case 'win':
        wins++;
      case 'draw':
        draws++;
      case 'loss':
        losses++;
    }
  }

  PlayerResultTally get value =>
      PlayerResultTally(wins: wins, draws: draws, losses: losses);
}

class _DirectOpeningGroup {
  _DirectOpeningGroup(this.eco, this.name);

  final String eco;
  final String? name;
  final _DirectTally tally = _DirectTally();
}

class _DirectOpponentGroup {
  _DirectOpponentGroup(this.name);

  final String name;
  final _DirectTally tally = _DirectTally();
  int ratingTotal = 0;
  int ratingCount = 0;
}

class _DirectYearGroup {
  final _DirectTally tally = _DirectTally();
  final Map<String, int> timeControls = <String, int>{};
  final Map<String, int> sources = <String, int>{};
  int total = 0;
}

_DirectPlayerGame? _directPlayerGame(
  LocalChessGame localGame, {
  required int order,
  required Set<String> normalizedAliases,
  required String? normalizedFideId,
  required String? unclassifiedTimeControlCategory,
}) {
  final metadata = localGame.game.metadata;
  String header(String key) => metadata[key]?.toString().trim() ?? '';
  int number(String key) => int.tryParse(header(key)) ?? 0;

  final white = header('White');
  final black = header('Black');
  final whiteFideId = _normalizeFideId(
    header('WhiteFideId').isNotEmpty
        ? header('WhiteFideId')
        : header('WhiteFideID'),
  );
  final blackFideId = _normalizeFideId(
    header('BlackFideId').isNotEmpty
        ? header('BlackFideId')
        : header('BlackFideID'),
  );
  String? side;
  if (normalizedFideId != null) {
    if (whiteFideId == normalizedFideId) {
      side = 'w';
    } else if (blackFideId == normalizedFideId) {
      side = 'b';
    } else if (whiteFideId == null &&
        normalizedAliases.contains(_normalizeName(white))) {
      side = 'w';
    } else if (blackFideId == null &&
        normalizedAliases.contains(_normalizeName(black))) {
      side = 'b';
    }
  } else if (normalizedAliases.contains(_normalizeName(white))) {
    side = 'w';
  } else if (normalizedAliases.contains(_normalizeName(black))) {
    side = 'b';
  }
  if (side == null) return null;

  final result = header('Result');
  final event = header('Event');
  final site = header('Site');
  final source = header('ChessEverSource');
  final storedTimeControl = _normalizeTimeControlFilter(
    header('ChessEverTimeControlCategory'),
  );
  final classifiedTimeControl = classifyTimeControlCategory(
    header('TimeControl'),
    event: event,
    site: site,
    source: source,
  );
  final timeControl =
      storedTimeControl ??
      _normalizeTimeControlFilter(classifiedTimeControl) ??
      unclassifiedTimeControlCategory;
  final plyCount = number('PlyCount');

  return _DirectPlayerGame(
    side: side,
    outcome: _directPlayerOutcome(result, side),
    date: _dateFromDot(header('Date')),
    myElo: side == 'w' ? number('WhiteElo') : number('BlackElo'),
    opponentName: side == 'w' ? black : white,
    opponentElo: side == 'w' ? number('BlackElo') : number('WhiteElo'),
    eco: header('ECO').toUpperCase(),
    opening: header('Opening'),
    timeControl: timeControl,
    source: _directSourceLabel(source: source, site: site),
    plyCount: plyCount > 0 ? plyCount : null,
    order: order,
  );
}

String? _directPlayerOutcome(String result, String side) {
  final normalized = result.trim().toLowerCase();
  if (normalized == '1/2-1/2' ||
      normalized == '1/2' ||
      normalized == '0.5-0.5' ||
      normalized == '½-½') {
    return 'draw';
  }
  if (normalized == '1-0') return side == 'w' ? 'win' : 'loss';
  if (normalized == '0-1') return side == 'b' ? 'win' : 'loss';
  return null;
}

bool _directOutcomeMatches(
  String? outcome,
  PlayerStatsOutcomeFilter filter,
) {
  return switch (filter) {
    PlayerStatsOutcomeFilter.all => true,
    PlayerStatsOutcomeFilter.win => outcome == 'win',
    PlayerStatsOutcomeFilter.draw => outcome == 'draw',
    PlayerStatsOutcomeFilter.loss => outcome == 'loss',
  };
}

String _directSourceLabel({required String source, required String site}) {
  switch (source.trim().toLowerCase()) {
    case 'chessever':
      return 'ChessEver';
    case 'lichess':
      return 'Lichess';
    case 'chesscom':
      return 'Chess.com';
    case 'manual':
      return 'Manual PGN';
  }
  final normalizedSite = site.trim().toLowerCase();
  if (normalizedSite.contains('lichess')) return 'Lichess';
  if (normalizedSite.contains('chess.com')) return 'Chess.com';
  if (normalizedSite.contains('chess24')) return 'Chess24';
  if (normalizedSite.contains('chessbase')) return 'ChessBase';
  if (normalizedSite.isEmpty || normalizedSite == '?') return 'Unknown';
  return 'Other';
}

({List<PlayerRatingSpot> spots, String? timeControlCategory})
_directRatingSeries(
  List<_DirectPlayerGame> scoped, {
  required String? scopedTimeControl,
  required String? preferredTimeControl,
}) {
  final rated = scoped
      .where((game) => game.date != null && game.myElo > 0)
      .toList(growable: false);
  if (rated.isEmpty) {
    return (spots: const <PlayerRatingSpot>[], timeControlCategory: null);
  }

  var candidates = rated;
  String? selectedCategory;
  if (scopedTimeControl != null) {
    selectedCategory = scopedTimeControl;
  } else {
    final preferred = preferredTimeControl ?? 'classical';
    const categoryOrder = <String>['classical', 'rapid', 'blitz'];
    final counts = <String, int>{};
    for (final game in rated) {
      final tc = game.timeControl;
      if (tc != null && categoryOrder.contains(tc)) {
        counts.update(tc, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    if (counts.containsKey(preferred)) {
      selectedCategory = preferred;
    } else if (counts.isNotEmpty) {
      selectedCategory = categoryOrder
          .where(counts.containsKey)
          .reduce((a, b) => counts[a]! >= counts[b]! ? a : b);
    }
    if (selectedCategory != null) {
      final selected = rated
          .where((game) => game.timeControl == selectedCategory)
          .toList(growable: false);
      final useFullHistory =
          preferred == 'classical' &&
          selected.isNotEmpty &&
          rated
              .map((game) => game.date!)
              .reduce((a, b) => a.isBefore(b) ? a : b)
              .isBefore(
                selected
                    .map((game) => game.date!)
                    .reduce((a, b) => a.isBefore(b) ? a : b),
              );
      if (useFullHistory) {
        selectedCategory = null;
      } else {
        candidates = selected;
      }
    }
  }

  final byDay = <String, _DirectPlayerGame>{};
  for (final game in candidates) {
    final date = game.date!;
    final key =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final existing = byDay[key];
    if (existing == null || game.order >= existing.order) byDay[key] = game;
  }
  final spots = byDay.values
      .map((game) => PlayerRatingSpot(date: game.date!, rating: game.myElo))
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  return (
    spots: _downsample(spots, 400),
    timeControlCategory: selectedCategory,
  );
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
