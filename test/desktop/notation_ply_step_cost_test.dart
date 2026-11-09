// What one ply step costs the inline notation. Board stepping does this once
// per move, so the notation must re-render only the two moves whose highlight
// changed, not the whole paragraph (it rebuilt all 87 moves before).
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _moves =
    '1. e4 d6 2. d4 Nf6 3. Nc3 g6 4. Be3 Bg7 5. Qd2 c6 6. f3 b5 7. Nge2 Nbd7 '
    '8. Bh6 Bxh6 9. Qxh6 Bb7 10. a3 e5 11. O-O-O Qe7 12. Kb1 a6 13. Nc1 O-O-O '
    '14. Nb3 exd4 15. Rxd4 c5 16. Rd1 Nb6 17. g3 Kb8 18. Na5 Ba8 19. Bh3 d5 '
    '20. Qf4+ Ka7 21. Rhe1 d4 22. Nd5 Nbxd5 23. exd5 Qd6 24. Rxd4 cxd4 '
    '25. Re7+ Kb6 26. Qxd4+ Kxa5 27. b4+ Ka4 28. Qc3 Qxd5 29. Ra7 Bb7 '
    '30. Rxb7 Qc4 31. Qxf6 Kxa3 32. Qxa6+ Kxb4 33. c3+ Kxc3 34. Qa1+ Kd2 '
    '35. Qb2+ Kd1 36. Bf1 Rd2 37. Rd7 Rxd7 38. Bxc4 bxc4 39. Qxh8 Rd3 '
    '40. Qa8 c3 41. Qa4+ Ke1 42. f4 f5 43. Kc1 Rd2 44. Qa7 1-0';

String _withClocks(String moves) {
  var i = 0;
  return moves
      .split(' ')
      .map((token) {
        if (RegExp(r'^\d+\.$').hasMatch(token) || token == '1-0') return token;
        i++;
        return '$token {[%clk 0:${(59 - i % 50).toString().padLeft(2, '0')}:00]}';
      })
      .join(' ');
}

void main() {
  for (final mode in NotationLayoutMode.values) {
    testWidgets('a ply step re-renders few widgets (${mode.name})', (
      tester,
    ) async {
      final game = ChessGame.fromPgn(
        'ply-step-cost',
        '[Result "1-0"]\n\n${_withClocks(_moves)}',
      );
      final pointer = ValueNotifier<List<int>>(const [40]);
      addTearDown(pointer.dispose);
      final layout = ValueNotifier(mode);
      addTearDown(layout.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 700,
              child: ValueListenableBuilder<List<int>>(
                valueListenable: pointer,
                builder:
                    (context, active, _) => NotationLadderView(
                      game: game,
                      activePointer: active,
                      // A fresh closure per build, as real hosts pass.
                      onJump: (_) {},
                      layoutModeController: layout,
                    ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rebuilt = <String, int>{};
      debugOnRebuildDirtyWidget = (element, _) {
        final name = element.widget.runtimeType.toString();
        rebuilt[name] = (rebuilt[name] ?? 0) + 1;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      pointer.value = const [41];
      await tester.pump();
      debugOnRebuildDirtyWidget = null;

      // The old and the new highlighted move, nothing else (all 87 before).
      expect(
        rebuilt['_LadderChip'] ?? 0,
        lessThanOrEqualTo(2),
        reason: '$rebuilt',
      );
      expect(
        rebuilt['_InlineMove'] ?? 0,
        lessThanOrEqualTo(2),
        reason: '$rebuilt',
      );
      expect(
        rebuilt['_PairRow'] ?? 0,
        lessThanOrEqualTo(2),
        reason: '$rebuilt',
      );

      // The stable slot key still brings a far jump into view.
      pointer.value = const [86];
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(NotationLadderView));
      final last = tester.getRect(find.text('Qa7', findRichText: true).last);
      expect(
        viewport.contains(last.center),
        isTrue,
        reason: '$last in $viewport',
      );
    });
  }
}
