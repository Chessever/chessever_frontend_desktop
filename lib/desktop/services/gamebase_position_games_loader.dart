import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
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
) {
  return GamebasePositionGamesQuery(
    fen: query.fen,
    moves: List<String>.unmodifiable(query.moves),
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
    pageNumber: pageNumber,
    pageSize: query.pageSize,
    notationPlies: query.notationPlies,
  );
}

Future<DesktopPositionGamesPageResult> fetchDesktopPositionGamesPage(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  required bool exactFenSearch,
  BoardTabPositionGamesApi? resolvedApi,
}) async {
  final playerId = query.playerId?.trim();
  if (playerId != null &&
      playerId.isNotEmpty &&
      ref
          .read(gamebaseExplorerProvider.notifier)
          .isLocalPlayerTreeEnabledFor(playerId)) {
    final localState = ref.read(playerOpeningTreeProvider(playerId));
    ref.read(playerOpeningTreeProvider(playerId).notifier).start();
    return DesktopPositionGamesPageResult(
      response: localPlayerTreeGamesResponse(
        index: localState.index,
        fen: query.fen,
        uci: query.uci,
        filters: PlayerOpeningTreeFilterCriteria(
          playerId: playerId,
          timeControl: query.timeControl,
          minRating: query.minRating,
          maxRating: query.maxRating,
          color: query.color,
          result: query.result,
          isOnline: query.isOnline,
          yearFrom: query.yearFrom,
          yearTo: query.yearTo,
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
    final response = await ref.read(positionGamesProvider(query).future);
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
    final response = await _fetchExactFenPositionGames(ref, query);
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
      moves: const <String>[],
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
    moves: const <String>[],
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
  final exact = await _fetchExactFenPositionGames(ref, query);
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

Future<GamebaseSearchQueryResponse> _fetchIndexedPositionGames(
  WidgetRef ref,
  GamebasePositionGamesQuery query, {
  required List<String> moves,
}) {
  return ref.read(
    positionGamesProvider(
      GamebasePositionGamesQuery(
        fen: query.fen,
        moves: moves,
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
      ),
    ).future,
  );
}

Future<GamebaseSearchQueryResponse> _fetchExactFenPositionGames(
  WidgetRef ref,
  GamebasePositionGamesQuery query,
) {
  return ref
      .read(gamebaseRepositoryProvider)
      .getFenPositionGames(
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
    hasPgn: false,
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
  );
}

GameStatus gamebaseStatusFromResult(String result) {
  final normalized = result
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
