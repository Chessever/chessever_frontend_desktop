import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/state/play_session.dart';

const String kAchievementBadgeSheetAsset =
    'assets/play/achievements/badge_sheet.png';

enum PlayAchievementId {
  firstGame,
  firstWin,
  firstDraw,
  tenGames,
  twentyFiveGames,
  fiftyGames,
  checkmateArtist,
  fiveWins,
  tenWins,
  twentyFiveWins,
  whiteWin,
  bulletWinner,
  blitzWinner,
  rapidWinner,
  classicalWinner,
  tournamentDirector,
  eventFinisher,
  fullHouseDirector,
  tournamentPoint,
  stockfishSlayer,
  leelaBreaker,
  maiaMatch,
  blackWin,
  defensiveHold,
  resourcefulDraw,
  comebackWin,
  swindleWin,
  attackFinish,
  cleanConversion,
  queenHunter,
  rookRaider,
  minorPieceCollector,
  promotionPoint,
  castleAndWin,
  endgameGrind,
  pawnEnding,
  rookEnding,
  minorPieceEnding,
  caroKannWin,
  sicilianWin,
  frenchWin,
  queenGambitWin,
  ruyLopezWin,
  londonSystemWin,
  kingsIndianWin,
  nimzoIndianWin,
  slavWin,
  englishWin,
  pircWin,
  scandinavianWin,
  playFromHereWin,
  lowTimeSave,
  marathonSurvivor,
  miniatureWin,
}

enum PlayAchievementGroup {
  milestones('Milestones'),
  results('Results'),
  clock('Clock'),
  events('Events'),
  engines('Engines'),
  resilience('Resilience'),
  tactics('Tactics'),
  technique('Technique'),
  endgames('Endgames'),
  openings('Openings'),
  setup('Setup');

  const PlayAchievementGroup(this.label);

  final String label;
}

@immutable
class PlayAchievementDefinition {
  const PlayAchievementDefinition({
    required this.id,
    required this.title,
    required this.description,
    required this.target,
    required this.badgeIndex,
    required this.color,
    required this.group,
  });

  final PlayAchievementId id;
  final String title;
  final String description;
  final int target;
  final int badgeIndex;
  final Color color;
  final PlayAchievementGroup group;
}

@immutable
class PlayBadgeContribution {
  const PlayBadgeContribution({
    required this.id,
    required this.reason,
    this.detail,
    this.metadata = const <String, dynamic>{},
  });

  final PlayAchievementId id;
  final String reason;
  final String? detail;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => {
    'id': id.name,
    'reason': reason,
    if (detail != null) 'detail': detail,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };
}

@immutable
class PlayAchievementStats {
  const PlayAchievementStats({
    this.gamesPlayed = 0,
    this.wins = 0,
    this.draws = 0,
    this.checkmateWins = 0,
    this.whiteWins = 0,
    this.blackWins = 0,
    this.bulletWins = 0,
    this.blitzWins = 0,
    this.rapidWins = 0,
    this.classicalWins = 0,
    this.stockfishWins = 0,
    this.leelaWins = 0,
    this.maiaWins = 0,
    this.tournamentsCreated = 0,
    this.tournamentsCompleted = 0,
    this.fullHouseTournaments = 0,
    this.badgeCounters = const <String, int>{},
  });

  final int gamesPlayed;
  final int wins;
  final int draws;
  final int checkmateWins;
  final int whiteWins;
  final int blackWins;
  final int bulletWins;
  final int blitzWins;
  final int rapidWins;
  final int classicalWins;
  final int stockfishWins;
  final int leelaWins;
  final int maiaWins;
  final int tournamentsCreated;
  final int tournamentsCompleted;
  final int fullHouseTournaments;
  final Map<String, int> badgeCounters;

