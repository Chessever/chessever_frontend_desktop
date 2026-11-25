// Two copies, one rule: web src/broadcast/lib/toby-quality.ts and desktop
// lib/desktop/services/toby/toby_quality.dart. Keep these cases in step with
// the web's tests.
import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart' show Side, Square;
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/services/toby/toby_quality.dart';
import 'package:chessever/desktop/state/toby_panel.dart';

TobyCandidate _move(String uci, double p, [TobyWdl? wdl]) =>
    TobyCandidate(uci: uci, san: uci, probability: p, wdl: wdl);

TobyWdl _wdl(double white, double draw, double black) =>
    TobyWdl(white: white, draw: draw, black: black);

TobyReading _reading(
  List<TobyCandidate> candidates, {
  Side side = Side.white,
  bool isFinal = true,
}) => TobyReading(
  isFinal: isFinal,
  sideToMove: side,
  candidates: candidates,
  otherProbability: 0,
  otherMoveCount: 0,
);

void main() {
  group('expected score', () {
    test('is the mover\'s win plus half the draw', () {
      final wdl = _wdl(0.30, 0.50, 0.20);
      expect(tobyExpectedScore(wdl, Side.white), moreOrLessEquals(0.55));
      expect(tobyExpectedScore(wdl, Side.black), moreOrLessEquals(0.45));
    });

    test('Gamebase\'s per-mille or percent outcomes read as fractions', () {
      // TobyWdl.fromJson divides by the total, whatever the scale.
      for (final scale in [1.0, 100.0, 1000.0]) {
        final wdl =
            TobyWdl.fromJson({
              'white': 0.31 * scale,
              'draw': 0.46 * scale,
              'black': 0.23 * scale,
            })!;
        expect(tobyExpectedScore(wdl, Side.white), moreOrLessEquals(0.54));
      }
    });
  });

  group('quality', () {
    TobyMoveQuality judge(double loss) => tobyMoveQuality(
      // White to move, best 0.60; this move scores 0.60 - loss.
      wdl: _wdl(0.60 - loss, 0, 0.40 + loss),
      best: 0.60,
      mover: Side.white,
    );

    test('loss under five points is good, five to ten dubious, ten or more '
        'a mistake', () {
      expect(judge(0), TobyMoveQuality.good);
      expect(judge(0.049), TobyMoveQuality.good);
      expect(judge(0.05), TobyMoveQuality.dubious);
      expect(judge(0.099), TobyMoveQuality.dubious);
      expect(judge(0.10), TobyMoveQuality.bad);
      expect(judge(0.40), TobyMoveQuality.bad);
    });

    test('no outcome is neutral', () {
      expect(
        tobyMoveQuality(wdl: null, best: 0.5, mover: Side.white),
        TobyMoveQuality.neutral,
      );
      expect(
        tobyMoveQuality(
          wdl: _wdl(0.3, 0.4, 0.3),
          best: null,
          mover: Side.black,
        ),
        TobyMoveQuality.neutral,
      );
    });

    test('the best is the reading\'s best judged candidate, from the '
        'mover\'s side: a likely bad move is red', () {
      // Black to move. Expected for Black: a .30, b .55, c .48.
      final reading = _reading([
        _move('e7e5', 0.6, _wdl(0.55, 0.30, 0.15)),
        _move('c7c5', 0.3, _wdl(0.20, 0.50, 0.30)),
        _move('d7d5', 0.1, _wdl(0.27, 0.50, 0.23)),
        _move('g8f6', 0.05),
      ], side: Side.black);
      expect(tobyMoveQualities(reading), {
        'e7e5': TobyMoveQuality.bad,
        'c7c5': TobyMoveQuality.good,
        'd7d5': TobyMoveQuality.dubious,
        'g8f6': TobyMoveQuality.neutral,
      });
    });

    test('the best counts every move the payload sent, not only the 24 '
        'the parser keeps (the web keeps them all)', () {
      // 30 moves, White to move. The 24 kept score .50; the least likely,
      // cut by the parser, scores .62, so every kept row loses .12: a mistake.
      const squares = 'abcdefgh';
      final moves = [
        for (var i = 0; i < 30; i++)
          {
            'uci': '${squares[i % 8]}2${squares[i % 8]}${3 + i ~/ 8}',
            'san': 'm$i',
            'probability': (40 - i) / 1000,
            'wdl':
                i == 29
                    ? {'white': 0.62, 'draw': 0.0, 'black': 0.38}
                    : {'white': 0.50, 'draw': 0.0, 'black': 0.50},
          },
      ];
      final reading =
          TobyReading.fromJson({
            'stage': 'final',
            'sideToMove': 'white',
            'moves': moves,
            'otherProbability': 0.0,
            'otherMoveCount': 0,
          })!;
      expect(reading.candidates, hasLength(24));
      expect(reading.bestOutcomeScore, moreOrLessEquals(0.62));
      expect(
        tobyMoveQualities(reading).values,
        everyElement(TobyMoveQuality.bad),
      );
    });

    test('the network stage is all neutral', () {
      final reading = _reading([
        _move('g1f3', 0.7),
        _move('d2d4', 0.3),
      ], isFinal: false);
      expect(
        tobyMoveQualities(reading).values,
        everyElement(TobyMoveQuality.neutral),
      );
    });

    test('board hues', () {
      expect(tobyArrowHue(TobyMoveQuality.good), const Color(0xFF2E7D4F));
      expect(tobyArrowHue(TobyMoveQuality.dubious), const Color(0xFFB7791F));
      expect(tobyArrowHue(TobyMoveQuality.bad), const Color(0xFFB23A3A));
      expect(tobyArrowHue(TobyMoveQuality.neutral), const Color(0xFF1E7F79));
    });
  });

  group('top arrows', () {
    final reading = _reading([
      _move('g1f3', 0.5, _wdl(0.30, 0.55, 0.15)),
      _move('d2d4', 0.4, _wdl(0.25, 0.55, 0.20)),
      _move('d1h5', 0.08, _wdl(0.15, 0.45, 0.40)),
      _move('a2a3', 0.02, _wdl(0.30, 0.55, 0.15)),
    ]);

    test('the three most likely, least likely first, so the most likely '
        'is drawn on top', () {
      final arrows = tobyTopArrows(reading);
      expect(
        [for (final a in arrows) (a.orig, a.dest)],
        [
          (Square.d1, Square.h5),
          (Square.d2, Square.d4),
          (Square.g1, Square.f3),
        ],
      );
    });

    test('weighted by chance against the most likely, with a floor', () {
      final arrows = tobyTopArrows(reading);
      expect(arrows.last.scale, 0.8);
      expect(arrows.last.color.a, moreOrLessEquals(0.9, epsilon: 0.005));
      expect(arrows[1].scale, moreOrLessEquals(0.64));
      expect(arrows[1].color.a, moreOrLessEquals(0.72, epsilon: 0.005));
      // 0.08 / 0.5 would be far too faint: the floor holds.
      expect(arrows.first.scale, 0.45);
      expect(arrows.first.color.a, moreOrLessEquals(0.55, epsilon: 0.005));
    });

    test('coloured by quality', () {
      expect(tobyTopArrows(reading).map((a) => a.color.withValues(alpha: 1)), [
        kTobyArrowBad,
        kTobyArrowDubious,
        kTobyArrowGood,
      ]);
    });

    test('fewer candidates, fewer arrows; none, none', () {
      expect(tobyTopArrows(_reading([_move('e2e4', 1)])), hasLength(1));
      expect(tobyTopArrows(_reading(const [])), isEmpty);
    });
  });

  group('controller', () {
    const position = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final reading = _reading([
      _move('g1f3', 0.5, _wdl(0.30, 0.55, 0.15)),
      _move('d2d4', 0.4, _wdl(0.25, 0.55, 0.20)),
      _move('d1h5', 0.1, _wdl(0.15, 0.45, 0.40)),
    ]);

    late TobyPanelController controller;
    setUp(() => controller = TobyPanelController(session: 'quality-test'));
    tearDown(() => controller.dispose());

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    List<(Square, Square)> drawn() => [
      for (final cg.Arrow a in controller.boardArrows.value?.arrows ?? const [])
        (a.orig, a.dest),
    ];

    test('a reading on show puts its top three on the board, after the '
        'frame, keyed by its position', () async {
      controller.showReadingSoon(position, reading);
      expect(controller.boardArrows.value, isNull);
      await settle();
      final shown = controller.boardArrows.value!;
      expect(shown.positionKey, position);
      expect(shown.exclusive, isFalse);
      expect(drawn(), hasLength(3));
    });

    test('a hover is exclusive and alone, at full weight in its hue; a pin '
        'stands in for the three and keeps the ink', () async {
      controller.showReadingSoon(position, reading);
      await settle();

      controller.hover(position, 'd1h5');
      final hovered = controller.boardArrows.value!;
      expect(hovered.exclusive, isTrue);
      expect(drawn(), [(Square.d1, Square.h5)]);
      expect(
        hovered.arrows.single.color,
        kTobyArrowBad.withValues(alpha: kTobyArrowAlpha),
      );
      expect(hovered.arrows.single.scale, kTobyArrowScale);

      controller.togglePin(position, 'd2d4');
      controller.clearHover();
      final pinned = controller.boardArrows.value!;
      expect(pinned.exclusive, isFalse);
      expect(drawn(), [(Square.d2, Square.d4)]);
      expect(
        pinned.arrows.single.color.withValues(alpha: 1),
        kTobyArrowDubious,
      );

      controller.clearPin();
      expect(drawn(), hasLength(3));
    });

    test('leaving the tab (no reading) takes the arrows off', () async {
      controller.showReadingSoon(position, reading);
      await settle();
      controller.showReadingSoon(null, null);
      await settle();
      expect(controller.boardArrows.value, isNull);
    });

    test('a hover with no reading on show for its position stays teal', () {
      controller.hover('other', 'g1f3');
      expect(
        controller.boardArrows.value!.arrows.single.color,
        kTobyArrowColor,
      );
    });
  });
}
