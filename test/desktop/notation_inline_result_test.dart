import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester, {
  required String movetext,
  required NotationLayoutMode mode,
}) async {
  final game = ChessGame.fromPgn('result', '[Result "1/2-1/2"]\n\n$movetext');
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 400,
          child: NotationLadderView(
            game: game,
            activePointer: const [0],
            onJump: (_) {},
            layoutModeController: ValueNotifier(mode),
            showHeader: false,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _san(String san) =>
    find
        .byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().trim().startsWith(san),
        )
        .first;

void main() {
  testWidgets('inline notation writes the result right after the last move', (
    tester,
  ) async {
    await _pump(
      tester,
      movetext: '1. e4 e5 2. Nf3 Nc6 1/2-1/2',
      mode: NotationLayoutMode.inline,
    );

    final withResult =
        tester
            .widgetList<RichText>(find.byType(RichText))
            .where((w) => w.text.toPlainText().contains('½–½'))
            .toList();
    expect(withResult, hasLength(1));
    // Same paragraph as the moves, ending on the result: no banner row.
    expect(withResult.single.text.toPlainText().trimRight(), endsWith('½–½'));
    expect(find.text('½–½'), findsNothing);
  });

  testWidgets('ladder puts the result in the empty black slot', (tester) async {
    await _pump(
      tester,
      movetext: '1. e4 e5 2. Nf3 1/2-1/2',
      mode: NotationLayoutMode.ladder,
    );

    final result = find.text('½–½');
    expect(result, findsOneWidget);
    // Same row as 2. Nf3, to its right.
    final nf3 = tester.getCenter(_san('Nf3'));
    final r = tester.getCenter(result);
    expect((r.dy - nf3.dy).abs(), lessThan(4));
    expect(r.dx, greaterThan(nf3.dx));
  });

  testWidgets('ladder puts the result in the white slot after black', (
    tester,
  ) async {
    await _pump(
      tester,
      movetext: '1. e4 e5 2. Nf3 Nc6 1/2-1/2',
      mode: NotationLayoutMode.ladder,
    );

    final result = find.text('½–½');
    expect(result, findsOneWidget);
    final nf3 = tester.getRect(_san('Nf3'));
    final r = tester.getRect(result);
    // Next row, starting in the white column.
    expect(r.top, greaterThanOrEqualTo(nf3.bottom));
    expect((r.left - nf3.left).abs(), lessThan(24));
    // One line, not a padded banner.
    expect(r.top - nf3.bottom, lessThan(20));
  });
}
