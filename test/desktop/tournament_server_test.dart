import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';

void main() {
  test('round robin schedule math matches chess tournament formats', () {
    expect(
      tournamentScheduleSummary(
        format: TournamentFormat.roundRobin,
        participantCount: 5,
      ).label,
      '5 rounds • 10 games • 1 bye per round',
    );
    expect(
      tournamentScheduleSummary(
        format: TournamentFormat.doubleRoundRobin,
        participantCount: 5,
      ).label,
      '10 rounds • 20 games • 1 bye per round',
    );
    expect(
      tournamentScheduleSummary(
        format: TournamentFormat.knockout,
        participantCount: 6,
      ).label,
      '3 rounds • 5 games • 2 first-round byes',
    );
  });

  test(
    'generated round robin schedule has the expected round and game count',
    () async {
      final snapshots = <TournamentSnapshot>[];
      final conductor = Conductor(
        config: _config(
          participants: [
            _participant('p1'),
            _participant('p2'),
            _participant('p3'),
            _participant('p4'),
            _participant('p5'),
          ],
        ),
        onSnapshotChange: snapshots.add,
        enginePathFor: (_) => null,
      );

      await conductor.run();

      final first = snapshots.first;
      expect(first.totalRounds, 5);
      expect(first.games.length, 10);
      for (var round = 1; round <= 5; round++) {
        expect(first.games.where((game) => game.round == round), hasLength(2));
      }
    },
  );

  test(
    'round robin starts each round only after the prior round finishes',
    () async {
      final snapshots = <TournamentSnapshot>[];
      final conductor = Conductor(
        config: _config(
          participants: [
            _participant('p1', elo: 2100),
            _participant('p2', elo: 2000),
            _participant('p3', elo: 1900),
            _participant('p4', elo: 1800),
          ],
        ),
        onSnapshotChange: snapshots.add,
        enginePathFor: (_) => null,
      );

      await conductor.run();

      for (final snapshot in snapshots) {
        final round2Started = snapshot.games.any(
          (game) =>
              game.round == 2 && game.status != TournamentGameStatus.scheduled,
        );
        final round1Finished = snapshot.games
            .where((game) => game.round == 1)
            .every((game) => game.status == TournamentGameStatus.finished);
        expect(round2Started && !round1Finished, isFalse);
      }
    },
  );

  test('human tournament moves are published before the result', () async {
    final snapshots = <TournamentSnapshot>[];
    final conductor = Conductor(
      config: _config(
        participants: [
          _participant('human', isHuman: true),
          _participant('bot'),
        ],
      ),
      onSnapshotChange: snapshots.add,
      enginePathFor: (_) => null,
    );
    final runFuture = conductor.run();
    addTearDown(() async {
      await conductor.shutdown();
      await runFuture;
    });

    await _waitFor(() => snapshots.isNotEmpty);
    final game = snapshots.last.games.single;
    conductor.markHumanGameStarted(game.id);
    final afterE4 = Chess.initial.play(NormalMove.fromUci('e2e4'));

    conductor.recordHumanGameProgress(
      gameId: game.id,
      fen: afterE4.fen,
      movesUci: const ['e2e4'],
      whiteMillis: 180000,
      blackMillis: 180000,
    );

    final updated = snapshots.last.gameById(game.id)!;
    expect(updated.status, TournamentGameStatus.inProgress);
    expect(updated.lastMoveUci, 'e2e4');
    expect(updated.movesUci, ['e2e4']);
    expect(updated.fen, afterE4.fen);
  });

  test('human tournament start opens only the current pairing', () async {
    final snapshots = <TournamentSnapshot>[];
    final conductor = Conductor(
      config: _config(
        participants: [
          _participant('human', isHuman: true),
          _participant('bot-1'),
          _participant('bot-2'),
          _participant('bot-3'),
        ],
      ),
      onSnapshotChange: snapshots.add,
      enginePathFor: (_) => null,
    );
    final runFuture = conductor.run();
    addTearDown(() async {
      await conductor.shutdown();
      await runFuture;
    });

    await _waitFor(() => snapshots.isNotEmpty);
    final currentRound = snapshots.last.currentRound;
    final currentHumanGame = snapshots.last.games.singleWhere(
      (game) => game.round == currentRound && snapshots.last.isHumanGame(game),
    );

    conductor.markHumanGameStarted(currentHumanGame.id);

    final latest = snapshots.last;
    final startedHumanGames =
        latest.games
            .where(
              (game) =>
                  latest.isHumanGame(game) &&
                  game.status == TournamentGameStatus.inProgress,
            )
            .toList();
    expect(startedHumanGames.map((game) => game.id), [currentHumanGame.id]);
    expect(startedHumanGames.single.whiteMillis, 180000);
    expect(startedHumanGames.single.blackMillis, 180000);
    expect(
      latest.games
          .where(
            (game) =>
                latest.isHumanGame(game) && game.id != currentHumanGame.id,
          )
          .every((game) => game.status == TournamentGameStatus.scheduled),
      isTrue,
    );
  });

  test('starting an already-started human game is idempotent', () async {
    final snapshots = <TournamentSnapshot>[];
    final conductor = Conductor(
      config: _config(
        participants: [
          _participant('human', isHuman: true),
          _participant('bot'),
        ],
      ),
      onSnapshotChange: snapshots.add,
      enginePathFor: (_) => null,
    );
    final runFuture = conductor.run();
    addTearDown(() async {
      await conductor.shutdown();
      await runFuture;
    });

    await _waitFor(() => snapshots.isNotEmpty);
    final game = snapshots.last.games.single;

    final started = conductor.markHumanGameStarted(game.id);
    final emittedAfterStart = snapshots.length;
    final repeated = conductor.markHumanGameStarted(game.id);

    expect(started?.status, TournamentGameStatus.inProgress);
    expect(repeated?.status, TournamentGameStatus.inProgress);
    expect(snapshots.length, emittedAfterStart);
  });

  test(
    'same-round engine games progress while the human game is open',
    () async {
      final snapshots = <TournamentSnapshot>[];
      final conductor = Conductor(
        config: _config(
          participants: [
            _participant('human', isHuman: true),
            _participant('bot-1'),
            _participant('bot-2'),
            _participant('bot-3'),
          ],
        ),
        onSnapshotChange: snapshots.add,
        enginePathFor: (_) => null,
      );
      final runFuture = conductor.run();
      addTearDown(() async {
        await conductor.shutdown();
        await runFuture;
      });

      await _waitFor(() => snapshots.isNotEmpty);
      final humanGame = snapshots.last.games.singleWhere(
        (game) =>
            game.round == snapshots.last.currentRound &&
            snapshots.last.isHumanGame(game),
      );

      conductor.markHumanGameStarted(humanGame.id);
      await _waitFor(() {
        final latest = snapshots.last;
        return latest.games.any(
          (game) =>
              game.round == humanGame.round &&
              !latest.isHumanGame(game) &&
              game.status != TournamentGameStatus.scheduled,
        );
      });

      final latest = snapshots.last;
      expect(
        latest.gameById(humanGame.id)?.status,
        TournamentGameStatus.inProgress,
      );
      expect(
        latest.games.where(
          (game) =>
              game.round == humanGame.round &&
              !latest.isHumanGame(game) &&
              game.status != TournamentGameStatus.scheduled,
        ),
        isNotEmpty,
      );
    },
  );
}

TournamentConfig _config({required List<TournamentParticipant> participants}) {
  return TournamentConfig(
    id: 'event-test',
    title: 'Test Cup',
    format: TournamentFormat.roundRobin,
    baseSeconds: 180,
    incrementSeconds: 2,
    participants: participants,
  );
}

TournamentParticipant _participant(
  String id, {
  int elo = 1800,
  bool isHuman = false,
}) {
  return TournamentParticipant(
    id: id,
    identity: BotIdentity(
      firstName: id,
      lastName: 'Player',
      countryCode: 'US',
      elo: elo,
    ),
    engine: BotEngineKind.stockfish,
    isHuman: isHuman,
  );
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
