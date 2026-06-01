import 'package:intl/intl.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class DesktopGameDateGroup {
  const DesktopGameDateGroup({required this.label, required this.games});

  final String label;
  final List<GamesTourModel> games;
}

List<DesktopGameDateGroup> buildDesktopGameDateGroups(
  List<GamesTourModel> games,
) {
  const unknownKey = '0000-00-00';
  final byDay = <String, List<GamesTourModel>>{};
  for (final game in games) {
    final date = game.bucketDate;
    final key =
        date == null ? unknownKey : DateFormat('yyyy-MM-dd').format(date);
    byDay.putIfAbsent(key, () => <GamesTourModel>[]).add(game);
  }

  final keys = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final key in keys)
      DesktopGameDateGroup(
        label: _formatDesktopGameDateHeader(key),
        games: byDay[key]!,
      ),
  ];
}

String _formatDesktopGameDateHeader(String dateKey) {
  if (dateKey == '0000-00-00') return 'Unknown date';
  final date = DateTime.tryParse(dateKey);
  if (date == null) return dateKey;

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final day = DateTime(date.year, date.month, date.day);
  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return DateFormat('EEEE, MMM d').format(date);
}
