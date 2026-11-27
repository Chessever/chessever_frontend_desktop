import 'package:flutter/widgets.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';

// ---------------------------------------------------------------------------
// Badge tracks and tiers
// ---------------------------------------------------------------------------

/// Tier names, lowest first. A track uses as many as it has thresholds.
const List<String> kPlayBadgeTierNames = [
  'Bronze',
  'Silver',
  'Gold',
  'Platinum',
  'Master',
];

/// Metal of each tier. Muted on purpose: they read as materials, not as
/// highlighter colours.
const List<Color> kPlayBadgeTierMetals = [
  Color(0xFFC08A5E),
  Color(0xFFC3C9D1),
  Color(0xFFD9B865),
  Color(0xFF9FCBD3),
  Color(0xFFD99A92),
];

/// XP awarded the first time a track reaches each tier.
const List<int> kPlayBadgeTierXp = [25, 50, 100, 200, 400];

String playBadgeTierName(int tier) =>
    tier <= 0 ? 'Locked' : kPlayBadgeTierNames[(tier - 1).clamp(0, 4)];

Color playBadgeTierMetal(int tier) =>
    tier <= 0
        ? const Color(0xFF5A5A5E)
        : kPlayBadgeTierMetals[(tier - 1).clamp(0, 4)];

/// One collectable badge with tiers. The earlier one-shot badges each sit
/// in a track: "Games played" and "Wins" join their old milestone badges
/// as the tiers of one track, every other badge gains Silver and Gold for
/// doing it again.
@immutable
class PlayBadgeTrack {
  const PlayBadgeTrack({
    required this.key,
    required this.title,
    required this.description,
    required this.group,
    required this.art,
    required this.progressId,
    required this.thresholds,
    this.ids = const <PlayAchievementId>[],
  });

  /// Stable id, saved in the recent-unlocks log.
  final String key;
  final String title;
  final String description;
  final PlayAchievementGroup group;

  /// The badge whose art and colour the track shows.
  final PlayAchievementId art;

  /// The counter that fills this track.
  final PlayAchievementId progressId;

  /// Ascending targets; tier N is reached at `thresholds[N - 1]`.
  final List<int> thresholds;

  /// Claimable badges that belong to this track, oldest first.
  final List<PlayAchievementId> ids;

  int get maxTier => thresholds.length;

  PlayAchievementDefinition get artDefinition => achievementDefinition(art);

  int progress(PlayAchievementStats stats) => stats.progressFor(progressId);

  /// Tiers reached at [progress], 0 to [maxTier].
  int tierFor(int progress) {
    var tier = 0;
    for (final t in thresholds) {
      if (progress >= t) tier++;
    }
    return tier;
  }

  /// Target of the next tier, or null at the top.
  int? nextTarget(int progress) {
    for (final t in thresholds) {
      if (progress < t) return t;
    }
    return null;
  }

  /// 0..1 progress from the current tier's target to the next one.
  double fractionToNext(int progress) {
    final tier = tierFor(progress);
    if (tier >= maxTier) return 1;
    final from = tier == 0 ? 0 : thresholds[tier - 1];
    final to = thresholds[tier];
    return ((progress - from) / (to - from)).clamp(0.0, 1.0);
  }
}

List<int> _thresholdsFor(PlayAchievementGroup group) {
  return switch (group) {
    PlayAchievementGroup.results => const [1, 10, 50],
    PlayAchievementGroup.clock => const [1, 10, 40],
    PlayAchievementGroup.events => const [1, 3, 10],
    PlayAchievementGroup.engines => const [1, 10, 40],
    PlayAchievementGroup.resilience => const [1, 5, 15],
    PlayAchievementGroup.tactics => const [1, 5, 20],
    PlayAchievementGroup.technique => const [1, 8, 25],
    PlayAchievementGroup.endgames => const [1, 5, 20],
    PlayAchievementGroup.openings => const [1, 5, 15],
    PlayAchievementGroup.setup => const [1, 5, 20],
    PlayAchievementGroup.milestones => const [1, 10, 50],
  };
}

const _gamesSeries = [
  PlayAchievementId.firstGame,
  PlayAchievementId.tenGames,
  PlayAchievementId.twentyFiveGames,
  PlayAchievementId.fiftyGames,
];

const _winsSeries = [
  PlayAchievementId.firstWin,
  PlayAchievementId.fiveWins,
  PlayAchievementId.tenWins,
  PlayAchievementId.twentyFiveWins,
];