  int progressFor(PlayAchievementId id) {
    final contributionProgress = badgeCounters[id.name] ?? 0;
    int withContributionProgress(int value) =>
        value > contributionProgress ? value : contributionProgress;

    return switch (id) {
      PlayAchievementId.firstGame => gamesPlayed,
      PlayAchievementId.firstWin => wins,
      PlayAchievementId.firstDraw => draws,
      PlayAchievementId.tenGames => gamesPlayed,
      PlayAchievementId.twentyFiveGames => gamesPlayed,
      PlayAchievementId.fiftyGames => gamesPlayed,
      PlayAchievementId.checkmateArtist => checkmateWins,
      PlayAchievementId.fiveWins => wins,
      PlayAchievementId.tenWins => wins,
      PlayAchievementId.twentyFiveWins => wins,
      PlayAchievementId.whiteWin => withContributionProgress(whiteWins),
      PlayAchievementId.blackWin => withContributionProgress(blackWins),
      PlayAchievementId.bulletWinner => withContributionProgress(bulletWins),
      PlayAchievementId.blitzWinner => withContributionProgress(blitzWins),
      PlayAchievementId.rapidWinner => withContributionProgress(rapidWins),
      PlayAchievementId.classicalWinner => withContributionProgress(
        classicalWins,
      ),
      PlayAchievementId.stockfishSlayer => withContributionProgress(
        stockfishWins,
      ),
      PlayAchievementId.leelaBreaker => withContributionProgress(leelaWins),
      PlayAchievementId.maiaMatch => withContributionProgress(maiaWins),
      PlayAchievementId.tournamentDirector => tournamentsCreated,
      PlayAchievementId.eventFinisher => tournamentsCompleted,
      PlayAchievementId.fullHouseDirector => fullHouseTournaments,
      _ => contributionProgress,
    };
  }

  PlayAchievementStats withBadgeContributions(
    Iterable<PlayBadgeContribution> contributions,
  ) {
    final counters = Map<String, int>.from(badgeCounters);
    for (final contribution in contributions) {
      counters[contribution.id.name] =
          (counters[contribution.id.name] ?? 0) + 1;
    }
    return copyWith(badgeCounters: counters);
  }

  Map<String, dynamic> toJson() => {
    'gamesPlayed': gamesPlayed,
    'wins': wins,
    'draws': draws,
    'checkmateWins': checkmateWins,
    'whiteWins': whiteWins,
    'blackWins': blackWins,
    'bulletWins': bulletWins,
    'blitzWins': blitzWins,
    'rapidWins': rapidWins,
    'classicalWins': classicalWins,
    'stockfishWins': stockfishWins,
    'leelaWins': leelaWins,
    'maiaWins': maiaWins,
    'tournamentsCreated': tournamentsCreated,
    'tournamentsCompleted': tournamentsCompleted,
    'fullHouseTournaments': fullHouseTournaments,
    'badgeCounters': badgeCounters,
  };

  static PlayAchievementStats fromJson(Map<String, dynamic> json) {
    int read(String key) => (json[key] as num?)?.toInt() ?? 0;
    return PlayAchievementStats(
      gamesPlayed: read('gamesPlayed'),
      wins: read('wins'),
      draws: read('draws'),
      checkmateWins: read('checkmateWins'),
      whiteWins: read('whiteWins'),
      blackWins: read('blackWins'),
      bulletWins: read('bulletWins'),
      blitzWins: read('blitzWins'),
      rapidWins: read('rapidWins'),
      classicalWins: read('classicalWins'),
      stockfishWins: read('stockfishWins'),
      leelaWins: read('leelaWins'),
      maiaWins: read('maiaWins'),
      tournamentsCreated: read('tournamentsCreated'),
      tournamentsCompleted: read('tournamentsCompleted'),
      fullHouseTournaments: read('fullHouseTournaments'),
      badgeCounters: (json['badgeCounters'] as Map<String, dynamic>? ??
              const {})
          .map((key, value) => MapEntry(key, (value as num?)?.toInt() ?? 0)),
    );
  }

