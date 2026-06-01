import 'package:flutter_test/flutter_test.dart';

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
  });
}
