import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/play_from_here.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';

void main() {
  group('play from here defaults', () {
    test('assigns the side to move to the bot from an initial FEN', () {
      expect(
        defaultPlayFromHereHumanColor(
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        ),
        PlayColorChoice.black,
      );
    });

    test('keeps the human opposite black-to-move positions', () {
      expect(
        defaultPlayFromHereHumanColor(
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        ),
        PlayColorChoice.white,
      );
    });

    test('falls back to the old white default for malformed FEN text', () {
      expect(defaultPlayFromHereHumanColor('not a fen'), PlayColorChoice.white);
    });

    test('makes the seeded side-to-move belong to the bot', () {
      final afterE4 = Chess.initial.play(NormalMove.fromUci('e2e4'));
      final config = PlayConfig.defaults.copyWith(
        color: defaultPlayFromHereHumanColor(afterE4.fen),
        startingFen: Chess.initial.fen,
        startingMovesUci: const ['e2e4'],
      );

      final state = debugInitialPlayState(config);

      expect(state.position.turn, Side.black);
      expect(state.humanSide, Side.white);
      expect(state.isBotToMove, isTrue);
    });

    test('start-clock-immediately seeds clocks ticking from session start', () {
      final config = PlayConfig.defaults.copyWith(
        startingFen: Chess.initial.fen,
        startClockImmediately: true,
      );

      final state = debugInitialPlayState(config);

      expect(state.activeClock, Side.white);
      expect(state.lastClockTick, isNotNull);
    });

    test('seeds white and black clocks independently', () {
      final draft = initialPlayFromHereClockDraft(
        const PlayFromHereSeed(
          fen: '8/8/8/8/8/8/8/8 w - - 0 1',
          inheritedWhiteBaseSeconds: 242,
          inheritedWhiteIncrementSeconds: 3,
          inheritedBlackBaseSeconds: 181,
          inheritedBlackIncrementSeconds: 5,
        ),
      );

      expect(draft.whiteBaseSeconds, 242);
      expect(draft.whiteIncrementSeconds, 3);
      expect(draft.blackBaseSeconds, 181);
      expect(draft.blackIncrementSeconds, 5);
      expect(draft.mirror, isFalse);
      expect(draft.inherited, isTrue);
    });

    test('keeps mirroring when inherited side clocks match', () {
      final draft = initialPlayFromHereClockDraft(
        const PlayFromHereSeed(
          fen: '8/8/8/8/8/8/8/8 w - - 0 1',
          inheritedWhiteBaseSeconds: 300,
          inheritedWhiteIncrementSeconds: 2,
          inheritedBlackBaseSeconds: 300,
          inheritedBlackIncrementSeconds: 2,
        ),
      );

      expect(draft.mirror, isTrue);
      expect(draft.inherited, isTrue);
    });
  });
}
