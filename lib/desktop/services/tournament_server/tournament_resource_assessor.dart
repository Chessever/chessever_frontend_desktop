import 'dart:io';

import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';

TournamentResourceAssessment assessTournamentResources({
  required int participantCount,
  required Iterable<BotEngineKind> engines,
  int? hostCores,
}) {
  final cores = hostCores ?? Platform.numberOfProcessors;
  final engineList = engines.isEmpty ? [BotEngineKind.stockfish] : engines;
  final averageCost =
      engineList.map(_engineCost).reduce((a, b) => a + b) / engineList.length;
  final availableCpuUnits = (cores - 1).clamp(1, 32).toDouble();
  final gameCost = averageCost * 2;
  final maxConcurrentGames = (availableCpuUnits / gameCost).floor().clamp(1, 8);
  final recommendedMaxParticipants = (maxConcurrentGames * 4).clamp(2, 16);

  final level =
      participantCount > recommendedMaxParticipants + 4
          ? TournamentResourceWarningLevel.unsuitable
          : participantCount > recommendedMaxParticipants
          ? TournamentResourceWarningLevel.caution
          : TournamentResourceWarningLevel.ok;

  final message = switch (level) {
    TournamentResourceWarningLevel.ok =>
      'This computer can run the selected tournament comfortably.',
    TournamentResourceWarningLevel.caution =>
      'This tournament is above the recommended size for this computer. ChessEver will still start every board in the active round, so move generation may be slower.',
    TournamentResourceWarningLevel.unsuitable =>
      'This computer is not suitable for that many bot players at once. Reduce participants, use lighter bots, or expect slower moves.',
  };

  return TournamentResourceAssessment(
    level: level,
    hostCores: cores,
    recommendedConcurrency: maxConcurrentGames,
    recommendedMaxParticipants: recommendedMaxParticipants,
    message: message,
  );
}

TournamentResourceAssessment assessTournamentConfig(TournamentConfig config) {
  return assessTournamentResources(
    participantCount: config.participants.length,
    engines: config.participants.map((p) => p.engine),
  );
}

double _engineCost(BotEngineKind engine) {
  return switch (engine) {
    BotEngineKind.stockfish => 1.0,
    BotEngineKind.maia => 1.25,
    BotEngineKind.leela => 1.75,
  };
}