  PlayAchievementStats copyWith({
    int? gamesPlayed,
    int? wins,
    int? draws,
    int? checkmateWins,
    int? whiteWins,
    int? blackWins,
    int? bulletWins,
    int? blitzWins,
    int? rapidWins,
    int? classicalWins,
    int? stockfishWins,
    int? leelaWins,
    int? maiaWins,
    int? tournamentsCreated,
    int? tournamentsCompleted,
    int? fullHouseTournaments,
    Map<String, int>? badgeCounters,
  }) {
    return PlayAchievementStats(
      gamesPlayed: gamesPlayed ?? this.gamesPlayed,
      wins: wins ?? this.wins,
      draws: draws ?? this.draws,
      checkmateWins: checkmateWins ?? this.checkmateWins,
      whiteWins: whiteWins ?? this.whiteWins,
      blackWins: blackWins ?? this.blackWins,
      bulletWins: bulletWins ?? this.bulletWins,
      blitzWins: blitzWins ?? this.blitzWins,
      rapidWins: rapidWins ?? this.rapidWins,
      classicalWins: classicalWins ?? this.classicalWins,
      stockfishWins: stockfishWins ?? this.stockfishWins,
      leelaWins: leelaWins ?? this.leelaWins,
      maiaWins: maiaWins ?? this.maiaWins,
      tournamentsCreated: tournamentsCreated ?? this.tournamentsCreated,
      tournamentsCompleted: tournamentsCompleted ?? this.tournamentsCompleted,
      fullHouseTournaments: fullHouseTournaments ?? this.fullHouseTournaments,
      badgeCounters: badgeCounters ?? this.badgeCounters,
    );
  }
}

@immutable
class PlayAchievementsState {
  const PlayAchievementsState({
    required this.stats,
    required this.unlocked,
    this.claimable = const <PlayAchievementId>{},
    this.lastUnlock,
    this.lastEarned = const <PlayAchievementId>[],
    this.lastContributions = const <PlayBadgeContribution>[],
  });

  final PlayAchievementStats stats;

  /// Badges the user has explicitly claimed into the profile cabinet.
  final Set<PlayAchievementId> unlocked;

  /// Earned badges waiting for the full-screen claim interaction.
  final Set<PlayAchievementId> claimable;
  final PlayAchievementId? lastUnlock;
  final List<PlayAchievementId> lastEarned;
  final List<PlayBadgeContribution> lastContributions;

  PlayAchievementsState copyWith({
    PlayAchievementStats? stats,
    Set<PlayAchievementId>? unlocked,
    Set<PlayAchievementId>? claimable,
    PlayAchievementId? lastUnlock,
    List<PlayAchievementId>? lastEarned,
    List<PlayBadgeContribution>? lastContributions,
    bool clearLastUnlock = false,
    bool clearLastContributions = false,
  }) {
    return PlayAchievementsState(
      stats: stats ?? this.stats,
      unlocked: unlocked ?? this.unlocked,
      claimable: claimable ?? this.claimable,
      lastUnlock: clearLastUnlock ? null : (lastUnlock ?? this.lastUnlock),
      lastEarned:
          clearLastUnlock
              ? const <PlayAchievementId>[]
              : (lastEarned ?? this.lastEarned),
      lastContributions:
          clearLastContributions
              ? const <PlayBadgeContribution>[]
              : (lastContributions ?? this.lastContributions),
    );
  }
}

class PlayAchievementsNotifier extends StateNotifier<PlayAchievementsState> {
  PlayAchievementsNotifier()
    : super(
        const PlayAchievementsState(
          stats: PlayAchievementStats(),
          unlocked: <PlayAchievementId>{},
        ),
      ) {
    unawaited(_load());
  }

  final Set<String> _recordedGameKeys = <String>{};
  final Set<String> _recordedTournamentKeys = <String>{};

