import '../../screens/tour_detail/games_tour/models/games_tour_model.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter/foundation.dart';
import '../services/local_chess_pgn_fingerprint.dart';
import '../services/local_pgn_source.dart';
import '../services/local_pgn_position.dart';

import '../services/local_chess_database_repository.dart';
import '../services/local_chess_file_scanner.dart';
import '../services/local_chess_game_filter.dart';
import '../services/local_raw_pgn_catalog.dart';
import '../../widgets/game_filter/game_filter_model.dart';
import '../../utils/local_pgn_metadata.dart';
import 'tournament_games.dart';

/// A captured Library ordering, not the loaded/visible portion of its table.
/// Catalogs retain header records only; indexed sources retain the exact query.
/// Neither page reads nor serialization read or parse PGN movetext.
class LocalBoardGamesSource {
  LocalBoardGamesSource.catalog(List<LocalChessGame> games)
    : catalog = List.unmodifiable(games),
      path = games.first.sourcePath,
      totalCount = games.length,
      search = '',
      sortBy = LocalChessGameSortField.originalOrder,
      sortDirection = LocalChessGameSortDirection.asc,
      filter = LocalChessGameFilter(),
      rawPgnCatalog = null,
      playerFideId = null,
      playerAliases = const [],
      physicalOrder = null;

  LocalBoardGamesSource.query({
    required this.path,
    required this.totalCount,
    this.rawPgnCatalog,
    required this.search,
    required this.sortBy,
    required this.sortDirection,
    required this.filter,
    this.playerFideId,
    this.playerAliases = const [],
  }) : catalog = null,
       physicalOrder = null;

  LocalBoardGamesSource._restoredCatalog(this.path, this.physicalOrder)
    : totalCount = physicalOrder!.length,
      catalog = null,
      search = '',
      sortBy = LocalChessGameSortField.originalOrder,
      sortDirection = LocalChessGameSortDirection.asc,
      filter = LocalChessGameFilter(),
      rawPgnCatalog = null,
      playerFideId = null,
      playerAliases = const [];

  static const pageSize = 100;
  final String path;
  final int totalCount;
  final String search;
  final LocalChessGameSortField sortBy;
  final LocalChessGameSortDirection sortDirection;
  final LocalChessGameFilter filter;
  final LocalRawPgnCatalogDescriptor? rawPgnCatalog;
  final String? playerFideId;
  final List<String> playerAliases;
  final List<LocalChessGame>? catalog;
  final List<int>? physicalOrder;
  Future<List<LocalChessGame>>? _restoredCatalog;
  final _pages = <int, List<TournamentGameSummary>>{};
  final _inFlight = <int, Future<List<TournamentGameSummary>>>{};
  final _ranks = <String, int>{};
  final _pageRows = <int, List<LocalChessGame>>{};

  /// Raw catalogs have no fingerprint until a record is read. Acquire it for
  /// just the activated row through the scanner's verified-span/identity guard.
  /// The retained reader subsequently revalidates count and mainline identity.
  Future<TournamentGameSummary> prepareSelection(
    LocalChessDatabaseRepository repository,
    TournamentGameSummary game,
  ) async {
    if (game.localPgnSource?.pgnFingerprint.isNotEmpty == true) return game;
    final rank = rankOf(game.id);
    if (rank == null) {
      throw StateError('Reopen the database to refresh this game.');
    }
    final number = rank ~/ pageSize;
    await page(repository, number);
    final row = _pageRows[number]![rank % pageSize];
    if (row.id != game.id) throw StateError('The source ordering changed.');
    return compute(_prepareLocalBoardSelection, row);
  }

  int get lastPage => totalCount == 0 ? 0 : (totalCount - 1) ~/ pageSize;
  void rememberSelection(String id, int rank) => _ranks[id] = rank;
  int? rankOf(String id) => _ranks[id];
  List<TournamentGameSummary>? cachedPage(int page) => _pages[page];

