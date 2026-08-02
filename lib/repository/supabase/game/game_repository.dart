// repositories/game_repository.dart
import 'dart:convert';

import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/base_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final gameRepositoryProvider = AutoDisposeProvider<GameRepository>((ref) {
  return GameRepository();
});

/// Chess title prefixes that may appear before player names
const _chessTitlePrefixes = [
  'GM ',
  'IM ',
  'FM ',
  'CM ',
  'NM ',
  'WGM ',
  'WIM ',
  'WFM ',
  'WCM ',
  'WNM ',
];

/// Strips chess title prefix from a player name if present.
/// e.g., "GM Nakamura, Hikaru" -> "Nakamura, Hikaru"
String _stripTitlePrefix(String playerName) {
  final trimmed = playerName.trim();
  for (final prefix in _chessTitlePrefixes) {
    if (trimmed.startsWith(prefix)) {
      return trimmed.substring(prefix.length).trim();
    }
  }
  return trimmed;
}

int? _parseRpcInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _tryParseRepositoryDateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value.trim());
  }
  return null;
}

const String _gameSummarySelectColumns = '''
          id,
          round_id,
          round_slug,
          tour_id,
          tour_slug,
          name,
          fen,
          players,
          last_move,
          think_time,
          status,
          search,
          lichess_id,
          player_white,
          player_black,
          date_start,
          round_schedule:rounds!games_round_id_fkey(name,starts_at),
          time_start,
          board_nr,
          last_move_time,
          game_day,
          last_clock_white,
          last_clock_black,
          eco,
          opening_name,
          tours!games_tour_id_fkey(
            name,
            avg_elo,
            tc:info->>tc,
            group_broadcasts!tours_group_broadcast_id_fkey(
              name,
              max_avg_elo,
              time_control
            )
          )
        ''';

const String _gameListSelectColumns = '''
          $_gameSummarySelectColumns,
          pgn
        ''';

/// Board-rail rows intentionally omit PGN, search, and clocks. The focused
/// game owns PGN hydration and its single-game stream; the rail only needs
/// stable display metadata and the latest FEN/status.
const String _eventRailGameSelectColumns = '''
          id,
          round_id,
          round_slug,
          tour_id,
          tour_slug,
          name,
          fen,
          players,
          last_move,
          status,
          date_start,
          round_schedule:rounds!games_round_id_fkey(name,starts_at),
          board_nr,
          last_move_time,
          game_day,
          eco,
          opening_name
        ''';

@visibleForTesting
String get eventRailGameSelectColumnsForTesting => _eventRailGameSelectColumns;

@visibleForTesting
const List<String> eventRailTourOrderColumnsForTesting = <String>[
  'round_id',
  'board_nr',
  'id',
];

@visibleForTesting
const List<String> eventRailRoundOrderColumnsForTesting = <String>[
  'board_nr',
  'id',
];

@visibleForTesting
({int from, int to}) eventRailPageRangeForTesting({
  required int limit,
  required int offset,
}) {
  if (limit <= 0) throw ArgumentError.value(limit, 'limit');
  if (offset < 0) throw ArgumentError.value(offset, 'offset');
  return (from: offset, to: offset + limit - 1);
}

const List<String> _classicalTimeControlValues = [
  'standard',
  'classical',
  'Standard',
  'Classical',
];

@immutable
class EventRailRoundMetadata {
  const EventRailRoundMetadata({
    required this.id,
    required this.name,
    required this.startsAt,
    required this.createdAt,
  });

  final String id;
  final String name;

  /// Scheduled start. A round is treated as started once this is in the past;
  /// `rounds` carries no live/ongoing flag, so live status is derived from game
  /// rows and the live-round signal rather than from this catalog.
  final DateTime? startsAt;
  final DateTime? createdAt;
}

const int _currentSmartGamesPageSize = 1000;
const Duration _currentSmartLiveMaxAge = Duration(hours: 8);
const Duration _currentSmartEventScopeCacheTtl = Duration(minutes: 1);

/// One whole day of a smart collection.
///
/// Smart collections paginate by day, never inside one: a day is either fully
/// loaded or not loaded at all, so [games] is every in-scope game on [day].
class CurrentSmartEventDayPage {
  const CurrentSmartEventDayPage({
    required this.day,
    required this.games,
    required this.nextDay,
  });

  final DateTime day;
  final List<Games> games;

  /// Next older day that holds in-scope games, or null when [day] is the last.
  final DateTime? nextDay;

  bool get hasMore => nextDay != null;
}

