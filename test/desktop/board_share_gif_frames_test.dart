import 'dart:typed_data';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:chessever/desktop/services/board_share_service.dart';
import 'package:chessever/desktop/widgets/board_share_dialog.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

// Last-move highlight color: lib/utils/board_customization_utils.dart ->
// kLastMoveHighlightColor (0xFFADB9CF).
const int _hlR = 0xAD;
const int _hlG = 0xB9;
const int _hlB = 0xCF;

int _sqDist(img.Pixel p, int r, int g, int b) {
  final dr = p.r.toInt() - r;
  final dg = p.g.toInt() - g;
  final db = p.b.toInt() - b;
  return dr * dr + dg * dg + db * db;
}

/// Count pixels within [tol] of the highlight color across the whole frame.
int _highlightPixelCount(img.Image frame, {int tol = 12}) {
  final tol2 = tol * tol;
  var count = 0;
  for (final p in frame) {
    if (_sqDist(p, _hlR, _hlG, _hlB) <= tol2) count++;
  }
  return count;
}

/// Count near-white pixels in the eval-bar column (left edge of the card).
///
/// The eval bar is 24 px wide at the very left; for an un-flipped board White's
/// fill (near-white) sits at the bottom, so the count grows with White's
/// advantage. Sampling column x=12 avoids the numeric badge in the centre.
int _evalBarWhiteRun(img.Image frame) {
  const x = 12;
  var whites = 0;
  for (var y = 0; y < frame.height; y++) {
    final p = frame.getPixel(x, y);
    if (p.r > 200 && p.g > 200 && p.b > 200) whites++;
  }
  return whites;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseBoardShareMoveEval', () {
    test('parses centipawn floats and mate strings', () {
      expect(parseBoardShareMoveEval('0.34')?.evaluation, 0.34);
      expect(parseBoardShareMoveEval('-1.2')?.evaluation, -1.2);
      expect(parseBoardShareMoveEval('#3')?.mate, 3);
      expect(parseBoardShareMoveEval('M-2')?.mate, -2);
      expect(parseBoardShareMoveEval(''), isNull);
      expect(parseBoardShareMoveEval(null), isNull);
    });
  });

  group('buildBoardShareGifFrames', () {
    test('carries annotated evals forward and never smears frame 0', () {
      final game = ChessGame.fromPgn(
        'g1',
        '1. e4 { [%eval 0.2] } e5 { [%eval 0.3] } '
        '2. Nf3 { [%eval 0.1] } Nc6 { [%eval 0.4] } *',
      );
      final data = buildBoardShareGifFrames(
        startingFen: game.startingFen,
        mainline: game.mainline,
      );

      // 4 plies -> 5 frames (start + one per move), all lists aligned.
      expect(data.frames.length, 5);
      expect(data.durationsCs.length, 5);
      expect(data.clocks.length, 5);
      expect(data.evaluations.length, 5);

      // Frame 0 is the starting position: no move, no eval (not the last eval).
      expect(data.frames[0].lastMove, isNull);
      expect(data.evaluations[0].evaluation, isNull);
      expect(data.evaluations[0].mate, isNull);

      // Each move frame highlights its own move and shows its own eval.
      expect(data.frames[1].lastMove, isNotNull);
      expect(data.evaluations[1].evaluation, 0.2);
      expect(data.evaluations[2].evaluation, 0.3);
      expect(data.evaluations[3].evaluation, 0.1);
      expect(data.evaluations[4].evaluation, 0.4);

      // Final frame is held longer than the middle frames.
      expect(data.durationsCs.last, greaterThan(data.durationsCs[1]));
    });

    test('leaves evals neutral for an unannotated game (no smear)', () {
      final game = ChessGame.fromPgn('g2', '1. e4 e5 2. Nf3 Nc6 *');
      final data = buildBoardShareGifFrames(
        startingFen: game.startingFen,
        mainline: game.mainline,
      );

      expect(data.frames.length, 5);
      for (final e in data.evaluations) {
        expect(e.evaluation, isNull);
        expect(e.mate, isNull);
        expect(e.isEvaluating, isFalse);
      }
      // Still highlights every move.
      expect(data.frames[0].lastMove, isNull);
      for (var i = 1; i < data.frames.length; i++) {
        expect(data.frames[i].lastMove, isNotNull);
      }
      expect(shouldShowBoardShareGifEvalBar(data.evaluations), isFalse);
    });

    test('keeps the GIF eval bar when replay frames contain evaluations', () {
      final game = ChessGame.fromPgn(
        'g-with-evals',
        '1. e4 { [%eval 0.2] } e5 { [%eval 0.1] } *',
      );
      final data = buildBoardShareGifFrames(
        startingFen: game.startingFen,
        mainline: game.mainline,
      );

      expect(shouldShowBoardShareGifEvalBar(data.evaluations), isTrue);
    });

    test('stops replay cleanly at an unparseable SAN', () {
      final legal = ChessMove(
        num: 1,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        san: 'e4',
        uci: 'e2e4',
        turn: ChessColor.white,
      );
      final illegal = ChessMove(
        num: 1,
        fen: '',
        san: 'Qh8', // impossible from the position after 1.e4
        uci: 'd1h8',
        turn: ChessColor.black,
      );
      final data = buildBoardShareGifFrames(
        startingFen: Chess.initial.fen,
        mainline: [legal, illegal],
      );

      // start + e4 only; the illegal SAN halts replay instead of desyncing.
      expect(data.frames.length, 2);
      expect(data.frames[1].lastMove, isNotNull);
    });
  });

  group('generateGif (decoded frames)', () {
    testWidgets('highlights every move frame and updates the eval bar', (
      tester,
    ) async {
      const settings = BoardSettingsNew();
      final boardSettings = cg.ChessboardSettings(
        enableCoordinates: true,
        animationDuration: Duration.zero,
        colorScheme: settings.colorScheme,
        pieceAssets: settings.pieceAssets,
        borderRadius: BorderRadius.zero,
        boxShadow: const [],
      );

      final sans = <String>['e4', 'e5', 'Nf3', 'Nc6'];
      Position pos = Chess.initial;
      final frames = <({String fen, Move? lastMove})>[
        (fen: Chess.initial.fen, lastMove: null),
      ];
      for (final san in sans) {
        final m = pos.parseSan(san)! as NormalMove;
        pos = pos.play(m);
        frames.add((fen: pos.fen, lastMove: NormalMove(from: m.from, to: m.to)));
      }

      // Frame 0 neutral (null) — must NOT inherit a later eval. Later frames
      // lean progressively toward White.
      final evals = <({double? evaluation, int? mate, bool isEvaluating})>[
        (evaluation: null, mate: null, isEvaluating: false),
        (evaluation: 0.3, mate: null, isEvaluating: false),
        (evaluation: 1.0, mate: null, isEvaluating: false),
        (evaluation: 2.5, mate: null, isEvaluating: false),
        (evaluation: 5.0, mate: null, isEvaluating: false),
      ];

      Uint8List? gifBytes;
      await tester.runAsync(() async {
        gifBytes = await BoardShareService.generateGif(
          frames: frames,
          durationsCs: const [80, 50, 50, 50, 160],
          boardSettings: boardSettings,
          whiteName: 'White Player',
          blackName: 'Black Player',
          event: 'Repro Event',
          showEvalBar: true,
          // A strong single top-level eval that the OLD code smeared onto every
          // un-annotated frame. With the fix, per-frame nulls win and this is
          // ignored for the neutral starting frame.
          evaluation: 5.0,
          frameEvaluations: evals,
        );
      });

      expect(gifBytes, isNotNull, reason: 'generateGif returned null');
      final decoded = img.decodeGif(gifBytes!);
      expect(decoded, isNotNull);
      expect(decoded!.numFrames, frames.length);

      // Highlight: frame 0 (no move) clean; every move frame highlighted.
      expect(
        _highlightPixelCount(decoded.frames[0]),
        lessThan(50),
        reason: 'frame 0 has no last move',
      );
      for (var i = 1; i < decoded.numFrames; i++) {
        expect(
          _highlightPixelCount(decoded.frames[i]),
          greaterThan(200),
          reason: 'frame $i must highlight its last move',
        );
      }

      // Eval bar: neutral frame 0 must sit near the middle, NOT smeared to the
      // +5 endgame value; White's fill must grow as the advantage grows.
      final w0 = _evalBarWhiteRun(decoded.frames[0]);
      final w1 = _evalBarWhiteRun(decoded.frames[1]);
      final wLast = _evalBarWhiteRun(decoded.frames[decoded.numFrames - 1]);
      // ignore: avoid_print
      print('EVAL BAR white-run  frame0=$w0 frame1=$w1 frameLast=$wLast');

      // Neutral frame 0 must stay near the middle even though a strong
      // top-level eval (+5.0) was supplied — proving the smear is gone. The
      // +5.0 fill is ~328 px; neutral is ~200 px. Guard well below the +5 fill.
      expect(
        w0,
        lessThan(260),
        reason: 'frame 0 must render a neutral bar, not the smeared +5.0 eval',
      );
      expect(
        wLast,
        greaterThan(w0 + 30),
        reason: 'strong White eval must show more white fill than neutral',
      );
      expect(
        wLast,
        greaterThan(w1),
        reason: 'eval bar must grow with the advantage across frames',
      );
    });
  });
}
