import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';

void main() {
  test('tournament human game records carry rating inputs', () {
    final snapshot = _snapshotWithHumanGame(
      whiteId: 'human',
      blackId: 'bot-a',
      result: '1-0',
    );
    final game = snapshot.games.single;

    final record = const PlayGameAnalyzer().buildTournamentRecord(
      snapshot: snapshot,
      game: game,
    );

    expect(record.humanColor, 'white');
    expect(record.opponentElo, 1500);
    expect(record.opponentEngine, BotEngineKind.stockfish.name);
    expect(record.userScore, 1.0);
  });

  test('newer local play profile beats stale remote profile', () {
    final remote = PlayUserProfile.fallback('Player');
    final local = remote
        .copyWithRating(
          RatedTimeControl.rapid,
          const PlayRatingStats(
            rating: 1220,
            peak: 1220,
            gamesPlayed: 1,
            wins: 1,
            losses: 0,
            draws: 0,
          ),
        )
        .copyWith(lastGameAt: DateTime(2026, 5, 27, 12));

    expect(debugShouldPreferLocalPlayProfile(local, remote), isTrue);
    expect(debugShouldPreferLocalPlayProfile(remote, local), isFalse);
  });
}

TournamentSnapshot _snapshotWithHumanGame({
  required String whiteId,
  required String blackId,
  required String result,
}) {
  return TournamentSnapshot(
    config: TournamentConfig(
      id: 'event-test',
      title: 'Rating Reflection Cup',
      format: TournamentFormat.roundRobin,
      baseSeconds: 300,
      incrementSeconds: 0,
      participants: const [
        TournamentParticipant(
          id: 'human',
          identity: BotIdentity(
            firstName: 'Human',
            lastName: 'Player',
            countryCode: 'US',
            elo: 1200,
          ),
          engine: BotEngineKind.stockfish,
          isHuman: true,
        ),
        TournamentParticipant(
          id: 'bot-a',
          identity: BotIdentity(
            firstName: 'Bot',
            lastName: 'A',
            countryCode: 'US',
            elo: 1500,
          ),
          engine: BotEngineKind.stockfish,
        ),
      ],
    ),
    games: [
      TournamentGame(
        id: 'g1',
        round: 1,
        whiteId: whiteId,
        blackId: blackId,
        status: TournamentGameStatus.finished,
        result: result,
        startingFen: Chess.initial.fen,
        fen: Chess.initial.fen,
        movesUci: const ['e2e4', 'e7e5'],
        endReason: 'test',
      ),
    ],
    standings: const [],
    currentRound: 1,
    totalRounds: 1,
    isRunning: false,
    resourceAssessment: const TournamentResourceAssessment(
      level: TournamentResourceWarningLevel.ok,
      hostCores: 8,
      recommendedConcurrency: 2,
      recommendedMaxParticipants: 8,
      message: 'ok',
    ),
  );
}