/// `game_day` is a `date` column and is the day key the UI groups on, so it is
/// the pagination cursor. Formats it the way PostgREST compares dates.
String formatSmartEventDay(DateTime day) {
  return '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}

class _CurrentSmartEventScopeCache {
  const _CurrentSmartEventScopeCache({
    required this.tourIds,
    required this.expiresAt,
  });

  final List<String> tourIds;
  final DateTime expiresAt;
}

int gameStructuredAverageRating(Games game) {
  final players = game.players;
  if (players == null || players.length < 2) return 0;

  final whiteElo = players.first.rating;
  final blackElo = players[1].rating;
  if (whiteElo <= 0 || blackElo <= 0) return 0;
  return (whiteElo + blackElo) ~/ 2;
}

class GameRepository extends BaseRepository {
  final Map<String, _CurrentSmartEventScopeCache> _currentSmartEventScopeCache =
      <String, _CurrentSmartEventScopeCache>{};

  List<int> _parseFideIds(List<String> fideIds) {
    return fideIds.map((id) => int.tryParse(id)).whereType<int>().toList();
  }

  int? _parseFideId(String fideId) => int.tryParse(fideId);

  String _normalizeCountryCode(String countryCode) {
    return countryCode.trim().toUpperCase();
  }

  // Fetch games by round ID
  Future<List<Games>> getGamesByRoundId(String roundId) async {
    return handleApiCall(() async {
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .eq('round_id', roundId)
          .order('id', ascending: true);

      final games =
          (response as List).map((json) => Games.fromJson(json)).toList();
      return _deduplicateGames(games);
    });
  }

  // Fetch games by tour ID
  Future<List<Games>> getGamesByTourId(
    String tourId, {
    int? limit,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      var query = supabase
          .from('games')
          // Tournament cards render from FEN/player/status metadata. Loading
          // every full PGN here makes large and live events wait on a much
          // larger payload; the selected game is hydrated on demand before
          // the board tab opens.
          .select(_gameSummarySelectColumns)
          .eq('tour_id', tourId)
          .order('id', ascending: true);

      if (limit != null) {
        query = query.range(offset, offset + limit - 1);
      }

      final response = await query;

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      return games;
    });
  }

  Future<List<Games>> getEventRailGamesByTourId(
    String tourId, {
    required int limit,
    required int offset,
  }) async {
    final range = eventRailPageRangeForTesting(limit: limit, offset: offset);
    return handleApiCall(() async {
      final response = await supabase
          .from('games')
          .select(_eventRailGameSelectColumns)
          .eq('tour_id', tourId)
          .order('round_id', ascending: true)
          .order('board_nr', ascending: true, nullsFirst: false)
          .order('id', ascending: true)
          .range(range.from, range.to);
      final jsonList = (response as List)
          .map((item) => json.encode(item))
          .toList(growable: false);
      return compute(_decodeGamesInIsolate, jsonList);
    });
  }

  Future<List<Games>> getEventRailGamesByRoundId(
    String roundId, {
    required int limit,
    required int offset,
  }) async {
    final range = eventRailPageRangeForTesting(limit: limit, offset: offset);
    return handleApiCall(() async {
      final response = await supabase
          .from('games')
          .select(_eventRailGameSelectColumns)
          .eq('round_id', roundId)
          .order('board_nr', ascending: true, nullsFirst: false)
          .order('id', ascending: true)
          .range(range.from, range.to);
      final jsonList = (response as List)
          .map((item) => json.encode(item))
          .toList(growable: false);
      return compute(_decodeGamesInIsolate, jsonList);
    });
  }

  /// Returns the selected row's zero-based index in the event rail's exact
  /// round ordering (`board_nr ASC NULLS LAST, id ASC`).
  ///
  /// Board numbers are presentation metadata, not ranks: team events can
  /// repeat them, feeds can leave gaps, and some rows have no number. Two
  /// small count queries locate the selected id without downloading or
  /// retaining every preceding game in a large round.
  Future<int> countEventRailGamesBeforeSelectedInRound({
    required String roundId,
    required String selectedGameId,
    required int? selectedBoardNumber,
  }) {
    return handleApiCall(() async {
      final counts =
          selectedBoardNumber == null
              ? await Future.wait<int>(<Future<int>>[
                supabase
                    .from('games')
                    .count()
                    .eq('round_id', roundId)
                    .not('board_nr', 'is', null),
                supabase
                    .from('games')
                    .count()
                    .eq('round_id', roundId)
                    .isFilter('board_nr', null)
                    .lt('id', selectedGameId),
              ])
              : await Future.wait<int>(<Future<int>>[
                supabase
                    .from('games')
                    .count()
                    .eq('round_id', roundId)
                    .lt('board_nr', selectedBoardNumber),
                supabase
                    .from('games')
                    .count()
                    .eq('round_id', roundId)
                    .eq('board_nr', selectedBoardNumber)
                    .lt('id', selectedGameId),
              ]);
      return counts[0] + counts[1];
    });
  }

  /// Loads only the round catalog needed to resolve cross-round navigation.
  /// This stays O(round count), not O(game count), for very large broadcasts.
  Future<List<EventRailRoundMetadata>> getEventRailRoundsByTourId(
    String tourId,
  ) {
    return handleApiCall(() async {
      // `rounds` has no `ongoing` column. Selecting it made PostgREST answer
      // 400 (`column rounds.ongoing does not exist`), so this catalog always
      // threw and the rail lost every authoritative round heading.
      final response = await supabase
          .from('rounds')
          .select('id,name,starts_at,created_at')
          .eq('tour_id', tourId)
          .order('created_at', ascending: true);
      return <EventRailRoundMetadata>[
        for (final raw in response as List)
          if (raw is Map)
            EventRailRoundMetadata(
              id: raw['id']?.toString() ?? '',
              name: raw['name']?.toString() ?? '',
              startsAt: _tryParseRepositoryDateTime(raw['starts_at']),
              createdAt: _tryParseRepositoryDateTime(raw['created_at']),
            ),
      ];
    });
  }

  Future<int> countEventRailGamesByRoundIds(List<String> roundIds) {
    final ids = roundIds.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (ids.isEmpty) return Future<int>.value(0);
    return handleApiCall(
      () => supabase.from('games').count().inFilter('round_id', ids),
    );
  }

  Future<List<Games>> getEventRailGamesByRoundIds(
    List<String> roundIds, {
    required int limit,
    required int offset,
  }) async {
    final ids = roundIds.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const <Games>[];
    final range = eventRailPageRangeForTesting(limit: limit, offset: offset);
    return handleApiCall(() async {
      final response = await supabase
          .from('games')
          .select(_eventRailGameSelectColumns)
          .inFilter('round_id', ids)
          .order('round_id', ascending: true)
          .order('board_nr', ascending: true, nullsFirst: false)
          .order('id', ascending: true)
          .range(range.from, range.to);
      final jsonList = (response as List)
          .map((item) => json.encode(item))
          .toList(growable: false);
      return compute(_decodeGamesInIsolate, jsonList);
    });
  }

  Future<Games> getEventRailGameById(String gameId) async {
    return handleApiCall(() async {
      final response =
          await supabase
              .from('games')
              .select(_eventRailGameSelectColumns)
              .eq('id', gameId)
              .single();
      return Games.fromJson(response);
    });
  }

  Future<int> countGamesByTourId(String tourId) {
    return handleApiCall(
      () => supabase.from('games').count().eq('tour_id', tourId),
    );
  }

  /// Fetches the complete event context for one player without downloading
  /// every other board in the tournament.
  ///
  /// Scorecards need all of this player's rounds for exact scoring, but a
  /// 1,000-game open may contain only a dozen games for that player. Prefer
  /// the indexed FIDE-id array and fall back to the canonical player names
  /// for older rows that do not carry FIDE ids.
  Future<List<Games>> getEventGamesByPlayer({
    required String tourId,
    int? fideId,
    required String playerName,
  }) async {
    final normalizedTourId = tourId.trim();
    if (normalizedTourId.isEmpty) return const <Games>[];

    var byFide = const <Games>[];
    if (fideId != null && fideId > 0) {
      try {
        byFide = await handleApiCall(() async {
          final response = await supabase
              .from('games')
              .select(_gameListSelectColumns)
              .eq('tour_id', normalizedTourId)
              .contains('player_fide_ids', <int>[fideId])
              .order('round_id', ascending: true)
              .order('board_nr', ascending: true, nullsFirst: false)
              .order('id', ascending: true);
          return (response as List)
              .map((json) => Games.fromJson(json))
              .toList(growable: false);
        });
      } catch (_) {
        // Older schemas/rows can lack the generated FIDE-id array. The exact
        // canonical-name query below remains a complete fallback in that case.
      }
    }

    final normalizedName = _stripTitlePrefix(playerName);
    if (normalizedName.isEmpty) {
      return mergeEventPlayerGameQueryResults(byFide: byFide);
    }
    final escapedName = normalizedName.replaceAll('"', r'\"');
    final byName = await handleApiCall(() async {
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .eq('tour_id', normalizedTourId)
          .or(
            'player_white.eq."$escapedName",'
            'player_black.eq."$escapedName"',
          )
          .order('round_id', ascending: true)
          .order('board_nr', ascending: true, nullsFirst: false)
          .order('id', ascending: true);
      return (response as List)
          .map((json) => Games.fromJson(json))
          .toList(growable: false);
    });
    return mergeEventPlayerGameQueryResults(byFide: byFide, byName: byName);
  }

  Future<Games> getGameWithPGN(String gameId) async {
    return handleApiCall(() async {
      final response =
          await supabase.from('games').select().eq('id', gameId).single();

      return Games.fromJson(response);
    });
  }

  // Fetch game by its Supabase UUID (games.id column).
  Future<Games> getGameById(String id) async {
    debugPrint('Fetching game by ID: $id');
    return handleApiCall(() async {
      final response =
          await supabase
              .from('games')
              .select(_gameListSelectColumns)
              .eq('id', id)
              .single();

      return Games.fromJson(response);
    });
  }

  // Fetch game by Lichess short ID (games.lichess_id column).
  Future<Games> getGameByLichessId(String lichessId) async {
    debugPrint('Fetching game by Lichess ID: $lichessId');
    return handleApiCall(() async {
      final response =
          await supabase
              .from('games')
              .select(_gameListSelectColumns)
              .eq('lichess_id', lichessId)
              .single();

      return Games.fromJson(response);
    });
  }

  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Resolves a game from either a Supabase UUID or a Lichess short ID.
  /// UUID  → queries games.id
  /// Other → queries games.lichess_id (e.g. "4uVwSr9q")
  Future<Games> getGameByAnyId(String id) async {
    final trimmed = id.trim();
    if (_uuidPattern.hasMatch(trimmed)) {
      return getGameById(trimmed);
    }
    return getGameByLichessId(trimmed);
  }

  // Get all games for a specific player by fideId
  Future<List<Games>> getGamesByFideId(String fideId, {int? limit}) async {
    return handleApiCall(() async {
      debugPrint(
        '===== GameRepository: Fetching games for fideId: $fideId =====',
      );

      final fideIdInt = _parseFideId(fideId);
      if (fideIdInt == null) return <Games>[];

      // Query games where the fideId appears in the generated array column
      var query = supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('player_fide_ids', [fideIdInt])
          .order('date_start', ascending: false)
          .order('time_start', ascending: false);

      if (limit != null) {
        query = query.limit(limit);
      }

      debugPrint(
        '===== GameRepository: Executing query with limit: $limit =====',
      );
      final response = await query;

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      return games;
    });
  }

  // Get games for a specific player by fideId with pagination
  Future<List<Games>> getGamesByFideIdPaginated(
    String fideId, {
    required int limit,
    required int offset,
  }) async {
    return handleApiCall(() async {
      final fideIdInt = _parseFideId(fideId);
      if (fideIdInt == null) return <Games>[];

      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('player_fide_ids', [fideIdInt])
          .order('date_start', ascending: false)
          .order('time_start', ascending: false)
          .range(offset, offset + limit - 1);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      return games;
    });
  }

  // Get all games for a specific player by player name (for players without fideId)
  Future<List<Games>> getGamesByPlayerName(
    String playerName, {
    int? limit,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      // Strip title prefix if present (e.g., "GM Nakamura, Hikaru" -> "Nakamura, Hikaru")
      final normalizedName = _stripTitlePrefix(playerName);

      debugPrint(
        '===== GameRepository: Fetching games for player name: $playerName (normalized: $normalizedName) =====',
      );

      // Query games where player_white or player_black matches the name
      var query = supabase
          .from('games')
          .select(_gameListSelectColumns)
          .or(
            'player_white.eq."$normalizedName",player_black.eq."$normalizedName"',
          )
          .order('date_start', ascending: false)
          .order('time_start', ascending: false);

      if (limit != null) {
        query = query.range(offset, offset + limit - 1);
      }

      debugPrint(
        '===== GameRepository: Executing name query with limit: $limit =====',
      );
      final response = await query;

      debugPrint(
        '===== GameRepository: Received ${(response as List).length} games =====',
      );
      final games =
          (response as List).map((json) => Games.fromJson(json)).toList();
      return _deduplicateGames(games);
    });
  }

  // Get games for a specific player by name with pagination (for players without fideId)
  Future<List<Games>> getGamesByPlayerNamePaginated(
    String playerName, {
    required int limit,
    required int offset,
  }) async {
    return handleApiCall(() async {
      // Strip title prefix if present (e.g., "GM Nakamura, Hikaru" -> "Nakamura, Hikaru")
      final normalizedName = _stripTitlePrefix(playerName);

      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .or(
            'player_white.eq."$normalizedName",player_black.eq."$normalizedName"',
          )
          .order('date_start', ascending: false)
          .order('time_start', ascending: false)
          .range(offset, offset + limit - 1);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      return games;
    });
  }

  Future<String?> getGamePgn(String gameId) async {
    return handleApiCall(() async {
      final response =
          await supabase.from('games').select('pgn').eq('id', gameId).single();

      return response['pgn'] as String?;
    });
  }

  // Get games where any player has a specific country code
  Future<List<Games>> getGamesByCountryCode(String countryCode) async {
    return handleApiCall(() async {
      final normalizedCode = _normalizeCountryCode(countryCode);
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('player_feds', [normalizedCode])
          .order('id', ascending: true);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      return games;
    });
  }

  // Get "For You" games - personalized feed based on favorited players, country, and high ELO
  // This fetches ALL matching games and sorting/pagination is done in the provider
  Future<List<Games>> getForYouGames({
    List<String>? favoritedFideIds,
    String? countryCode,
    int limit = 50,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      debugPrint('===== GameRepository: Fetching For You games =====');
      debugPrint('Favorited FIDE IDs: $favoritedFideIds');
      debugPrint('Country code: $countryCode');
      debugPrint('Limit: $limit, Offset: $offset');

      // Build the query based on what filters we have
      // If we have favorited players or country code, filter for them
      // Otherwise, just get high ELO games as fallback
      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint('===== GameRepository: Fetched ${games.length} games =====');

      return games;
    });
  }

  // Get games by multiple FIDE IDs (for favorited players) with pagination
  Future<List<Games>> getGamesByMultipleFideIds({
    required List<String> fideIds,
    int limit = 50,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      final fideIdInts = _parseFideIds(fideIds);
      if (fideIdInts.isEmpty) {
        return <Games>[];
      }

      debugPrint(
        '===== GameRepository: Fetching games for ${fideIdInts.length} FIDE IDs =====',
      );

      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .overlaps('player_fide_ids', fideIdInts)
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '===== GameRepository: Fetched ${games.length} games for favorited players =====',
      );

      return games;
    });
  }

  // Get games by country code with pagination
  Future<List<Games>> getGamesByCountryCodePaginated({
    required String countryCode,
    int limit = 50,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      final normalizedCode = _normalizeCountryCode(countryCode);
      debugPrint(
        '===== GameRepository: Fetching games for country $normalizedCode =====',
      );

      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('player_feds', [normalizedCode])
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '===== GameRepository: Fetched ${games.length} games for country =====',
      );

      return games;
    });
  }

  /// Get highest ELO games (fallback when no favorites/country)
  /// Only returns games where at least one player has ELO >= minElo (default 2500)
  Future<List<Games>> getHighEloGames({
    int minElo = 2500,
    int limit = 50,
    int offset = 0,
    bool onlyLive = false,
  }) async {
    return handleApiCall(() async {
      debugPrint(
        '===== GameRepository: Fetching high ELO games (>= $minElo) =====',
      );

      // Fetch more games than needed since we filter by ELO in Dart
      // (JSONB nested field filtering is complex in Supabase)
      dynamic query = supabase.from('games').select(_gameListSelectColumns);

      if (onlyLive) {
        query = query.eq('status', '*');
      }

      // Order by date_start first to group games by day, then by last_move_time
      query = query
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(
            offset,
            offset +
                limit * (onlyLive ? 2 : 3) -
                1, // Fetch extra to compensate for ELO filter
          );

      final response = await query;

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      var games = await compute(_decodeGamesInIsolate, jsonList);

      // Filter games where at least one player has ELO >= minElo
      games =
          games
              .where((game) {
                if (game.players == null || game.players!.isEmpty) return false;
                return game.players!.any((player) => player.rating >= minElo);
              })
              .take(limit)
              .toList();

      debugPrint(
        '===== GameRepository: Fetched ${games.length} high ELO games (>= $minElo) =====',
      );

      return games;
    });
  }

  /// Get games where the average rating of the two players is at least
  /// [minAverageElo]. Used by smart event collections where "GM" means a
  /// genuinely elite game, not just one 2500+ player paired down.
  Future<List<Games>> getHighAverageEloGames({
    int minAverageElo = 2500,
    int limit = 30,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      debugPrint(
        '===== GameRepository: Fetching avg ELO games (>= $minAverageElo) =====',
      );

      final collected = <Games>[];

      // Start from recent broadcasts/tours, then qualify games using the same
      // structured player ratings the desktop UI displays. PGN WhiteElo/
      // BlackElo tags can be missing or lag behind live/imported rows, which
      // makes obviously qualifying GM games disappear from the desktop smart
      // collection.
      final broadcastResponse = await supabase
          .from('group_broadcasts')
          .select('id')
          .order('date_start', ascending: false, nullsFirst: false)
          .range(offset, offset + 119);

      final broadcastIds =
          (broadcastResponse as List)
              .map((row) => row['id'] as String?)
              .whereType<String>()
              .toList();

      if (broadcastIds.isNotEmpty) {
        final tourIds = <String>[];
        for (final chunk in _chunks(broadcastIds, 40)) {
          final tourResponse = await supabase
              .from('tours')
              .select('id')
              .inFilter('group_broadcast_id', chunk);
          tourIds.addAll(
            (tourResponse as List)
                .map((row) => row['id'] as String?)
                .whereType<String>(),
          );
        }

        for (final chunk in _chunks(tourIds, 40)) {
          final response = await supabase
              .from('games')
              .select(_gameListSelectColumns)
              .inFilter('tour_id', chunk)
              .order('date_start', ascending: false, nullsFirst: false)
              .order('last_move_time', ascending: false, nullsFirst: false)
              .limit(limit * 2);

          final jsonList =
              (response as List).map((item) => json.encode(item)).toList();
          final games = await compute(_decodeGamesInIsolate, jsonList);
          collected.addAll(
            games.where(
              (game) => gameStructuredAverageRating(game) >= minAverageElo,
            ),
          );
        }
      }

      var rawOffset = offset;
      var exhausted = false;

      // Fallback for rows outside the recent broadcast window. This is only a
      // candidate source; the two-player structured rating check remains the
      // source of truth.
      while (collected.length < limit && !exhausted) {
        final rawLimit = (limit - collected.length) * 3;
        final response = await supabase
            .from('games')
            .select(_gameListSelectColumns)
            .gte('player_max_rating', minAverageElo)
            .order('date_start', ascending: false, nullsFirst: false)
            .order('last_move_time', ascending: false, nullsFirst: false)
            .range(rawOffset, rawOffset + rawLimit - 1);

        final rawRows = response as List;
        exhausted = rawRows.length < rawLimit;
        rawOffset += rawRows.length;

        final jsonList = rawRows.map((item) => json.encode(item)).toList();
        final games = await compute(_decodeGamesInIsolate, jsonList);

        collected.addAll(
          games.where(
            (game) => gameStructuredAverageRating(game) >= minAverageElo,
          ),
        );
      }

      final result = _deduplicateGames(collected);
      result.sort((a, b) {
        final eloCompare = gameStructuredAverageRating(
          b,
        ).compareTo(gameStructuredAverageRating(a));
        if (eloCompare != 0) return eloCompare;

        final aDate = a.lastMoveTime ?? a.gameDay ?? a.dateStart ?? DateTime(0);
        final bDate = b.lastMoveTime ?? b.gameDay ?? b.dateStart ?? DateTime(0);
        return bDate.compareTo(aDate);
      });

      return result.take(limit).toList();
    });
  }

  Future<List<String>> _getCurrentSmartEventTourIds({
    int? minEventAverageElo,
    List<String>? eventTimeControls,
  }) async {
    final normalizedTimeControls =
        (eventTimeControls ?? const <String>[])
            .map((value) => value.trim().toLowerCase())
            .where((value) => value.isNotEmpty)
            .toList()
          ..sort();
    final cacheKey =
        '${minEventAverageElo ?? ''}|'
        '${normalizedTimeControls.join(',')}';
    final now = DateTime.now().toUtc();
    final cached = _currentSmartEventScopeCache[cacheKey];

    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.tourIds;
    }

    dynamic eventQuery = supabase
        .from('group_broadcasts_current')
        .select('id,max_avg_elo,time_control,date_closest_round,date_start');

    if (minEventAverageElo != null) {
      eventQuery = eventQuery.gte('max_avg_elo', minEventAverageElo);
    }

    if (eventTimeControls != null && eventTimeControls.isNotEmpty) {
      eventQuery = eventQuery.inFilter('time_control', eventTimeControls);
    }

    final eventResponse = await eventQuery
        .order('max_avg_elo', ascending: false, nullsFirst: false)
        .order('date_closest_round', ascending: true, nullsFirst: false)
        .limit(500);

    final eventIds = (eventResponse as List)
        .map((row) => row['id'] as String?)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

    if (eventIds.isEmpty) {
      _currentSmartEventScopeCache[cacheKey] = _CurrentSmartEventScopeCache(
        tourIds: const <String>[],
        expiresAt: now.add(_currentSmartEventScopeCacheTtl),
      );
      return const <String>[];
    }

    final tourIds = <String>[];
    for (final chunk in _chunks(eventIds, 40)) {
      final tourResponse = await supabase
          .from('tours')
          .select('id')
          .inFilter('group_broadcast_id', chunk);
      tourIds.addAll(
        (tourResponse as List)
            .map((row) => row['id'] as String?)
            .whereType<String>()
            .where((id) => id.isNotEmpty),
      );
    }

    final scopedTourIds = List<String>.unmodifiable(tourIds);
    _currentSmartEventScopeCache[cacheKey] = _CurrentSmartEventScopeCache(
      tourIds: scopedTourIds,
      expiresAt: now.add(_currentSmartEventScopeCacheTtl),
    );
    return scopedTourIds;
  }

  /// Applies the shared smart-collection row predicates to [query].
  ///
  /// Kept in one place so the day probe and the day fetch can never disagree
  /// about which rows count as in-scope — if they did, the probe would hand out
  /// a day the fetch then returns empty.
  dynamic _applyCurrentSmartEventPredicates(
    dynamic query, {
    required bool liveOnly,
    int? minGameAverageElo,
  }) {
    final now = DateTime.now().toUtc();
    var scoped = query.or(
      'starts_at.is.null,starts_at.lte.${now.toIso8601String()}',
      referencedTable: 'rounds',
    );

    if (liveOnly) {
      final liveCutoffIso =
          now.subtract(_currentSmartLiveMaxAge).toIso8601String();
      scoped = scoped
          .inFilter('status', ['*', 'ongoing', 'live'])
          .not('last_move', 'is', null)
          .not('last_move_time', 'is', null)
          .not('last_clock_white', 'is', null)
          .not('last_clock_black', 'is', null)
          .gt('last_clock_white', 0)
          .gt('last_clock_black', 0)
          .gte('last_move_time', liveCutoffIso);
    }

    if (minGameAverageElo != null) {
      scoped = scoped.gte('player_max_rating', minGameAverageElo);
    }

    return scoped;
  }

  /// Newest smart-collection day that holds in-scope games.
  ///
  /// Never returns a future day, and returns the newest day strictly older than
  /// [before] when given, which is how the feed walks backwards one day at a
  /// time. Null means there is nothing left to load.
  Future<DateTime?> getCurrentSmartEventDay({
    bool liveOnly = false,
    int? minEventAverageElo,
    int? minGameAverageElo,
    List<String>? eventTimeControls,
    DateTime? before,
  }) async {
    return handleApiCall(() async {
      final tourIds = await _getCurrentSmartEventTourIds(
        minEventAverageElo: minEventAverageElo,
        eventTimeControls: eventTimeControls,
      );
      if (tourIds.isEmpty) return null;

      final today = DateTime.now();
      dynamic dayQuery = supabase
          .from('games')
          .select('game_day,\nrounds!games_round_id_fkey!inner(starts_at)')
          .inFilter('tour_id', tourIds)
          .not('game_day', 'is', null)
          .lte('game_day', formatSmartEventDay(today));

      if (before != null) {
        dayQuery = dayQuery.lt('game_day', formatSmartEventDay(before));
      }

      dayQuery = _applyCurrentSmartEventPredicates(
        dayQuery,
        liveOnly: liveOnly,
        minGameAverageElo: minGameAverageElo,
      );

      final response = await dayQuery
          .order('game_day', ascending: false, nullsFirst: false)
          .limit(1);

      final rows = response as List;
      if (rows.isEmpty) return null;

      final rawDay = rows.first['game_day'] as String?;
      if (rawDay == null) return null;
      final parsed = DateTime.tryParse(rawDay);
      if (parsed == null) return null;
      return DateTime(parsed.year, parsed.month, parsed.day);
    });
  }

  /// Every in-scope smart-collection game on [day], plus the next older day.
  ///
  /// Deliberately unpaged: the day is the unit of pagination, so a day arrives
  /// whole. Time-control and average-rating narrowing that the backend cannot
  /// express still runs here, so the caller receives the final day contents.
  Future<CurrentSmartEventDayPage> getCurrentSmartEventGamesOnDay({
    required DateTime day,
    bool liveOnly = false,
    int? minEventAverageElo,
    int? minGameAverageElo,
    List<String>? eventTimeControls,
  }) async {
    return handleApiCall(() async {
      final normalizedDay = DateTime(day.year, day.month, day.day);
      final tourIds = await _getCurrentSmartEventTourIds(
        minEventAverageElo: minEventAverageElo,
        eventTimeControls: eventTimeControls,
      );
      if (tourIds.isEmpty) {
        return CurrentSmartEventDayPage(
          day: normalizedDay,
          games: const <Games>[],
          nextDay: null,
        );
      }

      dynamic gamesQuery = supabase
          .from('games')
          .select(
            '$_gameListSelectColumns,\nrounds!games_round_id_fkey!inner(starts_at)',
          )
          .inFilter('tour_id', tourIds)
          .eq('game_day', formatSmartEventDay(normalizedDay));

      gamesQuery = _applyCurrentSmartEventPredicates(
        gamesQuery,
        liveOnly: liveOnly,
        minGameAverageElo: minGameAverageElo,
      );

      final response = await gamesQuery
          .order('last_move_time', ascending: false, nullsFirst: false)
          .order('player_max_rating', ascending: false, nullsFirst: false)
          .limit(_currentSmartGamesPageSize);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();
      var games = await compute(_decodeGamesInIsolate, jsonList);

      if (eventTimeControls != null && eventTimeControls.isNotEmpty) {
        final normalizedEventTimeControls =
            eventTimeControls
                .map((value) => value.trim().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toSet();
        games =
            games
                .where(
                  (game) => normalizedEventTimeControls.contains(
                    game.timeControl?.trim().toLowerCase(),
                  ),
                )
                .toList();
      }

      if (minGameAverageElo != null) {
        games =
            games
                .where(
                  (game) =>
                      gameStructuredAverageRating(game) >= minGameAverageElo,
                )
                .toList();
      }

      final result = _deduplicateGames(games);
      result.sort(_compareCurrentSmartGames);

      final nextDay = await getCurrentSmartEventDay(
        liveOnly: liveOnly,
        minEventAverageElo: minEventAverageElo,
        minGameAverageElo: minGameAverageElo,
        eventTimeControls: eventTimeControls,
        before: normalizedDay,
      );

      return CurrentSmartEventDayPage(
        day: normalizedDay,
        games: result,
        nextDay: nextDay,
      );
    });
  }

  /// Get classical/standard games globally.
  Future<List<Games>> getClassicalGames({
    int limit = 30,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      debugPrint('===== GameRepository: Fetching classical games =====');

      final broadcastResponse = await supabase
          .from('group_broadcasts')
          .select('id')
          .inFilter('time_control', _classicalTimeControlValues)
          .order('date_start', ascending: false, nullsFirst: false)
          .range(offset, offset + 79);

      final broadcastIds =
          (broadcastResponse as List)
              .map((row) => row['id'] as String?)
              .whereType<String>()
              .toList();

      if (broadcastIds.isEmpty) return <Games>[];

      final tourIds = <String>[];
      for (final chunk in _chunks(broadcastIds, 40)) {
        final tourResponse = await supabase
            .from('tours')
            .select('id')
            .inFilter('group_broadcast_id', chunk);
        tourIds.addAll(
          (tourResponse as List)
              .map((row) => row['id'] as String?)
              .whereType<String>(),
        );
      }

      if (tourIds.isEmpty) return <Games>[];

      final collected = <Games>[];
      for (final chunk in _chunks(tourIds, 40)) {
        final response = await supabase
            .from('games')
            .select(_gameListSelectColumns)
            .inFilter('tour_id', chunk)
            .order('date_start', ascending: false, nullsFirst: false)
            .order('last_move_time', ascending: false, nullsFirst: false)
            .limit(limit);

        final jsonList =
            (response as List).map((item) => json.encode(item)).toList();
        final games = await compute(_decodeGamesInIsolate, jsonList);
        collected.addAll(games.where(_isClassicalTimeControl));
      }

      collected.sort((a, b) {
        final aDate = a.lastMoveTime ?? a.gameDay ?? a.dateStart ?? DateTime(0);
        final bDate = b.lastMoveTime ?? b.gameDay ?? b.dateStart ?? DateTime(0);
        return bDate.compareTo(aDate);
      });

      return _deduplicateGames(collected).take(limit).toList();
    });
  }

  bool _isClassicalTimeControl(Games game) {
    final normalized = game.timeControl?.trim().toLowerCase();
    return normalized == 'standard' || normalized == 'classical';
  }

  /// Get LIVE games (status = '*') - highest priority in For You
  /// These are ongoing games with recent activity
  Future<List<Games>> getLiveGames({int limit = 30, int offset = 0}) async {
    return handleApiCall(() async {
      debugPrint('===== GameRepository: Fetching LIVE games =====');

      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .eq('status', '*')
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '===== GameRepository: Fetched ${games.length} LIVE games =====',
      );

      return games;
    });
  }

  /// Get countryman games with minimum ELO filter.
  /// Shows games where at least one player from the country has rating >= minElo.
  ///
  /// The caller is responsible for pagination. This method fetches exactly
  /// `limit` games starting at `offset` with server-side ELO filtering.
  /// Returns: (filteredGames, rawGamesFetched).
  Future<({List<Games> games, int rawFetched})>
  getCountrymanGamesWithMinEloAndRawCount({
    required String countryCode,
    int minElo = 2300,
    int limit = 20,
    int rawOffset = 0,
  }) async {
    return handleApiCall(() async {
      final normalizedCode = _normalizeCountryCode(countryCode);
      debugPrint(
        '===== GameRepository: Fetching countryman games (ELO >= $minElo) for countryCode="$normalizedCode", limit=$limit, rawOffset=$rawOffset =====',
      );

      // Order by date_start first to group games by day, then by last_move_time
      // This ensures all games from today appear together, even if some have NULL last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('player_feds', [normalizedCode])
          .gte('player_max_rating', minElo)
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(rawOffset, rawOffset + limit - 1);

      final rawCount = (response as List).length;
      debugPrint('===== GameRepository: Raw response count: $rawCount =====');

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint('===== GameRepository: Decoded ${games.length} games =====');

      return (games: games, rawFetched: rawCount);
    });
  }

  /// Get countryman games with minimum ELO filter (simple version).
  /// For backwards compatibility - just returns filtered games.
  Future<List<Games>> getCountrymanGamesWithMinElo({
    required String countryCode,
    int minElo = 2300,
    int limit = 50,
    int offset = 0,
  }) async {
    final result = await getCountrymanGamesWithMinEloAndRawCount(
      countryCode: countryCode,
      minElo: minElo,
      limit: limit,
      rawOffset: offset,
    );
    return result.games;
  }

  /// Get live games for specific players (favorited players who are currently playing)
  Future<List<Games>> getLiveGamesForPlayers({
    required List<String> fideIds,
    int limit = 20,
  }) async {
    return handleApiCall(() async {
      final fideIdInts = _parseFideIds(fideIds);
      if (fideIdInts.isEmpty) return <Games>[];

      debugPrint(
        '===== GameRepository: Fetching LIVE games for ${fideIdInts.length} players =====',
      );

      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .eq('status', '*')
          .overlaps('player_fide_ids', fideIdInts)
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .limit(limit);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '===== GameRepository: Fetched ${games.length} LIVE games for players =====',
      );

      return games;
    });
  }

  /// Get live games for favorited events
  Future<List<Games>> getLiveGamesForEvents({
    required List<String> eventIds,
    int limit = 20,
  }) async {
    return handleApiCall(() async {
      if (eventIds.isEmpty) return <Games>[];

      debugPrint(
        '===== GameRepository: Fetching LIVE games for ${eventIds.length} events =====',
      );

      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .eq('status', '*')
          .inFilter('tour_id', eventIds)
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .limit(limit);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '===== GameRepository: Fetched ${games.length} LIVE games for events =====',
      );

      return games;
    });
  }

  /// Get top board games from a specific tournament (highest ELO players)
  /// Used to fill up the "For You" feed when there aren't enough personalized games
  Future<List<Games>> getTopBoardGamesByTourId({
    required String tourId,
    int limit = 4,
    Set<String>? excludeGameIds,
  }) async {
    return handleApiCall(() async {
      debugPrint(
        '===== GameRepository: Fetching top $limit board games for tour $tourId =====',
      );

      // Fetch more games than needed since we sort by ELO in Dart
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .eq('tour_id', tourId)
          .order(
            'board_nr',
            ascending: true,
          ) // Lower board number = higher boards
          .limit(limit * 3); // Fetch extra for filtering

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      var games = await compute(_decodeGamesInIsolate, jsonList);

      // Exclude games already in the feed
      if (excludeGameIds != null && excludeGameIds.isNotEmpty) {
        games = games.where((g) => !excludeGameIds.contains(g.id)).toList();
      }

      // Sort by max ELO (highest first) - top boards have highest rated players
      games.sort((a, b) {
        final maxEloA =
            a.players
                ?.map((p) => p.rating)
                .fold<int>(0, (max, r) => r > max ? r : max) ??
            0;
        final maxEloB =
            b.players
                ?.map((p) => p.rating)
                .fold<int>(0, (max, r) => r > max ? r : max) ??
            0;
        return maxEloB.compareTo(maxEloA);
      });

      final result = games.take(limit).toList();

      debugPrint(
        '===== GameRepository: Fetched ${result.length} top board games for tour $tourId =====',
      );

      return result;
    });
  }

  Future<Map<String, List<Games>>> getForYouTopGamesByEventIds({
    required List<String> eventIds,
    int boardsPerEvent = 4,
  }) async {
    if (eventIds.isEmpty) return <String, List<Games>>{};

    return handleApiCall(() async {
      final response = await supabase.rpc(
        'get_for_you_top_games',
        params: {'p_event_ids': eventIds, 'p_boards_per_event': boardsPerEvent},
      );

      final gamesByEvent = <String, List<Games>>{};
      for (final item in response as List) {
        final row = Map<String, dynamic>.from(item as Map);
        final eventId = row['event_id'] as String?;
        if (eventId == null || eventId.isEmpty) continue;

        try {
          gamesByEvent
              .putIfAbsent(eventId, () => <Games>[])
              .add(Games.fromJson(row));
        } catch (e) {
          debugPrint('[GameRepository] Skipping malformed top game row: $e');
        }
      }

      return {
        for (final entry in gamesByEvent.entries)
          entry.key: _deduplicateGames(entry.value),
      };
    });
  }

  /// Returns matching favorite-player FIDE IDs for each For You event in one batched RPC.
  Future<Map<String, List<int>>> getForYouFavoritePlayerFideIdsByEventIds({
    required List<String> eventIds,
    required List<int> favoriteFideIds,
  }) async {
    if (eventIds.isEmpty || favoriteFideIds.isEmpty) {
      return <String, List<int>>{};
    }

    return handleApiCall(() async {
      final response = await supabase.rpc(
        'get_for_you_favorite_player_counts',
        params: {'p_event_ids': eventIds, 'p_fide_ids': favoriteFideIds},
      );

      final matchesByEventId = <String, List<int>>{};
      for (final item in response as List) {
        final json = Map<String, dynamic>.from(item as Map);
        final eventId = json['event_id'] as String?;
        if (eventId == null || eventId.isEmpty) continue;

        final fideIds =
            (json['fide_ids'] as List? ?? const [])
                .map(_parseRpcInt)
                .whereType<int>()
                .toSet()
                .toList()
              ..sort();
        matchesByEventId[eventId] = fideIds;
      }

      return matchesByEventId;
    });
  }

  /// Search games using the precomputed `search` tokens column.
  ///
  /// The `games.search` column contains normalized tokens (players, events,
  /// openings, ECO codes, countries, common move strings, etc). This query
  /// matches games that contain all provided tokens.
  Future<List<Games>> searchGamesBySearchTermsPaginated({
    required List<String> terms,
    int limit = 30,
    int offset = 0,
    String? status,
  }) async {
    return handleApiCall(() async {
      final normalizedTerms =
          terms
              .map((t) => t.trim().toLowerCase())
              .where((t) => t.isNotEmpty)
              .toList();

      if (normalizedTerms.isEmpty) return <Games>[];

      // Build filter chain first (must come before transform operations)
      var query = supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('search', normalizedTerms);

      if (status != null && status.isNotEmpty) {
        query = query.eq('status', status);
      }

      // Transform operations (order, range) come after filters
      // Order by date_start first to group games by day, then by last_move_time
      final response = await query
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);
      return games;
    });
  }

  /// Search games using flexible text matching on the `name` column.
  /// The `name` column contains "WhitePlayer - BlackPlayer" format.
  /// This uses ILIKE for partial matching (e.g., "carlsen" matches "Carlsen, Magnus").
  ///
  /// Optionally filter by country using the `players` JSONB column.
  Future<List<Games>> searchGamesFlexible({
    required String query,
    String? countryCode,
    int limit = 30,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      final trimmedQuery = query.trim();
      if (trimmedQuery.isEmpty && countryCode == null) return <Games>[];

      debugPrint(
        '[GameRepository] searchGamesFlexible: query="$trimmedQuery", countryCode=$countryCode, limit=$limit, offset=$offset',
      );

      // Build the query with ILIKE on the name column
      var dbQuery = supabase.from('games').select(_gameListSelectColumns);

      // If we have a text query, use ILIKE on the name column
      if (trimmedQuery.isNotEmpty) {
        dbQuery = dbQuery.ilike('name', '%$trimmedQuery%');
      }

      // If we have a country filter, add it
      if (countryCode != null && countryCode.isNotEmpty) {
        dbQuery = dbQuery.contains('player_feds', [
          _normalizeCountryCode(countryCode),
        ]);
      }

      // Order by date_start first to group games by day, then by last_move_time
      final response = await dbQuery
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      final rawCount = (response as List).length;
      debugPrint('[GameRepository] searchGamesFlexible: got $rawCount results');

      final jsonList = response.map((item) => json.encode(item)).toList();
      final games = await compute(_decodeGamesInIsolate, jsonList);
      return games;
    });
  }

  /// Search games for a specific country with optional text query.
  /// Returns games where at least one player is from the country AND
  /// optionally matches the search query.
  Future<List<Games>> searchCountrymenGames({
    required String countryCode,
    String? query,
    int limit = 30,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      final normalizedCode = _normalizeCountryCode(countryCode);
      debugPrint(
        '[GameRepository] searchCountrymenGames: country=$normalizedCode, query=$query',
      );

      var dbQuery = supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('player_feds', [normalizedCode]);

      // Add text search if query provided (searches player names, ECO code, and opening name)
      if (query != null && query.trim().isNotEmpty) {
        dbQuery = dbQuery.or(
          'name.ilike.%${query.trim()}%,eco.ilike.%${query.trim()}%,opening_name.ilike.%${query.trim()}%',
        );
      }

      // Order by date_start first to group games by day, then by last_move_time
      final response = await dbQuery
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      debugPrint(
        '[GameRepository] searchCountrymenGames: raw results = ${(response as List).length}',
      );

      final jsonList = response.map((item) => json.encode(item)).toList();
      final games = await compute(_decodeGamesInIsolate, jsonList);

      return games;
    });
  }

  /// Search games for favorite players with optional text query.
  /// First filters by FIDE IDs (indexed), then applies text search.
  Future<List<Games>> searchFavoritesGames({
    required List<String> fideIds,
    required List<String> playerNames,
    String? query,
    int limit = 30,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      debugPrint(
        '[GameRepository] searchFavoritesGames: fideIds=${fideIds.length}, query=$query, offset=$offset',
      );

      final fideIdInts = _parseFideIds(fideIds);
      if (fideIdInts.isEmpty) return <Games>[];

      var dbQuery = supabase
          .from('games')
          .select(_gameListSelectColumns)
          .overlaps('player_fide_ids', fideIdInts);

      // Add text search if query provided (searches player names, ECO code, and opening name)
      if (query != null && query.trim().isNotEmpty) {
        dbQuery = dbQuery.or(
          'name.ilike.%${query.trim()}%,eco.ilike.%${query.trim()}%,opening_name.ilike.%${query.trim()}%',
        );
      }

      // Order and paginate
      final response = await dbQuery
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      debugPrint(
        '[GameRepository] searchFavoritesGames: results = ${(response as List).length}',
      );

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();
      final games = await compute(_decodeGamesInIsolate, jsonList);

      return games;
    });
  }

  /// Get games from multiple tour IDs (for fetching all current events' games)
  /// Returns games ordered by last_move_time descending
  Future<List<Games>> getGamesFromTourIds({
    required List<String> tourIds,
    int limit = 500,
    int offset = 0,
  }) async {
    if (tourIds.isEmpty) {
      return <Games>[];
    }

    debugPrint(
      '[GameRepository] Fetching games from ${tourIds.length} tour IDs (limit: $limit, offset: $offset)',
    );

    try {
      // Use inFilter for multiple tour IDs
      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .inFilter('tour_id', tourIds)
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .range(offset, offset + limit - 1);

      final responseList = response as List<dynamic>;

      if (responseList.isEmpty) {
        debugPrint(
          '[GameRepository] Empty response from getGamesFromTourIds query',
        );
        return <Games>[];
      }

      final jsonList = responseList.map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '[GameRepository] Fetched ${games.length} games from current events',
      );

      return games;
    } catch (e) {
      debugPrint('[GameRepository] Error in getGamesFromTourIds: $e');
      return <Games>[];
    }
  }

  /// Resolve the best tour to open for an event group.
  ///
  /// Priority:
  /// 1) live games with moves
  /// 2) most recently moved game
  /// 3) most recently started round
  /// 4) nearest upcoming round when nothing started yet
  Future<String?> getMostRelevantTourId({required List<String> tourIds}) async {
    if (tourIds.isEmpty) return null;

    try {
      final liveResponse = await supabase
          .from('games')
          .select('tour_id,last_move_time,date_start')
          .inFilter('tour_id', tourIds)
          .inFilter('status', ['*', 'ongoing'])
          .not('last_move_time', 'is', null)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .order('date_start', ascending: false, nullsFirst: false)
          .limit(1);

      if (liveResponse.isNotEmpty) {
        final id = liveResponse.first['tour_id'];
        if (id is String && id.isNotEmpty) {
          return id;
        }
      }

      final recentResponse = await supabase
          .from('games')
          .select('tour_id,last_move_time,date_start')
          .inFilter('tour_id', tourIds)
          .not('last_move_time', 'is', null)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .limit(1);

      if (recentResponse.isNotEmpty) {
        final id = recentResponse.first['tour_id'];
        if (id is String && id.isNotEmpty) {
          return id;
        }
      }

      final nowIso = DateTime.now().toUtc().toIso8601String();
      final startedRounds = await supabase
          .from('rounds')
          .select('tour_id,starts_at')
          .inFilter('tour_id', tourIds)
          .not('starts_at', 'is', null)
          .lte('starts_at', nowIso)
          .order('starts_at', ascending: false)
          .limit(1);

      if (startedRounds.isNotEmpty) {
        final id = startedRounds.first['tour_id'];
        if (id is String && id.isNotEmpty) {
          return id;
        }
      }

      final upcomingRounds = await supabase
          .from('rounds')
          .select('tour_id,starts_at')
          .inFilter('tour_id', tourIds)
          .not('starts_at', 'is', null)
          .gte('starts_at', nowIso)
          .order('starts_at', ascending: true)
          .limit(1);

      if (upcomingRounds.isNotEmpty) {
        final id = upcomingRounds.first['tour_id'];
        if (id is String && id.isNotEmpty) {
          return id;
        }
      }

      return null;
    } catch (e) {
      debugPrint('[GameRepository] Error in getMostRelevantTourId: $e');
      return null;
    }
  }

  Future<Map<String, DateTime>> getLatestLastMoveTimesByRoundIds(
    List<String> roundIds,
  ) async {
    if (roundIds.isEmpty) return <String, DateTime>{};

    return handleApiCall(() async {
      final response = await supabase
          .from('games')
          .select('round_id,last_move_time')
          .inFilter('round_id', roundIds)
          .not('last_move_time', 'is', null)
          .order('last_move_time', ascending: false, nullsFirst: false);

      final latestByRoundId = <String, DateTime>{};
      for (final row in response as List) {
        final roundId = row['round_id'] as String?;
        final lastMoveTimeRaw = row['last_move_time'] as String?;
        if (roundId == null || roundId.isEmpty || lastMoveTimeRaw == null) {
          continue;
        }
        latestByRoundId.putIfAbsent(
          roundId,
          () => DateTime.parse(lastMoveTimeRaw),
        );
      }

      return latestByRoundId;
    });
  }

  /// Get games for "For You" event cards
  /// Current round = live games with moves, else most recently played,
  /// else earliest upcoming round when nothing has started yet.
  Future<List<Games>> getForYouEventGames({
    required List<String> tourIds,
    int neededCount = 4,
  }) async {
    if (tourIds.isEmpty) return <Games>[];

    try {
      // Step 1: Check for live games first - their round is the "current" round
      final liveResponse = await supabase
          .from('games')
          .select('round_id, last_move_time, date_start')
          .inFilter('tour_id', tourIds)
          .inFilter('status', ['*', 'ongoing'])
          .not('last_move_time', 'is', null)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .order('date_start', ascending: false, nullsFirst: false)
          .limit(1);

      Set<String> currentRoundIds = {};

      if (liveResponse.isNotEmpty) {
        // Live games exist - use the most recently active live round
        final liveRoundId = liveResponse.first['round_id'];
        if (liveRoundId is String && liveRoundId.isNotEmpty) {
          currentRoundIds = {liveRoundId};
          debugPrint(
            '[GameRepository] ForYou: Found live round: $currentRoundIds',
          );
        }
      }

      if (currentRoundIds.isEmpty) {
        // No live games - find most recently played round (by last_move_time)
        final recentResponse = await supabase
            .from('games')
            .select('round_id')
            .inFilter('tour_id', tourIds)
            .not('last_move_time', 'is', null)
            .order('last_move_time', ascending: false)
            .limit(1);

        if (recentResponse.isNotEmpty) {
          currentRoundIds.add(recentResponse.first['round_id'] as String);
          debugPrint(
            '[GameRepository] ForYou: Most recent round: $currentRoundIds',
          );
        }
      }

      if (currentRoundIds.isEmpty) {
        // No games played yet - use the earliest upcoming round (by starts_at)
        final nowIso = DateTime.now().toUtc().toIso8601String();
        List<dynamic>? roundResponse;
        try {
          roundResponse = await supabase
              .from('rounds')
              .select('id, starts_at')
              .inFilter('tour_id', tourIds)
              .not('starts_at', 'is', null)
              .gte('starts_at', nowIso)
              .order('starts_at', ascending: true)
              .limit(1);
        } catch (e) {
          debugPrint(
            '[GameRepository] ForYou: Failed to load upcoming rounds ($e)',
          );
        }

        if (roundResponse != null && roundResponse.isNotEmpty) {
          final roundId = roundResponse.first['id'];
          if (roundId is String && roundId.isNotEmpty) {
            currentRoundIds.add(roundId);
            debugPrint(
              '[GameRepository] ForYou: Earliest upcoming round: $currentRoundIds',
            );
          }
        }
      }

      if (currentRoundIds.isEmpty) return <Games>[];

      // Step 2: Fetch games from current round(s), ordered by ELO
      final gamesResponse = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .inFilter('round_id', currentRoundIds.toList())
          .order('player_max_rating', ascending: false, nullsFirst: false)
          .limit(neededCount + 4);

      final games = <Games>[];
      if (gamesResponse.isNotEmpty) {
        final jsonList =
            gamesResponse.map((item) => json.encode(item)).toList();
        games.addAll(await compute(_decodeGamesInIsolate, jsonList));
      }

      return games;
    } catch (e) {
      debugPrint('[GameRepository] Error in getForYouEventGames: $e');
      return <Games>[];
    }
  }

  /// Get top live games globally, ordered by recency.
  Future<List<Games>> getTopLiveGames({int limit = 200}) async {
    return handleApiCall(() async {
      // Order by date_start first to group games by day, then by last_move_time
      final response = await supabase
          .from('games')
          .select(_gameListSelectColumns)
          .eq('status', '*')
          .order('date_start', ascending: false, nullsFirst: false)
          .order('last_move_time', ascending: false, nullsFirst: false)
          .limit(limit);

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);
      return games;
    });
  }

  /// Get distinct game dates for favorited players.
  /// Returns dates in descending order (most recent first).
  Future<List<DateTime>> getDistinctDatesForFavorites({
    required List<String> fideIds,
    int limit = 30,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      final fideIdInts = _parseFideIds(fideIds);
      if (fideIdInts.isEmpty) return <DateTime>[];

      debugPrint(
        '[GameRepository] getDistinctDatesForFavorites: fideIds=${fideIdInts.length}',
      );

      final response = await supabase.rpc(
        'get_distinct_dates_for_favorites',
        params: {
          'fide_ids': fideIdInts,
          'limit_count': limit,
          'offset_count': offset,
        },
      );

      final dates = <DateTime>[];

      for (final row in (response as List)) {
        final dateStr = row['date_start']?.toString();
        if (dateStr == null) continue;
        try {
          dates.add(DateTime.parse(dateStr));
        } catch (e) {
          debugPrint('[GameRepository] Error parsing date: $dateStr');
        }
      }

      final filteredDates = _filterOutFutureDates(dates);
      debugPrint(
        '[GameRepository] getDistinctDatesForFavorites: found ${filteredDates.length} dates',
      );
      return filteredDates;
    });
  }

  /// Get ALL games by FIDE IDs for a specific date.
  /// No pagination - returns all games for the date.
  Future<List<Games>> getGamesByFideIdsAndDate({
    required List<String> fideIds,
    required DateTime date,
    String? eco,
  }) async {
    return handleApiCall(() async {
      final fideIdInts = _parseFideIds(fideIds);
      if (fideIdInts.isEmpty) return <Games>[];

      final dateStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final dayStartUtc = DateTime.utc(date.year, date.month, date.day);
      final nextDayUtc = dayStartUtc.add(const Duration(days: 1));
      // Match game_day first (PGN [Date], stable per round), then fall back
      // to last_move_time, then date_start. date_start is the broadcast
      // pairing-upload day and can drift several days from the round day on
      // pre-created multi-round broadcasts (e.g. GCT), so it is only used
      // when game_day and last_move_time are both null on the row.
      final dayFilter =
          'game_day.eq.$dateStr,'
          'and(game_day.is.null,last_move_time.gte.${dayStartUtc.toIso8601String()},last_move_time.lt.${nextDayUtc.toIso8601String()}),'
          'and(game_day.is.null,last_move_time.is.null,date_start.eq.$dateStr)';
      debugPrint(
        '[GameRepository] getGamesByFideIdsAndDate: fideIds=${fideIdInts.length}, date=$dateStr, eco=$eco',
      );

      // Fetch ALL games for this date (no limit)
      var dbQuery = supabase
          .from('games')
          .select(_gameListSelectColumns)
          .overlaps('player_fide_ids', fideIdInts)
          .or(dayFilter);

      if (eco != null && eco.isNotEmpty) {
        dbQuery = dbQuery.eq('eco', eco);
      }

      final response = await dbQuery.order(
        'last_move_time',
        ascending: false,
        nullsFirst: false,
      );

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '[GameRepository] getGamesByFideIdsAndDate: found ${games.length} games for $dateStr',
      );
      return games;
    });
  }

  /// Get distinct game dates for a country.
  /// Returns dates in descending order (most recent first).
  Future<List<DateTime>> getDistinctDatesForCountry({
    required String countryCode,
    int minElo = 2000,
    int limit = 30,
    int offset = 0,
  }) async {
    return handleApiCall(() async {
      final normalizedCode = _normalizeCountryCode(countryCode);
      debugPrint(
        '[GameRepository] getDistinctDatesForCountry: countryCode=$normalizedCode',
      );

      final response = await supabase.rpc(
        'get_distinct_dates_for_country',
        params: {
          'country_code': normalizedCode,
          'min_elo': minElo,
          'limit_count': limit,
          'offset_count': offset,
        },
      );

      final dates = <DateTime>[];

      for (final row in (response as List)) {
        final dateStr = row['date_start']?.toString();
        if (dateStr == null) continue;
        try {
          dates.add(DateTime.parse(dateStr));
        } catch (e) {
          debugPrint('[GameRepository] Error parsing date: $dateStr');
        }
      }

      final filteredDates = _filterOutFutureDates(dates);
      debugPrint(
        '[GameRepository] getDistinctDatesForCountry: found ${filteredDates.length} dates',
      );
      return filteredDates;
    });
  }

  List<DateTime> _filterOutFutureDates(List<DateTime> dates) {
    if (dates.isEmpty) return dates;
    final nowUtc = DateTime.now().toUtc();
    final todayUtc = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    return dates.where((date) {
      final dateUtc = DateTime.utc(date.year, date.month, date.day);
      return !dateUtc.isAfter(todayUtc);
    }).toList();
  }

  /// Get games by country for a specific date.
  /// Returns ALL games for the date (no limit) - the countrymen tab should display
  /// everything your countrymen played on that date.
  Future<List<Games>> getGamesByCountryAndDate({
    required String countryCode,
    required DateTime date,
    int minElo = 2000,
    String? eco,
  }) async {
    return handleApiCall(() async {
      final normalizedCode = _normalizeCountryCode(countryCode);
      final dateStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final dayStartUtc = DateTime.utc(date.year, date.month, date.day);
      final nextDayUtc = dayStartUtc.add(const Duration(days: 1));
      // Match game_day first (PGN [Date], stable per round), then fall back
      // to last_move_time, then date_start. date_start is the broadcast
      // pairing-upload day and can drift several days from the round day on
      // pre-created multi-round broadcasts (e.g. GCT), so it is only used
      // when game_day and last_move_time are both null on the row.
      final dayFilter =
          'game_day.eq.$dateStr,'
          'and(game_day.is.null,last_move_time.gte.${dayStartUtc.toIso8601String()},last_move_time.lt.${nextDayUtc.toIso8601String()}),'
          'and(game_day.is.null,last_move_time.is.null,date_start.eq.$dateStr)';
      debugPrint(
        '[GameRepository] getGamesByCountryAndDate: countryCode=$normalizedCode, date=$dateStr, eco=$eco',
      );

      // No limit - fetch ALL games for this date
      var dbQuery = supabase
          .from('games')
          .select(_gameListSelectColumns)
          .contains('player_feds', [normalizedCode])
          .or(dayFilter)
          .gte('player_max_rating', minElo);

      if (eco != null && eco.isNotEmpty) {
        dbQuery = dbQuery.eq('eco', eco);
      }

      final response = await dbQuery.order(
        'last_move_time',
        ascending: false,
        nullsFirst: false,
      );

      final jsonList =
          (response as List).map((item) => json.encode(item)).toList();

      final games = await compute(_decodeGamesInIsolate, jsonList);

      debugPrint(
        '[GameRepository] getGamesByCountryAndDate: found ${games.length} games',
      );
      return games;
    });
  }
}

