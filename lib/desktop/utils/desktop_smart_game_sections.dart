import 'package:intl/intl.dart';

import 'package:chessever/desktop/utils/game_date_groups.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

class DesktopSmartGameSection {
  const DesktopSmartGameSection({
    required this.key,
    required this.title,
    required this.dateLabel,
    required this.games,
    required this.liveCount,
    required this.eventAverageRating,
    required this.latestActivity,
    required this.sortDay,
    this.timeControlLabel,
  });

  final String key;
  final String title;
  final String dateLabel;
  final List<GamesTourModel> games;
  final int liveCount;
  final int eventAverageRating;
  final DateTime latestActivity;
  final DateTime sortDay;
  final String? timeControlLabel;

  int get gameCount => games.length;
  bool get hasLiveGames => liveCount > 0;
}

List<DesktopSmartGameSection> buildDesktopSmartGameSections(
  List<GamesTourModel> games, {
  required PremiumGamesType type,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final sectionsByKey = <String, _MutableSmartGameSection>{};

  for (final game in games) {
    final day = _gameDay(game);
    if (day != null && day.isAfter(today)) {
      continue;
    }

    final dateLabel = _formatSmartSectionDate(day, now: clock);
    final dateKey =
        day == null ? '0000-00-00' : DateFormat('yyyy-MM-dd').format(day);
    final isGmDateSection = type == PremiumGamesType.gm;
    final key =
        isGmDateSection ? 'gm-date::$dateKey' : '${_eventKey(game)}::$dateKey';
    final section = sectionsByKey.putIfAbsent(
      key,
      () => _MutableSmartGameSection(
        key: key,
        title: isGmDateSection ? dateLabel : _eventTitle(game),
        dateLabel: isGmDateSection ? '2500+ average rating' : dateLabel,
        sortDay: day ?? DateTime(0),
        timeControlLabel:
            isGmDateSection ? null : _timeControlLabel(game.timeControl),
      ),
    );
    section.add(game);
  }

  final sections = [
    for (final section in sectionsByKey.values) section.freeze(),
  ]..sort((a, b) => _compareSections(a, b, type));

  return sections;
}

class _MutableSmartGameSection {
  _MutableSmartGameSection({
    required this.key,
    required this.title,
    required this.dateLabel,
    required this.sortDay,
    required this.timeControlLabel,
  });

  final String key;
  final String title;
  final String dateLabel;
  final DateTime sortDay;
  final String? timeControlLabel;
  final List<GamesTourModel> games = <GamesTourModel>[];
  int liveCount = 0;
  int eventAverageRating = 0;
  DateTime latestActivity = DateTime(0);

  void add(GamesTourModel game) {
    games.add(game);
    if (game.effectiveGameStatus == GameStatus.ongoing) {
      liveCount += 1;
    }
    final rating = game.avgElo ?? desktopGameAverageRating(game);
    if (rating > eventAverageRating) {
      eventAverageRating = rating;
    }
    final activity = game.lastMoveTime ?? game.bucketDate ?? DateTime(0);
    if (activity.isAfter(latestActivity)) {
      latestActivity = activity;
    }
  }

  DesktopSmartGameSection freeze() {
    final sortedGames = games.toList(growable: false)..sort(_compareGames);
    return DesktopSmartGameSection(
      key: key,
      title: title,
      dateLabel: dateLabel,
      games: sortedGames,
      liveCount: liveCount,
      eventAverageRating: eventAverageRating,
      latestActivity: latestActivity,
      sortDay: sortDay,
      timeControlLabel: timeControlLabel,
    );
  }
}

int _compareSections(
  DesktopSmartGameSection a,
  DesktopSmartGameSection b,
  PremiumGamesType type,
) {
  if (type == PremiumGamesType.gm) {
    final dayCompare = b.sortDay.compareTo(a.sortDay);
    if (dayCompare != 0) return dayCompare;

    final liveCompare = b.liveCount.compareTo(a.liveCount);
    if (liveCompare != 0) return liveCompare;

    final ratingCompare = b.eventAverageRating.compareTo(a.eventAverageRating);
    if (ratingCompare != 0) return ratingCompare;

    return b.latestActivity.compareTo(a.latestActivity);
  }

  if (type == PremiumGamesType.live || a.hasLiveGames != b.hasLiveGames) {
    final liveCompare = b.liveCount.compareTo(a.liveCount);
    if (liveCompare != 0) return liveCompare;
  }

  final dayCompare = b.sortDay.compareTo(a.sortDay);
  if (dayCompare != 0) return dayCompare;

  final ratingCompare = b.eventAverageRating.compareTo(a.eventAverageRating);
  if (ratingCompare != 0) return ratingCompare;

  final activityCompare = b.latestActivity.compareTo(a.latestActivity);
  if (activityCompare != 0) return activityCompare;

  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

int _compareGames(GamesTourModel a, GamesTourModel b) {
  final liveCompare = _liveRank(b).compareTo(_liveRank(a));
  if (liveCompare != 0) return liveCompare;

  final dayCompare = (b.bucketDate ?? DateTime(0)).compareTo(
    a.bucketDate ?? DateTime(0),
  );
  if (dayCompare != 0) return dayCompare;

  final boardCompare = _boardRank(a).compareTo(_boardRank(b));
  if (boardCompare != 0) return boardCompare;

  final ratingCompare = desktopGameAverageRating(
    b,
  ).compareTo(desktopGameAverageRating(a));
  if (ratingCompare != 0) return ratingCompare;

  final moveCompare = (b.lastMoveTime ?? DateTime(0)).compareTo(
    a.lastMoveTime ?? DateTime(0),
  );
  if (moveCompare != 0) return moveCompare;

  return a.gameId.compareTo(b.gameId);
}

int _liveRank(GamesTourModel game) {
  return game.effectiveGameStatus == GameStatus.ongoing ? 1 : 0;
}

int _boardRank(GamesTourModel game) {
  return game.boardNr == null || game.boardNr! <= 0 ? 1 << 20 : game.boardNr!;
}

DateTime? _gameDay(GamesTourModel game) {
  final raw = game.bucketDate;
  if (raw == null) return null;
  final local = raw.toLocal();
  return DateTime(local.year, local.month, local.day);
}

String _eventKey(GamesTourModel game) {
  final eventName = game.eventName?.trim();
  if (eventName != null && eventName.isNotEmpty) {
    return 'event:${eventName.toLowerCase()}';
  }
  final tourId = game.tourId.trim();
  if (tourId.isNotEmpty) return 'tour:$tourId';
  final title = _eventTitle(game).toLowerCase();
  return 'title:${title.replaceAll(RegExp(r'\s+'), '-')}';
}

String _eventTitle(GamesTourModel game) {
  final title = _firstNonBlank([
    game.eventName,
    game.tourName,
    game.tourSlug,
    game.roundSlug,
  ]);
  if (title == null) return 'Unknown event';
  return _humanizeSlug(title);
}

String? _firstNonBlank(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String _humanizeSlug(String value) {
  final trimmed = value.trim();
  if (trimmed.contains(' ')) return trimmed;

  final words =
      trimmed
          .replaceAll(RegExp(r'[-_]+'), ' ')
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toList();
  if (words.isEmpty) return trimmed;

  return words
      .map((word) {
        if (word.length <= 3 && word.toUpperCase() == word) return word;
        if (RegExp(r'^\d').hasMatch(word)) return word;
        return word.substring(0, 1).toUpperCase() + word.substring(1);
      })
      .join(' ');
}

String _formatSmartSectionDate(DateTime? date, {required DateTime now}) {
  if (date == null) return 'Unknown date';
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final day = DateTime(date.year, date.month, date.day);
  if (day == today) return 'Today';
  if (day == yesterday) return 'Yesterday';
  return DateFormat('d MMM yyyy').format(date);
}

String? _timeControlLabel(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  final lower = normalized.toLowerCase();
  return switch (lower) {
    'standard' || 'classical' => 'Classical',
    'rapid' => 'Rapid',
    'blitz' => 'Blitz',
    _ => _humanizeSlug(normalized),
  };
}
