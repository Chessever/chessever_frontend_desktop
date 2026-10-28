import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _pointer = <int>[0, 0, 0];
const _icons = <(int, String)>[
  (242, 'Best move'),
  (247, 'Book move'),
  (243, 'Missed Win'),
];

ChessGame fixture() => ChessGame.fromPgn(
  'variation-classification',
  '[SetUp "1"]\n[FEN "2b3k1/8/8/8/8/8/8/6K1 b - - 0 39"]\n[Result "*"]\n\n'
      r'39... Be6 (39... Bd7 $14 {Keep prose [%clk 0:26:23]} 40. Kf2) (39... Bf5) *',
);

ChessMove _bd7(ChessGame game) => game.mainline.first.variations!.first.first;

Finder _badge(String label) => find.byWidgetPredicate(
  (widget) => widget is DesktopTooltip && widget.message == label,
);

void main() {
  for (final (code, label) in _icons) {
    test('$label preserves branch identity, commentary and native reopen', () {
      final original = fixture();
      final snapshot = original.toJson();
      final edited = toggleBoardMoveNagAtPointer(original, _pointer, code);
      expect(_bd7(edited).nags, [14, code]);
      expect(_bd7(edited).comments, _bd7(original).comments);
      expect(edited.mainline.first.san, 'Be6');
      expect(edited.mainline.first.nags, original.mainline.first.nags);
      expect(edited.mainline.first.comments, original.mainline.first.comments);
      expect(
        edited.mainline.first.variations![1],
        original.mainline.first.variations![1],
      );
      expect(
        edited.mainline.first.variations!.first[1],
        original.mainline.first.variations!.first[1],
      );
      expect(original.toJson(), snapshot);
      final reopened = ChessGame.fromPgn('reopened', exportGameToPgn(edited));
      expect(_bd7(reopened).nags, [14, code]);
      // Native export separates the clock directive from prose comments.
      final control = ChessGame.fromPgn('control', exportGameToPgn(original));
      expect(_bd7(reopened).comments, _bd7(control).comments);
      expect(_bd7(reopened).clockTime, _bd7(original).clockTime);
      expect(reopened.mainline.first.san, 'Be6');
      expect(reopened.mainline.first.variations![1].first.san, 'Bf5');
      final cleared = toggleBoardMoveNagAtPointer(reopened, _pointer, code);
      expect(_bd7(cleared).nags, [14]);
      expect(
        _bd7(ChessGame.fromPgn('cleared', exportGameToPgn(cleared))).nags,
        [14],
      );
      expect(getNagDisplay(code), isNull);
    });

    for (final old in <int>[1, 4, 242, 247, 243]) {
      if (old == code) continue;
      test(
        '$label replaces quality $old without losing positional symbols',
        () {
          final before = toggleBoardMoveNagAtPointer(fixture(), _pointer, old);
          final after = toggleBoardMoveNagAtPointer(before, _pointer, code);
          expect(_bd7(after).nags, [14, code]);
          expect(_bd7(before).nags, [14, old]);
        },
      );
    }

    test('$label also addresses nested branches without touching Bd7', () {
      final original = ChessGame.fromPgn(
        'nested',
        '[SetUp "1"]\n[FEN "2b3k1/8/8/8/8/8/8/6K1 b - - 0 39"]\n\n'
            r'39... Be6 (39... Bd7 $14 40. Kf2 (40. Kh2)) (39... Bf5) *',
      );
      expect(_bd7(original).variations!.first.first.san, 'Kh2');
      final edited = toggleBoardMoveNagAtPointer(original, [
        0,
        0,
        0,
        0,
        0,
      ], code);
      expect(_bd7(edited).nags, [14]);
      expect(edited.mainline.first.variations!.first[1].nags, isNull);
      final nested = _bd7(edited).variations!.first.first;
      expect(nested.san, 'Kh2');
      expect(nested.nags, [code]);
      expect(edited.mainline.first.variations![1].first.nags, isNull);
    });
  }

  for (final code in <int>[1, 2, 3, 4, 5, 6, 7, 10, 14, 16, 32, 140, 146]) {
    test('existing variation symbol $code still adds and toggles off', () {
      final empty = toggleBoardMoveNagAtPointer(fixture(), _pointer, 14);
      final added = toggleBoardMoveNagAtPointer(empty, _pointer, code);
      expect(_bd7(added).nags, [code]);
      final removed = toggleBoardMoveNagAtPointer(added, _pointer, code);
      expect(_bd7(removed).nags ?? const <int>[], isEmpty);
    });
  }

  test('adding a positional symbol retains the classification badge', () {
    final best = toggleBoardMoveNagAtPointer(fixture(), _pointer, 242);
    final positional = toggleBoardMoveNagAtPointer(best, _pointer, 32);
    expect(_bd7(positional).nags, [14, 242, 32]);
    final equality = toggleBoardMoveNagAtPointer(positional, _pointer, 16);
    expect(_bd7(equality).nags, [242, 32, 16]);
  });

  test('invalid pointers and the private override marker are inert', () {
    final original = fixture();
    for (final pointer in <List<int>>[
      [],
      [999],
      [0, 999, 0],
      [0, 0, 999],
    ]) {
      expect(
        toggleBoardMoveNagAtPointer(original, pointer, 247),
        same(original),
      );
    }
    expect(
      toggleBoardMoveNagAtPointer(original, _pointer, 248),
      same(original),
    );
  });

  for (final mode in NotationLayoutMode.values) {
    for (final (code, label) in _icons) {
      testWidgets(
        '$label variation palette applies, replaces, removes in $mode',
        (tester) async {
          tester.view.physicalSize = const Size(1100, 850);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final controller = ValueNotifier(mode);
          addTearDown(controller.dispose);
          var game = fixture();
          final before = game.toJson();
          final history = <ChessGame>[];
          final targets = <List<int>>[];
          late StateSetter repaint;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    repaint = setState;
                    return NotationLadderView(
                      game: game,
                      activePointer: _pointer,
                      autoCollapseDepth: 99,
                      layoutModeController: controller,
                      onJump: (_) {},
                      onToggleMoveNag: (pointer, nag) {
                        history.add(game);
                        targets.add(List<int>.of(pointer));
                        setState(
                          () =>
                              game = toggleBoardMoveNagAtPointer(
                                game,
                                pointer,
                                nag,
                              ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          Future<void> choose(int nag) async {
            final move = find.text('Bd7', findRichText: true);
            expect(move, findsOneWidget);
            await tester.tapAt(
              tester.getCenter(move),
              buttons: kSecondaryMouseButton,
            );
            await tester.pumpAndSettle();
            final cell = find.byKey(ValueKey('notation-nag-$nag'));
            expect(cell, findsOneWidget);
            await tester.tap(cell);
            await tester.pumpAndSettle();
          }

          await choose(code);
          expect(targets.last, _pointer);
          expect(_bd7(game).nags, [14, code]);
          expect(_badge(label), findsOneWidget);
          expect(find.byType(SvgPicture), findsOneWidget);
          for (final (raw, _) in _icons) {
            expect(find.text('\$$raw', findRichText: true), findsNothing);
          }
          final replacement = code == 247 ? 242 : 247;
          await choose(replacement);
          expect(_bd7(game).nags, [14, replacement]);
          expect(find.byType(SvgPicture), findsOneWidget);
          await choose(replacement);
          expect(_bd7(game).nags, [14]);
          expect(find.byType(SvgPicture), findsNothing);
          expect(targets, everyElement(_pointer));
          // The immutable snapshots used by Board undo remain intact.
          repaint(() => game = history.first);
          await tester.pumpAndSettle();
          expect(game.toJson(), before);
          expect(find.byType(SvgPicture), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }
  test('toggling Best off clears its paired portable quality symbol', () {
    final game = ChessGame.fromPgn(
      'paired-variation-quality',
      exportGameToPgn(fixture()).replaceFirst(r'$14', r'$1 $242 $14'),
    );
    final edited = toggleBoardMoveNagAtPointer(game, [0, 0, 0], 242);
    expect(edited.mainline.first.variations!.first.first.nags, [14]);
  });
  test('Book move can be applied to Bd7 in a variation', () {
    final game = fixture();
    expect(game.mainline.first.variations!.first.first.san, 'Bd7');
    final edited = toggleBoardMoveNagAtPointer(game, [0, 0, 0], 247);
    expect(edited.mainline.first.variations!.first.first.nags, contains(247));
    expect(edited.mainline.first.variations!.first.first.nags, contains(14));
    expect(game.mainline.first.variations!.first.first.nags, [14]);
  });
}