List<Games> _decodeGamesInIsolate(List<String> gameJsonList) {
  final games =
      gameJsonList.map((e) {
        final decoded = json.decode(e) as Map<String, dynamic>;
        return Games.fromJson(decoded);
      }).toList();
  return _deduplicateGames(games);
}

/// Removes duplicate games by ID, keeping the first occurrence.
List<Games> _deduplicateGames(List<Games> games) {
  final seen = <String>{};
  return games.where((game) => seen.add(game.id)).toList();
}

/// Combines indexed FIDE matches with canonical-name matches from legacy rows.
///
/// A mixed event can contain both representations. Returning the FIDE result
/// early silently loses historical rounds whose generated id array is absent.
@visibleForTesting
List<Games> mergeEventPlayerGameQueryResults({
  Iterable<Games> byFide = const <Games>[],
  Iterable<Games> byName = const <Games>[],
}) {
  final byId = <String, Games>{};
  for (final game in <Games>[...byFide, ...byName]) {
    final id = game.id.trim();
    if (id.isNotEmpty) byId.putIfAbsent(id, () => game);
  }
  final merged = byId.values.toList(growable: false);
  merged.sort((a, b) {
    final byRound = a.roundId.compareTo(b.roundId);
    if (byRound != 0) return byRound;
    final aBoard = a.boardNr;
    final bBoard = b.boardNr;
    if (aBoard != null && bBoard != null && aBoard != bBoard) {
      return aBoard.compareTo(bBoard);
    }
    if (aBoard != null && bBoard == null) return -1;
    if (aBoard == null && bBoard != null) return 1;
    return a.id.compareTo(b.id);
  });
  return merged;
}

