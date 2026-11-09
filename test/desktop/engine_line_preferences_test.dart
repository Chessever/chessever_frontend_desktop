import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

void main() {
  test(
    'fresh engine settings use two PVs without replacing an explicit choice',
    () {
      expect(const EngineSettings().principalVariationIndex, 1);
      expect(const EngineSettings().multiPvForStockfish(), 2);
      expect(
        engineSettingsFromCache({
          'principalVariationIndex': 4,
        }).multiPvForStockfish(),
        5,
      );
      expect(engineSettingsFromCache({}).multiPvForStockfish(), 2);
    },
  );

  test(
    'compact default matches approved split without migrating saved layouts',
    () {
      expect(
        desktopEngineRightRailInitialWeight,
        closeTo(0.17628418635800888, 0.0001),
      );
      expect(
        desktopEngineRightRailSplitStorageKey,
        'board_pane.right_rail.engine_top.v2',
      );
      expect(desktopEngineRightRailGutterThickness, 12);
    },
  );

  testWidgets('expansion is scoped to position and game, not PV ticks', (
    tester,
  ) async {
    Future<void> show({
      String fen = _start,
      Object owner = ('game-a', _start),
      String moves = 'e2e4 e7e5 g1f3 b8c6 f1b5 a7a6',
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 180,
              child: enginePvLineForTesting(
                pv: BoardPv(evaluation: 0.3, mate: null, moves: moves),
                fen: fen,
                playOwner: owner,
                onPlayUci: (_) {},
                formatSan: (_) async => ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6'],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> expand() async {
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    }

    await show();
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    await expand();
    await show(moves: 'e2e4 c7c5 g1f3 d7d6');
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

    // New target, while the display still retains the old formatted FEN.
    await show(owner: ('game-a', _afterE4));
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    await expand();
    await show(fen: _afterE4, owner: ('game-a', _afterE4), moves: 'e7e5 g1f3');
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await expand();
    // A different game at the identical board position must also reset.
    await show(fen: _afterE4, owner: ('game-b', _afterE4), moves: 'e7e5 g1f3');
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
