import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_strength.dart';
import 'package:chessever/desktop/state/play_setup.dart';
import 'package:chessever/desktop/widgets/play_strength_control.dart';

void main() {
  group('play strength model', () {
    test('stockfish keeps exact ELO slider semantics', () {
      expect(usesExactEloSlider(BotEngineKind.stockfish), isTrue);
      expect(normalizePlayStrength(BotEngineKind.stockfish, 1000), 1320);
      expect(normalizePlayStrength(BotEngineKind.stockfish, 1500), 1500);
      expect(normalizePlayStrength(BotEngineKind.stockfish, 4000), 3190);
      expect(playStrengthLabel(BotEngineKind.stockfish, 1500), '1500 ELO');
      expect(playStrengthControlTitle(BotEngineKind.stockfish), 'Opponent ELO');
    });

    test('leela snaps arbitrary values to finite neural profiles', () {
      expect(usesExactEloSlider(BotEngineKind.leela), isFalse);
      expect(normalizePlayStrength(BotEngineKind.leela, 900), 1000);
      expect(normalizePlayStrength(BotEngineKind.leela, 1500), 1600);
      expect(normalizePlayStrength(BotEngineKind.leela, 3150), 3200);
      expect(playStrengthLabel(BotEngineKind.leela, 1500), 'Club neural');
      expect(
        playStrengthStartSummary(BotEngineKind.leela, 1500),
        'Club neural profile',
      );
    });

    test('maia snaps arbitrary values to human cohorts', () {
      expect(usesExactEloSlider(BotEngineKind.maia), isFalse);
      expect(normalizePlayStrength(BotEngineKind.maia, 700), 600);
      expect(normalizePlayStrength(BotEngineKind.maia, 1500), 1400);
      expect(normalizePlayStrength(BotEngineKind.maia, 2500), 2600);
      expect(playStrengthLabel(BotEngineKind.maia, 1500), 'Maia 1400');
      expect(
        playStrengthControlCaption(BotEngineKind.maia),
        contains('not an arbitrary slider'),
      );
    });
  });

  group('play setup strength state', () {
    test('engine changes normalize the current strength value', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final setup = container.read(playSetupProvider.notifier);

      expect(container.read(playSetupProvider).elo, 1500);

      setup.setEngine(BotEngineKind.leela);
      expect(container.read(playSetupProvider).elo, 1600);

      setup.setElo(3100);
      expect(container.read(playSetupProvider).elo, 3200);

      setup.setEngine(BotEngineKind.maia);
      expect(container.read(playSetupProvider).elo, 2600);

      setup.setElo(1500);
      expect(container.read(playSetupProvider).elo, 1400);
    });
  });

  group('play strength control rendering', () {
    testWidgets('leela renders modes instead of an opponent ELO slider', (
      tester,
    ) async {
      await tester.pumpWidget(
        _Harness(
          child: PlayStrengthControl(
            engine: BotEngineKind.leela,
            value: 1600,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Opponent ELO'), findsNothing);
      expect(find.text('Leela mode'), findsOneWidget);
      expect(find.text('Club neural'), findsNWidgets(2));
    });

    testWidgets('maia renders cohorts instead of an opponent ELO slider', (
      tester,
    ) async {
      await tester.pumpWidget(
        _Harness(
          child: PlayStrengthControl(
            engine: BotEngineKind.maia,
            value: 1400,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Opponent ELO'), findsNothing);
      expect(find.text('Maia cohort'), findsOneWidget);
      expect(find.text('Maia 1400'), findsNWidgets(2));
    });
  });
}

class _Harness extends StatelessWidget {
  const _Harness({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: SizedBox(width: 520, child: child)),
      ),
    );
  }
}
