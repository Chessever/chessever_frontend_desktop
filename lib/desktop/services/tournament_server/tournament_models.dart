import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';

/// Format the tournament conductor pairs games in. Round-robin and knockout
/// are the only two for v1; Swiss/arena come next.
enum TournamentFormat { roundRobin, knockout, doubleRoundRobin }

extension TournamentFormatLabel on TournamentFormat {
  String get displayName => switch (this) {
    TournamentFormat.roundRobin => 'Round robin',
    TournamentFormat.doubleRoundRobin => 'Double round robin',
    TournamentFormat.knockout => 'Knockout',
  };
}

@immutable
class TournamentScheduleSummary {
  const TournamentScheduleSummary({
    required this.rounds,
    required this.games,
    required this.maxGamesPerRound,
    this.byeLabel,
  });

  final int rounds;
  final int games;
  final int maxGamesPerRound;
  final String? byeLabel;

  String get label {
    final roundLabel = rounds == 1 ? '1 round' : '$rounds rounds';
    final gameLabel = games == 1 ? '1 game' : '$games games';
    final bye = byeLabel;
    if (bye == null || bye.isEmpty) return '$roundLabel • $gameLabel';
    return '$roundLabel • $gameLabel • $bye';
  }
}

TournamentScheduleSummary tournamentScheduleSummary({
  required TournamentFormat format,
  required int participantCount,
}) {
  final count = participantCount.clamp(0, 1 << 20).toInt();
  if (count <= 1) {
    return const TournamentScheduleSummary(
      rounds: 0,
      games: 0,
      maxGamesPerRound: 0,
    );
  }

  switch (format) {
    case TournamentFormat.roundRobin:
    case TournamentFormat.doubleRoundRobin:
      final roundsPerCycle = count.isEven ? count - 1 : count;
      final gamesPerCycle = count * (count - 1) ~/ 2;
      final cycles = format == TournamentFormat.doubleRoundRobin ? 2 : 1;
      return TournamentScheduleSummary(
        rounds: roundsPerCycle * cycles,
        games: gamesPerCycle * cycles,
        maxGamesPerRound: count ~/ 2,
        byeLabel: count.isOdd ? '1 bye per round' : null,
      );
    case TournamentFormat.knockout:
      var rounds = 0;
      var slots = 1;
      while (slots < count) {
        slots *= 2;
        rounds++;
      }
      final firstRoundGames = count - (slots ~/ 2);
      final laterRoundGames = slots ~/ 4;
      return TournamentScheduleSummary(
        rounds: rounds,
        games: count - 1,
        maxGamesPerRound:
            max(firstRoundGames, laterRoundGames).clamp(1, count).toInt(),
        byeLabel: slots == count ? null : '${slots - count} first-round byes',
      );
  }
}

enum KnockoutTiebreakMode {
  higherEloAdvances,
  rematchThenArmageddon,
  armageddonOnly,
}

extension KnockoutTiebreakModeLabel on KnockoutTiebreakMode {
  String get displayName => switch (this) {
    KnockoutTiebreakMode.higherEloAdvances => 'Higher ELO advances',
    KnockoutTiebreakMode.rematchThenArmageddon => 'Rematch, then armageddon',
    KnockoutTiebreakMode.armageddonOnly => 'Armageddon',
  };
}

enum KnockoutReseeding { fixedBracket, reseedEachRound }

extension KnockoutReseedingLabel on KnockoutReseeding {
  String get displayName => switch (this) {
    KnockoutReseeding.fixedBracket => 'Fixed bracket',
    KnockoutReseeding.reseedEachRound => 'Reseed each round',
  };
}

/// A single seat in the bracket. We don't reuse [BotIdentity] directly so
/// the server can swap engines / re-roll names without churning the
/// participant list.
@immutable
class TournamentParticipant {
  const TournamentParticipant({
    required this.id,
    required this.identity,
    required this.engine,
    this.isHuman = false,
  });
  final String id;
  final BotIdentity identity;
  final BotEngineKind engine;
  final bool isHuman;
}

enum TournamentGameStatus { scheduled, inProgress, finished }

