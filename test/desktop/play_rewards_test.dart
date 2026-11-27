import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_rewards.dart';

void main() {
  test('every badge sits in exactly one track', () {
    final seen = <PlayAchievementId>[
      for (final t in kPlayBadgeTracks) ...t.ids,
    ];
    expect(seen.toSet().length, seen.length);
    expect(seen, unorderedEquals(PlayAchievementId.values));
    for (final t in kPlayBadgeTracks) {
      expect(t.thresholds, isNotEmpty);
      for (var i = 1; i < t.thresholds.length; i++) {
        expect(t.thresholds[i], greaterThan(t.thresholds[i - 1]));
      }
      expect(t.maxTier, lessThanOrEqualTo(kPlayBadgeTierNames.length));
    }
    expect(
      kPlayBadgeTracks.map((t) => t.key).toSet().length,
      kPlayBadgeTracks.length,
    );
  });

  test('the games and wins milestones are tiers of one track', () {
    final games = playBadgeTrackByKey('games')!;
    expect(games.tierFor(0), 0);
    expect(games.tierFor(1), 1);
    expect(games.tierFor(10), 2);
    expect(games.tierFor(49), 3);
    expect(games.tierFor(500), 5);
    expect(games.nextTarget(12), 25);
    expect(games.nextTarget(500), isNull);
    expect(games.fractionToNext(17), closeTo(7 / 15, 1e-9));
    expect(playBadgeTierName(games.tierFor(25)), 'Gold');
  });

  test('stat changes report each tier crossed', () {
    const before = PlayAchievementStats(gamesPlayed: 9, wins: 4);
    const after = PlayAchievementStats(gamesPlayed: 10, wins: 5);
    final ups = playBadgeTierUps(before, after, DateTime(2026));
    expect(
      ups.map((u) => '${u.trackKey}:${u.tier}'),
      containsAll(['games:2', 'wins:2']),
    );
    expect(ups.every((u) => u.xp > 0), isTrue);
  });

  test('levels climb with a growing XP step', () {
    expect(PlayLevel.fromXp(0).level, 1);
    expect(PlayLevel.fromXp(119).level, 1);
    expect(PlayLevel.fromXp(120).level, 2);
    expect(PlayLevel.fromXp(120 + 180).level, 3);
    final l = PlayLevel.fromXp(150);
    expect(l.xpIntoLevel, 30);
    expect(l.xpForNext, 180);
    expect(l.xpToNext, 150);
    expect(l.title, 'Newcomer');
    expect(PlayLevel.fromXp(100000).title, 'Legend');
  });

  test('a game earns XP for the result, the opponent and the day', () {
    final win = playGameXpLines(
      score: 1,
      opponentRating: 1600,
      humanRating: 1300,
      plies: 70,
      winStreak: 3,
      firstGameToday: true,
      checkmate: false,
      analysis: const {'kind': 'uci_quick', 'largestDropCentipawns': 80},
    );
    final labels = win.map((l) => l.label).toList();
    expect(labels, contains('Win'));
    expect(labels, contains('Beat a stronger bot'));
    expect(labels, contains('3 wins in a row'));
    expect(labels, contains('First game today'));
    expect(labels, contains('No big mistakes'));
    expect(win.firstWhere((l) => l.label == 'Beat a stronger bot').xp, 30);

    final loss = playGameXpLines(
      score: 0,
      opponentRating: 1000,
      humanRating: 1300,
      plies: 20,
      winStreak: 0,
      firstGameToday: false,
      checkmate: false,
    );
    expect(loss, [const PlayXpLine('Game finished', 10)]);
  });

  test('existing players are credited XP for what they already did', () {
    const stats = PlayAchievementStats(gamesPlayed: 12, wins: 6, draws: 2);
    final xp = playBackfillXp(stats);
    // 12*10 + 6*25 + 2*12 = 294, plus tiers: games 1 and 10 (25 + 50),
    // wins 1 and 5 (25 + 50), first draw Bronze (25).
    expect(xp, 294 + 75 + 75 + 25);
    final rewards = PlayGameRewards(
      lines: const [PlayXpLine('Win', 25)],
      xpBefore: 100,
      xpAfter: 140,
      tierUps: const [],
      newlyEarned: const [],
      winStreak: 1,
    );
    expect(rewards.xpEarned, 40);
    expect(rewards.leveledUp, isTrue);
  });
}
