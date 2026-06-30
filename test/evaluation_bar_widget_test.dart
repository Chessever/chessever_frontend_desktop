import 'dart:async';

import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/chessboard/widgets/evaluation_bar_widget.dart';
import 'package:chessever/screens/chessboard/widgets/player_first_row_detail_widget.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/chess_progress_bar.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

CloudEval _cloudEval(int cp, {String fen = _fen, String moves = 'e7e5'}) {
  return CloudEval(
    fen: fen,
    knodes: 0,
    depth: 12,
    pvs: [Pv(moves: moves, cp: cp)],
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
  CloudEval? fallbackEval,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gameCardEvalWithStockfishFallbackProvider.overrideWith(
          (ref, fen) async => fallbackEval ?? _cloudEval(120, fen: fen),
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

GamesTourModel _game({required String fen, String? pgn, String? lastMove}) {
  final white = PlayerCard(
    name: 'White',
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: null,
  );
  final black = PlayerCard(
    name: 'Black',
    federation: 'NOR',
    title: 'GM',
    rating: 2700,
    countryCode: 'NOR',
    team: null,
  );
  return GamesTourModel(
    roundId: 'round-1',
    tourId: 'tour-1',
    gameId: 'game-1',
    whitePlayer: white,
    blackPlayer: black,
    whiteTimeDisplay: '10:00',
    blackTimeDisplay: '10:00',
    whiteClockCentiseconds: 60000,
    blackClockCentiseconds: 60000,
    gameStatus: GameStatus.ongoing,
    fen: fen,
    pgn: pgn,
    lastMove: lastMove,
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

  testWidgets('renders cp-only database eval labels on board and grid cards', (
    tester,
  ) async {
    await _pumpEvalBar(
      tester,
      allowStockfishFallback: true,
      cacheOnlyEval: () async => _cloudEval(75, moves: ''),
      fallbackEval: _cloudEval(75, moves: ''),
      playerView: PlayerView.listView,
      width: 24,
      height: 240,
    );
    await tester.pump();

    expect(find.text('+0.8'), findsOneWidget);

    await _pumpEvalBar(
      tester,
      allowStockfishFallback: true,
      cacheOnlyEval: () async => _cloudEval(75, moves: ''),
      fallbackEval: _cloudEval(75, moves: ''),
      playerView: PlayerView.gridView,
      width: 14,
      height: 120,
    );
    await tester.pump();

    expect(find.text('+0.8'), findsOneWidget);
  });

  testWidgets('list progress bar labels the freshest live FEN', (tester) async {
    const afterE4 =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    const afterE4E5 =
        'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    const pgnAfterE4E5 = '''
[Event "Live Test"]
[Result "*"]

1. e4 e5 *
''';
    String? requestedFen;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          gameCardEvalWithStockfishFallbackProvider.overrideWith((ref, fen) {
            requestedFen = fen;
            return Future.value(_cloudEval(75, fen: fen, moves: ''));
          }),
          gameCardEvalCacheOnlyProvider.overrideWith(
            (ref, fen) => Future.value(_cloudEval(75, fen: fen, moves: '')),
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return Scaffold(
                body: ChessProgressBar(
                  gamesTourModel: _game(
                    fen: afterE4,
                    pgn: pgnAfterE4E5,
                    lastMove: 'e7e5',
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(requestedFen, afterE4E5);
    expect(find.text('+0.8'), findsOneWidget);
  });
}