List<PlayBadgeTrack> _buildTracks() {
  final tracks = <PlayBadgeTrack>[
    const PlayBadgeTrack(
      key: 'games',
      title: 'Games Played',
      description: 'Finish games against the bots.',
      group: PlayAchievementGroup.milestones,
      art: PlayAchievementId.fiftyGames,
      progressId: PlayAchievementId.firstGame,
      thresholds: [1, 10, 25, 50, 200],
      ids: _gamesSeries,
    ),
    const PlayBadgeTrack(
      key: 'wins',
      title: 'Wins',
      description: 'Beat the bots.',
      group: PlayAchievementGroup.results,
      art: PlayAchievementId.twentyFiveWins,
      progressId: PlayAchievementId.firstWin,
      thresholds: [1, 5, 10, 25, 100],
      ids: _winsSeries,
    ),
  ];
  for (final def in kPlayAchievementDefinitions) {
    if (_gamesSeries.contains(def.id) || _winsSeries.contains(def.id)) {
      continue;
    }
    final base = _thresholdsFor(def.group);
    tracks.add(
      PlayBadgeTrack(
        key: def.id.name,
        title: def.title,
        description: def.description,
        group: def.group,
        art: def.id,
        progressId: def.id,
        // The first tier is the old badge's own target.
        thresholds: [
          def.target,
          for (final t in base.skip(1))
            if (t > def.target) t,
        ],
        ids: [def.id],
      ),
    );
  }
  return List.unmodifiable(tracks);
}

final List<PlayBadgeTrack> kPlayBadgeTracks = _buildTracks();

PlayBadgeTrack? playBadgeTrackByKey(String key) {
  for (final t in kPlayBadgeTracks) {
    if (t.key == key) return t;
  }
  return null;
}

/// Every tier the [stats] have reached, across all tracks.
int playBadgeTiersReached(PlayAchievementStats stats) {
  var total = 0;
  for (final t in kPlayBadgeTracks) {
    total += t.tierFor(t.progress(stats));
  }
  return total;
}

int playBadgeTiersTotal() =>
    kPlayBadgeTracks.fold(0, (sum, t) => sum + t.maxTier);

/// A track that moved up a tier.
@immutable
class PlayBadgeTierUp {
  const PlayBadgeTierUp({
    required this.trackKey,
    required this.tier,
    required this.at,
  });

  final String trackKey;

  /// The tier reached, 1-based (1 = Bronze).
  final int tier;
  final DateTime at;

  PlayBadgeTrack? get track => playBadgeTrackByKey(trackKey);
  String get tierName => playBadgeTierName(tier);
  int get xp => kPlayBadgeTierXp[(tier - 1).clamp(0, 4)];

  Map<String, dynamic> toJson() => {
    'track': trackKey,
    'tier': tier,
    'at': at.toUtc().toIso8601String(),
  };

  static PlayBadgeTierUp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['track']?.toString();
    final tier = (raw['tier'] as num?)?.toInt();
    final at = DateTime.tryParse(raw['at']?.toString() ?? '');
    if (key == null || tier == null || at == null) return null;
    if (playBadgeTrackByKey(key) == null) return null;
    return PlayBadgeTierUp(trackKey: key, tier: tier, at: at.toLocal());
  }
}

/// Tier-ups between two stat snapshots.
List<PlayBadgeTierUp> playBadgeTierUps(
  PlayAchievementStats before,
  PlayAchievementStats after,
  DateTime at,
) {
  final ups = <PlayBadgeTierUp>[];
  for (final track in kPlayBadgeTracks) {
    final from = track.tierFor(track.progress(before));
    final to = track.tierFor(track.progress(after));
    for (var tier = from + 1; tier <= to; tier++) {
      ups.add(PlayBadgeTierUp(trackKey: track.key, tier: tier, at: at));
    }
  }
  return ups;
}

// ---------------------------------------------------------------------------
// Levels
// ---------------------------------------------------------------------------

/// XP needed to go from [level] to the next one: 120, 180, 240, ...
int playXpForLevelStep(int level) => 120 + 60 * (level - 1);

@immutable
class PlayLevel {
  const PlayLevel({
    required this.level,
    required this.xpIntoLevel,
    required this.xpForNext,
    required this.totalXp,
  });

  factory PlayLevel.fromXp(int xp) {
    var level = 1;
    var remaining = xp < 0 ? 0 : xp;
    while (remaining >= playXpForLevelStep(level)) {
      remaining -= playXpForLevelStep(level);
      level++;
    }
    return PlayLevel(
      level: level,
      xpIntoLevel: remaining,
      xpForNext: playXpForLevelStep(level),
      totalXp: xp,
    );
  }

  final int level;
  final int xpIntoLevel;
  final int xpForNext;
  final int totalXp;

