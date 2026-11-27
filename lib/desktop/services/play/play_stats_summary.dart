import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';

/// Won / drawn / lost counts with the derived score.
@immutable
class PlayWdl {
  const PlayWdl({this.wins = 0, this.draws = 0, this.losses = 0});

  final int wins;
  final int draws;
  final int losses;

  int get games => wins + draws + losses;

  /// Points scored: a win is 1, a draw 0.5.
  double get points => wins + draws / 2;

  /// Score as a percentage, 0 to 100. 0 with no games.
  int get scorePct => games == 0 ? 0 : (100 * points / games).round();

  PlayWdl add(double score) => PlayWdl(
    wins: wins + (score == 1 ? 1 : 0),
    draws: draws + (score == 0.5 ? 1 : 0),
    losses: losses + (score == 0 ? 1 : 0),
  );
}

/// One opening family the player reached with one colour.
@immutable
class PlayOpeningStat {
  const PlayOpeningStat({
    required this.name,
    required this.eco,
    required this.record,
    required this.lastPlayed,
  });

  final String name;
  final String? eco;
  final PlayWdl record;
  final DateTime lastPlayed;
}

/// Results against bots of one 200-point strength band.
@immutable
class PlayStrengthBand {
  const PlayStrengthBand({required this.from, required this.record});

  /// Lower bound of the band, e.g. 1400 for 1400 to 1599.
  final int from;
  final PlayWdl record;

  int get to => from + 199;
}

enum PlayStreakKind { win, draw, loss }

@immutable
class PlayStreak {
  const PlayStreak(this.kind, this.length);

  final PlayStreakKind kind;
  final int length;
}

/// Everything the Stats view shows that comes from the game list.
@immutable
class PlayStatsSummary {
  const PlayStatsSummary({
    required this.overall,
    required this.asWhite,
    required this.asBlack,
    required this.whiteOpenings,
    required this.blackOpenings,
    required this.bands,
    required this.byTimeControl,
    required this.form,
    required this.current,
    required this.bestWinStreak,
    required this.bestUnbeaten,
    required this.performance,
    required this.averageOpponent,
    required this.strongestWin,
    required this.activity,
    required this.averageMoves,
  });

  factory PlayStatsSummary.from(List<PlayGameRecord> games, {DateTime? now}) {
    final scored =
        games.where((g) => g.userScore != null).toList()
          ..sort((a, b) => a.playedAt.compareTo(b.playedAt));

    var overall = const PlayWdl();
    var asWhite = const PlayWdl();
    var asBlack = const PlayWdl();
    final white = <String, _OpeningAcc>{};
    final black = <String, _OpeningAcc>{};
    final bands = <int, PlayWdl>{};
    final byTc = <RatedTimeControl, PlayWdl>{};
    var oppSum = 0;
    var oppCount = 0;
    var oppWdl = const PlayWdl();
    PlayGameRecord? strongestWin;
    var bestWin = 0;
    var bestUnbeaten = 0;
    var runWin = 0;
    var runUnbeaten = 0;
    var moveSum = 0;

    for (final g in scored) {
      final s = g.userScore!;
      overall = overall.add(s);
      final isWhite = g.humanColor == 'white';
      if (isWhite) {
        asWhite = asWhite.add(s);
      } else {
        asBlack = asBlack.add(s);
      }
      final family = openingFamily(g.openingName, g.eco);
      if (family != null) {
        final bucket = isWhite ? white : black;
        bucket.putIfAbsent(family, () => _OpeningAcc(family)).add(g, s);
      }
      final opp = g.opponentElo;
      if (opp != null && opp > 0) {
        final from = (opp ~/ 200) * 200;
        bands[from] = (bands[from] ?? const PlayWdl()).add(s);
        oppSum += opp;
        oppCount++;
        oppWdl = oppWdl.add(s);
        if (s == 1 && (strongestWin?.opponentElo ?? 0) < opp) {
          strongestWin = g;
        }
      }
      final tc = playRecordTimeControl(g);
      if (tc != null) byTc[tc] = (byTc[tc] ?? const PlayWdl()).add(s);
      runWin = s == 1 ? runWin + 1 : 0;
      runUnbeaten = s > 0 ? runUnbeaten + 1 : 0;
      if (runWin > bestWin) bestWin = runWin;
      if (runUnbeaten > bestUnbeaten) bestUnbeaten = runUnbeaten;
      moveSum += (g.movesUci.length + 1) ~/ 2;
    }

    PlayStreak? current;
    if (scored.isNotEmpty) {
      final kind = _kindOf(scored.last.userScore!);
      var length = 0;
      for (final g in scored.reversed) {
        if (_kindOf(g.userScore!) != kind) break;
        length++;
      }
      current = PlayStreak(kind, length);
    }

    final avgOpp = oppCount == 0 ? null : (oppSum / oppCount).round();
    int? performance;
    if (avgOpp != null && oppWdl.games > 0) {
      performance =
          (avgOpp + 400 * (oppWdl.wins - oppWdl.losses) / oppWdl.games).round();
    }

    final today = _day(now ?? DateTime.now());
    final activity = <int, int>{};
    for (final g in scored) {
      final ago = today.difference(_day(g.playedAt)).inDays;
      if (ago < 0 || ago >= kPlayActivityDays) continue;
      activity[ago] = (activity[ago] ?? 0) + 1;
    }

    List<PlayOpeningStat> rank(Map<String, _OpeningAcc> m) =>
        m.values.map((a) => a.toStat()).toList()..sort((a, b) {
          final byGames = b.record.games.compareTo(a.record.games);
          if (byGames != 0) return byGames;
          return b.lastPlayed.compareTo(a.lastPlayed);
        });

    return PlayStatsSummary(
      overall: overall,
      asWhite: asWhite,
      asBlack: asBlack,
      whiteOpenings: rank(white),
      blackOpenings: rank(black),
      bands: (bands.entries
              .map((e) => PlayStrengthBand(from: e.key, record: e.value))
              .toList()
            ..sort((a, b) => a.from.compareTo(b.from)))
          .toList(growable: false),
      byTimeControl: byTc,
      form: [
        for (final g in scored.reversed.take(12).toList().reversed)
          _kindOf(g.userScore!),
      ],
      current: current,
      bestWinStreak: bestWin,
      bestUnbeaten: bestUnbeaten,
      performance: performance,
      averageOpponent: avgOpp,
      strongestWin: strongestWin,
      activity: activity,
      averageMoves: scored.isEmpty ? 0 : (moveSum / scored.length).round(),
    );
  }

