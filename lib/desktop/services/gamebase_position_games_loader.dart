import 'package:chessever/desktop/services/local_chess_database_open_guard.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_opening_tree_filter_adapter.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/explorer_games_cache.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class DesktopPositionGamesPageResult {
  const DesktopPositionGamesPageResult({
    required this.response,
    required this.resolvedApi,
  });

  final GamebaseSearchQueryResponse response;
  final BoardTabPositionGamesApi? resolvedApi;
}

GamebasePositionGamesQuery gamebasePositionGamesQueryWithPage(
  GamebasePositionGamesQuery query,
  int pageNumber,
) => query.withPage(pageNumber);

/// A first page the explorer already holds for a desktop games table's query,
/// ready to paint in the frame the position lands.
@immutable
class DesktopHeldPositionGamesPage {
  const DesktopHeldPositionGamesPage({
    required this.response,
    required this.fetchedAt,
    required this.current,
    required this.source,
    required this.resolvedApi,
  });

  final GamebaseSearchQueryResponse response;

  /// When the request behind [response] was sent.
  final DateTime fetchedAt;

  /// A server answer from this session younger than [kExplorerGamesFreshFor]:
  /// shown as final, with no second request. Anything else is a saved copy
  /// that is shown and checked against the server.
  final bool current;

  /// [ExplorerGamesSource.memory] or [ExplorerGamesSource.disk].
  final ExplorerGamesSource source;

  /// The API the page came from, pinned for later pages exactly as a fetch
  /// would pin it. Null for the default (move-line) path.
  final BoardTabPositionGamesApi? resolvedApi;
}

/// Whether [fetchDesktopPositionGamesPage] would answer [query] from the
/// global database over the network, the only path the explorer games cache
/// covers. A local file tree, a downloaded player tree or a denied request
/// never touches it: those rows carry local PGN and source paths.
bool desktopPositionGamesUseNetwork(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  PlayerOpeningTreeIndex? localOpeningTreeIndex,
}) {
  if (localOpeningTreeIndex != null) return false;
  final playerId = query.playerId?.trim();
  if (playerId != null &&
      playerId.isNotEmpty &&
      ref
          .read(gamebaseExplorerProvider.notifier)
          .isLocalPlayerTreeEnabledFor(playerId)) {
    return false;
  }
  return true;
}

/// The indexed-position probe an exact-FEN table sends first.
GamebasePositionGamesQuery _indexedProbeQuery(
  GamebasePositionGamesQuery query,
) => GamebasePositionGamesQuery(
  fen: query.fen,
  uci: query.uci,
  timeControl: query.timeControl,
  playerId: query.playerId,
  color: query.color,
  result: query.result,
  isOnline: query.isOnline,
  minRating: query.minRating,
  maxRating: query.maxRating,
  yearFrom: query.yearFrom,
  yearTo: query.yearTo,
  sortBy: query.sortBy,
  sortDirection: query.sortDirection,
  pageNumber: query.pageNumber,
  pageSize: query.pageSize,
  notationPlies: query.notationPlies,
);

/// The `/fen/games` query an exact-FEN table falls back to.
GamebasePositionGamesQuery _exactFenQuery(GamebasePositionGamesQuery query) =>
    GamebasePositionGamesQuery(
      fen: query.fen,
      uci: query.uci,
      timeControl: query.timeControl,
      playerId: query.playerId,
      color: query.color,
      result: query.result,
      isOnline: query.isOnline,
      minRating: query.minRating,
      maxRating: query.maxRating,
      yearFrom: query.yearFrom,
      yearTo: query.yearTo,
      sortBy: query.sortBy,
      sortDirection: query.sortDirection,
      pageNumber: query.pageNumber,
      pageSize: query.pageSize,
      notationPlies: query.notationPlies,
      useFenEndpoint: true,
    );

