import 'package:flutter/foundation.dart';

/// Win / draw / loss tally from a single player's point of view.
@immutable
class PlayerResultTally {
  const PlayerResultTally({this.wins = 0, this.draws = 0, this.losses = 0});

  final int wins;
  final int draws;
  final int losses;

  int get games => wins + draws + losses;

  /// Score as a 0..1 fraction (win = 1, draw = 0.5).
  double get score {
    final total = games;
    if (total == 0) return 0;
    return (wins + draws * 0.5) / total;
  }

  /// Score percentage, or null when there are no games.
  double? get scorePercent => games == 0 ? null : score * 100;

  PlayerResultTally operator +(PlayerResultTally other) {
    return PlayerResultTally(
      wins: wins + other.wins,
      draws: draws + other.draws,
      losses: losses + other.losses,
    );
  }

  static const empty = PlayerResultTally();
}

/// One rating observation on a date (deduplicated to the latest per day).
@immutable
class PlayerRatingSpot {
  const PlayerRatingSpot({required this.date, required this.rating});

  final DateTime date;
  final int rating;
}

@immutable
class PlayerOpeningStat {
  const PlayerOpeningStat({
    required this.eco,
    required this.name,
    required this.tally,
  });

  final String eco;
  final String? name;
  final PlayerResultTally tally;
}

@immutable
class PlayerOpponentStat {
  const PlayerOpponentStat({
    required this.name,
    required this.tally,
    this.averageRating,
  });

  final String name;
  final PlayerResultTally tally;
  final int? averageRating;
}

@immutable
class PlayerYearStat {
  const PlayerYearStat({required this.year, required this.tally});

  final int year;
  final PlayerResultTally tally;
}

@immutable
class PlayerLengthBucket {
  const PlayerLengthBucket({required this.label, required this.count});

  final String label;
  final int count;
}

@immutable
class PlayerTimeControlStat {
  const PlayerTimeControlStat({required this.category, required this.count});

  final String category;
  final int count;
}

/// Everything the Stats dashboard needs, computed locally from the player's
/// combined resqlite database in a handful of GROUP BY queries.
@immutable
class PlayerStatsSnapshot {
  const PlayerStatsSnapshot({
    required this.overall,
    required this.asWhite,
    required this.asBlack,
    required this.ratingSeries,
    required this.openings,
    required this.opponents,
    required this.years,
    required this.lengthBuckets,
    required this.timeControls,
    this.peakRating,
    this.latestRating,
    this.averageOpponentRating,
    this.performanceRating,
  });

  final PlayerResultTally overall;
  final PlayerResultTally asWhite;
  final PlayerResultTally asBlack;
  final List<PlayerRatingSpot> ratingSeries;
  final List<PlayerOpeningStat> openings;
  final List<PlayerOpponentStat> opponents;
  final List<PlayerYearStat> years;
  final List<PlayerLengthBucket> lengthBuckets;
  final List<PlayerTimeControlStat> timeControls;
  final int? peakRating;
  final int? latestRating;
  final int? averageOpponentRating;
  final int? performanceRating;

  int get games => overall.games;
  bool get isEmpty => games == 0;
  int get decisiveGames => overall.wins + overall.losses;

  double? get decisiveRate =>
      games == 0 ? null : (decisiveGames / games) * 100;

  static const empty = PlayerStatsSnapshot(
    overall: PlayerResultTally.empty,
    asWhite: PlayerResultTally.empty,
    asBlack: PlayerResultTally.empty,
    ratingSeries: <PlayerRatingSpot>[],
    openings: <PlayerOpeningStat>[],
    opponents: <PlayerOpponentStat>[],
    years: <PlayerYearStat>[],
    lengthBuckets: <PlayerLengthBucket>[],
    timeControls: <PlayerTimeControlStat>[],
  );
}
