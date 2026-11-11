// Diagnostic regression at the real navigator -> shared notation widget seam.
// It changes no app/auth state and does not simulate an admitted user.
import 'dart:convert';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _opening = '1. e4 e5 (1... c5 2. Nf3 Nc6 3. Bb5 a6) 2. Nf3 *';
// Reduced legal position reconstructed from the supplied screenshot, not a
// claimed full upstream game. Its branch is exactly 19.g3 Qxh3 -> add Qg4.
const _queen = '''
[SetUp "1"]
[FEN "2rq1rk1/1p3ppp/4p3/p1n5/2B1n3/P3P2P/1P3PP1/RQB2RK1 b - - 0 18"]
[Result "*"]

18... Qh4 19. Qc2 (19. g3 Qxh3) *
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = FontLoader('Geist')
      ..addFont(rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'));
    await fonts.load();
  });
  for (final mode in NotationLayoutMode.values) {
    for (final width in <double>[1100, 400]) {
      for (final queenCase in <bool>[false, true]) {
        testWidgets(
          'played nested ${queenCase ? 'Qg4' : 'opening'} ${mode.name} $width',
          (tester) async {
            final nav = ChessGameNavigator(
              ChessGame.fromPgn(
                'editing-diagnostic',
                queenCase ? _queen : _opening,
              ),
            );
            final layout = ValueNotifier(mode);
            final collapse = NotationVariationCollapseController();
            late StateSetter redraw;
            addTearDown(layout.dispose);
            addTearDown(nav.dispose);
            await tester.binding.setSurfaceSize(Size(width, 900));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData.dark().copyWith(
                  textTheme: ThemeData.dark().textTheme.apply(
                    fontFamily: 'Geist',
                  ),
                ),
                home: Scaffold(
                  body: StatefulBuilder(
                    builder: (context, update) {
                      redraw = update;
                      return NotationLadderView(
                        game: nav.state.game,
                        activePointer: nav.state.movePointer,
                        onJump:
                            (p) =>
                                redraw(() => nav.goToMovePointerUnchecked(p)),
                        layoutModeController: layout,
                        variationCollapseController: collapse,
                      );
                    },
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final originalMainline =
                nav.state.game.mainline.map((m) => m.uci).toList();

            Future<List<int>> play(
              List<int> from,
              String uci,
              String san,
            ) async {
              redraw(() {
                nav.goToMovePointerUnchecked(from);
                nav.makeOrGoToMove(uci);
              });
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(nav.state.currentMove?.san, san);
              final added = List<int>.of(nav.state.movePointer);
              expect(_chip(added), findsOneWidget);
              return added;
            }

            void precedes(
              List<int> main,
              List<int> alternative,
              String reason,
            ) {
              final a = tester.getCenter(_chip(main));
              final b = tester.getCenter(_chip(alternative));
              expect(
                a.dy < b.dy - 5 || ((a.dy - b.dy).abs() <= 5 && a.dx < b.dx),
                isTrue,
                reason:
                    '$reason; principal=$main at $a, new alternative=$alternative at $b',
              );
              // This API intentionally returns line anchors, not every token.
              // Select the principal so it is inserted before the branch anchor.
              final order = visibleNotationMoveOrder(
                game: nav.state.game,
                activePointer: main,
              );
              int index(List<int> p) =>
                  order.indexWhere((q) => q.toString() == p.toString());
              expect(index(main), greaterThanOrEqualTo(0));
              expect(index(main), lessThan(index(alternative)), reason: reason);
            }

            late List<int> latest;
            if (queenCase) {
              // Enter an existing user-visible variation, then make a different
              // black reply by the same production navigator used by BoardPane.
              expect(
                ChessGameNavigatorState(
                  game: nav.state.game,
                  movePointer: [0, 0, 0],
                ).currentMove?.san,
                'g3',
              );
              expect(
                ChessGameNavigatorState(
                  game: nav.state.game,
                  movePointer: [0, 0, 1],
                ).currentMove?.san,
                'Qxh3',
              );
              latest = await play([0, 0, 0], 'h4g4', 'Qg4');
              precedes(
                [0, 0, 1],
                latest,
                '19...Qxh3 before newly entered 19...Qg4',
              );
            } else {
              final d6 = await play([0, 0, 1], 'd7d6', 'd6');
              precedes([0, 0, 2], d6, '2...Nc6 before newly entered 2...d6');
              latest = await play([0, 0, 2], 'd2d4', 'd4');
              precedes([0, 0, 3], latest, '3.Bb5 before newly entered 3.d4');
              // Grow the user-created nested line, then fork that new line too.
              final d4 = await play(d6, 'd2d4', 'd4');
              await play(d4, 'c5d4', 'cxd4');
              latest = await play(d6, 'f1b5', 'Bb5+');
              precedes(
                d4,
                latest,
                'New-line principal 3.d4 before deeper 3.Bb5+',
              );
            }
            await tester.ensureVisible(_chip(latest));
            await tester.pumpAndSettle();
            await tester.tap(_chip(latest));
            await tester.pumpAndSettle();
            expect(nav.state.movePointer, latest);
            redraw(() => nav.goToHead());
            await tester.pumpAndSettle();
            collapse.collapseAll();
            await tester.pumpAndSettle();
            collapse.expandAll();
            await tester.pumpAndSettle();
            expect(_chip(latest), findsOneWidget);
            final beforeRender = jsonEncode(nav.state.game.toJson());
            await tester.pump();
            expect(jsonEncode(nav.state.game.toJson()), beforeRender);
            expect(
              nav.state.game.mainline.map((m) => m.uci).toList(),
              originalMainline,
            );
            final pgn = exportGameToPgn(nav.state.game);
            expect(
              exportGameToPgn(
                ChessGame.fromPgn('reopened-editing-diagnostic', pgn),
              ),
              pgn,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}

Finder _chip(List<int> pointer) => find.byWidgetPredicate((widget) {
  if (widget.runtimeType.toString() != '_LadderChip') return false;
  final actual = (widget as dynamic).pointer as ChessMovePointer;
  return actual.toString() == pointer.toString();
});
