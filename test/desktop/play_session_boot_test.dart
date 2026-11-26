import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';

void main() {
  group('play session boot', () {
    test('engine command uses replayed state position, not raw seed text', () {
      final config = PlayConfig.defaults.copyWith(
        startingFen: '',
        startingMovesUci: const ['e2e4'],
      );

      final state = debugInitialPlayState(config);
      final command = debugPlayEnginePositionCommand(state);

      expect(state.history, const ['e2e4']);
      expect(command, 'position fen ${state.position.fen}');
      expect(command, isNot(contains('position fen  moves')));
    });

    test('a failed engine says so and starts again on retry', () async {
      var spawns = 0;
      final notifier = PlaySessionNotifier(
        config: PlayConfig.defaults,
        engineBinaryPath: '/missing/engine',
        botIdentity: const BotIdentity(
          firstName: 'Test',
          lastName: 'Bot',
          countryCode: 'US',
          elo: 1500,
        ),
        spawnEngine: () async {
          spawns += 1;
          throw StateError('engine unavailable');
        },
      );
      addTearDown(notifier.dispose);

      await pumpEventQueue();
      expect(spawns, 1);
      expect(notifier.state.engineReady, isFalse);
      expect(notifier.state.engineFailed, isTrue);
      expect(notifier.state.engineStatus, contains('could not start'));

      await notifier.retryEngine();
      expect(spawns, 2);
      expect(notifier.state.engineFailed, isTrue);
    });

    test('retry does nothing while the engine is still starting', () async {
      var spawns = 0;
      final notifier = PlaySessionNotifier(
        config: PlayConfig.defaults,
        engineBinaryPath: '/missing/engine',
        botIdentity: const BotIdentity(
          firstName: 'Test',
          lastName: 'Bot',
          countryCode: 'US',
          elo: 1500,
        ),
        spawnEngine: () {
          spawns += 1;
          return Completer<UciEngine>().future;
        },
      );
      addTearDown(notifier.dispose);

      await pumpEventQueue();
      await notifier.retryEngine();
      expect(spawns, 1);
      expect(notifier.state.engineFailed, isFalse);
    });
  });
}
