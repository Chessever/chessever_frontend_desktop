import 'package:chessever/desktop/combined/combined_round_sections.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class GamesTourSourceSection {
  const GamesTourSourceSection({
    required this.roundId,
    required this.label,
    required this.games,
  });
  final String roundId;
  final String label;
  final List<GamesTourModel> games;
}

/// One round card: the same round of every category that plays it, each
/// category in its own source grid. The generated header never replaces a
/// game's real tour or round identity.
class CombinedRoundBucket {
  const CombinedRoundBucket({required this.round, required this.sources});
  final GamesAppBarModel round;
  final List<GamesTourSourceSection> sources;

  List<GamesTourModel> get games => [
    for (final source in sources) ...source.games,
  ];
}

/// Groups [sections] into round cards, in the order
/// `buildCombinedRoundSections` already gave them. A card is one
/// [combinedRoundKey]: the same round name on the same day, as on the phone.
List<CombinedRoundBucket> buildCombinedRoundBuckets(
  List<CombinedRoundSection> sections, {
  required String eventId,
  Set<String>? loadedRoundIds,
  Set<String> failedRoundIds = const {},
}) {
  final buckets = <String, List<CombinedRoundSection>>{};
  for (final section in sections) {
    (buckets[combinedRoundKey(section)] ??= []).add(section);
  }
  return [
    for (final entry in buckets.entries)
      CombinedRoundBucket(
        round: GamesAppBarModel(
          id: 'combined:$eventId:${entry.key}',
          name: combinedCardTitle(entry.value),
          startsAt: _earliestStart(entry.value),
          roundStatus: _mostActiveStatus(entry.value),
          sourceRoundIds: [for (final source in entry.value) source.round.id],
        ),
        sources: [
          for (final source in entry.value)
            GamesTourSourceSection(
              roundId: source.round.id,
              label:
                  source.games.isNotEmpty
                      ? source.category.label
                      : '${source.category.label} • ${failedRoundIds.contains(source.round.id)
                          ? 'Unable to load games. Retry to continue.'
                          : loadedRoundIds != null && !loadedRoundIds.contains(source.round.id)
                          ? 'Loading games…'
                          : 'No games yet'}',
              games: source.games,
            ),
        ],
      ),
  ];
}

/// A round card's title: what its categories have in common, then the round
/// ("Group Stage · Round 5", "Blitz Tiebreak · Round 9"). The round name
/// alone when the categories share nothing.
String combinedCardTitle(List<CombinedRoundSection> sections) {
  final round = sections.first.round.name;
  final shared = combinedCardLabel([
    for (final section in sections) section.category.label,
  ]);
  return shared == null ? round : '$shared · $round';
}

/// What a round card's categories have in common, for its title: the one
/// category's label ("Blitz Tiebreak"), or the leading part every label
/// shares up to a separator ("Group Stage" for "Group Stage | A" and
/// "Group Stage | B"). Null when they share nothing.
String? combinedCardLabel(List<String> labels) {
  final distinct = labels.toSet().toList();
  if (distinct.isEmpty) return null;
  if (distinct.length == 1) return distinct.single;
  var shared = distinct.first;
  for (final other in distinct.skip(1)) {
    var i = 0;
    while (i < shared.length && i < other.length && shared[i] == other[i]) {
      i++;
    }
    shared = shared.substring(0, i);
  }
  // Cut back to the last separator, so "Group Stage | " never shows as a
  // half word.
  final cut = shared.lastIndexOf(RegExp(r'\s*[|:–—]\s*'));
  if (cut <= 0) return null;
  final head = shared.substring(0, cut).trim();
  return head.isEmpty ? null : head;
}

/// The card starts when its first category does.
DateTime? _earliestStart(List<CombinedRoundSection> sections) {
  DateTime? earliest;
  for (final section in sections) {
    final start = section.startsAt;
    if (start != null && (earliest == null || start.isBefore(earliest))) {
      earliest = start;
    }
  }
  return earliest;
}

/// The most active status any of the card's categories has.
RoundStatus _mostActiveStatus(List<CombinedRoundSection> sections) {
  bool any(RoundStatus status) =>
      sections.any((section) => section.round.roundStatus == status);
  if (any(RoundStatus.live)) return RoundStatus.live;
  if (any(RoundStatus.ongoing)) return RoundStatus.ongoing;
  if (any(RoundStatus.upcoming)) return RoundStatus.upcoming;
  return RoundStatus.completed;
}

/// Vertical movement follows the independently laid-out source grids. A
/// partial last row never borrows cells from the next source group.
int? combinedVerticalGameIndex(
  List<GamesTourSourceSection> sources,
  int index,
  int columns,
  bool forward,
) {
  assert(columns > 0);
  var offset = 0;
  for (var i = 0; i < sources.length; i++) {
    final count = sources[i].games.length;
    if (index >= offset + count) {
      offset += count;
      continue;
    }
    if (index < offset) return null;
    final local = index - offset;
    final row = local ~/ columns;
    final column = local % columns;
    final targetRow = row + (forward ? 1 : -1);
    if (targetRow >= 0 && targetRow <= (count - 1) ~/ columns) {
      return offset + (targetRow * columns + column).clamp(0, count - 1);
    }
    if (forward && i + 1 < sources.length) {
      return offset + count + column.clamp(0, sources[i + 1].games.length - 1);
    }
    if (!forward && i > 0) {
      final previous = sources[i - 1].games.length;
      return offset -
          previous +
          (((previous - 1) ~/ columns) * columns + column).clamp(
            0,
            previous - 1,
          );
    }
    return null;
  }
  return null;
}
