import 'package:intl/intl.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class DesktopGameDateGroup {
  const DesktopGameDateGroup({
    required this.key,
    required this.label,
    required this.games,
  });

  final String key;
  final String label;
  final List<GamesTourModel> games;
}

List<DesktopGameDateGroup> buildDesktopGameDateGroups(
  List<GamesTourModel> games, {
  DateTime? now,
  bool includeToday = false,
  bool excludeFuture = false,
}) {
  const unknownKey = '0000-00-00';
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final todayKey = DateFormat('yyyy-MM-dd').format(today);
  final byDay = <String, List<GamesTourModel>>{};

  if (includeToday) {
    byDay[todayKey] = <GamesTourModel>[];
  }

  for (final game in games) {
    final date = game.bucketDate;
    final day = date == null ? null : DateTime(date.year, date.month, date.day);
    if (excludeFuture && day != null && day.isAfter(today)) {
      continue;
    }
    final key = day == null ? unknownKey : DateFormat('yyyy-MM-dd').format(day);
    byDay.putIfAbsent(key, () => <GamesTourModel>[]).add(game);
  }

  for (final dayGames in byDay.values) {
    dayGames.sort(_compareGamesByAverageRatingThenTime);
  }

  final keys =
      byDay.keys.toList()..sort((a, b) {
        if (a == unknownKey) return 1;
        if (b == unknownKey) return -1;
        return b.compareTo(a);
      });
  return [
    for (final key in keys)
      DesktopGameDateGroup(
        key: key,
        label: _formatDesktopGameDateHeader(key, now: clock),
        games: byDay[key]!,
      ),
  ];
}

int _compareGamesByAverageRatingThenTime(GamesTourModel a, GamesTourModel b) {
  final eloCompare = _averageRating(b).compareTo(_averageRating(a));
  if (eloCompare != 0) return eloCompare;

  return (b.bucketDate ?? DateTime(0)).compareTo(a.bucketDate ?? DateTime(0));
}

int desktopGameAverageRating(GamesTourModel game) => _averageRating(game);

int _averageRating(GamesTourModel game) {
  final white = game.whitePlayer.rating;
  final black = game.blackPlayer.rating;
  if (white == 0 && black == 0) return 0;
  if (white == 0) return black;
  if (black == 0) return white;
  return (white + black) ~/ 2;
}

String _formatDesktopGameDateHeader(String dateKey, {DateTime? now}) {
  if (dateKey == '0000-00-00') return 'Unknown date';
  final date = DateTime.tryParse(dateKey);
  if (date == null) return dateKey;

  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final day = DateTime(date.year, date.month, date.day);
  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return DateFormat('MMM d, yyyy').format(date);
}