  Future<void> recordSingleGame(
    PlaySessionState session, {
    List<PlayBadgeContribution> contributions = const <PlayBadgeContribution>[],
  }) async {
    if (!session.isGameOver) return;
    final key = '${session.startingFen}|${session.history.join(' ')}';
    if (!_recordedGameKeys.add(key)) return;

    final humanWon =
        (session.humanSide == Side.white &&
            session.outcome == Outcome.whiteWins) ||
        (session.humanSide == Side.black &&
            session.outcome == Outcome.blackWins);
    final humanDrew = session.outcome == Outcome.draw;
    final checkmateWin =
        humanWon &&
        (session.endReason == PlayEndReason.blackCheckmated ||
            session.endReason == PlayEndReason.whiteCheckmated);
    final engineWins = switch (session.config.engine) {
      BotEngineKind.stockfish => (
        stockfish: humanWon ? 1 : 0,
        leela: 0,
        maia: 0,
      ),
      BotEngineKind.leela => (stockfish: 0, leela: humanWon ? 1 : 0, maia: 0),
      BotEngineKind.maia => (stockfish: 0, leela: 0, maia: humanWon ? 1 : 0),
    };

    final stats = state.stats
        .copyWith(
          gamesPlayed: state.stats.gamesPlayed + 1,
          wins: state.stats.wins + (humanWon ? 1 : 0),
          draws: state.stats.draws + (humanDrew ? 1 : 0),
          checkmateWins: state.stats.checkmateWins + (checkmateWin ? 1 : 0),
          whiteWins:
              state.stats.whiteWins +
              (humanWon && session.humanSide == Side.white ? 1 : 0),
          blackWins:
              state.stats.blackWins +
              (humanWon && session.humanSide == Side.black ? 1 : 0),
          bulletWins:
              state.stats.bulletWins +
              (humanWon && session.config.category == TimeControlCategory.bullet
                  ? 1
                  : 0),
          blitzWins:
              state.stats.blitzWins +
              (humanWon && session.config.category == TimeControlCategory.blitz
                  ? 1
                  : 0),
          rapidWins:
              state.stats.rapidWins +
              (humanWon && session.config.category == TimeControlCategory.rapid
                  ? 1
                  : 0),
          classicalWins:
              state.stats.classicalWins +
              (humanWon &&
                      session.config.category == TimeControlCategory.classical
                  ? 1
                  : 0),
          stockfishWins: state.stats.stockfishWins + engineWins.stockfish,
          leelaWins: state.stats.leelaWins + engineWins.leela,
          maiaWins: state.stats.maiaWins + engineWins.maia,
        )
        .withBadgeContributions(contributions);
    await _applyStats(stats, contributions: contributions);
  }

  Future<void> recordTournamentCreated(TournamentConfig config) async {
    final stats = state.stats.copyWith(
      tournamentsCreated: state.stats.tournamentsCreated + 1,
      fullHouseTournaments:
          state.stats.fullHouseTournaments +
          (config.participants.length >= 16 ? 1 : 0),
    );
    await _applyStats(stats);
  }

  Future<void> recordTournamentCompleted(TournamentSnapshot snapshot) async {
    if (snapshot.isRunning) return;
    final key =
        '${snapshot.config.title}|${snapshot.config.participants.length}|'
        '${snapshot.games.length}|${snapshot.games.map((g) => g.result).join(',')}';
    if (!_recordedTournamentKeys.add(key)) return;
    final stats = state.stats.copyWith(
      tournamentsCompleted: state.stats.tournamentsCompleted + 1,
    );
    await _applyStats(stats);
  }

  void clearLastUnlock() {
    if (state.lastUnlock == null &&
        state.lastEarned.isEmpty &&
        state.lastContributions.isEmpty) {
      return;
    }
    state = state.copyWith(clearLastUnlock: true, clearLastContributions: true);
  }

  Future<void> claimAchievements(Iterable<PlayAchievementId> ids) async {
    final unlocked = {...state.unlocked};
    final claimable = {...state.claimable};
    var changed = false;
    for (final id in ids) {
      if (!claimable.remove(id)) continue;
      unlocked.add(id);
      changed = true;
    }
    if (!changed) return;
    state = state.copyWith(
      unlocked: unlocked,
      claimable: claimable,
      clearLastUnlock: true,
      clearLastContributions: true,
    );
    await _save();
  }

