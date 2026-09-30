import 'package:chessever/repository/supabase/round/round.dart';

/// Chooses the first round worth painting for a tournament.
///
/// Explicit navigation wins, followed by a live round and then the newest
/// round that has started. Pre-published future rounds must not displace the
/// current round.
String? initialTourRoundId({
  required List<Round> rounds,
  required DateTime now,
  String? requestedRoundId,
  List<String> liveRoundIds = const <String>[],
}) {
  if (rounds.isEmpty) return null;
  if (rounds.any((round) => round.id == requestedRoundId)) {
    return requestedRoundId;
  }

  int newestFirst(Round a, Round b) {
    final date = (b.startsAt ?? b.createdAt).compareTo(
      a.startsAt ?? a.createdAt,
    );
    return date != 0 ? date : a.id.compareTo(b.id);
  }

  final live =
      rounds.where((round) => liveRoundIds.contains(round.id)).toList()
        ..sort(newestFirst);
  if (live.isNotEmpty) return live.first.id;

  final started =
      rounds
          .where(
            (round) => round.startsAt != null && !round.startsAt!.isAfter(now),
          )
          .toList()
        ..sort(newestFirst);
  if (started.isNotEmpty) return started.first.id;

  // Unknown start times need activity evidence from the repository fallback;
  // guessing here can select an unpublished or unrelated stage.
  if (rounds.any((round) => round.startsAt == null)) return null;

  final upcoming = rounds.toList()..sort((a, b) => -newestFirst(a, b));
  return upcoming.first.id;
}
