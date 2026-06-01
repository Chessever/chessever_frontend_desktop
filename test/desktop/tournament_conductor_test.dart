import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';

void main() {
  test(
    'does not advance while a human game in the round is unfinished',
    () async {
      final snapshots = <TournamentSnapshot>[];
      final conductor = Conductor(
        config: _roundRobinConfig(),
        onSnapshotChange: snapshots.add,
        enginePathFor: (_) => null,
      );

      final runFuture = conductor.run();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await conductor.shutdown();
      await runFuture.timeout(const Duration(seconds: 1));

      final latest = snapshots.last;
      expect(latest.currentRound, 1);

      final humanRoundOneGame = latest.games.singleWhere(
        (game) => game.round == 1 && latest.isHumanGame(game),
      );
      expect(humanRoundOneGame.status, TournamentGameStatus.scheduled);

      final engineRoundOneGame = latest.games.singleWhere(
        (game) => game.round == 1 && !latest.isHumanGame(game),
      );
      expect(engineRoundOneGame.status, TournamentGameStatus.finished);

      final laterRounds = latest.games.where((game) => game.round > 1);
      expect(laterRounds, isNotEmpty);
      expect(
        laterRounds.every(
          (game) => game.status == TournamentGameStatus.scheduled,
        ),
        isTrue,
      );
    },
  );

  test('advances after the human result completes the round', () async {
    final snapshots = <TournamentSnapshot>[];
    final conductor = Conductor(
      config: _roundRobinConfig(),
      onSnapshotChange: snapshots.add,
      enginePathFor: (_) => null,
    );

    final runFuture = conductor.run();
    await _waitFor(() {
      if (snapshots.isEmpty) return false;
      final latest = snapshots.last;
      return latest.currentRound == 1 &&
          latest.games.any(
            (game) =>
                game.round == 1 &&
                !latest.isHumanGame(game) &&
                game.status == TournamentGameStatus.finished,
          );
    });

    final firstRoundHumanGame = snapshots.last.games.singleWhere(
      (game) => game.round == 1 && snapshots.last.isHumanGame(game),
    );
    conductor.recordHumanGameResult(
      gameId: firstRoundHumanGame.id,
      result: '1-0',
      fen: firstRoundHumanGame.fen ?? '',
      movesUci: const [],
      whiteMillis: 300000,
      blackMillis: 300000,
      endReason: 'test result',
    );

    await _waitFor(() => snapshots.last.currentRound > 1);
    await conductor.shutdown();
    await runFuture.timeout(const Duration(seconds: 1));

    final latest = snapshots.last;
    expect(latest.currentRound, greaterThan(1));
    expect(
      latest.games
          .where((game) => game.round == 1)
          .every((game) => game.status == TournamentGameStatus.finished),
      isTrue,
    );
  });
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('condition was not met within $timeout');
}

TournamentConfig _roundRobinConfig() {
  return TournamentConfig(
    id: 'test-tournament',
    title: 'Test Tournament',
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
          elo: 1500,
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
          elo: 1400,
        ),
        engine: BotEngineKind.stockfish,
      ),
      TournamentParticipant(
        id: 'bot-b',
        identity: BotIdentity(
          firstName: 'Bot',
          lastName: 'B',
          countryCode: 'US',
          elo: 1450,
        ),
        engine: BotEngineKind.stockfish,
      ),
      TournamentParticipant(
        id: 'bot-c',
        identity: BotIdentity(
          firstName: 'Bot',
          lastName: 'C',
          countryCode: 'US',
          elo: 1500,
        ),
        engine: BotEngineKind.stockfish,
      ),
    ],
  );
}
