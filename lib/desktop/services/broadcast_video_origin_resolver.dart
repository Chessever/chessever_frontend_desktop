import 'package:supabase_flutter/supabase_flutter.dart';

import 'broadcast_video_streams.dart';

/// A mirror/Combined board owns no copy of its original section's video
/// configuration. Resolve only the unique original game in the same event,
/// scheduled round and player order. Never pick an arbitrary sibling section.
class BroadcastVideoOriginResolver {
  BroadcastVideoOriginResolver(
    this.client, {
    this.timeout = const Duration(seconds: 8),
  });

  final SupabaseClient client;
  final Duration timeout;

  static const _projection =
      'id,tour_id,round_id,player_white,player_black,'
      'round:rounds!games_round_id_fkey!inner(starts_at),'
      'tour:tours!games_tour_id_fkey!inner(group_broadcast_id,is_mirror)';

  Future<BroadcastVideoScope?> resolve(
    BroadcastVideoScope scope,
    String gameId,
  ) => _resolve(scope, gameId).timeout(timeout);

  Future<BroadcastVideoScope?> _resolve(
    BroadcastVideoScope scope,
    String gameId,
  ) async {
    if (gameId.isEmpty || scope.tourId.isEmpty) return null;
    final rows = await client
        .from('games')
        .select(_projection)
        .eq('id', gameId)
        .eq('tour_id', scope.tourId)
        .limit(1);
    if (rows.length != 1) return null;
    final game = rows.single;
    if (scope.hasRound && game['round_id'] != scope.effectiveRoundId) {
      return null;
    }
    final tour = game['tour'];
    final round = game['round'];
    if (tour is! Map || round is! Map || tour['is_mirror'] != true) {
      return null;
    }
    final group = tour['group_broadcast_id'];
    final startsAt = round['starts_at'];
    final white = game['player_white'];
    final black = game['player_black'];
    if (group is! String ||
        group.isEmpty ||
        startsAt is! String ||
        DateTime.tryParse(startsAt) == null ||
        white is! String ||
        white.isEmpty ||
        black is! String ||
        black.isEmpty) {
      return null;
    }
    // Enumerate the tiny original-round set first. Filtering the full games
    // catalog through joined tour/date predicates can hit PostgREST's normal
    // client statement timeout even though the same query is fast as admin.
    final rounds = await client
        .from('rounds')
        .select(
          'id,tour_id,tour:tours!rounds_tour_id_fkey!inner(group_broadcast_id,is_mirror)',
        )
        .eq('tour.group_broadcast_id', group)
        .eq('tour.is_mirror', false)
        .eq('starts_at', startsAt)
        .limit(65);
    if (rounds.isEmpty || rounds.length > 64) return null;
    final roundIds = <String>[];
    for (final originalRound in rounds) {
      final id = originalRound['id'];
      final owner = originalRound['tour'];
      if (id is! String ||
          id.isEmpty ||
          owner is! Map ||
          owner['group_broadcast_id'] != group ||
          owner['is_mirror'] != false) {
        return null;
      }
      roundIds.add(id);
    }
    final candidates = await client
        .from('games')
        .select(_projection)
        .inFilter('round_id', roundIds)
        .eq('tour.group_broadcast_id', group)
        .eq('tour.is_mirror', false)
        .eq('round.starts_at', startsAt)
        .eq('player_white', white)
        .eq('player_black', black)
        .limit(2);
    // Two rows suffice to prove ambiguity. Neither names nor group order
    // alone establish the source; an uncertain match must stay video-free.
    if (candidates.length != 1) return null;
    final original = candidates.single;
    final originalTour = original['tour'];
    final originalRound = original['round'];
    final tourId = original['tour_id'];
    final roundId = original['round_id'];
    if (originalTour is! Map ||
        originalRound is! Map ||
        originalTour['is_mirror'] != false ||
        originalTour['group_broadcast_id'] != group ||
        DateTime.tryParse('${originalRound['starts_at']}') !=
            DateTime.tryParse(startsAt) ||
        original['player_white'] != white ||
        original['player_black'] != black ||
        tourId is! String ||
        tourId.isEmpty ||
        tourId == scope.tourId ||
        roundId is! String ||
        roundId.isEmpty) {
      return null;
    }
    return BroadcastVideoScope(tourId: tourId, roundId: roundId);
  }
}