/// The queries [fetchDesktopPositionGamesPage] may send for page 0 of
/// [query], first one first.
List<GamebasePositionGamesQuery> desktopPositionGamesWireQueries(
  GamebasePositionGamesQuery query, {
  required bool exactFenSearch,
}) {
  final page = query.withPage(0);
  if (!exactFenSearch) return <GamebasePositionGamesQuery>[page];
  return <GamebasePositionGamesQuery>[
    _indexedProbeQuery(page),
    _exactFenQuery(page),
  ];
}

/// Whether the request [fetchDesktopPositionGamesPage] would send first for
/// page 0 of [query] is already on the wire (a warm-up, another table), so a
/// table can attach to it now rather than after its navigation dwell.
bool isDesktopPositionGamesFirstPageInFlight(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  required bool exactFenSearch,
}) {
  final cache = ref.read(explorerGamesCacheProvider);
  return cache.isFetching(
    desktopPositionGamesWireQueries(
      query,
      exactFenSearch: exactFenSearch,
    ).first,
  );
}

/// The first page the explorer holds for [query] right now, from a settled
/// request or the in-memory cache (which disk reads also land in), or null.
///
/// An exact-FEN table pins the API a probe settles on: the indexed page when
/// it has games, otherwise `/fen/games`. A held answer is only returned when
/// every page that decision reads is held, and it is only current when all of
/// them are.
DesktopHeldPositionGamesPage? peekDesktopPositionGamesFirstPage(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  required bool exactFenSearch,
}) {
  final cache = ref.read(explorerGamesCacheProvider);
  final queries = desktopPositionGamesWireQueries(
    query,
    exactFenSearch: exactFenSearch,
  );
  final first = _heldPage(ref, cache, queries.first);
  if (first == null) return null;
  if (!exactFenSearch) {
    return DesktopHeldPositionGamesPage(
      response: first.response,
      fetchedAt: first.fetchedAt,
      current: first.current,
      source: first.source,
      resolvedApi: null,
    );
  }
  if (first.response.data.isNotEmpty || first.response.metadata.hasMore) {
    return DesktopHeldPositionGamesPage(
      response: first.response,
      fetchedAt: first.fetchedAt,
      current: first.current,
      source: first.source,
      resolvedApi: BoardTabPositionGamesApi.indexedPosition,
    );
  }
  final exact = _heldPage(ref, cache, queries.last);
  if (exact == null) return null;
  return DesktopHeldPositionGamesPage(
    response: exact.response,
    fetchedAt: exact.fetchedAt,
    current: first.current && exact.current,
    source:
        first.current && exact.current
            ? ExplorerGamesSource.memory
            : (exact.source == ExplorerGamesSource.disk ||
                    first.source == ExplorerGamesSource.disk
                ? ExplorerGamesSource.disk
                : ExplorerGamesSource.memory),
    resolvedApi: BoardTabPositionGamesApi.exactFen,
  );
}

/// Reads whatever the disk saved for page 0 of [query] into memory, then
/// answers like [peekDesktopPositionGamesFirstPage].
Future<DesktopHeldPositionGamesPage?> readDesktopPositionGamesSavedFirstPage(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  required bool exactFenSearch,
}) async {
  final cache = ref.read(explorerGamesCacheProvider);
  await cache.preload(
    desktopPositionGamesWireQueries(query, exactFenSearch: exactFenSearch),
  );
  return peekDesktopPositionGamesFirstPage(
    ref,
    query,
    exactFenSearch: exactFenSearch,
  );
}

({
  GamebaseSearchQueryResponse response,
  DateTime fetchedAt,
  bool current,
  ExplorerGamesSource source,
})?
_heldPage(
  WidgetRef ref,
  ExplorerGamesCache cache,
  GamebasePositionGamesQuery query,
) {
  final provider = positionGamesProvider(query);
  if (ref.exists(provider)) {
    final held = ref.read(provider);
    if (!held.isLoading && held.hasValue && !held.hasError) {
      final response = held.requireValue;
      final fetchedAt = cache.fetchedAtOf(response);
      if (fetchedAt != null && cache.isFresh(response)) {
        return (
          response: response,
          fetchedAt: fetchedAt,
          current: true,
          source: ExplorerGamesSource.memory,
        );
      }
    }
  }
  final snapshot = cache.peek(query);
  if (snapshot == null) return null;
  return (
    response: snapshot.response,
    fetchedAt: snapshot.fetchedAt,
    current: cache.isSnapshotFresh(snapshot),
    source: snapshot.source,
  );
}

