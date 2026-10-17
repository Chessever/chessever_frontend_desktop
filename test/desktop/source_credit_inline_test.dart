import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/source_credit_fixture.dart' as sample;

void main() {
  testWidgets(
    'trimmed source credit is full green italic inline text before closing RAV',
    (tester) async {
      final nav = ChessGameNavigator(sample.fixture())
        ..goToMovePointerUnchecked(const [0, 0, 1]);
      nav.deleteContinuationAfterPointer(const [0, 0, 1]);
      final mode = ValueNotifier(NotationLayoutMode.inline);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 220,
              height: 500,
              child: NotationLadderView(
                game: nav.state.game,
                activePointer: const [0, 0, 1],
                onJump: (_) {},
                layoutModeController: mode,
                showHeader: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final paragraphs =
          tester
              .widgetList<RichText>(find.byType(RichText))
              .where((w) => w.text.toPlainText().contains(sample.credit))
              .toList();
      expect(paragraphs, hasLength(1));
      final paragraph = paragraphs.single;
      final text = paragraph.text.toPlainText();
      final creditEnd = text.indexOf(sample.credit) + sample.credit.length;
      expect(text.substring(creditEnd), matches(RegExp(r'^ [\])}] ')));
      TextSpan? creditSpan;
      paragraph.text.visitChildren((span) {
        if (span is TextSpan && (span.text ?? '').contains(sample.credit)) {
          creditSpan = span;
        }
        return true;
      });
      expect(creditSpan, isNotNull);
      expect(creditSpan!.style!.fontStyle, FontStyle.italic);
      expect(creditSpan!.style!.color, kCommentaryGreenDim);
      expect(paragraph.maxLines, isNull);
      expect(paragraph.overflow, isNot(TextOverflow.ellipsis));
      final render = tester.renderObject<RenderParagraph>(
        find.byWidget(paragraph),
      );
      final boxes = render.getBoxesForSelection(
        TextSelection(
          baseOffset: text.indexOf(sample.credit),
          extentOffset: creditEnd,
        ),
      );
      expect(
        boxes.map((box) => box.top).toSet().length,
        greaterThan(1),
        reason: 'the full credit must wrap at real paragraph word boundaries',
      );
      expect(
        render.getBoxesForSelection(
          TextSelection(baseOffset: creditEnd - 1, extentOffset: creditEnd),
        ),
        isNotEmpty,
        reason: 'the last credit character must not be ellipsized',
      );
      expect(find.byIcon(Icons.article_outlined), findsNothing);
      expect(find.textContaining('[%src', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      mode.dispose();
      nav.dispose();
    },
  );
}