  Future<void> claimAllPending() => claimAchievements(state.claimable);

  Future<void> _applyStats(
    PlayAchievementStats stats, {
    List<PlayBadgeContribution> contributions = const <PlayBadgeContribution>[],
  }) async {
    final unlocked = {...state.unlocked};
    final claimable = {...state.claimable};
    final newlyEarned = <PlayAchievementId>[];
    for (final definition in kPlayAchievementDefinitions) {
      if (unlocked.contains(definition.id)) continue;
      if (claimable.contains(definition.id)) continue;
      if (stats.progressFor(definition.id) >= definition.target) {
        claimable.add(definition.id);
        newlyEarned.add(definition.id);
      }
    }
    state = PlayAchievementsState(
      stats: stats,
      unlocked: unlocked,
      claimable: claimable,
      lastUnlock: newlyEarned.isEmpty ? null : newlyEarned.last,
      lastEarned: newlyEarned,
      lastContributions: contributions,
    );
    await _save();
  }

  Future<void> _load() async {
    final file = await _stateFile();
    if (!await file.exists()) return;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final unlocked = <PlayAchievementId>{};
    for (final name
        in (json['unlocked'] as List<dynamic>? ?? const <dynamic>[])) {
      if (name is! String) continue;
      try {
        unlocked.add(PlayAchievementId.values.byName(name));
      } catch (_) {}
    }
    final claimable = <PlayAchievementId>{};
    for (final name
        in (json['claimable'] as List<dynamic>? ?? const <dynamic>[])) {
      if (name is! String) continue;
      try {
        final id = PlayAchievementId.values.byName(name);
        if (!unlocked.contains(id)) claimable.add(id);
      } catch (_) {}
    }
    final statsJson = json['stats'];
    state = PlayAchievementsState(
      stats:
          statsJson is Map<String, dynamic>
              ? PlayAchievementStats.fromJson(statsJson)
              : const PlayAchievementStats(),
      unlocked: unlocked,
      claimable: claimable,
    );
  }

  Future<void> _save() async {
    final file = await _stateFile();
    if (!await file.parent.exists()) await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'stats': state.stats.toJson(),
        'unlocked': [for (final id in state.unlocked) id.name],
        'claimable': [for (final id in state.claimable) id.name],
      }),
      flush: true,
    );
  }

  Future<File> _stateFile() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'play_achievements', 'achievements.json'));
  }
}