@immutable
class TournamentGame {
  const TournamentGame({
    required this.id,
    required this.round,
    required this.whiteId,
    required this.blackId,
    required this.status,
    this.result,
    this.fen,
    this.lastMoveUci,
    this.movesUci = const [],
    this.whiteMillis,
    this.blackMillis,
    this.startingFen,
    this.endReason,
    this.ecoLine,
    this.baseSecondsOverride,
    this.incrementSecondsOverride,
    this.drawAdvancesParticipantId,
    this.tiebreakLabel,
    this.clockUpdatedAt,
  });

  final String id;
  final int round;
  final String whiteId;
  final String blackId;
  final TournamentGameStatus status;

  /// 1-0 / 0-1 / 1/2-1/2 / `*` for in-progress / not started.
  final String? result;
  final String? fen;
  final String? lastMoveUci;
  final List<String> movesUci;
  final int? whiteMillis;
  final int? blackMillis;
  final String? startingFen;

  /// Why this game ended (timeout, mate, …) — null while in progress.
  final String? endReason;

  /// If this game came from an ECO-locked opening, the human-readable
  /// label of the line (e.g. "B12 — Caro-Kann"). Otherwise null.
  final String? ecoLine;

  /// Optional per-game clock override used by knockout tiebreak games.
  final int? baseSecondsOverride;
  final int? incrementSecondsOverride;

  /// Armageddon-style draw odds. When set and the game result is a draw,
  /// this participant advances in knockout resolution.
  final String? drawAdvancesParticipantId;

  /// Human label for bracket tiebreak games.
  final String? tiebreakLabel;

  /// Wall-clock instant when [whiteMillis]/[blackMillis] were last sampled.
  /// The UI subtracts elapsed time for the side to move so observed engine
  /// games keep live clock pressure between moves.
  final DateTime? clockUpdatedAt;

  TournamentGame copyWith({
    TournamentGameStatus? status,
    String? result,
    String? fen,
    String? lastMoveUci,
    List<String>? movesUci,
    int? whiteMillis,
    int? blackMillis,
    String? startingFen,
    String? endReason,
    String? ecoLine,
    int? baseSecondsOverride,
    int? incrementSecondsOverride,
    String? drawAdvancesParticipantId,
    String? tiebreakLabel,
    DateTime? clockUpdatedAt,
  }) {
    return TournamentGame(
      id: id,
      round: round,
      whiteId: whiteId,
      blackId: blackId,
      status: status ?? this.status,
      result: result ?? this.result,
      fen: fen ?? this.fen,
      lastMoveUci: lastMoveUci ?? this.lastMoveUci,
      movesUci: movesUci ?? this.movesUci,
      whiteMillis: whiteMillis ?? this.whiteMillis,
      blackMillis: blackMillis ?? this.blackMillis,
      startingFen: startingFen ?? this.startingFen,
      endReason: endReason ?? this.endReason,
      ecoLine: ecoLine ?? this.ecoLine,
      baseSecondsOverride: baseSecondsOverride ?? this.baseSecondsOverride,
      incrementSecondsOverride:
          incrementSecondsOverride ?? this.incrementSecondsOverride,
      drawAdvancesParticipantId:
          drawAdvancesParticipantId ?? this.drawAdvancesParticipantId,
      tiebreakLabel: tiebreakLabel ?? this.tiebreakLabel,
      clockUpdatedAt: clockUpdatedAt ?? this.clockUpdatedAt,
    );
  }
}

/// Snapshot of one participant's score in the cross-table.
@immutable
class TournamentStanding {
  const TournamentStanding({
    required this.participantId,
    required this.points,
    required this.played,
  });
  final String participantId;
  final double points;
  final int played;
}

/// Top-level tournament config sent to the server when the user creates one.
@immutable
class TournamentConfig {
  const TournamentConfig({
    required this.id,
    required this.format,
    required this.baseSeconds,
    required this.incrementSeconds,
    required this.participants,
    this.ecoLines = const <EcoOpeningSeed>[],
    this.title = 'Engine Cup',
    this.knockoutTiebreakMode = KnockoutTiebreakMode.rematchThenArmageddon,
    this.knockoutReseeding = KnockoutReseeding.reseedEachRound,
  });

  final String id;
  final String title;
  final TournamentFormat format;
  final int baseSeconds;
  final int incrementSeconds;
  final List<TournamentParticipant> participants;
  final KnockoutTiebreakMode knockoutTiebreakMode;
  final KnockoutReseeding knockoutReseeding;