int _compareCurrentSmartGames(Games a, Games b) {
  final aDay = _currentSmartGameDay(a);
  final bDay = _currentSmartGameDay(b);
  final byDay = bDay.compareTo(aDay);
  if (byDay != 0) return byDay;

  final byAverageElo = gameStructuredAverageRating(
    b,
  ).compareTo(gameStructuredAverageRating(a));
  if (byAverageElo != 0) return byAverageElo;

  final byTopElo = _currentSmartGameTopElo(
    b,
  ).compareTo(_currentSmartGameTopElo(a));
  if (byTopElo != 0) return byTopElo;

  final aBoard = a.boardNr;
  final bBoard = b.boardNr;
  if (aBoard != null && bBoard != null) return aBoard.compareTo(bBoard);
  if (aBoard != null) return -1;
  if (bBoard != null) return 1;

  return a.id.compareTo(b.id);
}

DateTime _currentSmartGameDay(Games game) {
  final raw =
      game.lastMoveTime ?? game.gameDay ?? game.dateStart ?? DateTime(0);
  final local = raw.toLocal();
  return DateTime(local.year, local.month, local.day);
}

int _currentSmartGameTopElo(Games game) {
  final players = game.players;
  if (players == null || players.isEmpty) return 0;
  return players.fold<int>(
    0,
    (maxRating, player) =>
        player.rating > maxRating ? player.rating : maxRating,
  );
}

Iterable<List<T>> _chunks<T>(List<T> items, int size) sync* {
  for (var start = 0; start < items.length; start += size) {
    final end = start + size > items.length ? items.length : start + size;
    yield items.sublist(start, end);
  }
}