  double get fraction => (xpIntoLevel / xpForNext).clamp(0.0, 1.0);
  int get xpToNext => xpForNext - xpIntoLevel;

  String get title => playLevelTitle(level);
}

String playLevelTitle(int level) {
  if (level >= 30) return 'Legend';
  if (level >= 20) return 'Master';
  if (level >= 14) return 'Expert';
  if (level >= 9) return 'Contender';
  if (level >= 5) return 'Regular';
  if (level >= 3) return 'Club player';
  return 'Newcomer';
}

// ---------------------------------------------------------------------------
// XP per game
// ---------------------------------------------------------------------------

@immutable
class PlayXpLine {
  const PlayXpLine(this.label, this.xp);

  final String label;
  final int xp;

  @override
  bool operator ==(Object other) =>
      other is PlayXpLine && other.label == label && other.xp == xp;

  @override
  int get hashCode => Object.hash(label, xp);

  @override
  String toString() => '$label +$xp';
}

/// The XP lines one finished game earns, before badge tier bonuses.
///
/// [score] is the human's score (1, 0.5, 0). [humanRating] is the
/// human's rating on that ladder before the game, when known.
/// [winStreak] is the win streak including this game.
List<PlayXpLine> playGameXpLines({
  required double score,
  required int opponentRating,
  required int plies,
  required int winStreak,
  required bool firstGameToday,
  required bool checkmate,
  int? humanRating,
  Map<String, dynamic>? analysis,
}) {
  final lines = <PlayXpLine>[const PlayXpLine('Game finished', 10)];
  if (score == 1) {
    lines.add(const PlayXpLine('Win', 25));
  } else if (score == 0.5) {
    lines.add(const PlayXpLine('Draw', 12));
  } else if (plies >= 60) {
    lines.add(const PlayXpLine('Long fight', 5));
  }

  if (humanRating != null && score > 0) {
    final gap = opponentRating - humanRating;
    if (gap >= 50) {
      final bonus = ((gap / 10) * score).round().clamp(5, 40);
      lines.add(
        PlayXpLine(
          score == 1 ? 'Beat a stronger bot' : 'Held a stronger bot',
          bonus,
        ),
      );
    }
  }

  if (score == 1 && winStreak >= 2) {
    lines.add(
      PlayXpLine('$winStreak wins in a row', (5 * winStreak).clamp(10, 30)),
    );
  }
  if (checkmate) lines.add(const PlayXpLine('Checkmate', 5));
  if (firstGameToday) lines.add(const PlayXpLine('First game today', 15));

  if (analysis != null && score >= 0.5 && plies >= 30) {
    final engineChecked = analysis['kind'] == 'uci_quick';
    final drop = (analysis['largestDropCentipawns'] as num?)?.toInt();
    if (engineChecked && drop != null && drop <= 150) {
      lines.add(const PlayXpLine('No big mistakes', 15));
    }
  }
  return lines;
}

/// XP an existing player is credited with when the XP system first loads,
/// so older accounts do not start at level 1.
int playBackfillXp(PlayAchievementStats stats) {
  var xp = stats.gamesPlayed * 10 + stats.wins * 25 + stats.draws * 12;
  for (final track in kPlayBadgeTracks) {
    final tier = track.tierFor(track.progress(stats));
    for (var i = 0; i < tier; i++) {
      xp += kPlayBadgeTierXp[i.clamp(0, 4)];
    }
  }
  return xp;
}

/// What the last recorded game earned. Published on
/// `playLastGameRewardsProvider` by [PlayAchievementsNotifier.recordSingleGame].
@immutable
class PlayGameRewards {
  const PlayGameRewards({
    required this.lines,
    required this.xpBefore,
    required this.xpAfter,
    required this.tierUps,
    required this.newlyEarned,
    required this.winStreak,
  });

  /// Every reason with its XP, badge tier bonuses last.
  final List<PlayXpLine> lines;
  final int xpBefore;
  final int xpAfter;

  /// Tracks that moved up a tier with this game.
  final List<PlayBadgeTierUp> tierUps;

  /// Claimable badges first earned with this game (also in
  /// `PlayAchievementsState.lastEarned`).
  final List<PlayAchievementId> newlyEarned;

  /// Win streak after this game; 0 after a draw or loss.
  final int winStreak;

  int get xpEarned => xpAfter - xpBefore;
  PlayLevel get levelBefore => PlayLevel.fromXp(xpBefore);
  PlayLevel get levelAfter => PlayLevel.fromXp(xpAfter);
  bool get leveledUp => levelAfter.level > levelBefore.level;
}
