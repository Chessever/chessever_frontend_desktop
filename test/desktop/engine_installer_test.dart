import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart' show Side;

import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_models.dart';

void main() {
  group('engine play search tuning', () {
    test('stockfish keeps clock context but adds a bounded movetime', () {
      final moveTime = stockfishMoveTimeMillis(
        elo: 1500,
        whiteMillis: 300000,
        blackMillis: 300000,
        incrementMillis: 0,
      );

      expect(
        engineGoCommand(
          BotEngineKind.stockfish,
          elo: 1500,
          whiteMillis: 300000,
          blackMillis: 300000,
          incrementMillis: 0,
          sideToMove: Side.white,
        ),
        'go wtime 300000 btime 300000 winc 0 binc 0 movetime $moveTime',
      );
    });

    test('stockfish movetime is bounded by clock and absolute caps', () {
      expect(
        stockfishMoveTimeMillis(
          elo: 1320,
          whiteMillis: 1000,
          blackMillis: 1000,
          incrementMillis: 0,
        ),
        140,
      );
      expect(
        stockfishMoveTimeMillis(
          elo: 3190,
          whiteMillis: 600000,
          blackMillis: 600000,
          incrementMillis: 2000,
        ),
        inInclusiveRange(4000, 12000),
      );
    });

    test('leela uses node-limited searches so it returns a bestmove', () {
      expect(leelaNodeBudgetForElo(800), 8);
      expect(leelaNodeBudgetForElo(2000), 28);
      expect(leelaNodeBudgetForElo(3200), 48);
      expect(
        engineGoCommand(
          BotEngineKind.leela,
          elo: 2000,
          whiteMillis: 300000,
          blackMillis: 300000,
          incrementMillis: 0,
          sideToMove: Side.white,
        ),
        'go wtime 300000 btime 300000 winc 0 binc 0 movetime 1616 nodes 28',
      );
    });

    test('legacy Maia UCI engines are node-limited too', () {
      expect(maiaLegacyNodeBudgetForElo(1100), 6);
      expect(maiaLegacyNodeBudgetForElo(1900), 32);
      expect(
        engineGoCommand(
          BotEngineKind.maia,
          elo: 1500,
          whiteMillis: 300000,
          blackMillis: 300000,
          incrementMillis: 0,
          sideToMove: Side.white,
        ),
        'go wtime 300000 btime 300000 winc 0 binc 0 movetime 1527 nodes 19',
      );
    });

    test('play and tournament engines share strength setup commands', () {
      expect(
        engineStrengthOptionCommands(BotEngineKind.stockfish, 1500),
        <String>[
          'setoption name UCI_LimitStrength value true',
          'setoption name UCI_Elo value 1500',
          'setoption name Skill Level value 2',
        ],
      );
      expect(stockfishSkillLevelForElo(3190), 20);

      expect(engineStrengthOptionCommands(BotEngineKind.leela, 1500), <String>[
        'setoption name PolicyTemperature value 1.06',
      ]);
      expect(leelaPolicyTemperatureForElo(800), 1.5);
      expect(leelaPolicyTemperatureForElo(3200), 0);
      expect(engineStrengthOptionCommands(BotEngineKind.maia, 1500), isEmpty);
    });

    test('think time scales by time control and clock pressure', () {
      final bullet = clockAwareMoveTimeMillis(
        elo: 1500,
        ownMillis: 60000,
        incrementMillis: 0,
        baseMillis: 60000,
        ply: 30,
      );
      final blitz = clockAwareMoveTimeMillis(
        elo: 1500,
        ownMillis: 300000,
        incrementMillis: 0,
        baseMillis: 300000,
        ply: 30,
      );
      final rapid = clockAwareMoveTimeMillis(
        elo: 1500,
        ownMillis: 600000,
        incrementMillis: 0,
        baseMillis: 600000,
        ply: 30,
      );
      final relaxedLowElo = clockAwareMoveTimeMillis(
        elo: 900,
        ownMillis: 180000,
        incrementMillis: 0,
        baseMillis: 300000,
        ply: 30,
      );
      final pressuredLowElo = clockAwareMoveTimeMillis(
        elo: 900,
        ownMillis: 8000,
        incrementMillis: 0,
        baseMillis: 300000,
        ply: 30,
      );

      expect(blitz, greaterThan(bullet));
      expect(rapid, greaterThan(blitz));
      expect(pressuredLowElo, lessThan(relaxedLowElo));
      expect(pressuredLowElo, lessThan(500));
    });

    test('low elo jitter permits occasional longer and panic moves', () {
      final calm = clockAwareMoveTimeMillis(
        elo: 900,
        ownMillis: 300000,
        incrementMillis: 0,
        baseMillis: 300000,
        ply: 30,
        random: math.Random(11),
      );
      final panic = clockAwareMoveTimeMillis(
        elo: 900,
        ownMillis: 8000,
        incrementMillis: 0,
        baseMillis: 300000,
        ply: 30,
        random: math.Random(11),
      );

      expect(calm, inInclusiveRange(400, 4200));
      expect(panic, lessThan(calm));
      expect(panic, lessThan(500));
    });

    test(
      'move budgets use the mover clock instead of the lower opponent clock',
      () {
        final whiteMoveTime = stockfishMoveTimeMillis(
          elo: 1800,
          whiteMillis: 300000,
          blackMillis: 900,
          incrementMillis: 0,
          sideToMove: Side.white,
        );
        final blackMoveTime = stockfishMoveTimeMillis(
          elo: 1800,
          whiteMillis: 300000,
          blackMillis: 900,
          incrementMillis: 0,
          sideToMove: Side.black,
        );

        expect(whiteMoveTime, greaterThan(1000));
        expect(blackMoveTime, lessThan(200));
        expect(whiteMoveTime, greaterThan(blackMoveTime));
        expect(
          engineGoCommand(
            BotEngineKind.stockfish,
            elo: 1800,
            whiteMillis: 300000,
            blackMillis: 900,
            incrementMillis: 0,
            sideToMove: Side.white,
          ).endsWith('movetime $whiteMoveTime'),
          isTrue,
        );
        expect(
          engineGoCommand(
            BotEngineKind.stockfish,
            elo: 1800,
            whiteMillis: 300000,
            blackMillis: 900,
            incrementMillis: 0,
            sideToMove: Side.black,
          ).endsWith('movetime $blackMoveTime'),
          isTrue,
        );
      },
    );
  });
}
