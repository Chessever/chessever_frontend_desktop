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

/// Like web CombinedHall, one time bucket contains separate source grids.
/// The generated header never replaces a game's real tour or round identity.
class CombinedRoundBucket {
  const CombinedRoundBucket({required this.round, required this.sources});
  final GamesAppBarModel round;
  final List<GamesTourSourceSection> sources;

  List<GamesTourModel> get games => [
    for (final source in sources) ...source.games,
  ];
}

List<CombinedRoundBucket> buildCombinedRoundBuckets(
  List<CombinedRoundSection> sections, {
  required String eventId,
}) {
  final buckets = <String, List<CombinedRoundSection>>{};
  for (final section in sections) {
    final start = section.startsAt?.toUtc().microsecondsSinceEpoch;
    // An unknown, undated round must not merge with unrelated undated rounds.
    final key = start == null ? 'round:${section.round.id}' : 'start:$start';
    (buckets[key] ??= []).add(section);
  }
  return [
    for (final entry in buckets.entries)
      CombinedRoundBucket(
        round: GamesAppBarModel(
          id: 'combined:$eventId:${entry.key}',
          name:
              entry.value.every(
                    (source) =>
                        source.round.name == entry.value.first.round.name,
                  )
                  ? entry.value.first.round.name
                  : 'Games',
          startsAt: entry.value.first.startsAt,
          roundStatus: entry.value.first.round.roundStatus,
          sourceRoundIds: [for (final source in entry.value) source.round.id],
        ),
        sources: [
          for (final source in entry.value)
            GamesTourSourceSection(
              roundId: source.round.id,
              label: source.category.label,
              games: source.games,
            ),
        ],
      ),
  ];
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
