import 'package:chessever/desktop/state/arrow_move_eval.dart';
import 'package:chessever/desktop/widgets/arrow_move_eval_labels.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  group('arrowMoveCandidates', () {
    test('keeps legal arrows only, once each', () {
      final candidates = arrowMoveCandidates(start, [
        (Square.e2, Square.e4),
        (Square.e2, Square.e5), // pawn cannot go three squares
        (Square.e7, Square.e5), // not White's move
        (Square.d4, Square.d5), // empty square
        (Square.g1, Square.f3),
        (Square.e2, Square.e4), // drawn twice
      ]);
      expect(candidates.map((c) => c.move.uci), ['e2e4', 'g1f3']);
      expect(
        candidates.first.fenAfter,
        startsWith('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq'),
      );
    });

    test('accepts castling drawn to the king square or onto the rook', () {
      const fen = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';
      final candidates = arrowMoveCandidates(fen, [
        (Square.e1, Square.g1),
        (Square.e1, Square.a1),
      ]);
      expect(candidates, hasLength(2));
      expect(
        candidates[0].fenAfter.split(' ').first,
        'r3k2r/8/8/8/8/8/8/R4RK1',
      );
      expect(
        candidates[1].fenAfter.split(' ').first,
        'r3k2r/8/8/8/8/8/8/2KR3R',
      );
    });

    test('promotes a pawn arrow to a queen', () {
      const fen = '7k/P7/8/8/8/8/8/K7 w - - 0 1';
      final candidates = arrowMoveCandidates(fen, [(Square.a7, Square.a8)]);
      expect(candidates.single.move.promotion, Role.queen);
    });

    test('labels nothing once the game is over', () {
      const mated =
          'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3';
      expect(arrowMoveCandidates(mated, [(Square.e2, Square.e3)]), isEmpty);
    });
  });

  group('uciPlaysArrowMove', () {
    test('matches engine castling against either drawing', () {
      final position = Chess.fromSetup(
        Setup.parseFen('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1'),
      );
      final toRook = arrowLegalMove(position, Square.e1, Square.h1)!;
      final toKingSquare = arrowLegalMove(position, Square.e1, Square.g1)!;
      expect(uciPlaysArrowMove(position, 'e1g1', toRook), isTrue);
      expect(uciPlaysArrowMove(position, 'e1g1', toKingSquare), isTrue);
      expect(uciPlaysArrowMove(position, 'e1c1', toRook), isFalse);
    });

    test('an under-promotion is not the drawn queen move', () {
      final position = Chess.fromSetup(
        Setup.parseFen('7k/P7/8/8/8/8/8/K7 w - - 0 1'),
      );
      final move = arrowLegalMove(position, Square.a7, Square.a8)!;
      expect(uciPlaysArrowMove(position, 'a7a8q', move), isTrue);
      expect(uciPlaysArrowMove(position, 'a7a8n', move), isFalse);
    });
  });

  group('formatArrowMoveEval', () {
    test('writes signed pawns with a real minus and mates with #', () {
      expect(
        formatArrowMoveEval(const ArrowMoveEval(evaluation: 0.84)),
        '+0.8',
      );
      expect(
        formatArrowMoveEval(const ArrowMoveEval(evaluation: -1.36)),
        '−1.4',
      );
      expect(formatArrowMoveEval(const ArrowMoveEval(evaluation: 0.04)), '0.0');
      expect(
        formatArrowMoveEval(const ArrowMoveEval(evaluation: -0.04)),
        '0.0',
      );
      expect(
        formatArrowMoveEval(const ArrowMoveEval(evaluation: 10, mate: 3)),
        '#3',
      );
      expect(
        formatArrowMoveEval(const ArrowMoveEval(evaluation: -10, mate: -2)),
        '#−2',
      );
      expect(
        formatArrowMoveEval(const ArrowMoveEval(evaluation: 10, mate: 0)),
        '#',
      );
    });
  });

  group('arrowMoveEvalFromPvs', () {
    test('turns side-to-move scores into White scores', () {
      const blackToMove = '8/8/8/8/8/8/8/K6k b - - 0 1';
      final eval = arrowMoveEvalFromPvs([
        Pv(moves: 'h1g2', cp: 120, whitePerspective: false),
      ], blackToMove);
      expect(eval, const ArrowMoveEval(evaluation: -1.2));

      final mate = arrowMoveEvalFromPvs([
        Pv(
          moves: 'h1g2',
          cp: 100000,
          isMate: true,
          mate: 2,
          whitePerspective: false,
        ),
      ], blackToMove);
      expect(mate, const ArrowMoveEval(evaluation: -10, mate: -2));
    });

    test('keeps White scores and skips empty lines', () {
      expect(
        arrowMoveEvalFromPvs([
          Pv(moves: '', cp: 900),
          Pv(moves: 'e2e4', cp: 35),
        ], start),
        const ArrowMoveEval(evaluation: 0.35),
      );
      expect(arrowMoveEvalFromPvs(const [], start), isNull);
    });
  });

  test('a move that mates reads as #, a stalemate as 0.0', () {
    expect(
      terminalArrowMoveEval(
        'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3',
      ),
      const ArrowMoveEval(evaluation: -10, mate: 0),
    );
    expect(
      terminalArrowMoveEval('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1'),
      const ArrowMoveEval(evaluation: 0),
    );
    expect(terminalArrowMoveEval(start), isNull);
  });

  group('arrowMoveEvalLabelAnchor', () {
    test('sits behind the head, flipped with the board', () {
      final white = arrowMoveEvalLabelAnchor(
        orig: Square.e2,
        dest: Square.e4,
        boardSize: 800,
        orientation: Side.white,
      );
      // e4 centre is (450, 450); the label backs off 58 px toward e2.
      expect(white, const Offset(450, 508));

      final black = arrowMoveEvalLabelAnchor(
        orig: Square.e2,
        dest: Square.e4,
        boardSize: 800,
        orientation: Side.black,
      );
      expect(black, const Offset(350, 292));
    });

    test('never passes the middle of a one-square arrow', () {
      final anchor = arrowMoveEvalLabelAnchor(
        orig: Square.e2,
        dest: Square.e3,
        boardSize: 160,
        orientation: Side.white,
      );
      // e2 (90, 130) to e3 (90, 110): midpoint.
      expect(anchor, const Offset(90, 120));
    });
  });

  testWidgets('labels a legal arrow with the eval after its move', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          arrowMoveEvalProvider.overrideWith(
            (ref, fenAfter) async => const ArrowMoveEval(evaluation: 0.31),
          ),
        ],
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox.square(
            dimension: 640,
            child: ArrowMoveEvalLabels(
              fen: start,
              arrows: [
                cg.Arrow(
                  color: Color(0xCC15781B),
                  orig: Square.e2,
                  dest: Square.e4,
                ),
                cg.Arrow(
                  color: Color(0xCCB72217),
                  orig: Square.e2,
                  dest: Square.e5,
                ),
              ],
              boardSize: 640,
              orientation: Side.white,
              liveLinesFen: null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('+0.3'), findsOneWidget);
    final center = tester.getCenter(find.text('+0.3'));
    // e4 centre (360, 360), backed off 0.58 of an 80 px square toward e2.
    expect(center.dx, closeTo(360, 0.5));
    expect(center.dy, closeTo(406.4, 0.5));
  });
}