/// Reads [query] through `positionGamesProvider`.
///
/// A page 0 held longer than [kExplorerGamesFreshFor] is asked for again
/// first: this read is what checks a saved copy on screen, so it must never
/// hand that same copy back as the answer. (The explorer's warm-ups keep the
/// pages they warmed alive for minutes, well past that.)
///
/// For a later page, a copy asked for before [notOlderThan] (the moment the
/// page 0 on screen was asked for) is asked for again, once, so its offsets
/// match that page 0: a page held from an earlier visit, or still on the
/// wire from before it, may sit on offsets that have moved since.
Future<GamebaseSearchQueryResponse> _readPositionGames(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  DateTime? notOlderThan,
}) async {
  final provider = positionGamesProvider(query);
  if (query.pageNumber == 0) {
    refreshExplorerGamesIfStale(ref, query);
    return ref.read(provider.future);
  }
  if (notOlderThan == null) return ref.read(provider.future);
  final cache = ref.read(explorerGamesCacheProvider);
  bool askedBefore(GamebaseSearchQueryResponse page) {
    final askedAt = cache.fetchedAtOf(page);
    return askedAt == null || askedAt.isBefore(notOlderThan);
  }

  if (ref.exists(provider)) {
    final held = ref.read(provider);
    if (!held.isLoading &&
        (held.hasError || (held.hasValue && askedBefore(held.requireValue)))) {
      ref.invalidate(provider);
    }
  }
  final response = await ref.read(provider.future);
  if (!askedBefore(response)) return response;
  ref.invalidate(provider);
  return ref.read(provider.future);
}

