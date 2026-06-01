import 'dart:async';

import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/chessboard/widgets/evaluation_bar_widget.dart';
import 'package:chessever/screens/chessboard/widgets/player_first_row_detail_widget.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

CloudEval _cloudEval(int cp) {
  return CloudEval(
    fen: _fen,
    knodes: 0,
    depth: 12,
    pvs: [Pv(moves: 'e7e5', cp: cp)],
    requestedMultiPv: 1,
  );
}

Future<void> _pumpEvalBar(
  WidgetTester tester, {
  required bool allowStockfishFallback,
  required Future<CloudEval> Function() cacheOnlyEval,
  PlayerView playerView = PlayerView.listView,
  double width = 24,
  double height = 240,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gameCardEvalWithStockfishFallbackProvider.overrideWith(
          (ref, fen) async => _cloudEval(120),
        ),
        gameCardEvalCacheOnlyProvider.overrideWith(
          (ref, fen) => cacheOnlyEval(),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return Scaffold(
              body: EvaluationBarWidgetForGames(
                width: width,
                height: height,
                fen: _fen,
                playerView: playerView,
                allowStockfishFallback: allowStockfishFallback,
              ),
            );
          },
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('retains previous eval while scroll cache-only eval is loading', (
    tester,
  ) async {
    final pendingCacheOnly = Completer<CloudEval>();

    await _pumpEvalBar(
      tester,
      allowStockfishFallback: true,
      cacheOnlyEval: () => pendingCacheOnly.future,
    );
    await tester.pump();

    expect(find.text('+1.2'), findsOneWidget);

    await _pumpEvalBar(
      tester,
      allowStockfishFallback: false,
      cacheOnlyEval: () => pendingCacheOnly.future,
    );
    await tester.pump();

    expect(find.text('+1.2'), findsOneWidget);
    expect(find.text('...'), findsNothing);
  });

  testWidgets('renders readable grid eval labels', (tester) async {
    await _pumpEvalBar(
      tester,
      allowStockfishFallback: true,
      cacheOnlyEval: () async => _cloudEval(120),
      playerView: PlayerView.gridView,
      width: 14,
      height: 120,
    );
    await tester.pump();

    final label = tester.widget<Text>(find.text('+1.2'));
    expect(label.style?.fontSize, greaterThanOrEqualTo(10));
    expect(label.style?.fontWeight, FontWeight.w700);
  });
}