  Future<List<TournamentGameSummary>> page(
    LocalChessDatabaseRepository repository,
    int number,
  ) async {
    if (number < 0 || number > lastPage) return const [];
    final cached = _pages.remove(number);
    if (cached != null) {
      _pages[number] = cached;
      return cached;
    }
    final pending = _inFlight[number];
    if (pending != null) return pending;
    final future = _loadPage(repository, number);
    _inFlight[number] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(number);
    }
  }

  Future<List<TournamentGameSummary>> _loadPage(
    LocalChessDatabaseRepository repository,
    int number,
  ) async {
    List<LocalChessGame>? rows = catalog;
    if (physicalOrder != null) {
      rows = await (_restoredCatalog ??= _restoreCatalog());
    }
    final start = number * pageSize;
    final end = (start + pageSize).clamp(0, totalCount);
    final List<LocalChessGame> pageRows;
    if (rows != null) {
      pageRows = rows.sublist(start, end);
    } else if (rawPgnCatalog != null) {
      final result = await _rawPgnCatalogPage(number);
      if (result == null ||
          result.totalCount != totalCount ||
          result.games.length != end - start) {
        throw StateError(
          'The database changed. Reopen it to refresh the game list.',
        );
      }
      pageRows = result.games;
    } else {
      final result = await repository.localDatabaseGamesPage(
        databasePath: path,
        search: search,
        sortBy: sortBy,
        sortDirection: sortDirection,
        filter: filter,
        playerFideId: playerFideId,
        playerAliases: playerAliases,
        pageNumber: number,
        pageSize: pageSize,
      );
      if (result == null ||
          result.totalCount != totalCount ||
          result.games.length != end - start) {
        throw StateError(
          'The database changed. Reopen it to refresh the game list.',
        );
      }
      pageRows = result.games;
    }
    final summaries = <TournamentGameSummary>[];
    for (var i = 0; i < pageRows.length; i++) {
      final row = pageRows[i];
      _ranks[row.id] = start + i;
      summaries.add(localBoardGameSummary(row));
    }
    final result = List<TournamentGameSummary>.unmodifiable(summaries);
    _pages[number] = result;
    _pageRows[number] = pageRows;
    while (_pages.length > 4) {
      final oldest = _pages.keys.first;
      _pages.remove(oldest);
      _pageRows.remove(oldest);
    }
    return result;
  }

  Future<LocalChessGameQueryPage?> _rawPgnCatalogPage(int number) async {
    final descriptor = rawPgnCatalog!;
    final current = await localRawPgnCatalogPage(
      LocalRawPgnCatalogPageQuery(
        descriptor: descriptor,
        search: search,
        sortBy: sortBy,
        sortDirection: sortDirection,
        filter: filter,
        playerFideId: playerFideId,
        playerAliases: playerAliases,
        pageNumber: number,
        pageSize: pageSize,
      ),
    );
    if (current != null) return current;
    final handle = await openLocalRawPgnCatalog(
      descriptor.path,
      sourceLabel: descriptor.label,
    );
    try {
      if (handle.descriptor.sessionId != descriptor.sessionId ||
          handle.descriptor.contentFingerprint != descriptor.contentFingerprint ||
          handle.descriptor.fullSha256 != descriptor.fullSha256 ||
          handle.descriptor.totalGames != descriptor.totalGames) {
        throw StateError('The database changed. Reopen it to refresh the game list.');
      }
      return await localRawPgnCatalogPage(
        LocalRawPgnCatalogPageQuery(
          descriptor: handle.descriptor,
          search: search,
          sortBy: sortBy,
          sortDirection: sortDirection,
          filter: filter,
          playerFideId: playerFideId,
          playerAliases: playerAliases,
          pageNumber: number,
          pageSize: pageSize,
        ),
      );
    } finally {
      handle.release();
    }
  }

  Future<List<LocalChessGame>> _restoreCatalog() async {
    final source = await scanLocalChessPgnCatalog(path, maxGames: 2147483647);
    final rows = source.root.files.single.games;
    final order = physicalOrder!;
    if (order.any((index) => index < 0 || index >= rows.length)) {
      throw StateError(
        'The database changed. Reopen it to refresh the game list.',
      );
    }
    return [for (final index in order) rows[index]];
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'totalCount': totalCount,
    if (rawPgnCatalog != null) 'rawPgnCatalog': rawPgnCatalog!.toJson(),
    if (catalog != null || physicalOrder != null)
      'physicalOrder':
          physicalOrder ?? [for (final row in catalog!) row.indexInFile],
    'search': search,
    'sortBy': sortBy.name,
    'sortDirection': sortDirection.name,
    'playerFideId': playerFideId,
    'playerAliases': playerAliases,
    'ranks': _ranks,
    'filter': {
      'result': filter.base.result.name,
      'finish': filter.base.finish.name,
      'color': filter.base.color.name,
      'timeControl': filter.base.timeControl.name,
      'online': filter.base.online.name,
      'live': filter.base.live.name,
      'eco': filter.base.eco.code,
      'minYear': filter.base.minYear,
      'maxYear': filter.base.maxYear,
      'minRating': filter.base.minRating,
      'maxRating': filter.base.maxRating,
      'outcome': filter.playerOutcome.name,
      'opponent': filter.opponentName,
      'category': filter.timeControlCategory,
    },
  };

  factory LocalBoardGamesSource.fromJson(Map<String, dynamic> json) {
    final order = json['physicalOrder'];
    final f = Map<String, dynamic>.from(json['filter'] as Map);
    final source =
        order is List
            ? LocalBoardGamesSource._restoredCatalog(
              json['path'] as String,
              order.cast<int>(),
            )
            : LocalBoardGamesSource.query(
              path: json['path'] as String,
              totalCount: json['totalCount'] as int,
              rawPgnCatalog:
                  json['rawPgnCatalog'] == null
                      ? null
                      : LocalRawPgnCatalogDescriptor.fromJson(
                        Map<String, dynamic>.from(
                          json['rawPgnCatalog'] as Map,
                        ),
                      ),
              search: json['search'] as String,
              sortBy: LocalChessGameSortField.values.byName(
                json['sortBy'] as String,
              ),
              sortDirection: LocalChessGameSortDirection.values.byName(
                json['sortDirection'] as String,
              ),
              playerFideId: json['playerFideId'] as String?,
              playerAliases: (json['playerAliases'] as List).cast<String>(),
              filter: LocalChessGameFilter(
                playerOutcome: LocalPlayerOutcomeFilter.values.byName(
                  f['outcome'] as String,
                ),
                opponentName: f['opponent'] as String?,
                timeControlCategory: f['category'] as String?,
                base: GameFilter(
                  result: GameResultFilter.values.byName(f['result'] as String),
                  finish: GameFinishFilter.values.byName(f['finish'] as String),
                  color: GameColorFilter.values.byName(f['color'] as String),
                  timeControl: GameTimeControlFilter.values.byName(
                    f['timeControl'] as String,
                  ),
                  online: GameOnlineFilter.values.byName(f['online'] as String),
                  live: GameLiveFilter.values.byName(f['live'] as String),
                  eco:
                      f['eco'] == null
                          ? GameEcoFilter.all
                          : GameEcoFilter.forCode(f['eco'] as String),
                  minYear: f['minYear'] as int,
                  maxYear: f['maxYear'] as int,
                  minRating: f['minRating'] as int,
                  maxRating: f['maxRating'] as int,
                ),
              ),
            );
    source._ranks.addAll(Map<String, int>.from(json['ranks'] as Map));
    return source;
  }
}

