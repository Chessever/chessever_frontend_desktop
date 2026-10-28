import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:intl/intl.dart';

/// Rating substituted for a side with no rating when ranking miniatures.
const int miniatureMissingRatingFallback = 1800;

/// Section key for miniatures with no date.
const String kMiniatureUnknownDateKey = '0000-00-00';

extension GamebaseMiniatureRanking on GamebaseMiniature {
  /// Average of both sides, each missing or zero rating replaced by
  /// [miniatureMissingRatingFallback].
  int get effectiveAverageRating =>
      miniatureEffectiveAverageRating(whiteElo, blackElo);
}

int miniatureEffectiveAverageRating(int? whiteElo, int? blackElo) {
  final white =
      whiteElo != null && whiteElo > 0
          ? whiteElo
          : miniatureMissingRatingFallback;
  final black =
      blackElo != null && blackElo > 0
          ? blackElo
          : miniatureMissingRatingFallback;
  return ((white + black) / 2).round();
}

/// The canonical Miniatures order: UTC calendar day descending, then average
/// rating descending, then game id ascending. Undated games sort last.
List<GamebaseMiniature> orderMiniaturesByDayAndAverageRating(
  Iterable<GamebaseMiniature> games,
) {
  final ordered = games.toList(growable: false);
  ordered.sort(
    (left, right) => _compareDayRatingId(
      leftDay: miniatureUtcDayKey(left.date),
      rightDay: miniatureUtcDayKey(right.date),
      leftRating: left.effectiveAverageRating,
      rightRating: right.effectiveAverageRating,
      leftId: left.gameId,
      rightId: right.gameId,
    ),
  );
  return ordered;
}

/// The same order over board-ready models, which carry the miniature date on
/// [GamesTourModel.lastMoveTime] and each side's rating on its player card.
int compareMiniatureGamesByDayAndAverageRating(
  GamesTourModel left,
  GamesTourModel right,
) {
  return _compareDayRatingId(
    leftDay: miniatureUtcDayKey(left.lastMoveTime),
    rightDay: miniatureUtcDayKey(right.lastMoveTime),
    leftRating: miniatureEffectiveAverageRating(
      left.whitePlayer.rating,
      left.blackPlayer.rating,
    ),
    rightRating: miniatureEffectiveAverageRating(
      right.whitePlayer.rating,
      right.blackPlayer.rating,
    ),
    leftId: left.gameId,
    rightId: right.gameId,
  );
}

int _compareDayRatingId({
  required int? leftDay,
  required int? rightDay,
  required int leftRating,
  required int rightRating,
  required String leftId,
  required String rightId,
}) {
  if (leftDay != rightDay) {
    if (leftDay == null) return 1;
    if (rightDay == null) return -1;
    return rightDay.compareTo(leftDay);
  }
  final ratingOrder = rightRating.compareTo(leftRating);
  if (ratingOrder != 0) return ratingOrder;
  return leftId.compareTo(rightId);
}

/// `yyyymmdd` of the game's UTC calendar day. Bare PGN dates are stored at
/// UTC midnight, so reading them back in local time would shift every game a
/// day west of Greenwich.
int? miniatureUtcDayKey(DateTime? date) {
  if (date == null) return null;
  final utc = date.toUtc();
  return utc.year * 10000 + utc.month * 100 + utc.day;
}

/// `yyyy-MM-dd` section key from the game's UTC calendar day.
String miniatureUtcDateKey(DateTime? date) {
  if (date == null) return kMiniatureUnknownDateKey;
  return DateFormat('yyyy-MM-dd').format(date.toUtc());
}

/// Section label for a [miniatureUtcDateKey]. The key is a wall-clock day and
/// is compared against the viewer's LOCAL calendar day, exactly as the
/// today-only access rule compares them, so a section labelled Today is the
/// section a free user can open.
///
/// Today and Yesterday use calendar equality rather than `difference().inDays`,
/// which reads a 23-hour gap across a daylight-saving change as zero days and
/// would label yesterday's games Today.
String formatMiniatureDayHeader(String dateKey, {DateTime? now}) {
  if (dateKey == kMiniatureUnknownDateKey) return 'Unknown date';
  final date = DateTime.tryParse(dateKey);
  if (date == null) return dateKey;
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final yesterday = DateTime(clock.year, clock.month, clock.day - 1);
  final target = DateTime(date.year, date.month, date.day);
  if (target == today) return 'Today';
  if (target == yesterday) return 'Yesterday';
  return DateFormat('EEEE, MMM d, y').format(target);
}

class MiniatureDayGroup {
  const MiniatureDayGroup({
    required this.key,
    required this.label,
    required this.games,
  });

  final String key;
  final String label;
  final List<GamesTourModel> games;
}

/// Groups [games] by UTC calendar day, newest day first, undated last. Order
/// inside a day is preserved.
List<MiniatureDayGroup> buildMiniatureDayGroups(
  List<GamesTourModel> games, {
  DateTime? now,
}) {
  final grouped = <String, List<GamesTourModel>>{};
  for (final game in games) {
    grouped
        .putIfAbsent(
          miniatureUtcDateKey(game.lastMoveTime),
          () => <GamesTourModel>[],
        )
        .add(game);
  }
  final keys =
      grouped.keys.toList()..sort((a, b) {
        if (a == kMiniatureUnknownDateKey) return 1;
        if (b == kMiniatureUnknownDateKey) return -1;
        return b.compareTo(a);
      });
  return [
    for (final key in keys)
      MiniatureDayGroup(
        key: key,
        label: formatMiniatureDayHeader(key, now: now),
        games: grouped[key]!,
      ),
  ];
}
