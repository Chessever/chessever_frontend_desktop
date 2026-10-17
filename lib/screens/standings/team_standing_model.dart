import 'package:chessever/repository/supabase/tour/published_tiebreak.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';

/// One row in the team-event "Standings" tab: a team's collected score plus its
/// players (the same individual [PlayerStandingModel]s shown on the "Players"
/// tab), revealed when the row is expanded.
class TeamStandingModel {
  final String teamName;
  final int rank;

  /// When set, totals and ordering are the published table after this round.
  final int? officialRound;

  /// Match points — 2 win / 1 draw / 0 loss, counted only for completed
  /// matches. Primary ranking metric (chess team-event standard).
  final num matchPoints;

  /// Board (game) points — sum of finished individual board results. Tiebreak.
  final double gamePoints;

  final int matchesWon;
  final int matchesDrawn;
  final int matchesLost;

  /// Finished boards contributing to [gamePoints]; for display/debug.
  final int boardsPlayed;

  /// Values and priority copied from the organizer, never recomputed.
  final List<PublishedTiebreak> tiebreaks;

  final List<PlayerStandingModel> players;

  const TeamStandingModel({
    required this.teamName,
    required this.rank,
    this.officialRound,
    this.tiebreaks = const [],
    required this.matchPoints,
    required this.gamePoints,
    required this.matchesWon,
    required this.matchesDrawn,
    required this.matchesLost,
    required this.boardsPlayed,
    required this.players,
  });

  /// Board points as a decimal, e.g. 26.5 -> "26.5", 31.0 -> "31".
  String get gamePointsLabel =>
      gamePoints % 1 == 0
          ? gamePoints.toInt().toString()
          : gamePoints.toStringAsFixed(1);

  /// [tiebreaks] without the published match-point and game-point columns
  /// (Chess-Results TB1/TB2, Info64 MP/GP) when they repeat the [matchPoints]
  /// and [gamePoints] the row already shows. Derived tiebreaks such as BH:MP
  /// or EMMSB stay.
  List<PublishedTiebreak> get extraTiebreaks => [
    for (final tiebreak in tiebreaks)
      if (!repeatsShownPoints(tiebreak)) tiebreak,
  ];

  /// Whether [tiebreak] is the published MP or GP column carrying the same
  /// value as [matchPoints] or [gamePoints].
  bool repeatsShownPoints(PublishedTiebreak tiebreak) {
    final description = tiebreak.description;
    final code = tiebreak.extendedCode;
    if (tiebreak.points == matchPoints &&
        (description == 'MP' ||
            code == 'MP' ||
            _publishedMatchPoints.hasMatch(description))) {
      return true;
    }
    return tiebreak.points == gamePoints &&
        (description == 'GP' ||
            code == 'GP' ||
            description == 'points (game-points)');
  }

  static final _publishedMatchPoints = RegExp(r'^Matchpoints \(\d+ for wins');

  /// Tiebreak columns for a table of [teams], in first-seen published order.
  /// A column is dropped only when every team publishing it repeats that
  /// team's own match or game points, so a column never vanishes for some
  /// rows and stays for others.
  static List<PublishedTiebreak> tableTiebreakColumns(
    Iterable<TeamStandingModel> teams,
  ) {
    final definitions = <String, PublishedTiebreak>{};
    final informative = <String>{};
    for (final team in teams) {
      for (final value in team.tiebreaks) {
        definitions.putIfAbsent(value.identity, () => value);
        if (!team.repeatsShownPoints(value)) informative.add(value.identity);
      }
    }
    return [
      for (final entry in definitions.entries)
        if (informative.contains(entry.key)) entry.value,
    ];
  }

  /// Completed matches behind [matchPoints].
  int get matchesPlayed => matchesWon + matchesDrawn + matchesLost;

  /// "W · D · L" record over completed matches.
  String get recordLabel => '$matchesWon · $matchesDrawn · $matchesLost';

  /// Board points per finished board (GP / boards played). Null when the team
  /// has no finished boards yet.
  double? get averageBoardPoints =>
      boardsPlayed > 0 ? gamePoints / boardsPlayed : null;

  /// Compact average for app bars, e.g. "0.65" or "1" / "—".
  String get averageBoardPointsLabel {
    final avg = averageBoardPoints;
    if (avg == null) return '—';
    if (avg % 1 == 0) return avg.toInt().toString();
    // Two decimals is enough for half-point board averages without noise.
    final fixed = avg.toStringAsFixed(2);
    return fixed
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
}