final localBoardGamesPageProvider = FutureProvider.autoDispose.family<
  List<TournamentGameSummary>,
  ({LocalBoardGamesSource source, int page})
>(
  (ref, key) =>
      key.source.page(ref.read(localChessDatabaseRepositoryProvider), key.page),
);

TournamentGameSummary _prepareLocalBoardSelection(LocalChessGame row) {
  final pgn = row.rawPgn;
  return localBoardGameSummary(row).copyWith(
    pgn: pgn,
    localPgnSource: TournamentGameLocalPgnSource(
      sourcePath: row.sourcePath,
      sourceIndex: row.indexInFile,
      sourceFileGameCount: row.fileGameCount,
      pgnFingerprint: localChessPgnFingerprint(pgn),
      recordRevision: localPgnRecordRevision(pgn),
      title: row.title,
    ),
  );
}

/// Headers plus physical identity. PGN is hydrated only on activation
/// by the existing retained-local-record reader, never while paging the rail.
TournamentGameSummary localBoardGameSummary(LocalChessGame row) {
  final md = row.game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fide(String key) => rating(key) > 0 ? rating(key) : null;
  return TournamentGameSummary(
    id: row.id,
    name: row.title,
    whitePlayer: s('White'),
    blackPlayer: s('Black'),
    whiteFederation: localPgnFederation(md, 'White'),
    blackFederation: localPgnFederation(md, 'Black'),
    whiteTitle: s('WhiteTitle'),
    blackTitle: s('BlackTitle'),
    whiteRating: rating('WhiteElo'),
    blackRating: rating('BlackElo'),
    whiteFideId: fide('WhiteFideId'),
    blackFideId: fide('BlackFideId'),
    hasPgn: row.hasMoves || localPgnHasValidSetupHeaders(md),
    hasStarted: row.hasMoves,
    roundLabel: s('Round'),
    openingName: s('Opening').isNotEmpty ? s('Opening') : s('ECO'),
    status: switch (s('Result').replaceAll('½', '1/2')) {
      '1-0' => GameStatus.whiteWins,
      '0-1' => GameStatus.blackWins,
      '1/2-1/2' => GameStatus.draw,
      '*' => GameStatus.ongoing,
      _ => GameStatus.unknown,
    },
    localPgnSource: TournamentGameLocalPgnSource(
      sourcePath: row.sourcePath,
      sourceIndex: row.indexInFile,
      sourceFileGameCount: row.fileGameCount,
      pgnFingerprint: row.pgnFingerprint,
      recordRevision: '',
      title: row.title,
    ),
  );
}
