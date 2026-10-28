import 'package:chessever/desktop/widgets/desktop_eval_midpoint.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/chessboard/widgets/evaluation_bar_widget.dart';
import 'package:chessever/screens/chessboard/widgets/player_first_row_detail_widget.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

Finder get _marker => find.byWidgetPredicate(
  (widget) => widget is ColoredBox && widget.color == const Color(0xFF808080),
);

void main() {
  testWidgets('mini rail midpoint ignores score, flip and fill rotation', (
    tester,
  ) async {
    for (final width in [5.0, 14.0]) {
      for (final flipped in [false, true]) {
        for (final turns in [0, 1]) {
          for (final cp in [-2000, 0, 2000]) {
            await tester.pumpWidget(
              ProviderScope(
                key: ValueKey('$width/$flipped/$turns/$cp'),
                overrides: [
                  gameCardEvalCacheOnlyProvider.overrideWith(
                    (ref, fen) async => CloudEval(
                      fen: fen,
                      knodes: 0,
                      depth: 12,
                      pvs: [Pv(moves: 'e7e5', cp: cp)],
                      requestedMultiPv: 1,
                    ),
                  ),
                ],
                child: MaterialApp(
                  home: Builder(
                    builder: (context) {
                      ResponsiveHelper.init(context);
                      return Center(
                        child: RotatedBox(
                          quarterTurns: turns,
                          child: DesktopEvalMidpoint(
                            child: EvaluationBarWidgetForGames(
                              width: width,
                              height: 201,
                              fen: _fen,
                              playerView: PlayerView.gridView,
                              isFlipped: flipped,
                              allowStockfishFallback: false,
                              showText: false,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            );
            // Inspect both the initial/loading frame and resolved evaluation.
            for (var frame = 0; frame < 2; frame++) {
              expect(_marker, findsOneWidget);
              expect(tester.getSize(_marker), Size(width, 3));
              expect(
                tester.getCenter(_marker),
                tester.getCenter(find.byType(DesktopEvalMidpoint)),
              );
              expect(
                find.ancestor(
                  of: _marker,
                  matching: find.byType(IgnorePointer),
                ),
                findsOneWidget,
              );
              expect(
                find.ancestor(of: _marker, matching: find.byType(ClipRect)),
                findsOneWidget,
              );
              await tester.pump();
            }
          }
        }
      }
    }
  });

  testWidgets('horizontal placeholder marker is centered and passes taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 201,
            height: 3,
            child: DesktopEvalMidpoint(
              axis: Axis.horizontal,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(_marker), const Size(3, 3));
    expect(
      tester.getCenter(_marker),
      tester.getCenter(find.byType(DesktopEvalMidpoint)),
    );
    await tester.tapAt(tester.getCenter(_marker));
    expect(taps, 1);
  });
}