///
/// [notOlderThan] is when the page 0 already on screen was asked for: a later
/// page from the global database is only ever returned if it was asked for
/// at or after that moment (see [_readPositionGames]).
Future<DesktopPositionGamesPageResult> fetchDesktopPositionGamesPage(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  required bool exactFenSearch,
  BoardTabPositionGamesApi? resolvedApi,
  PlayerOpeningTreeIndex? localOpeningTreeIndex,
  DateTime? notOlderThan,
}) async {
  if (localOpeningTreeIndex != null) {
    final localDatabasePath = localOpeningTreeIndex.playerId?.trim();
    final localCriteria = _localTreeCriteriaFromQuery(
      query,
      filters: ref.read(gamebaseExplorerProvider).filters,
    );
    if (localOpeningTreeIndex.gamesByFen.isEmpty &&
        localDatabasePath != null &&
        localDatabasePath.isNotEmpty) {
      final GamebaseSearchQueryResponse? localResponse;
      try {
        localResponse = await ref
            .read(localChessDatabaseRepositoryProvider)
            .localPositionGamesResponse(
              databasePath: localDatabasePath,
              fen: query.fen,
              moves: query.moves,
              uci: query.uci,
              filters: localCriteria,
              sortBy: query.sortBy,
              sortDirection: query.sortDirection,
              pageNumber: query.pageNumber,
              pageSize: query.pageSize,
            );
      } on LocalChessDatabaseUnavailableException catch (error) {
        // The tree store is generated: name the user's own database instead of
        // `<name>.pgn.cetg`, keep the failure retryable (a build may still be
        // publishing the store) and let the panel recover in place rather than
        // dead-ending on a raw native string.
        throw error.withLabel(p.basename(localDatabasePath));
      }
      if (localResponse != null) {
        return DesktopPositionGamesPageResult(
          response: localResponse,
          resolvedApi: resolvedApi,
        );
      }
    }

    return DesktopPositionGamesPageResult(
      response: localPlayerTreeGamesResponse(
        index: localOpeningTreeIndex,
        fen: query.fen,
        uci: query.uci,
        filters: localCriteria,
        sortBy: query.sortBy,
        sortDirection: query.sortDirection,
        pageNumber: query.pageNumber,
        pageSize: query.pageSize,
      ),
      resolvedApi: resolvedApi,
    );
  }

  final playerId = query.playerId?.trim();
  if (playerId != null &&
      playerId.isNotEmpty &&
      ref
          .read(gamebaseExplorerProvider.notifier)
          .isLocalPlayerTreeEnabledFor(playerId)) {
    final localState = ref.read(playerOpeningTreeProvider(playerId));
    ref
        .read(playerOpeningTreeProvider(playerId).notifier)
        .requestGamesDownload();
    return DesktopPositionGamesPageResult(
      response: localPlayerTreeGamesResponse(
        index: localState.index,
        fen: query.fen,
        uci: query.uci,
        filters: _localTreeCriteriaFromQuery(
          query,
          filters: ref.read(gamebaseExplorerProvider).filters,
        ),
        sortBy: query.sortBy,
        sortDirection: query.sortDirection,
        pageNumber: query.pageNumber,
        pageSize: query.pageSize,
      ),
      resolvedApi: resolvedApi,
    );
  }

  if (!exactFenSearch) {
    final stopwatch = Stopwatch()..start();
    final response = await _readPositionGames(
      ref,
      query,
      notOlderThan: notOlderThan,
    );
    if (kDebugMode) {
      debugPrint(
        '[DesktopPositionGamesLoader] indexed default '
        '${stopwatch.elapsedMilliseconds}ms moves=${query.moves.length} '
        'page=${query.pageNumber} rows=${response.data.length}',
      );
    }
    return DesktopPositionGamesPageResult(
      response: response,
      resolvedApi: resolvedApi,
    );
  }

  if (resolvedApi == BoardTabPositionGamesApi.exactFen) {
    final stopwatch = Stopwatch()..start();
    final response = await _fetchExactFenPositionGames(
      ref,
      query,
      notOlderThan: notOlderThan,
    );
    if (kDebugMode) {
      debugPrint(
        '[DesktopPositionGamesLoader] exactFen pinned '
        '${stopwatch.elapsedMilliseconds}ms page=${query.pageNumber} '
        'rows=${response.data.length}',
      );
    }
    return DesktopPositionGamesPageResult(
      response: response,
      resolvedApi: BoardTabPositionGamesApi.exactFen,
    );
  }

  if (resolvedApi == BoardTabPositionGamesApi.indexedPosition) {
    final stopwatch = Stopwatch()..start();
    final response = await _fetchIndexedPositionGames(
      ref,
      query,
      notOlderThan: notOlderThan,
    );
    if (kDebugMode) {
      debugPrint(
        '[DesktopPositionGamesLoader] indexed pinned '
        '${stopwatch.elapsedMilliseconds}ms page=${query.pageNumber} '
        'rows=${response.data.length}',
      );
    }
    return DesktopPositionGamesPageResult(
      response: response,
      resolvedApi: BoardTabPositionGamesApi.indexedPosition,
    );
  }

  // Custom FENs may or may not be indexed by the fast position endpoint.
  // Probe that endpoint first, then pin the winning API for later pages so
  // pagination keeps returning rows from the same source.
  final indexedStopwatch = Stopwatch()..start();
  final indexed = await _fetchIndexedPositionGames(
    ref,
    query,
    notOlderThan: notOlderThan,
  );
  if (kDebugMode) {
    debugPrint(
      '[DesktopPositionGamesLoader] indexed probe '
      '${indexedStopwatch.elapsedMilliseconds}ms page=${query.pageNumber} '
      'rows=${indexed.data.length} hasMore=${indexed.metadata.hasMore}',
    );
  }
  if (indexed.data.isNotEmpty || indexed.metadata.hasMore) {
    return DesktopPositionGamesPageResult(
      response: indexed,
      resolvedApi: BoardTabPositionGamesApi.indexedPosition,
    );
  }

  final exactStopwatch = Stopwatch()..start();
  final exact = await _fetchExactFenPositionGames(
    ref,
    query,
    notOlderThan: notOlderThan,
  );
  if (kDebugMode) {
    debugPrint(
      '[DesktopPositionGamesLoader] exactFen fallback '
      '${exactStopwatch.elapsedMilliseconds}ms page=${query.pageNumber} '
      'rows=${exact.data.length}',
    );
  }
  return DesktopPositionGamesPageResult(
    response: exact,
    resolvedApi: BoardTabPositionGamesApi.exactFen,
  );
}