  final PlayWdl overall;
  final PlayWdl asWhite;
  final PlayWdl asBlack;

  /// Most played first.
  final List<PlayOpeningStat> whiteOpenings;
  final List<PlayOpeningStat> blackOpenings;

  /// Lowest band first.
  final List<PlayStrengthBand> bands;
  final Map<RatedTimeControl, PlayWdl> byTimeControl;

  /// Up to the last 12 results, oldest first.
  final List<PlayStreakKind> form;
  final PlayStreak? current;
  final int bestWinStreak;
  final int bestUnbeaten;

  /// Linear performance rating against the bots faced.
  final int? performance;
  final int? averageOpponent;
  final PlayGameRecord? strongestWin;

  /// Games per day, keyed by days ago (0 = today), within
  /// [kPlayActivityDays].
  final Map<int, int> activity;

  /// Full moves per game on average.
  final int averageMoves;

  bool get isEmpty => overall.games == 0;
}

/// Days covered by [PlayStatsSummary.activity]: 15 weeks.
const int kPlayActivityDays = 105;

PlayStreakKind _kindOf(double score) =>
    score == 1
        ? PlayStreakKind.win
        : score == 0.5
        ? PlayStreakKind.draw
        : PlayStreakKind.loss;

DateTime _day(DateTime d) {
  final l = d.toLocal();
  return DateTime(l.year, l.month, l.day);
}

/// The rated ladder a saved game belongs to, or null for custom clocks.
RatedTimeControl? playRecordTimeControl(PlayGameRecord g) {
  final fromCat = ratedTimeControlFromString(g.timeCategory);
  if (fromCat != null) return fromCat;
  final seconds = g.baseSeconds;
  if (seconds != null && seconds > 0) {
    return ratedTimeControlForSeconds(seconds);
  }
  return null;
}

/// "Sicilian Defense: Najdorf Variation" -> "Sicilian Defense". Falls back
/// to the ECO code, and returns null when neither is known.
String? openingFamily(String? name, String? eco) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isNotEmpty) {
    final cut = trimmed.indexOf(':');
    final family = (cut > 0 ? trimmed.substring(0, cut) : trimmed).trim();
    if (family.isNotEmpty) return family;
  }
  final code = eco?.trim() ?? '';
  return code.isEmpty ? null : code;
}

class _OpeningAcc {
  _OpeningAcc(this.name);

  final String name;
  String? eco;
  PlayWdl record = const PlayWdl();
  DateTime last = DateTime.fromMillisecondsSinceEpoch(0);

  void add(PlayGameRecord g, double score) {
    record = record.add(score);
    eco ??= g.eco;
    if (g.playedAt.isAfter(last)) last = g.playedAt;
  }

  PlayOpeningStat toStat() =>
      PlayOpeningStat(name: name, eco: eco, record: record, lastPlayed: last);
}
