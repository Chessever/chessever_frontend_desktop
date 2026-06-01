import 'package:chessground/chessground.dart' show PieceAssets;
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'switches to inline notation and keeps variation moves clickable',
    (tester) async {
      final jumps = <ChessMovePointer>[];
      final layoutMode = ValueNotifier(NotationLayoutMode.ladder);
      addTearDown(layoutMode.dispose);

      await tester.pumpWidget(
        _host(
          game: _sampleGame(),
          onJump: jumps.add,
          layoutModeController: layoutMode,
        ),
      );

      expect(find.byIcon(Icons.unfold_less_rounded), findsOneWidget);
      expect(find.byIcon(Icons.unfold_more_rounded), findsOneWidget);

      layoutMode.value = NotationLayoutMode.inline;
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.unfold_less_rounded), findsOneWidget);
      expect(find.byIcon(Icons.unfold_more_rounded), findsOneWidget);
      expect(find.text('1...'), findsNWidgets(2));
      expect(find.text('c5', findRichText: true), findsOneWidget);

      await tester.tap(find.text('c5', findRichText: true));
      await tester.pump();

      expect(jumps, [
        [0, 0, 0],
      ]);
    },
  );

  testWidgets(
    'inline notation exposes collapse and reopen controls for variations',
    (tester) async {
      final layoutMode = ValueNotifier(NotationLayoutMode.inline);
      addTearDown(layoutMode.dispose);

      await tester.pumpWidget(
        _host(
          game: _sampleGame(),
          onJump: (_) {},
          layoutModeController: layoutMode,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.unfold_less_rounded), findsOneWidget);
      expect(find.byIcon(Icons.unfold_more_rounded), findsOneWidget);
      expect(find.text('[−'), findsOneWidget);
      expect(find.text('[+'), findsNothing);

      await tester.tap(find.text('[−'));
      await tester.pumpAndSettle();

      expect(find.text('[−'), findsNothing);
      expect(find.text('[+'), findsOneWidget);

      await tester.tap(find.text('[+'));
      await tester.pumpAndSettle();

      expect(find.text('[−'), findsOneWidget);
      expect(find.text('[+'), findsNothing);
    },
  );

  testWidgets(
    'external collapse controller collapses and expands inline variations',
    (tester) async {
      final layoutMode = ValueNotifier(NotationLayoutMode.inline);
      final collapseController = NotationVariationCollapseController();
      addTearDown(layoutMode.dispose);

      await tester.pumpWidget(
        _host(
          game: _sampleGame(),
          onJump: (_) {},
          layoutModeController: layoutMode,
          variationCollapseController: collapseController,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('[−'), findsOneWidget);

      collapseController.collapseAll();
      await tester.pumpAndSettle();

      expect(find.text('[−'), findsNothing);
      expect(find.text('[+'), findsOneWidget);

      collapseController.expandAll();
      await tester.pumpAndSettle();

      expect(find.text('[−'), findsOneWidget);
      expect(find.text('[+'), findsNothing);
    },
  );

  testWidgets('keeps expanded variation closing bracket inline with moves', (
    tester,
  ) async {
    final layoutMode = ValueNotifier(NotationLayoutMode.inline);
    addTearDown(layoutMode.dispose);

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        onJump: (_) {},
        layoutModeController: layoutMode,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('c5', findRichText: true), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is Text && widget.data == ']'),
      findsNothing,
    );
  });

  testWidgets('keeps selected inline move-number prefixes contextual', (
    tester,
  ) async {
    final layoutMode = ValueNotifier(NotationLayoutMode.inline);
    addTearDown(layoutMode.dispose);

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        activePointer: const [2],
        onJump: (_) {},
        layoutModeController: layoutMode,
      ),
    );

    final selectedWhitePrefix = tester.widget<Text>(find.text('2.'));
    expect(selectedWhitePrefix.style?.color, kPrimaryColor);

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        activePointer: const [3],
        onJump: (_) {},
        layoutModeController: layoutMode,
      ),
    );
    await tester.pump();

    expect(find.text('2...'), findsNothing);
    expect(find.text('Nc6', findRichText: true), findsOneWidget);

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        activePointer: const [0, 0, 0],
        onJump: (_) {},
        layoutModeController: layoutMode,
      ),
    );
    await tester.pump();

    final selectedVariationPrefixes = tester.widgetList<Text>(
      find.text('1...'),
    );
    expect(
      selectedVariationPrefixes.any(
        (text) => text.style?.color == kPrimaryColor,
      ),
      isTrue,
    );
  });

  testWidgets(
    'restores black move prefix when an inline variation separates the reply',
    (tester) async {
      final layoutMode = ValueNotifier(NotationLayoutMode.inline);
      addTearDown(layoutMode.dispose);

      await tester.pumpWidget(
        _host(
          game: _separatedInlineContextGame(),
          activePointer: const [1],
          onJump: (_) {},
          layoutModeController: layoutMode,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('12.'), findsNWidgets(2));
      expect(find.text('Be2', findRichText: true), findsOneWidget);
      expect(find.text('12...'), findsOneWidget);
      expect(find.text('Qg4', findRichText: true), findsOneWidget);
      expect(find.text('11...'), findsNothing);
    },
  );

  testWidgets(
    'uses explicit black prefixes when white variations break adjacency',
    (tester) async {
      final layoutMode = ValueNotifier(NotationLayoutMode.inline);
      final collapseController = NotationVariationCollapseController();
      addTearDown(layoutMode.dispose);

      await tester.pumpWidget(
        _host(
          game: _najdorfInlineVariationContextGame(),
          activePointer: const [3],
          onJump: (_) {},
          layoutModeController: layoutMode,
          variationCollapseController: collapseController,
          width: 520,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('7.'), findsNWidgets(2));
      expect(find.text('Bc4', findRichText: true), findsOneWidget);
      expect(find.text('h5', findRichText: true), findsOneWidget);
      expect(find.text('7...'), findsNWidgets(2));
      expect(find.text('e6', findRichText: true), findsOneWidget);
      expect(find.text('Nc6', findRichText: true), findsOneWidget);
      expect(find.text('7…'), findsNothing);

      collapseController.collapseAll();
      await tester.pumpAndSettle();

      expect(find.text('7.'), findsNWidgets(2));
      expect(find.text('7...'), findsNWidgets(2));
      expect(find.text('7…'), findsNothing);
      expect(find.text('h5', findRichText: true), findsOneWidget);
      expect(find.text('Nc6', findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    'places inline alternative variation after the existing sibling move',
    (tester) async {
      final layoutMode = ValueNotifier(NotationLayoutMode.inline);
      addTearDown(layoutMode.dispose);

      await tester.pumpWidget(
        _host(
          game: _inlineSiblingVariationOrderGame(),
          activePointer: const [20],
          onJump: (_) {},
          layoutModeController: layoutMode,
          width: 1000,
        ),
      );
      await tester.pumpAndSettle();

      final qxd3 = tester.getTopLeft(find.text('Qxd3', findRichText: true));
      final qe2 = tester.getTopLeft(find.text('Qe2', findRichText: true));
      expect(
        qe2.dx,
        greaterThan(qxd3.dx),
        reason: 'White alternative 11.Qe2 must render after 11.Qxd3.',
      );
      expect(find.text('11.'), findsNWidgets(2));

      final rc8 = tester.getTopLeft(find.text('Rc8', findRichText: true));
      final e5 = tester.getTopLeft(find.text('e5', findRichText: true));
      expect(
        e5.dx,
        greaterThan(rc8.dx),
        reason: 'Black alternative 11...e5 must render after 11...Rc8.',
      );
      expect(find.text('11...'), findsNWidgets(2));
    },
  );

  testWidgets('renders figurine piece assets when enabled', (tester) async {
    await tester.pumpWidget(
      _host(game: _sampleGame(), onJump: (_) {}, useFigurine: false),
    );

    expect(find.text('Nf3', findRichText: true), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        onJump: (_) {},
        useFigurine: true,
        pieceAssets: const BoardSettingsNew().pieceAssets,
      ),
    );
    await tester.pump();

    expect(find.text('Nf3', findRichText: true), findsNothing);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets(
    'renders inserted source metadata in ladder and inline notation',
    (tester) async {
      final layoutMode = ValueNotifier(NotationLayoutMode.ladder);
      addTearDown(layoutMode.dispose);
      const sourceLabel = 'Alpha0 vs Beta0 · Keyboard UX Test · 2025-02-01';

      await tester.pumpWidget(
        _host(
          game: _sampleGameWithSourceMetadata(),
          onJump: (_) {},
          layoutModeController: layoutMode,
        ),
      );

      expect(find.text(sourceLabel), findsOneWidget);
      expect(find.textContaining('[%src'), findsNothing);

      layoutMode.value = NotationLayoutMode.inline;
      await tester.pumpAndSettle();

      expect(find.text(sourceLabel), findsOneWidget);
      expect(find.textContaining('[%src'), findsNothing);
    },
  );

  testWidgets(
    'scrolls notation to the top when active pointer returns to root',
    (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      await tester.pumpWidget(
        _host(
          game: _longGame(),
          activePointer: const [47],
          onJump: (_) {},
          scrollController: scrollController,
          height: 180,
        ),
      );
      await tester.pumpAndSettle();

      expect(scrollController.hasClients, isTrue);
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await tester.pump();
      expect(scrollController.offset, greaterThan(0));

      await tester.pumpWidget(
        _host(
          game: _longGame(),
          activePointer: const <int>[],
          onJump: (_) {},
          scrollController: scrollController,
          height: 180,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        scrollController.offset,
        moreOrLessEquals(scrollController.position.minScrollExtent),
      );
    },
  );

  testWidgets('annotation toolbar toggles NAGs for the active mainline move', (
    tester,
  ) async {
    final calls = <String>[];

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        onJump: (_) {},
        width: 900,
        onToggleUserNag: (ply, nag) => calls.add('$ply:$nag'),
      ),
    );

    await tester.tap(find.text('!!'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('±'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(calls, ['2:3', '2:16']);
  });

  testWidgets(
    'annotation toolbar toggles latest move when cursor is at start',
    (tester) async {
      final calls = <String>[];

      await tester.pumpWidget(
        _host(
          game: _sampleGame(),
          activePointer: const [],
          onJump: (_) {},
          width: 900,
          onToggleUserNag: (ply, nag) => calls.add('$ply:$nag'),
        ),
      );

      await tester.tap(find.text('!!'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(calls, ['3:3']);
    },
  );

  testWidgets('toolbar is icon-only and hides idea-only annotations', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        onJump: (_) {},
        width: 1100,
        onToggleUserNag: (_, _) {},
      ),
    );

    expect(find.text('MOVE'), findsNothing);
    expect(find.text('EVAL'), findsNothing);
    expect(find.text('IDEA'), findsNothing);
    expect(find.text('!!'), findsOneWidget);
    expect(find.text('±'), findsOneWidget);
    expect(find.text('N'), findsNothing);
  });

  testWidgets('right-click move menu opens eval and idea annotation groups', (
    tester,
  ) async {
    final qualityCalls = <int?>[];
    final toggleCalls = <String>[];

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        onJump: (_) {},
        width: 900,
        onSetUserQualityNag: (_, nag) => qualityCalls.add(nag),
        onToggleUserNag: (ply, nag) => toggleCalls.add('$ply:$nag'),
      ),
    );

    final move = find.text('Nf3', findRichText: true);
    await tester.tapAt(tester.getCenter(move), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('!, ?, ...'), findsOneWidget);
    expect(find.text('+-, =, ...'), findsOneWidget);
    expect(find.text('Special annotations'), findsOneWidget);

    await tester.tap(find.text('!, ?, ...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Brilliant'));
    await tester.pumpAndSettle();
    expect(qualityCalls, [3]);

    await tester.tapAt(tester.getCenter(move), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('+-, =, ...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('White winning'));
    await tester.pumpAndSettle();
    expect(toggleCalls, ['2:18']);

    await tester.tapAt(tester.getCenter(move), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Special annotations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novelty'));
    await tester.pumpAndSettle();
    expect(toggleCalls, ['2:18', '2:140']);
  });

  testWidgets('annotation toolbar clears active user NAGs', (tester) async {
    final cleared = <int>[];

    await tester.pumpWidget(
      _host(
        game: _sampleGame(),
        onJump: (_) {},
        width: 900,
        userNags: const {
          2: [3, 16],
        },
        onToggleUserNag: (_, _) {},
        onClearUserNags: cleared.add,
      ),
    );

    final toolbarScroller =
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is SingleChildScrollView &&
                  widget.scrollDirection == Axis.horizontal,
            )
            .last;
    await tester.drag(toolbarScroller, const Offset(-900, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.clear_rounded));
    await tester.pump(const Duration(milliseconds: 250));

    expect(cleared, [2]);
  });
}

ChessGame _sampleGameWithSourceMetadata() {
  final game = _sampleGame();
  final firstMove = game.mainline.first;
  final variations = firstMove.variations!;
  final sourceMove = variations.first.first.copyWith(
    comments: const <String>[
      '[%src Alpha0 vs Beta0, Keyboard UX Test, 2025-02-01]',
    ],
  );
  return game.copyWith(
    mainline: <ChessMove>[
      firstMove.copyWith(
        variations: <ChessLine>[
          <ChessMove>[sourceMove],
        ],
        overrideVariations: true,
      ),
      ...game.mainline.skip(1),
    ],
  );
}

ChessGame _separatedInlineContextGame() {
  return ChessGame(
    gameId: 'inline-separated-context-test',
    startingFen: '8/8/8/8/8/8/8/8 w - - 0 12',
    metadata: const <String, dynamic>{},
    mainline: [
      ChessMove(
        num: 12,
        fen: '8/8/8/8/8/8/8/8 b - - 0 12',
        san: 'g3',
        uci: 'g2g3',
        turn: ChessColor.white,
        variations: [
          [
            ChessMove(
              num: 12,
              fen: '8/8/8/8/8/8/8/8 b - - 0 12',
              san: 'Be2',
              uci: 'c4e2',
              turn: ChessColor.white,
            ),
            ChessMove(
              num: 12,
              fen: '8/8/8/8/8/8/8/8 w - - 1 13',
              san: 'Bd7',
              uci: 'c8d7',
              turn: ChessColor.black,
            ),
            ChessMove(
              num: 13,
              fen: '8/8/8/8/8/8/8/8 b - - 0 13',
              san: 'g3',
              uci: 'g2g3',
              turn: ChessColor.white,
            ),
            ChessMove(
              num: 13,
              fen: '8/8/8/8/8/8/8/8 w - - 1 14',
              san: 'Qe7',
              uci: 'd8e7',
              turn: ChessColor.black,
            ),
          ],
        ],
      ),
      ChessMove(
        num: 12,
        fen: '8/8/8/8/8/8/8/8 w - - 1 13',
        san: 'Qg4',
        uci: 'd8g4',
        turn: ChessColor.black,
      ),
    ],
  );
}

ChessGame _najdorfInlineVariationContextGame() {
  return ChessGame(
    gameId: 'najdorf-inline-variation-context-test',
    startingFen: '8/8/8/8/8/8/8/8 w - - 0 6',
    metadata: const <String, dynamic>{},
    mainline: [
      ChessMove(
        num: 6,
        fen: '8/8/8/8/8/8/8/8 b - - 0 6',
        san: 'h4',
        uci: 'h2h4',
        turn: ChessColor.white,
      ),
      ChessMove(
        num: 6,
        fen: '8/8/8/8/8/8/8/8 w - - 0 7',
        san: 'h6',
        uci: 'h7h6',
        turn: ChessColor.black,
      ),
      ChessMove(
        num: 7,
        fen: '8/8/8/8/8/8/8/8 b - - 1 7',
        san: 'Bc4',
        uci: 'f1c4',
        turn: ChessColor.white,
        variations: [
          [
            ChessMove(
              num: 7,
              fen: '8/8/8/8/8/8/8/8 b - - 1 7',
              san: 'h5',
              uci: 'h4h5',
              turn: ChessColor.white,
            ),
          ],
        ],
      ),
      ChessMove(
        num: 7,
        fen: '8/8/8/8/8/8/8/8 w - - 0 8',
        san: 'e6',
        uci: 'e7e6',
        turn: ChessColor.black,
        variations: [
          [
            ChessMove(
              num: 7,
              fen: '8/8/8/8/8/8/8/8 w - - 0 8',
              san: 'Nc6',
              uci: 'b8c6',
              turn: ChessColor.black,
            ),
          ],
        ],
      ),
    ],
  );
}

ChessGame _inlineSiblingVariationOrderGame() {
  final game = ChessGame.fromPgn(
    'inline-sibling-order-test',
    '1. Nf3 Nf6 2. c4 c6 3. Nc3 d5 4. d4 g6 5. cxd5 cxd5 '
        '6. Bf4 Nc6 7. h3 Bg7 8. e3 O-O 9. Bd3 Bf5 10. O-O Bxd3 '
        '11. Qxd3 Rc8',
  );

  final mainline = List<ChessMove>.of(game.mainline);
  mainline[19] = mainline[19].copyWith(
    variations: <ChessLine>[
      <ChessMove>[mainline[20].copyWith(san: 'Qe2', uci: 'd1e2')],
    ],
    overrideVariations: true,
  );
  mainline[20] = mainline[20].copyWith(
    variations: <ChessLine>[
      <ChessMove>[mainline[21].copyWith(san: 'e5', uci: 'e7e5')],
    ],
    overrideVariations: true,
  );
  return game.copyWith(mainline: mainline);
}

Widget _host({
  required ChessGame game,
  required ValueChanged<ChessMovePointer> onJump,
  ChessMovePointer activePointer = const [2],
  ScrollController? scrollController,
  bool useFigurine = false,
  PieceAssets? pieceAssets,
  double width = 360,
  double height = 420,
  Map<int, List<int>> userNags = const <int, List<int>>{},
  void Function(int ply, int? nag)? onSetUserQualityNag,
  void Function(int ply, int nag)? onToggleUserNag,
  void Function(int ply)? onClearUserNags,
  ValueNotifier<NotationLayoutMode>? layoutModeController,
  NotationVariationCollapseController? variationCollapseController,
}) {
  final notation = NotationLadderView(
    game: game,
    activePointer: activePointer,
    onJump: onJump,
    scrollController: scrollController,
    userNags: userNags,
    onSetUserQualityNag: onSetUserQualityNag,
    onToggleUserNag: onToggleUserNag,
    onClearUserNags: onClearUserNags,
    layoutModeController: layoutModeController,
    variationCollapseController: variationCollapseController,
    useFigurine: useFigurine,
    pieceAssets: pieceAssets,
  );

  return MaterialApp(
    home: Scaffold(
      body: SizedBox(width: width, height: height, child: notation),
    ),
  );
}

ChessGame _longGame() {
  return ChessGame(
    gameId: 'notation-long-test',
    startingFen: Chess.initial.fen,
    metadata: const <String, dynamic>{},
    mainline: List<ChessMove>.generate(48, (index) {
      final whiteToMove = index.isEven;
      return ChessMove(
        num: index ~/ 2 + 1,
        fen: Chess.initial.fen,
        san: whiteToMove ? 'e4' : 'e5',
        uci: whiteToMove ? 'e2e4' : 'e7e5',
        turn: whiteToMove ? ChessColor.white : ChessColor.black,
      );
    }),
  );
}

ChessGame _sampleGame() {
  final e4 = Chess.initial.play(NormalMove.fromUci('e2e4'));
  final e5 = e4.play(NormalMove.fromUci('e7e5'));
  final nf3 = e5.play(NormalMove.fromUci('g1f3'));
  final nc6 = nf3.play(NormalMove.fromUci('b8c6'));
  final c5 = e4.play(NormalMove.fromUci('c7c5'));

  return ChessGame(
    gameId: 'notation-test',
    startingFen: Chess.initial.fen,
    metadata: const <String, dynamic>{},
    mainline: [
      ChessMove(
        num: 1,
        fen: e4.fen,
        san: 'e4',
        uci: 'e2e4',
        turn: ChessColor.white,
        variations: [
          [
            ChessMove(
              num: 1,
              fen: c5.fen,
              san: 'c5',
              uci: 'c7c5',
              turn: ChessColor.black,
            ),
          ],
        ],
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