  /// When non-empty the tournament conductor forces each game to start
  /// from one of these lines (rotated through round-robin style). Used by
  /// the ECO-locked opening tournament mode.
  final List<EcoOpeningSeed> ecoLines;

  TournamentConfig copyWith({
    String? id,
    String? title,
    TournamentFormat? format,
    int? baseSeconds,
    int? incrementSeconds,
    List<TournamentParticipant>? participants,
    KnockoutTiebreakMode? knockoutTiebreakMode,
    KnockoutReseeding? knockoutReseeding,
    List<EcoOpeningSeed>? ecoLines,
  }) {
    return TournamentConfig(
      id: id ?? this.id,
      title: title ?? this.title,
      format: format ?? this.format,
      baseSeconds: baseSeconds ?? this.baseSeconds,
      incrementSeconds: incrementSeconds ?? this.incrementSeconds,
      participants: participants ?? this.participants,
      knockoutTiebreakMode: knockoutTiebreakMode ?? this.knockoutTiebreakMode,
      knockoutReseeding: knockoutReseeding ?? this.knockoutReseeding,
      ecoLines: ecoLines ?? this.ecoLines,
    );
  }
}

/// One ECO-locked opening seed — the conductor sets up this position
/// before turning the engines loose.
@immutable
class EcoOpeningSeed {
  const EcoOpeningSeed({
    required this.eco,
    required this.label,
    required this.fen,
    required this.moveSequence,
  });

  /// ECO code, e.g. "B12".
  final String eco;

  /// Human-friendly name shown in the standings/game header.
  final String label;

  /// FEN after the opening moves have been played.
  final String fen;

  /// UCI moves that lead to [fen] from the standard initial position. Stored
  /// so the move list shows the opening sequence as the engines played it.
  final List<String> moveSequence;
}

/// Top-level state the server pushes to subscribed clients.
@immutable
class TournamentSnapshot {
  const TournamentSnapshot({
    required this.config,
    required this.games,
    required this.standings,
    required this.currentRound,
    required this.totalRounds,
    required this.isRunning,
    required this.resourceAssessment,
  });

  final TournamentConfig config;
  final List<TournamentGame> games;
  final List<TournamentStanding> standings;
  final int currentRound;
  final int totalRounds;
  final bool isRunning;
  final TournamentResourceAssessment resourceAssessment;

  TournamentGame? gameById(String id) {
    for (final g in games) {
      if (g.id == id) return g;
    }
    return null;
  }

  TournamentParticipant? participantById(String id) {
    for (final p in config.participants) {
      if (p.id == id) return p;
    }
    return null;
  }

  String? get humanParticipantId {
    for (final p in config.participants) {
      if (p.isHuman) return p.id;
    }
    return null;
  }

  bool get hasHumanParticipant => humanParticipantId != null;

  bool isHumanParticipant(String id) => participantById(id)?.isHuman == true;

  bool isHumanGame(TournamentGame game) {
    return isHumanParticipant(game.whiteId) || isHumanParticipant(game.blackId);
  }

  TournamentSnapshot copyWith({
    List<TournamentGame>? games,
    List<TournamentStanding>? standings,
    int? currentRound,
    int? totalRounds,
    bool? isRunning,
    TournamentResourceAssessment? resourceAssessment,
  }) {
    return TournamentSnapshot(
      config: config,
      games: games ?? this.games,
      standings: standings ?? this.standings,
      currentRound: currentRound ?? this.currentRound,
      totalRounds: totalRounds ?? this.totalRounds,
      isRunning: isRunning ?? this.isRunning,
      resourceAssessment: resourceAssessment ?? this.resourceAssessment,
    );
  }
}

String newTournamentEventId() {
  return 'event_${DateTime.now().toUtc().microsecondsSinceEpoch}';
}

enum TournamentResourceWarningLevel { ok, caution, unsuitable }

@immutable
class TournamentResourceAssessment {
  const TournamentResourceAssessment({
    required this.level,
    required this.hostCores,
    required this.recommendedConcurrency,
    required this.recommendedMaxParticipants,
    required this.message,
  });

  final TournamentResourceWarningLevel level;
  final int hostCores;
  final int recommendedConcurrency;
  final int recommendedMaxParticipants;
  final String message;

  bool get shouldWarn => level != TournamentResourceWarningLevel.ok;
}
