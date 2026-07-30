import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  group('shouldShowNotationActiveHighlight', () {
    test('stays on for every right-rail page including Explorer', () {
      // Regression: Open Explorer set rightRailActivePage to 1 and the board
      // suppressed highlight via page == 0, so the notation cursor vanished
      // while the move pointer was still intact.
      for (final page in <int>[0, 1, 2]) {
        expect(
          shouldShowNotationActiveHighlight(rightRailActivePage: page),
          isTrue,
          reason: 'page $page must keep the notation selection highlight',
        );
      }
    });
  });

  group('NotationLadderView active highlight', () {
    testWidgets(
      'paints the active move when highlight policy is true under Explorer',
      (tester) async {
        await tester.pumpWidget(
          _ladderHost(
            game: _sampleGame(),
            activePointer: const <int>[2],
            showActiveHighlight: shouldShowNotationActiveHighlight(
              rightRailActivePage: 1,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          _primarySelectedChipCount(tester),
          greaterThan(0),
          reason:
              'Explorer-open highlight policy must still paint the active move',
        );
      },
    );

    testWidgets(
      'blanks selection only when showActiveHighlight is explicitly false',
      (tester) async {
        await tester.pumpWidget(
          _ladderHost(
            game: _sampleGame(),
            activePointer: const <int>[2],
            showActiveHighlight: false,
          ),
        );
        await tester.pumpAndSettle();

        expect(_primarySelectedChipCount(tester), 0);
      },
    );
  });

  group('Open Explorer preserves board pointer + highlight policy', () {
    testWidgets(
      'book-icon open leaves a non-start pointer selected under Explorer',
      (tester) async {
        // Drive the real strip toggle → rightRailActivePage path that the
        // board uses, and assert the shipped highlight policy still paints
        // for that page while the active pointer is unchanged.
        _ignoreExplorerEmptyStateOverflowForTest();
        const tabId = 'board-explorer-highlight';
        const cursor = <int>[2];
        final activePointer = ValueNotifier<ChessMovePointer>(
          List<int>.from(cursor),
        );
        addTearDown(activePointer.dispose);
        var stepped = 0;

        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 480,
                  height: 1100,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final page = ref.watch(
                        rightRailActivePageProvider(tabId),
                      );
                      return ValueListenableBuilder<ChessMovePointer>(
                        valueListenable: activePointer,
                        builder: (context, pointer, _) {
                          return NotationOpeningPanel(
                            tabId: tabId,
                            notationChild: NotationLadderView(
                              game: _sampleGame(),
                              activePointer: pointer,
                              showActiveHighlight:
                                  shouldShowNotationActiveHighlight(
                                    rightRailActivePage: page,
                                  ),
                              onJump: (next) {
                                activePointer.value = List<int>.from(next);
                              },
                            ),
                            currentFen: Chess.initial.fen,
                            startingFen: Chess.initial.fen,
                            lineUcis: const <String>[],
                            onPlayUciMove: (_) {},
                            onNotationStep: (delta) {
                              stepped += delta;
                              final current =
                                  activePointer.value.isEmpty
                                      ? 0
                                      : activePointer.value.last;
                              activePointer.value = <int>[
                                (current + delta).clamp(0, 3),
                              ];
                              return true;
                            },
                            canGoBack: true,
                            canGoForward: true,
                            onFirstMove: () {},
                            onPreviousMove: () {
                              stepped -= 1;
                              final current =
                                  activePointer.value.isEmpty
                                      ? 0
                                      : activePointer.value.last;
                              activePointer.value = <int>[
                                (current - 1).clamp(0, 3),
                              ];
                            },
                            onNextMove: () {
                              stepped += 1;
                              final current =
                                  activePointer.value.isEmpty
                                      ? 0
                                      : activePointer.value.last;
                              activePointer.value = <int>[
                                (current + 1).clamp(0, 3),
                              ];
                            },
                            onLastMove: () {},
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(activePointer.value, cursor);
        expect(
          tester.widget<NotationLadderView>(find.byType(NotationLadderView))
              .showActiveHighlight,
          isTrue,
        );
        expect(_primarySelectedChipCount(tester), greaterThan(0));

        // Real book-icon entry writes rightRailActivePage (same store the
        // board pane reads for highlight policy).
        await tester.tap(_byDesktopTooltip('Open Explorer'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(container.read(rightRailActivePageProvider(tabId)), 1);
        // Cursor must not be cleared by opening Explorer.
        expect(activePointer.value, cursor);
        final ladderAfterOpen = tester.widget<NotationLadderView>(
          find.byType(NotationLadderView),
        );
        expect(ladderAfterOpen.activePointer, cursor);
        expect(
          ladderAfterOpen.showActiveHighlight,
          isTrue,
          reason:
              'shipped highlight policy must stay true when Explorer page is open',
        );
        expect(
          shouldShowNotationActiveHighlight(rightRailActivePage: 1),
          isTrue,
        );
        // Ladder still has a non-empty display selection (policy + pointer).
        expect(
          ladderAfterOpen.showActiveHighlight
              ? ladderAfterOpen.activePointer
              : const <int>[],
          isNotEmpty,
        );

        // Stepping while Explorer is open still advances the preserved selection.
        await tester.tap(_byDesktopTooltip('Next move'));
        await tester.pump();
        expect(stepped, isNonZero);
        expect(activePointer.value, isNot(equals(cursor)));
        expect(
          tester.widget<NotationLadderView>(find.byType(NotationLadderView))
              .activePointer,
          activePointer.value,
        );
        expect(
          tester.widget<NotationLadderView>(find.byType(NotationLadderView))
              .showActiveHighlight,
          isTrue,
        );

        // Hide Explorer (book icon toggles) and keep highlight.
        await tester.tap(_byDesktopTooltip('Hide Explorer'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(container.read(rightRailActivePageProvider(tabId)), 0);
        expect(
          shouldShowNotationActiveHighlight(rightRailActivePage: 0),
          isTrue,
        );
        expect(
          tester.widget<NotationLadderView>(find.byType(NotationLadderView))
              .showActiveHighlight,
          isTrue,
        );
        expect(activePointer.value, isNotEmpty);
      },
    );
  });
}

int _primarySelectedChipCount(WidgetTester tester) {
  // Selected SAN chips fill with solid brand primary (see _LadderChip).
  return tester
      .widgetList<DecoratedBox>(find.byType(DecoratedBox))
      .where((box) {
        final decoration = box.decoration;
        if (decoration is! BoxDecoration) return false;
        return decoration.color == kPrimaryColor;
      })
      .length;
}

Finder _byDesktopTooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is DesktopTooltip && widget.message == message,
);

void _ignoreExplorerEmptyStateOverflowForTest() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
      return;
    }
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);
}

Widget _ladderHost({
  required ChessGame game,
  required ChessMovePointer activePointer,
  required bool showActiveHighlight,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 360,
        height: 420,
        child: NotationLadderView(
          game: game,
          activePointer: activePointer,
          showActiveHighlight: showActiveHighlight,
          onJump: (_) {},
        ),
      ),
    ),
  );
}

ChessGame _sampleGame() {
  final e4 = Chess.initial.play(NormalMove.fromUci('e2e4'));
  final e5 = e4.play(NormalMove.fromUci('e7e5'));
  final nf3 = e5.play(NormalMove.fromUci('g1f3'));
  final nc6 = nf3.play(NormalMove.fromUci('b8c6'));

  return ChessGame(
    gameId: 'explorer-highlight-test',
    startingFen: Chess.initial.fen,
    metadata: const <String, dynamic>{},
    mainline: [
      ChessMove(
        num: 1,
        fen: e4.fen,
        san: 'e4',
        uci: 'e2e4',
        turn: ChessColor.white,
      ),
      ChessMove(
        num: 1,
        fen: e5.fen,
        san: 'e5',
        uci: 'e7e5',
        turn: ChessColor.black,
      ),
      ChessMove(
        num: 2,
        fen: nf3.fen,
        san: 'Nf3',
        uci: 'g1f3',
        turn: ChessColor.white,
      ),
      ChessMove(
        num: 2,
        fen: nc6.fen,
        san: 'Nc6',
        uci: 'b8c6',
        turn: ChessColor.black,
      ),
    ],
  );
}
