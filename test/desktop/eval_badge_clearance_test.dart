import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/desktop/widgets/desktop_eval_midpoint.dart';
import 'package:chessever/screens/chessboard/widgets/evaluation_bar_widget.dart';
import 'package:chessever/screens/chessboard/widgets/player_first_row_detail_widget.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  for (final mini in [false, true]) {
    for (final flipped in [false, true]) {
      for (final score in [0.0, -0.19, 0.19, -0.32, 0.32, -3.0, 3.0]) {
        testWidgets('badge clearance mini=$mini flip=$flipped eval=$score', (
          tester,
        ) async {
          const fen =
              'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                gameCardEvalCacheOnlyProvider.overrideWith(
                  (ref, fen) async => CloudEval(
                    fen: fen,
                    knodes: 0,
                    depth: 12,
                    pvs: [Pv(moves: 'e7e5', cp: (score * 100).round())],
                    requestedMultiPv: 1,
                  ),
                ),
              ],
              child: MaterialApp(
                home: Center(
                  child:
                      mini
                          ? EvaluationBarWidgetForGames(
                            width: 24,
                            height: 401,
                            fen: fen,
                            playerView: PlayerView.gridView,
                            isFlipped: flipped,
                            allowStockfishFallback: false,
                            railDecorationBuilder:
                                DesktopEvalMidpoint.behindLabel,
                          )
                          : DesktopEvalBar(
                            width: 24,
                            height: 401,
                            isFlipped: flipped,
                            evaluation: score,
                            mate: null,
                            isEvaluating: true,
                          ),
                ),
              ),
            ),
          );
          await tester.pump();
          final reference = find.byType(DesktopEvalMidpoint);
          final label = find.byWidgetPredicate(
            (w) => w is Container && w.color == kPrimaryColor,
          );
          final origin = tester.getTopLeft(reference);
          final labelBounds = tester.getRect(label).shift(-origin);
          final clip =
              tester
                      .widget<ClipPath>(
                        find.descendant(
                          of: reference,
                          matching: find.byType(ClipPath),
                        ),
                      )
                      .clipper!
                  as DesktopEvalLabelClearance;
          expect(clip.labelBounds, labelBounds);
          final path = clip.getClip(const Size(24, 401));
          expect(path.contains(labelBounds.center), isFalse);
          expect(path.contains(Offset(12, labelBounds.top - 1)), isFalse);
          expect(path.contains(Offset(12, labelBounds.bottom + 1)), isFalse);
          expect(path.contains(Offset(12, labelBounds.top - 3)), isTrue);
          expect(path.contains(Offset(12, labelBounds.bottom + 3)), isTrue);
          final marker = find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == const Color(0xFF808080),
          );
          expect(tester.getSize(marker), const Size(24, 3));
          expect(tester.getCenter(marker), origin + const Offset(12, 200.5));
          // The reference's outer Positioned precedes the opaque label.
          final stack = tester.widget<Stack>(
            find.ancestor(of: label, matching: find.byType(Stack)).first,
          );
          final labelIndex = stack.children.indexWhere(
            (w) =>
                w is Positioned &&
                w.child is Container &&
                (w.child as Container).color == kPrimaryColor,
          );
          final markerIndex = stack.children.indexWhere(
            (w) => w is Positioned && w.child is DesktopEvalMidpoint,
          );
          expect(markerIndex, greaterThanOrEqualTo(0));
          expect(markerIndex, lessThan(labelIndex));
        });
      }
    }
  }
}