PlayerOpeningTreeFilterCriteria _localTreeCriteriaFromQuery(
  GamebasePositionGamesQuery query, {
  GamebaseFilters? filters,
}) {
  final sourceFilters =
      filters ??
      GamebaseFilters(
        playerIds: <String>[
          if (query.playerId?.trim().isNotEmpty == true) query.playerId!.trim(),
        ],
        timeControls: <TimeControl>[
          if (query.timeControl != null) query.timeControl!,
        ],
        minRating: query.minRating,
        maxRating: query.maxRating,
        playerColor: switch (query.color) {
          'white' => GamebasePlayerColor.white,
          'black' => GamebasePlayerColor.black,
          _ => null,
        },
        gameResult: switch (query.result) {
          'W' => GamebaseGameResult.whiteWins,
          'B' => GamebaseGameResult.blackWins,
          'D' => GamebaseGameResult.draw,
          _ => null,
        },
        isOnline: query.isOnline,
        yearFrom: query.yearFrom,
        yearTo: query.yearTo,
      );
  final identities = playerOpeningTreeCriteriaFromFilters(
    sourceFilters,
    subjectPlayerId: query.playerId,
  );
  return PlayerOpeningTreeFilterCriteria(
    playerId: identities.playerId,
    playerIds: identities.playerIds,
    playerFideIds: identities.playerFideIds,
    playerNames: identities.playerNames,
    opponentIds: identities.opponentIds,
    opponentFideIds: identities.opponentFideIds,
    opponentNames: identities.opponentNames,
    timeControl: query.timeControl,
    minRating: query.minRating,
    maxRating: query.maxRating,
    color: query.color,
    result: query.result,
    isOnline: query.isOnline,
    yearFrom: query.yearFrom,
    yearTo: query.yearTo,
  );
}

Future<GamebaseSearchQueryResponse> _fetchIndexedPositionGames(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  DateTime? notOlderThan,
}) {
  return _readPositionGames(
    ref,
    _indexedProbeQuery(query),
    notOlderThan: notOlderThan,
  );
}

Future<GamebaseSearchQueryResponse> _fetchExactFenPositionGames(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  DateTime? notOlderThan,
}) {
  return _readPositionGames(
    ref,
    _exactFenQuery(query),
    notOlderThan: notOlderThan,
  );
}

