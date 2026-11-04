import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/chess_title_utils.dart';

final communityLikesRepositoryProvider = Provider<CommunityLikesRepository>(
  (ref) => CommunityLikesRepository(
    client: () => Supabase.instance.client,
    gamebase: ref.watch(gamebaseRepositoryProvider),
  ),
);

/// Reads the community Likes ranking and resolves it to real games.
///
/// Same RPCs and fallbacks as the phone's `DiscoveryRepository.fetchMostLiked`.
/// Pure Supabase + Gamebase reads, so it runs unchanged in the browser build.
class CommunityLikesRepository {
  CommunityLikesRepository({required this.client, required this.gamebase});

  final SupabaseClient Function() client;
  final GamebaseRepository gamebase;

  /// The ranking for [query]. A backend without the ranking function answers
  /// [CommunityLikesResult.notLive], a refused Premium window answers
  /// [CommunityLikesResult.premiumRequired]; anything else is thrown.
  Future<CommunityLikesResult> fetch(
    CommunityLikesQuery query, {
    int limit = kCommunityLikesPageSize,
    CommunityLikesCursor? after,
  }) async {
    final pageSize = limit.clamp(1, 49);
    final window = query.window;
    Object? rows;
    var legacyPreview = false;
    try {
      rows = await client().rpc(
        'most_liked_ranking_page',
        params: {
          'p_from': window.from.toUtc().toIso8601String(),
          'p_to': window.to.toUtc().toIso8601String(),
          'p_limit': pageSize + 1,
          if (after != null) ...{
            'p_after_likes': after.likes,
            'p_after_game_id': after.gameId,
          },
        },
      );
    } catch (e) {
      switch (classifyCommunityLikesError(e)) {
        case CommunityLikesFailure.missingFunction:
          if (after != null) return const CommunityLikesResult.notLive();
          // A rolling deployment may still only have the preview RPC.
          try {
            rows = await client().rpc(
              'most_liked_ranking_preview',
              params: {
                'p_from': window.from.toUtc().toIso8601String(),
                'p_to': window.to.toUtc().toIso8601String(),
                'p_limit': pageSize,
              },
            );
            legacyPreview = true;
          } catch (fallbackError) {
            if (classifyCommunityLikesError(fallbackError) ==
                CommunityLikesFailure.missingFunction) {
              return const CommunityLikesResult.notLive();
            }
            rethrow;
          }
        case CommunityLikesFailure.premiumRequired:
          return const CommunityLikesResult.premiumRequired();
        case CommunityLikesFailure.other:
          rethrow;
      }
    }

    final ranked = parseCommunityLikesRows(rows);
    final counts = ranked.take(pageSize).toList(growable: false);
    if (counts.isEmpty) return const CommunityLikesResult.ranked([]);

    final gamesById = await _resolveGames([for (final c in counts) c.gameId]);
    return CommunityLikesResult.ranked(
      assembleCommunityLikesEntries(
        counts: counts,
        gamesById: gamesById,
        rankOffset: after?.rank ?? 0,
      ),
      nextCursor:
          !legacyPreview && ranked.length > pageSize
              ? (
                likes: counts.last.likes,
                gameId: counts.last.gameId,
                rank: (after?.rank ?? 0) + counts.length,
              )
              : null,
    );
  }

