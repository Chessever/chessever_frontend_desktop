import 'dart:io';
import 'dart:ui' as ui;
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const marks = <(int, String, String, LichessMoveAnnotationType?)>[
  (1, '!', 'good', LichessMoveAnnotationType.goodMove),
  (2, '?', 'mistake', LichessMoveAnnotationType.mistake),
  (3, '!!', 'brilliant', LichessMoveAnnotationType.brilliant),
  (4, '??', 'blunder', LichessMoveAnnotationType.blunder),
  (5, '!?', 'speculative', null),
  (6, '?!', 'inaccuracy', LichessMoveAnnotationType.inaccuracy),
  (7, '□', 'forced_move', LichessMoveAnnotationType.forced),
];

Finder asset(String name) => find.byWidgetPredicate(
  (widget) =>
      widget is SvgPicture &&
      widget.bytesLoader is SvgAssetLoader &&
      (widget.bytesLoader as SvgAssetLoader).assetName ==
          'assets/svgs/$name.svg',
);

Future<void> showGame(
  WidgetTester tester,
  ChessGame game,
  NotationLayoutMode mode, {
  Map<int, List<int>> user = const {},
  Map<int, LichessMoveAnnotation> annotations = const {},
}) async {
  final layout = ValueNotifier(mode);
  addTearDown(layout.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SizedBox(
          width: 780,
          height: 560,
          child: NotationLadderView(
            game: game,
            activePointer: const [],
            onJump: (_) {},
            showHeader: false,
            layoutModeController: layout,
            userNags: user,
            lichessAnnotations: annotations,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('capture actual source-widget badge preview', (tester) async {
    final output = Platform.environment['MANUAL_BADGE_PREVIEW'];
    if (output == null) return;
    // RichText SAN spans use the engine fallback font rather than ThemeData.
    // Supply the same real font for the widget-test fallback as well.
    for (final family in ['Geist', 'Roboto', 'Ahem']) {
      final font = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'));
      await font.load();
    }
    final game = ChessGame.fromPgn(
      'preview',
      r'1. e4 $1 e5 $2 2. Nf3 $3 Nc6 $4 3. Bb5 $5 a6 $6 4. Ba4 $7 *',
    );
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: boundaryKey,
              child: Container(
                color: const Color(0xFF111111),
                width: 720,
                height: 270,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Manual annotations — shared badge style',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: NotationLadderView(
                        game: game,
                        activePointer: const [],
                        onJump: (_) {},
                        showHeader: false,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The test engine's unstyled RichText fallback is Ahem. Substitute only
    // that test-render font; keep the actual widget geometry, colors and SVGs.
    InlineSpan previewFont(InlineSpan span) =>
        span is TextSpan
            ? TextSpan(
              text: span.text,
              style: (span.style ?? const TextStyle()).copyWith(
                fontFamily: 'Geist',
              ),
              children: span.children?.map(previewFont).toList(),
            )
            : span;
    for (final element in find.byType(RichText).evaluate()) {
      final render = element.renderObject;
      if (render is RenderParagraph) render.text = previewFont(render.text);
    }
    await tester.pump();
    final boundary =
        boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(output).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(File(output).lengthSync(), greaterThan(1000));
  });
  for (final mode in NotationLayoutMode.values) {
    for (final (nag, glyph, name, classification) in marks) {
      for (final origin in ['stored', 'overlay', 'variation']) {
        testWidgets('$glyph $origin uses one canonical badge in ${mode.name}', (
          tester,
        ) async {
          final game = ChessGame.fromPgn(
            'parity',
            origin == 'variation'
                ? '1. e4 e5 (1... c5 \$$nag \$14 {Kept prose}) *'
                : '1. e4 ${origin == 'stored' ? '\$$nag' : ''} \$14 {Kept prose} e5 *',
          );
          final before = game.toJson();
          await showGame(
            tester,
            game,
            mode,
            user:
                origin == 'overlay'
                    ? {
                      0: [nag],
                    }
                    : const {},
          );
          expect(asset(name), findsOneWidget);
          expect(find.byType(SvgPicture), findsOneWidget);
          expect(tester.getSize(asset(name)), const Size(17, 17));
          expect(find.text(glyph), findsNothing);
          expect(find.text(getNagDisplay(14)!.symbol), findsOneWidget);
          expect(game.toJson(), before);
          expect(tester.takeException(), isNull);
          if (classification != null) {
            expect(
              manualQualityIconAsset(glyph),
              moveAnnotationIconAsset(classification),
            );
          }
        });
      }
      testWidgets('$glyph manual override wins over report in ${mode.name}', (
        tester,
      ) async {
        final game = ChessGame.fromPgn('override', r'1. e4 $242 $1 $14 e5 *');
        await showGame(
          tester,
          game,
          mode,
          user: {
            0: [nag],
          },
          annotations: {
            0: const LichessMoveAnnotation(
              type: LichessMoveAnnotationType.bestMove,
              comment: 'Report evidence',
              reportOwnsMoveQuality: true,
              useClassificationIcon: true,
            ),
          },
        );
        expect(asset(name), findsOneWidget);
        expect(asset('best'), findsNothing);
        expect(find.byType(SvgPicture), findsOneWidget);
      });
      testWidgets(
        '$glyph saved manual override retains glyph after reopen in ${mode.name}',
        (tester) async {
          final game = ChessGame.fromPgn(
            'saved',
            '1. e4 \$$nag \$248 \$14 {Kept prose} e5 *',
          );
          final reopened = ChessGame.fromPgn('reopen', exportGameToPgn(game));
          final before = reopened.toJson();
          await showGame(
            tester,
            reopened,
            mode,
            annotations: {
              0: const LichessMoveAnnotation(
                type: LichessMoveAnnotationType.bestMove,
                comment: '',
                reportOwnsMoveQuality: true,
                useClassificationIcon: true,
              ),
            },
          );
          expect(asset(name), findsOneWidget);
          expect(reopened.mainline.first.nags, containsAll([nag, 248, 14]));
          expect(reopened.toJson(), before);
          expect(find.text(r'$248'), findsNothing);
        },
      );
    }
    testWidgets(
      'neutral report still hides stale source quality in ${mode.name}',
      (tester) async {
        await showGame(
          tester,
          ChessGame.fromPgn('neutral', r'1. e4 $1 $14 e5 *'),
          mode,
          annotations: {
            0: const LichessMoveAnnotation(
              type: LichessMoveAnnotationType.goodMove,
              comment: '',
              reportOwnsMoveQuality: true,
              useClassificationIcon: false,
            ),
          },
        );
        expect(find.byType(SvgPicture), findsNothing);
        expect(find.text('!'), findsNothing);
        expect(find.text(getNagDisplay(14)!.symbol), findsOneWidget);
      },
    );
    testWidgets(
      'observation square is not relabelled as forced in ${mode.name}',
      (tester) async {
        await showGame(
          tester,
          ChessGame.fromPgn('singular', r'1. e4 $8 e5 *'),
          mode,
        );
        expect(find.text('□'), findsOneWidget);
        expect(asset('forced_move'), findsNothing);
      },
    );
  }
  test('manual styles do not change Board classification meanings', () {
    for (final (nag, glyph, _, classification) in marks) {
      if (classification == null || nag == 7) continue;
      final resolved = resolveBoardMoveAssessment(
        isOnMainline: false,
        userNags: const [],
        pgnNags: [nag],
        moveAnnotation: null,
      );
      expect(resolved.annotation?.type, classification);
      expect(
        manualQualityIconAsset(glyph),
        moveAnnotationIconAsset(classification),
      );
    }
    expect(manualQualityIconAsset('='), isNull);
    expect(manualQualityIconAsset(r'$248'), isNull);
  });
  testWidgets('manual speculative mark keeps !? in a matching SVG badge', (
    tester,
  ) async {
    final game = ChessGame.fromPgn('speculative', r'1. e4 $5 $14 e5 *');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotationLadderView(
            game: game,
            activePointer: const [],
            onJump: (_) {},
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SvgPicture &&
            widget.bytesLoader is SvgAssetLoader &&
            (widget.bytesLoader as SvgAssetLoader).assetName ==
                'assets/svgs/speculative.svg',
      ),
      findsOneWidget,
    );
    expect(find.text('!?'), findsNothing);
  });
  testWidgets('manual exclamation uses the canonical Good Move badge', (
    tester,
  ) async {
    final game = ChessGame.fromPgn('manual', r'1. e4 $1 $14 e5 *');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotationLadderView(
            game: game,
            activePointer: const [],
            onJump: (_) {},
            showHeader: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SvgPicture &&
            widget.bytesLoader is SvgAssetLoader &&
            (widget.bytesLoader as SvgAssetLoader).assetName ==
                'assets/svgs/good.svg',
      ),
      findsOneWidget,
    );
    expect(find.text('!'), findsNothing);
  });
}