TournamentGameSummary gamebasePositionGameSummaryFromRow(
  Map<String, dynamic> row, {
  required String fallbackFen,
}) {
  final id = (row['id']?.toString().trim() ?? '');
  final white = (row['white']?.toString() ?? '').trim();
  final black = (row['black']?.toString() ?? '').trim();
  final name =
      white.isEmpty && black.isEmpty
          ? 'Game $id'
          : '${white.isEmpty ? 'White' : white} vs '
              '${black.isEmpty ? 'Black' : black}';
  final dateRaw = row['date']?.toString();
  final date = dateRaw == null ? null : DateTime.tryParse(dateRaw);
  final result = (row['result']?.toString() ?? '').trim();
  final fen =
      (row['fen']?.toString().trim().isNotEmpty == true)
          ? row['fen'].toString().trim()
          : fallbackFen;
  final pgn = (row['pgn']?.toString() ?? '').trim();
  final localPgnSource = _localPgnSourceFromPositionRow(row);

  return TournamentGameSummary(
    id: id,
    name: name,
    whitePlayer: white,
    blackPlayer: black,
    whiteFederation: (row['whiteFed']?.toString() ?? '').trim(),
    blackFederation: (row['blackFed']?.toString() ?? '').trim(),
    whiteTitle: (row['whiteTitle']?.toString() ?? '').trim(),
    blackTitle: (row['blackTitle']?.toString() ?? '').trim(),
    whiteRating: _readInt(row['whiteElo']),
    blackRating: _readInt(row['blackElo']),
    whiteFideId: _readNullableInt(row['whiteFideId']),
    blackFideId: _readNullableInt(row['blackFideId']),
    hasPgn: pgn.isNotEmpty,
    fen: fen.isEmpty ? null : fen,
    roundLabel: date == null ? '' : _formatYear(date),
    status: gamebaseStatusFromResult(result),
    openingName: gamebaseContinuationLabel(
      (row['opening']?.toString() ?? '').trim(),
      (row['variation']?.toString() ?? '').trim(),
      (row['eco']?.toString() ?? '').trim(),
    ),
    startsAt: date,
    hasStarted: true,
    pgn: pgn.isEmpty ? null : pgn,
    localPgnSource: localPgnSource,
  );
}

TournamentGameLocalPgnSource? _localPgnSourceFromPositionRow(
  Map<String, dynamic> row,
) {
  final sourcePath = (row['sourcePath']?.toString() ?? '').trim();
  final sourceIndex = _readNullableInt(row['indexInFile']);
  final sourceFileGameCount = _readNullableInt(row['fileGameCount']);
  if (sourcePath.isEmpty ||
      sourceIndex == null ||
      sourceIndex < 0 ||
      sourceFileGameCount == null ||
      sourceFileGameCount <= 0) {
    return null;
  }

  final white = (row['white']?.toString() ?? '').trim();
  final black = (row['black']?.toString() ?? '').trim();
  final event = (row['event']?.toString() ?? '').trim();
  final title =
      white.isNotEmpty || black.isNotEmpty
          ? '${white.isEmpty ? 'White' : white} vs ${black.isEmpty ? 'Black' : black}'
          : (event.isEmpty ? 'Local PGN game' : event);
  return TournamentGameLocalPgnSource(
    sourcePath: sourcePath,
    sourceIndex: sourceIndex,
    sourceFileGameCount: sourceFileGameCount,
    pgnFingerprint: (row['pgnHash']?.toString() ?? '').trim(),
    recordRevision:
        (row['pgn']?.toString().trim().isNotEmpty ?? false)
            ? localPgnRecordRevision(row['pgn'].toString())
            : '',
    title: title,
  );
}

GameStatus gamebaseStatusFromResult(String result) {
  final normalized =
      result
          .replaceAll('½', '1/2')
          .replaceAll(RegExp(r'[\u2010-\u2015\u2212]'), '-')
          .trim();
  switch (normalized) {
    case '1-0':
      return GameStatus.whiteWins;
    case '0-1':
      return GameStatus.blackWins;
    case '1/2-1/2':
      return GameStatus.draw;
    case '*':
      return GameStatus.ongoing;
    default:
      return GameStatus.unknown;
  }
}

String gamebaseContinuationLabel(String opening, String variation, String eco) {
  final hasOpening = opening.isNotEmpty;
  final hasVariation = variation.isNotEmpty;
  final hasEco = eco.isNotEmpty;
  if (!hasOpening && !hasVariation) return hasEco ? eco : '';
  final base = hasVariation ? '$opening: $variation' : opening;
  return hasEco ? '$base [$eco]' : base;
}

int _readInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _readNullableInt(dynamic value) {
  final parsed = _readInt(value);
  return parsed > 0 ? parsed : null;
}

final _yearFormat = DateFormat('yyyy');
String _formatYear(DateTime date) => _yearFormat.format(date);