  /// Broadcast games first (one batched read), then whatever is left through
  /// the Gamebase archive, where Miniatures and explorer games live. An id
  /// neither knows is left out. The card hydrates its own PGN, so the
  /// broadcast read leaves it out.
  Future<Map<String, GamesTourModel>> _resolveGames(List<String> ids) async {
    final byId = <String, GamesTourModel>{};
    try {
      final rows = await client()
          .from('games')
          .select(_rankedGameColumns)
          .inFilter('id', ids);
      for (final raw in rows) {
        try {
          final game = Games.fromJson(Map<String, dynamic>.from(raw));
          final model = GamesTourModel.fromGame(game);
          final event = model.tourName?.trim();
          byId[game.id] =
              (event != null && event.isNotEmpty && model.eventName == null)
                  ? model.copyWith(eventName: event)
                  : model;
        } catch (e) {
          // A row without two named players cannot be drawn; skip it.
          debugPrint('[CommunityLikes] skipped unreadable game: $e');
        }
      }
    } catch (e) {
      debugPrint('[CommunityLikes] broadcast games lookup failed: $e');
    }

    final missing = [
      for (final id in ids)
        if (!byId.containsKey(id)) id,
    ];
    if (missing.isEmpty) return byId;

    final archived = await Future.wait(
      missing.map((id) async {
        try {
          final game = await gamebase.getGameById(id);
          return game == null ? null : communityLikesGamebaseCard(game);
        } catch (_) {
          return null;
        }
      }),
    );
    for (var i = 0; i < missing.length; i++) {
      final game = archived[i];
      if (game != null) byId[missing[i]] = game;
    }
    return byId;
  }
}

/// The broadcast columns a ranked card draws, PGN and search terms left out.
const String _rankedGameColumns = '''
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

/// A Gamebase archive game as a desktop game card. Ported from the phone's
/// `mapGamebaseGameToGamesTourModel`.
@visibleForTesting
GamesTourModel communityLikesGamebaseCard(GamebaseGame game) {
  final data = game.data ?? const <String, dynamic>{};
  final mdRaw = data['md'] ?? data['metadata'];
  final md =
      mdRaw is Map
          ? Map<String, dynamic>.from(mdRaw)
          : const <String, dynamic>{};

  String field(String key) => (md[key]?.toString() ?? '').trim();

  String federation(String prefix) {
    for (final key in const [
      'Fed',
      'Federation',
      'Country',
      'FideFederation',
      'Nationality',
    ]) {
      final value = field('$prefix$key');
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  int rating(String key) {
    final raw = md[key];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  PlayerCard side(String prefix, String? gamebasePlayerId) {
    final name = field(prefix);
    final fed = federation(prefix);
    return PlayerCard(
      name: name.isNotEmpty ? name : prefix,
      federation: fed,
      title: ChessTitleUtils.normalize(field('${prefix}Title')),
      rating: rating('${prefix}Elo'),
      countryCode: fed,
      team: null,
      fideId: int.tryParse(field('${prefix}FideId')),
      gamebasePlayerId: gamebasePlayerId?.trim(),
    );
  }

  final white = side('White', game.whitePlayerId);
  final black = side('Black', game.blackPlayerId);
  final rawResult = field('Result');
  final status = GameStatus.fromString(
    rawResult.isNotEmpty ? rawResult : game.resultDisplay,
  );
  final event = field('Event');
  final tourId =
      (data['tour_id']?.toString() ??
              data['tournament_id']?.toString() ??
              (event.isNotEmpty ? event : 'Gamebase'))
          .trim();
  final eco = field('ECO');
  final opening = field('Opening');
  final roundSlug = eco.isNotEmpty ? eco : game.timeControlDisplay;
  final pgnResult = switch (status) {
    GameStatus.whiteWins => '1-0',
    GameStatus.blackWins => '0-1',
    GameStatus.draw => '1/2-1/2',
    GameStatus.ongoing || GameStatus.unknown => '*',
  };

  return GamesTourModel(
    gameId: game.id,
    source: GameSource.gamebase,
    whitePlayer: white,
    blackPlayer: black,
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'gamebase',
    roundSlug: roundSlug.isNotEmpty ? roundSlug : null,
    tourId: tourId,
    eventName: event.isNotEmpty ? event : null,
    pgn:
        buildPgnFromGamebaseData(data) ??
        '[Event "$tourId"]\n[White "${white.name}"]\n'
            '[Black "${black.name}"]\n[Result "$pgnResult"]\n\n$pgnResult',
    lastMoveTime: game.date,
    eco: eco.isNotEmpty ? eco : null,
    openingName: opening.isNotEmpty ? opening : null,
  );
}
