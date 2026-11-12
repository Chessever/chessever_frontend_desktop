import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _moves =
    '1. e4 {[%clk 0:05:00]} e5 {[%clk 0:05:00]} '
    '2. Nf3 {[%clk 0:04:59]} Nc6 {[%clk 0:04:58]} '
    '3. Bc4 {[%clk 0:04:57]} Bc5 {[%clk 0:04:56]}';

ChessGame _game(String moves) => ChessGame.fromPgn(
  'live-notation',
  '[TimeControl "300"]\n[Result "*"]\n\n$moves *',
);

void main() {
  for (final mode in NotationLayoutMode.values) {
    testWidgets('live append reuses unchanged ${mode.name} move widgets', (
      tester,
    ) async {
      final game = ValueNotifier(_game(_moves));
      final layout = ValueNotifier(mode);
      addTearDown(game.dispose);
      addTearDown(layout.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<ChessGame>(
              valueListenable: game,
              builder:
                  (context, value, _) => NotationLadderView(
                    game: value,
                    activePointer: const [],
                    onJump: (_) {},
                    layoutModeController: layout,
                  ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final previous = debugOnRebuildDirtyWidget;
      final builds = <String, int>{};
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        final type = element.widget.runtimeType.toString();
        builds.update(type, (n) => n + 1, ifAbsent: () => 1);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      // A live PGN is parsed into fresh objects, including its unchanged prefix.
      game.value = _game('$_moves 4. d3 {[%clk 0:04:55]}');
      await tester.pump();
      debugOnRebuildDirtyWidget = previous;
      expect(find.text('d3', findRichText: true), findsOneWidget);
      expect(builds['_InlineMove'] ?? 0, lessThanOrEqualTo(1));
      expect(builds['_LadderChip'] ?? 0, lessThanOrEqualTo(2));
    });
  }
}
