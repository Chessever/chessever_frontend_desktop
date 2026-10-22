import 'dart:io';
import 'dart:ui' as ui;
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> showGame(
  WidgetTester tester,
  ChessGame game,
  NotationLayoutMode mode, {
  ValueChanged<List<int>>? onJump,
  List<int> active = const [],
  double width = 780,
}) async {
  final layout = ValueNotifier(mode);
  addTearDown(layout.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SizedBox(
          width: width,
          height: 560,
          child: NotationLadderView(
            game: game,
            activePointer: active,
            onJump: onJump ?? (_) {},
            showHeader: false,
            layoutModeController: layout,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final mode in NotationLayoutMode.values) {
    testWidgets('${mode.name} displays time spent instead of remaining clock', (
      tester,
    ) async {
      final game = ChessGame.fromPgn(
        'elapsed',
        '[TimeControl "60+2"]\n\n'
            '1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]} '
            '2. Nf3 {[%clk 0:00:57]} Nc6 {[%clk 0:00:55]} *',
      );
      final before = exportGameToPgn(game);
      await showGame(tester, game, mode);
      expect(find.text('3s'), findsOneWidget);
      expect(find.text('4s'), findsNWidgets(2));
      expect(find.text('5s'), findsOneWidget);
      expect(find.text('0:59'), findsNothing);
      expect(game.mainline.first.clockTime, '0:00:59');
      expect(exportGameToPgn(game), before);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      '${mode.name} direct EMT wins and raw machine comments stay hidden',
      (tester) async {
        final game = ChessGame.fromPgn(
          'emt',
          '1. e4 {Human prose [%emt 0:00:07.25] [%clk 0:09:00]} *',
        );
        await showGame(tester, game, mode);
        expect(find.text('7.25s'), findsOneWidget);
        expect(find.textContaining('Human prose'), findsWidgets);
        expect(find.textContaining('[%emt'), findsNothing);
        expect(find.text('9:00'), findsNothing);
        expect(
          game.mainline.first.comments!.single,
          contains('[%emt 0:00:07.25]'),
        );
        expect(game.mainline.first.clockTime, '0:09:00');
      },
    );
    testWidgets('${mode.name} unknown control never invents an elapsed label', (
      tester,
    ) async {
      await showGame(
        tester,
        ChessGame.fromPgn(
          'unknown',
          '1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]} *',
        ),
        mode,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is DesktopTooltip && w.message.startsWith('Time spent:'),
        ),
        findsNothing,
      );
      expect(find.text('0:59'), findsNothing);
      expect(find.text('0s'), findsNothing);
    });
    testWidgets(
      '${mode.name} elapsed time is neutral, not a red low-clock warning',
      (tester) async {
        final game = ChessGame.fromPgn(
          'quick',
          '[TimeControl "30"]\n\n1. e4 {[%clk 0:00:29]} *',
        );
        await showGame(tester, game, mode);
        expect(
          tester.widget<Text>(find.text('1s')).style!.color,
          const Color(0xFF8E8E93),
        );
        expect(
          tester.widget<Text>(find.text('1s')).style!.color,
          isNot(kRedColor),
        );
        expect(
          tester.widget<Text>(find.text('1s')).style!.fontWeight,
          FontWeight.w500,
        );
        await showGame(tester, game, mode, active: const [0]);
        expect(
          tester.widget<Text>(find.text('1s')).style!.color,
          kBackgroundColor.withValues(alpha: 0.85),
        );
      },
    );
    testWidgets(
      '${mode.name} passive hover shows both times and click still jumps',
      (tester) async {
        final jumps = <List<int>>[];
        final game = ChessGame.fromPgn(
          'hover',
          '[TimeControl "60+2"]\n\n1. e4 {[%clk 0:00:59]} *',
        );
        await showGame(tester, game, mode, onJump: jumps.add);
        const message = 'Time spent: 3s\nTime remaining: 0:59';
        expect(
          find.byWidgetPredicate(
            (w) => w is DesktopTooltip && w.message == message,
          ),
          findsOneWidget,
        );
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(find.text('3s')));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        expect(jumps, isEmpty);
        await tester.tap(find.text('3s'));
        await tester.pumpAndSettle();
        expect(jumps, [
          <int>[0],
        ]);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${mode.name} variation clocks and jump pointers stay branch-local',
      (tester) async {
        final game = ChessGame.fromPgn(
          'branch',
          '[TimeControl "60+2"]\n\n'
              '1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]} '
              '(1... c5 {[%clk 0:00:54]} 2. Nf3 {[%clk 0:00:56]}) '
              '2. Nf3 {[%clk 0:00:57]} *',
        );
        final jumps = <List<int>>[];
        await showGame(tester, game, mode, onJump: jumps.add);
        expect(find.text('8s'), findsOneWidget);
        expect(find.text('5s'), findsOneWidget);
        await tester.tap(find.text('8s'));
        await tester.pumpAndSettle();
        expect(jumps, [
          <int>[0, 0, 0],
        ]);
      },
    );
    testWidgets(
      '${mode.name} new clock and metadata-only changes invalidate timing cache',
      (tester) async {
        final game = ChessGame.fromPgn(
          'live',
          '[TimeControl "60+2"]\n\n1. e4 {[%clk 0:00:59]} *',
        );
        await showGame(tester, game, mode);
        expect(find.text('3s'), findsOneWidget);
        final updated = game.copyWith(
          mainline: [game.mainline.first.copyWith(clockTime: '0:01:00')],
        );
        await showGame(tester, updated, mode);
        expect(find.text('2s'), findsOneWidget);
        expect(find.text('3s'), findsNothing);
        updated.metadata['TimeControl'] = '60+3';
        await showGame(tester, updated, mode);
        expect(find.text('3s'), findsOneWidget);
        expect(find.text('2s'), findsNothing);
      },
    );
    testWidgets(
      '${mode.name} precise clock correction is authoritative over stale raw annotation',
      (tester) async {
        final game = ChessGame.fromPgn(
          'precise',
          '[TimeControl "60+2"]\n\n1. e4 {[%clk 0:00:58.75]} *',
        );
        await showGame(tester, game, mode);
        expect(find.text('3.25s'), findsOneWidget);
        final updated = game.copyWith(
          mainline: [game.mainline.first.copyWith(clockTime: '0:00:58.25')],
        );
        await showGame(tester, updated, mode);
        expect(find.text('3.75s'), findsOneWidget);
        expect(find.text('3.25s'), findsNothing);
      },
    );
    testWidgets('${mode.name} zero and long labels fit a narrow pane', (
      tester,
    ) async {
      await showGame(
        tester,
        ChessGame.fromPgn(
          'narrow',
          '1. e4 {[%emt 0:00:00]} e5 {[%emt 1:02:03]} *',
        ),
        mode,
        width: 300,
      );
      expect(find.text('0s'), findsOneWidget);
      expect(find.text('1h2m3s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('capture elapsed notation source-widget preview', (tester) async {
    final output = Platform.environment['NOTATION_ELAPSED_PREVIEW'];
    if (output == null) return;
    for (final family in ['Geist', 'Roboto', 'Ahem']) {
      final font = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'));
      await font.load();
    }
    await tester.binding.setSurfaceSize(const Size(1000, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final game = ChessGame.fromPgn(
      'preview',
      '[TimeControl "600+2"]\n\n'
          '1. e4 {[%clk 0:09:34]} e5 {[%clk 0:09:50]} '
          '2. Nf3 {[%clk 0:09:18]} Nc6 {[%clk 0:09:05]} '
          '(2... d6 {[%emt 0:01:12]} 3. d4 {[%emt 0:00:03]}) '
          '3. Bb5 {[%clk 0:09:08]} a6 {[%clk 0:09:03]} *',
    );
    final key = GlobalKey();
    final layout = ValueNotifier(NotationLayoutMode.inline);
    addTearDown(layout.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Geist'),
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Elapsed move time — source-widget preview, not the running Development app',
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: NotationLadderView(
                          game: game,
                          activePointer: const [2],
                          onJump: (_) {},
                          showHeader: false,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: NotationLadderView(
                          game: game,
                          activePointer: const [2],
                          onJump: (_) {},
                          showHeader: false,
                          layoutModeController: layout,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Replace only the headless engine's Ahem fallback, never production fonts.
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
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(output).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