const List<PlayAchievementDefinition> kPlayAchievementDefinitions = [
  PlayAchievementDefinition(
    id: PlayAchievementId.firstGame,
    title: 'First Seat',
    description: 'Finish a bot game.',
    target: 1,
    badgeIndex: 0,
    color: Color(0xFFEAB95A),
    group: PlayAchievementGroup.milestones,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.firstWin,
    title: 'First Win',
    description: 'Win a bot game.',
    target: 1,
    badgeIndex: 1,
    color: Color(0xFF7DD3A8),
    group: PlayAchievementGroup.results,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.firstDraw,
    title: 'First Half-Point',
    description: 'Draw a bot game.',
    target: 1,
    badgeIndex: 2,
    color: Color(0xFFB8C0D4),
    group: PlayAchievementGroup.results,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.tenGames,
    title: 'Ten Boards',
    description: 'Finish 10 bot games.',
    target: 10,
    badgeIndex: 3,
    color: Color(0xFFFFB86B),
    group: PlayAchievementGroup.milestones,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.twentyFiveGames,
    title: 'Club Regular',
    description: 'Finish 25 bot games.',
    target: 25,
    badgeIndex: 4,
    color: Color(0xFF8BD5CA),
    group: PlayAchievementGroup.milestones,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.fiftyGames,
    title: 'Study Hall',
    description: 'Finish 50 bot games.',
    target: 50,
    badgeIndex: 5,
    color: Color(0xFFF2CDCD),
    group: PlayAchievementGroup.milestones,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.checkmateArtist,
    title: 'Checkmate Artist',
    description: 'Win by checkmate.',
    target: 1,
    badgeIndex: 6,
    color: Color(0xFFE66B6B),
    group: PlayAchievementGroup.tactics,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.fiveWins,
    title: 'Five-Point Match',
    description: 'Win five bot games.',
    target: 5,
    badgeIndex: 7,
    color: Color(0xFF65A9FF),
    group: PlayAchievementGroup.results,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.tenWins,
    title: 'Double Digits',
    description: 'Win 10 bot games.',
    target: 10,
    badgeIndex: 0,
    color: Color(0xFFABE9B3),
    group: PlayAchievementGroup.results,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.twentyFiveWins,
    title: 'Match Player',
    description: 'Win 25 bot games.',
    target: 25,
    badgeIndex: 1,
    color: Color(0xFFE5C890),
    group: PlayAchievementGroup.results,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.whiteWin,
    title: 'White Initiative',
    description: 'Beat a bot while playing White.',
    target: 1,
    badgeIndex: 2,
    color: Color(0xFFF8F7F2),
    group: PlayAchievementGroup.results,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.bulletWinner,
    title: 'Bullet Spark',
    description: 'Win a bullet game.',
    target: 1,
    badgeIndex: 3,
    color: Color(0xFFFFD166),
    group: PlayAchievementGroup.clock,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.blitzWinner,
    title: 'Blitz Specialist',
    description: 'Win a blitz game.',
    target: 1,
    badgeIndex: 4,
    color: Color(0xFFF5D15D),
    group: PlayAchievementGroup.clock,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.rapidWinner,
    title: 'Rapid Form',
    description: 'Win a rapid game.',
    target: 1,
    badgeIndex: 5,
    color: Color(0xFF6AD7D0),
    group: PlayAchievementGroup.clock,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.classicalWinner,
    title: 'Classical Point',
    description: 'Win a classical game.',
    target: 1,
    badgeIndex: 6,
    color: Color(0xFFD4D4D8),
    group: PlayAchievementGroup.clock,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.tournamentDirector,
    title: 'Tournament Director',
    description: 'Create a tournament.',
    target: 1,
    badgeIndex: 7,
    color: Color(0xFFC89BFF),
    group: PlayAchievementGroup.events,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.eventFinisher,
    title: 'Event Finisher',
    description: 'Run a tournament to completion.',
    target: 1,
    badgeIndex: 0,
    color: Color(0xFF9FD26A),
    group: PlayAchievementGroup.events,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.fullHouseDirector,
    title: 'Full House',
    description: 'Create a 16-player tournament.',
    target: 1,
    badgeIndex: 1,
    color: Color(0xFFE5A15F),
    group: PlayAchievementGroup.events,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.tournamentPoint,
    title: 'Event Point',
    description: 'Score a win in a tournament game.',
    target: 1,
    badgeIndex: 2,
    color: Color(0xFFFAE3B0),
    group: PlayAchievementGroup.events,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.stockfishSlayer,
    title: 'Stockfish Slayer',
    description: 'Beat Stockfish in a bot game.',
    target: 1,
    badgeIndex: 3,
    color: Color(0xFFFF6B6B),
    group: PlayAchievementGroup.engines,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.leelaBreaker,
    title: 'Leela Breaker',
    description: 'Beat Leela in a bot game.',
    target: 1,
    badgeIndex: 4,
    color: Color(0xFF81C995),
    group: PlayAchievementGroup.engines,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.maiaMatch,
    title: 'Human Pattern',
    description: 'Beat Maia in a bot game.',
    target: 1,
    badgeIndex: 5,
    color: Color(0xFFF0ABFC),
    group: PlayAchievementGroup.engines,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.blackWin,
    title: 'Dark-Square Point',
    description: 'Beat a bot while playing Black.',
    target: 1,
    badgeIndex: 6,
    color: Color(0xFFB5B4FF),
    group: PlayAchievementGroup.results,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.defensiveHold,
    title: 'Fortress Builder',
    description: 'Defend an objectively worse position and avoid losing.',
    target: 1,
    badgeIndex: 7,
    color: Color(0xFF89B4FA),
    group: PlayAchievementGroup.resilience,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.resourcefulDraw,
    title: 'Resourceful Half-Point',
    description: 'Escape with a draw after the bot had a clear edge.',
    target: 1,
    badgeIndex: 0,
    color: Color(0xFF94E2D5),
    group: PlayAchievementGroup.resilience,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.comebackWin,
    title: 'Comeback Win',
    description: 'Win after being worse during the game.',
    target: 1,
    badgeIndex: 1,
    color: Color(0xFFA6E3A1),
    group: PlayAchievementGroup.resilience,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.swindleWin,
    title: 'Swindle Artist',
    description: 'Flip a nearly lost position into a win.',
    target: 1,
    badgeIndex: 2,
    color: Color(0xFFF38BA8),
    group: PlayAchievementGroup.resilience,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.attackFinish,
    title: 'Attack Finish',
    description: 'Convert a large attacking advantage into victory.',
    target: 1,
    badgeIndex: 3,
    color: Color(0xFFFAB387),
    group: PlayAchievementGroup.tactics,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.cleanConversion,
    title: 'Clean Conversion',
    description: 'Win from an advantage without giving it back.',
    target: 1,
    badgeIndex: 4,
    color: Color(0xFFF9E2AF),
    group: PlayAchievementGroup.technique,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.queenHunter,
    title: 'Queen Hunter',
    description: 'Capture the opponent queen in a win.',
    target: 1,
    badgeIndex: 5,
    color: Color(0xFFFFA8A8),
    group: PlayAchievementGroup.tactics,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.rookRaider,
    title: 'Rook Raider',
    description: 'Capture both opponent rooks in a win.',
    target: 1,
    badgeIndex: 6,
    color: Color(0xFFF4B8E4),
    group: PlayAchievementGroup.tactics,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.minorPieceCollector,
    title: 'Minor Collector',
    description: 'Capture at least three minor pieces in one win.',
    target: 1,
    badgeIndex: 7,
    color: Color(0xFFB7BDF8),
    group: PlayAchievementGroup.tactics,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.promotionPoint,
    title: 'Promotion Point',
    description: 'Promote a pawn in a win.',
    target: 1,
    badgeIndex: 0,
    color: Color(0xFFFFD1DC),
    group: PlayAchievementGroup.technique,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.castleAndWin,
    title: 'King Sheltered',
    description: 'Castle and win the game.',
    target: 1,
    badgeIndex: 1,
    color: Color(0xFFA7C7E7),
    group: PlayAchievementGroup.technique,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.endgameGrind,
    title: 'Endgame Grind',
    description: 'Win a long bot game after move 50.',
    target: 1,
    badgeIndex: 2,
    color: Color(0xFFCDD6F4),
    group: PlayAchievementGroup.endgames,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.pawnEnding,
    title: 'Pawn Ending',
    description: 'Win when only kings and pawns remain.',
    target: 1,
    badgeIndex: 3,
    color: Color(0xFFDDB892),
    group: PlayAchievementGroup.endgames,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.rookEnding,
    title: 'Rook Ending',
    description: 'Win a game that reaches a rook ending.',
    target: 1,
    badgeIndex: 4,
    color: Color(0xFFBFD7EA),
    group: PlayAchievementGroup.endgames,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.minorPieceEnding,
    title: 'Minor Ending',
    description: 'Win a game that reaches a minor-piece ending.',
    target: 1,
    badgeIndex: 5,
    color: Color(0xFFCDB4DB),
    group: PlayAchievementGroup.endgames,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.caroKannWin,
    title: 'Caro-Kann Win',
    description: 'Win a game classified as a Caro-Kann.',
    target: 1,
    badgeIndex: 6,
    color: Color(0xFFA6ADC8),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.sicilianWin,
    title: 'Sicilian Point',
    description: 'Win a game classified as a Sicilian Defense.',
    target: 1,
    badgeIndex: 7,
    color: Color(0xFF74C7EC),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.frenchWin,
    title: 'French Structure',
    description: 'Win a game classified as a French Defense.',
    target: 1,
    badgeIndex: 0,
    color: Color(0xFF89DCEB),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.queenGambitWin,
    title: 'Queen\'s Gambit Win',
    description: 'Win out of a Queen\'s Gambit structure.',
    target: 1,
    badgeIndex: 1,
    color: Color(0xFFCBA6F7),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.ruyLopezWin,
    title: 'Spanish Main Line',
    description: 'Win a game classified as a Ruy Lopez.',
    target: 1,
    badgeIndex: 2,
    color: Color(0xFFF5C2E7),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.londonSystemWin,
    title: 'London System Win',
    description: 'Win with a London setup.',
    target: 1,
    badgeIndex: 3,
    color: Color(0xFFB4BEFE),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.kingsIndianWin,
    title: 'King\'s Indian Point',
    description: 'Win a game classified as a King\'s Indian.',
    target: 1,
    badgeIndex: 4,
    color: Color(0xFF8AADF4),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.nimzoIndianWin,
    title: 'Nimzo Bind',
    description: 'Win a game classified as a Nimzo-Indian.',
    target: 1,
    badgeIndex: 5,
    color: Color(0xFFA6DA95),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.slavWin,
    title: 'Slav Structure',
    description: 'Win a game classified as a Slav Defense.',
    target: 1,
    badgeIndex: 6,
    color: Color(0xFFEED49F),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.englishWin,
    title: 'English Grip',
    description: 'Win a game classified as an English Opening.',
    target: 1,
    badgeIndex: 7,
    color: Color(0xFF91D7E3),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.pircWin,
    title: 'Pirc Counter',
    description: 'Win a game classified as a Pirc or Modern Defense.',
    target: 1,
    badgeIndex: 0,
    color: Color(0xFFE78284),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.scandinavianWin,
    title: 'Scandi Strike',
    description: 'Win a game classified as a Scandinavian Defense.',
    target: 1,
    badgeIndex: 1,
    color: Color(0xFF99D1DB),
    group: PlayAchievementGroup.openings,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.playFromHereWin,
    title: 'From Here',
    description: 'Win a game that started from an existing board position.',
    target: 1,
    badgeIndex: 2,
    color: Color(0xFF7DD3FC),
    group: PlayAchievementGroup.setup,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.lowTimeSave,
    title: 'Last Seconds',
    description: 'Win or draw with 10 seconds or less left.',
    target: 1,
    badgeIndex: 3,
    color: Color(0xFFFF9F1C),
    group: PlayAchievementGroup.clock,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.marathonSurvivor,
    title: 'Marathon Survivor',
    description: 'Finish a game with at least 80 plies.',
    target: 1,
    badgeIndex: 4,
    color: Color(0xFFCAD2C5),
    group: PlayAchievementGroup.endgames,
  ),
  PlayAchievementDefinition(
    id: PlayAchievementId.miniatureWin,
    title: 'Miniature',
    description: 'Win in 20 moves or fewer.',
    target: 1,
    badgeIndex: 5,
    color: Color(0xFFFFD6A5),
    group: PlayAchievementGroup.tactics,
  ),
];

PlayAchievementDefinition achievementDefinition(PlayAchievementId id) {
  return kPlayAchievementDefinitions.firstWhere((d) => d.id == id);
}

final playAchievementsProvider =
    StateNotifierProvider<PlayAchievementsNotifier, PlayAchievementsState>(
      (ref) => PlayAchievementsNotifier(),
    );
