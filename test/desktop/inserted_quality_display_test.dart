import 'package:chessever/desktop/services/board_pgn_insertion.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/utils/pgn_external_compat.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChessGame _insertAnnotatedGame() {
  final base = ChessGame.fromPgn(
    'target',
    '[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *',
  );
  final inserted = insertBoardPgn(
    game: base,
    activePath: [base.mainline.first],
    pgn:
        '[Event "Synthetic annotated source"]\n[Result "*"]\n\n'
        r'1. e4 c5 $1 $242 $14 {Source prose [%clk 0:04:59]} 2. Nf3 d6 *',
    sourceLabel: 'Synthetic source credit',
  );
  expect(inserted, isNotNull);
  return inserted!.game;
}

Future<void> _show(
  WidgetTester tester,
  ChessGame game,
  NotationLayoutMode mode, {
  Map<int, List<int>> userNags = const {},
  Map<int, LichessMoveAnnotation> annotations = const {},
}) async {
  final layout = ValueNotifier(mode);
  addTearDown(layout.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 780,
          height: 560,
          child: NotationLadderView(
            game: game,
            activePointer: const [],
            onJump: (_) {},
            layoutModeController: layout,
            showHeader: false,
            userNags: userNags,
            lichessAnnotations: annotations,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _badge(String label) =>
    find.byWidgetPredicate((w) => w is DesktopTooltip && w.message == label);

Iterable<ChessMove> _moves(ChessLine line) sync* {
  for (final move in line) {
    yield move;
    for (final variation in move.variations ?? const <ChessLine>[]) {
      yield* _moves(variation);
    }
  }
}

ChessGame _mainline(String nags) => ChessGame.fromPgn(
  'mainline',
  '[Result "*"]\n\n1. e4 $nags {Unchanged prose} e5 *',
);
LichessMoveAnnotation _report({bool visible = true}) => LichessMoveAnnotation(
  type: LichessMoveAnnotationType.bestMove,
  comment: 'Preserved report commentary',
  reportOwnsMoveQuality: true,
  useClassificationIcon: visible,
);

void main() {
  for (final mode in NotationLayoutMode.values) {
    testWidgets(
      'Explorer inserted quality renders once without losing positional NAG in ${mode.name}',
      (tester) async {
        final game = _insertAnnotatedGame();
        final before = game.toJson();
        await _show(tester, game, mode);
        expect(_badge('Best move'), findsOneWidget);
        expect(
          find.text('!'),
          findsNothing,
          reason:
              'The native badge already represents the portable quality NAG.',
        );
        expect(find.text(getNagDisplay(14)!.symbol), findsOneWidget);
        expect(
          find.textContaining('Source prose', findRichText: true),
          findsOneWidget,
        );
        expect(
          game.toJson(),
          before,
          reason: 'Rendering must not rewrite imported annotation data.',
        );
        expect(tester.takeException(), isNull);
      },
    );
    for (final item in <(int?, int, String)>[
      (1, 242, 'Best move'),
      (3, 240, 'Brilliant'),
      (1, 241, 'Good Move'),
      (4, 243, 'Missed Win'),
      (6, 244, 'Inaccuracy'),
      (2, 245, 'Mistake'),
      (4, 246, 'Blunder'),
      (null, 247, 'Book move'),
    ]) {
      final (portable, native, label) = item;
      testWidgets(
        '$label native and portable markers render once in ${mode.name}',
        (tester) async {
          final marks = [
            if (portable != null) portable,
            native,
            14,
          ].map((n) => '\$$n').join(' ');
          final game = _mainline(marks);
          final before = game.toJson();
          await _show(tester, game, mode);
          expect(_badge(label), findsOneWidget);
          if (portable != null) {
            expect(find.text(getNagDisplay(portable)!.symbol), findsNothing);
          }
          expect(find.text(getNagDisplay(14)!.symbol), findsOneWidget);
          expect(game.toJson(), before);
        },
      );
    }
    testWidgets(
      'ordinary quality without a badge stays visible in ${mode.name}',
      (tester) async {
        await _show(tester, _mainline(r'$1 $14'), mode);
        expect(find.text('!'), findsOneWidget);
        expect(_badge('Best move'), findsNothing);
        expect(find.text(getNagDisplay(14)!.symbol), findsOneWidget);
      },
    );
    testWidgets(
      'manual quality overrides report and native class in ${mode.name}',
      (tester) async {
        final game = _mainline(r'$1 $242 $14');
        final before = game.toJson();
        await _show(
          tester,
          game,
          mode,
          userNags: {
            0: [2],
          },
          annotations: {0: _report()},
        );
        expect(find.text('?'), findsOneWidget);
        expect(find.text('!'), findsNothing);
        expect(_badge('Best move'), findsNothing);
        expect(find.text(getNagDisplay(14)!.symbol), findsOneWidget);
        expect(game.toJson(), before);
      },
    );
    testWidgets('persisted manual marker stays private in ${mode.name}', (
      tester,
    ) async {
      await _show(
        tester,
        _mainline(r'$2 $248 $14'),
        mode,
        annotations: {0: _report()},
      );
      expect(find.text('?'), findsOneWidget);
      expect(find.text(r'$248'), findsNothing);
      expect(_badge('Best move'), findsNothing);
    });
    testWidgets(
      'classified and neutral reports retain quality ownership in ${mode.name}',
      (tester) async {
        final game = _mainline(r'$6 $14');
        await _show(tester, game, mode, annotations: {0: _report()});
        expect(_badge('Best move'), findsOneWidget);
        expect(find.text('?!'), findsNothing);
        expect(find.text('!'), findsNothing);
        await _show(
          tester,
          game,
          mode,
          annotations: {0: _report(visible: false)},
        );
        expect(_badge('Best move'), findsNothing);
        expect(find.text('?!'), findsNothing);
        expect(find.text('!'), findsNothing);
        expect(find.text(getNagDisplay(14)!.symbol), findsOneWidget);
        expect(
          find.textContaining('Unchanged prose', findRichText: true),
          findsOneWidget,
        );
      },
    );
    testWidgets(
      'save and external-copy preserve inserted metadata while rendering once in ${mode.name}',
      (tester) async {
        final original = _insertAnnotatedGame();
        final before = original.toJson();
        final native = exportGameToPgn(original);
        for (final pgn in [native, toExternalCompatiblePgn(native)]) {
          final reopened = ChessGame.fromPgn('reopened', pgn);
          final c5 = _moves(
            reopened.mainline,
          ).singleWhere((m) => m.uci == 'c7c5');
          expect(c5.nags, containsAll([1, 242, 14]));
          expect(c5.comments!.join(' '), contains('Source prose'));
          expect(c5.comments!.join(' '), contains('[%clk 0:04:59]'));
          final frozen = reopened.toJson();
          await _show(tester, reopened, mode);
          expect(_badge('Best move'), findsOneWidget);
          expect(find.text('!'), findsNothing);
          expect(reopened.toJson(), frozen);
        }
        expect(original.toJson(), before);
      },
    );
    testWidgets(
      'transposition links survive quality deduplication in ${mode.name}',
      (tester) async {
        final base = ChessGame.fromPgn(
          'transpositions',
          '[Result "*"]\n\n1. Nf3 d5 2. g3 Nf6 3. Bg2 e6 *',
        );
        final inserted = insertBoardPgn(
          game: base,
          activePath: const [],
          pgn:
              '[Result "*"]\n\n'
              r'1. g3 $1 $242 d5 2. Nf3 Nf6 3. Bg2 e6 *',
        );
        expect(inserted, isNotNull);
        await _show(tester, inserted!.game, mode);
        expect(find.text('Tr'), findsWidgets);
        expect(_badge('Best move'), findsOneWidget);
        expect(find.text('!'), findsNothing);
      },
    );
  }
}
