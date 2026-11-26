// The Game Report's move classes on Toby's predicted moves.
//
// Two copies, one rule: the web's `test/toby-classes.test.ts` (chessever web
// frontend) runs the same shared table (`SHARED` there, [_shared] here,
// copied verbatim) against `src/broadcast/lib/toby-classes.ts`. Change a rule
// here, change it there, and the table in both.

import 'dart:math' as math;

import 'package:dartchess/dartchess.dart'
    show Chess, Move, Position, Side, Square;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/lichess_judgment.dart';
import 'package:chessever/desktop/services/toby/toby_classes.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/theme/app_theme.dart';

/// Italian Game, White to move, ply 12.
const String _white =
    'r1bq1rk1/ppp2ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP2PPP/R1BQ1RK1 w - - 0 7';

/// Twelve plies from the standard start, the last one d7d6. (Only the count
/// and the last move are read: the ply for the opening rule and the book
/// window, the previous move for the board facts.)
final List<String> _moves = [...List.filled(11, 'a2a3'), 'd7d6'];

/// An outcome whose White win% (white + draw / 2) is [win].
TobyWdl _wdl(double win) {
  final draw = 0.3 * (1 - (win - 50).abs() / 50);
  final white = win / 100 - draw / 2;
  return TobyWdl(white: white, draw: draw, black: 1 - white - draw);
}

const Map<String, String> _san = {
  'c1g5': 'Bg5',
  'a2a3': 'a3',
  'h2h3': 'h3',
  'c4f7': 'Bxf7+',
  'a7a6': 'a6',
  'h7h6': 'h6',
};

TobyReading _reading(
  Map<String, double?> moves, {
  double? position = 50,
  bool isFinal = true,
  Side side = Side.white,
}) {
  var p = 0.6;
  return TobyReading(
    isFinal: isFinal,
    sideToMove: side,
    candidates: [
      for (final MapEntry(key: uci, value: win) in moves.entries)
        TobyCandidate(
          uci: uci,
          san: _san[uci]!,
          probability: p /= 2,
          wdl: win == null ? null : _wdl(win),
        ),
    ],
    positionWdl: position == null ? null : _wdl(position),
    otherProbability: 0,
    otherMoveCount: 0,
  );
}

Map<String, GameMoveClassification?> _classes(
  TobyReading reading, {
  String fen = _white,
  Map<String, int>? book,
  String? startFen,
}) => tobyMoveClasses(
  reading,
  fen: fen,
  startFen: startFen,
  moves: _moves,
  bookCounts: book,
);

/// One row of the shared table: moves from the standard start, outcomes as
/// [white, draw, black], probabilities 0.40, 0.35, ... in list order, the
/// opening tree's counts, and every candidate's class by its web wire name
/// (`good` is Great, `best` Top move).
typedef _SharedCase =
    ({
      String name,
      List<String> moves,
      String stage,
      List<double>? position,
      List<List<Object?>> candidates,
      Map<String, int> book,
      Map<String, String?> expect,
    });

const List<_SharedCase> _shared = [
  (
    name: 'blunder',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.343, 0.294, 0.363],
      ],
      [
        'h2h3',
        [0.231, 0.198, 0.571],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'good', 'a2a3': null, 'h2h3': 'blunder'},
  ),
  (
    name: 'mistake',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.343, 0.294, 0.363],
      ],
      [
        'h2h3',
        [0.273, 0.234, 0.493],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'good', 'a2a3': null, 'h2h3': 'mistake'},
  ),
  (
    name: 'inaccuracy',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.343, 0.294, 0.363],
      ],
      [
        'h2h3',
        [0.308, 0.264, 0.428],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'good', 'a2a3': null, 'h2h3': 'inaccuracy'},
  ),
  (
    name: 'book takes an ordinary move; errors outrank book',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.343, 0.294, 0.363],
      ],
      [
        'h2h3',
        [0.308, 0.264, 0.428],
      ],
    ],
    book: {'a2a3': 120, 'h2h3': 500},
    expect: {'c1g5': 'good', 'a2a3': 'book', 'h2h3': 'inaccuracy'},
  ),
  (
    name: 'great: the best by 6 points',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.343, 0.294, 0.363],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'good', 'a2a3': null},
  ),
  (
    name: 'top move: the only good move',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.315, 0.27, 0.415],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'best', 'a2a3': 'inaccuracy'},
  ),
  (
    name: 'book at 10 games takes praise',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.315, 0.27, 0.415],
      ],
    ],
    book: {'c1g5': 10},
    expect: {'c1g5': 'book', 'a2a3': 'inaccuracy'},
  ),
  (
    name: '9 games is not book',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.315, 0.27, 0.415],
      ],
    ],
    book: {'c1g5': 9},
    expect: {'c1g5': 'best', 'a2a3': 'inaccuracy'},
  ),
  (
    name: 'brilliant: a sound sacrifice',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c4f7',
        [0.506, 0.228, 0.266],
      ],
      [
        'c1g5',
        [0.35, 0.3, 0.35],
      ],
    ],
    book: <String, int>{},
    expect: {'c4f7': 'brilliant', 'c1g5': null},
  ),
  (
    name: 'brilliant needs the sacrifice',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.506, 0.228, 0.266],
      ],
      [
        'a2a3',
        [0.35, 0.3, 0.35],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'best', 'a2a3': null},
  ),
  (
    name: 'missed win',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.74, 0.12, 0.14],
    candidates: [
      [
        'c1g5',
        [0.805, 0.09, 0.105],
      ],
      [
        'h2h3',
        [0.376, 0.288, 0.336],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'best', 'h2h3': 'missed_win'},
  ),
  (
    name: 'a decided win stays unjudged',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.87, 0.06, 0.07],
    candidates: [
      [
        'c1g5',
        [0.896, 0.048, 0.056],
      ],
      [
        'h2h3',
        [0.74, 0.12, 0.14],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'best', 'h2h3': null},
  ),
  (
    name: 'the best move losing ground',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.21, 0.18, 0.61],
      ],
      [
        'h2h3',
        [0.175, 0.15, 0.675],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': null, 'h2h3': 'blunder'},
  ),
  (
    name: 'one outcome: no praise',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'c1g5',
        [0.61, 0.18, 0.21],
      ],
      ['h2h3', null],
    ],
    book: <String, int>{},
    expect: {'c1g5': null, 'h2h3': null},
  ),
  (
    name: 'network stage: book or nothing',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'network',
    position: [0.35, 0.3, 0.35],
    candidates: [
      ['c1g5', null],
      ['a2a3', null],
    ],
    book: {'c1g5': 50},
    expect: {'c1g5': 'book', 'a2a3': null},
  ),
  (
    name: 'no position outcome: book only',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: null,
    candidates: [
      [
        'c1g5',
        [0.415, 0.27, 0.315],
      ],
      [
        'a2a3',
        [0.343, 0.294, 0.363],
      ],
    ],
    book: {'a2a3': 50},
    expect: {'c1g5': null, 'a2a3': 'book'},
  ),
  (
    name: 'black to move',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
    ],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'a7a6',
        [0.35, 0.3, 0.35],
      ],
      [
        'h7h6',
        [0.571, 0.198, 0.231],
      ],
    ],
    book: <String, int>{},
    expect: {'a7a6': 'best', 'h7h6': 'blunder'},
  ),
  (
    name: 'losing-side ceiling 25.58',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.175, 0.15, 0.675],
    candidates: [
      [
        'c1g5',
        [0.175, 0.15, 0.675],
      ],
      [
        'h2h3',
        [0.098, 0.084, 0.818],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'good', 'h2h3': null},
  ),
  (
    name: 'above the position average but behind the best: no praise',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.315, 0.27, 0.415],
    candidates: [
      [
        'c1g5',
        [0.48, 0.24, 0.28],
      ],
      [
        'a2a3',
        [0.415, 0.27, 0.315],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'good', 'a2a3': null},
  ),
  (
    name: 'great, not top move, under the best-line cap',
    moves: [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
      'f1c4',
      'f8c5',
      'c2c3',
      'g8f6',
      'd2d3',
      'd7d6',
      'e1g1',
      'e8g8',
    ],
    stage: 'final',
    position: [0.3367, 0.2886, 0.3747],
    candidates: [
      [
        'c1g5',
        [0.4761, 0.2418, 0.2821],
      ],
      [
        'c4f7',
        [0.3799, 0.2862, 0.3339],
      ],
    ],
    book: <String, int>{},
    expect: {'c1g5': 'good', 'c4f7': null},
  ),
  (
    name: 'a simple recapture earns no praise',
    moves: ['e2e4', 'd7d5'],
    stage: 'final',
    position: [0.35, 0.3, 0.35],
    candidates: [
      [
        'e4d5',
        [0.428, 0.264, 0.308],
      ],
      [
        'b1c3',
        [0.322, 0.276, 0.402],
      ],
    ],
    book: <String, int>{},
    expect: {'e4d5': null, 'b1c3': null},
  ),
  (
    name: 'the opening: book, an error over book, too few games',
    moves: <String>[],
    stage: 'final',
    position: [0.376, 0.288, 0.336],
    candidates: [
      [
        'e2e4',
        [0.415, 0.27, 0.315],
      ],
      [
        'd2d4',
        [0.4085, 0.273, 0.3185],
      ],
      [
        'g2g4',
        [0.28, 0.24, 0.48],
      ],
      [
        'g1f3',
        [0.428, 0.264, 0.308],
      ],
    ],
    book: {'e2e4': 1000000, 'd2d4': 800000, 'g2g4': 5000, 'g1f3': 9},
    expect: {'e2e4': 'book', 'd2d4': 'book', 'g2g4': 'mistake', 'g1f3': null},
  ),
];

const Map<GameMoveClassification, String> _wire = {
  GameMoveClassification.brilliant: 'brilliant',
  GameMoveClassification.goodMove: 'good',
  GameMoveClassification.bestMove: 'best',
  GameMoveClassification.bookMove: 'book',
  GameMoveClassification.inaccuracy: 'inaccuracy',
  GameMoveClassification.mistake: 'mistake',
  GameMoveClassification.blunder: 'blunder',
  GameMoveClassification.missedWin: 'missed_win',
};

Map<String, String?> _sharedClasses(_SharedCase c) {
  Position position = Chess.initial;
  for (final uci in c.moves) {
    position = position.play(Move.parse(uci)!);
  }
  Map<String, double>? triple(Object? t) {
    if (t == null) return null;
    final v = t as List<double>;
    return {'white': v[0], 'draw': v[1], 'black': v[2]};
  }

  final reading =
      TobyReading.fromJson({
        'stage': c.stage,
        'sideToMove': position.turn == Side.white ? 'white' : 'black',
        'moves': [
          for (final (k, row) in c.candidates.indexed)
            {
              'uci': row[0],
              'san': position.makeSan(Move.parse(row[0]! as String)!).$2,
              'probability': 0.4 - k * 0.05,
              'wdl': triple(row[1]),
            },
        ],
        'positionWdl': triple(c.position),
        'otherProbability': 0,
        'otherMoveCount': 0,
      })!;
  final classes = tobyMoveClasses(
    reading,
    fen: position.fen,
    moves: c.moves,
    bookCounts: c.book,
  );
  return {
    for (final MapEntry(:key, :value) in classes.entries)
      key: value == null ? null : _wire[value],
  };
}

void main() {
  group('the shared parity table (the web\'s SHARED)', () {
    for (final (i, c) in _shared.indexed) {
      test('shared ${i + 1}: ${c.name}', () {
        expect(_sharedClasses(c), c.expect);
      });
    }
  });

  group('inputs', () {
    test('win% is White plus half the draw', () {
      expect(
        tobyWhiteWinPercent(
          const TobyWdl(white: 0.40, draw: 0.30, black: 0.30),
        ),
        moreOrLessEquals(55),
      );
    });

    test('no position outcome: no class', () {
      expect(
        _classes(_reading({'c1g5': 55, 'h2h3': 20}, position: null)).values,
        everyElement(isNull),
      );
    });

    test('Book only from the standard start, inside the probe window', () {
      expect(tobyBookApplies(startFen: null, plies: 12), isTrue);
      expect(
        tobyBookApplies(startFen: null, plies: kBookProbeMaxPlies),
        isFalse,
      );
      expect(tobyBookApplies(startFen: _white, plies: 0), isFalse);
      expect(
        _classes(
          _reading({'c1g5': 55, 'a2a3': 49}),
          book: {'a2a3': 500},
          startFen: _white,
        )['a2a3'],
        isNull,
      );
    });

    test('a castle finds its count under either spelling', () {
      expect(tobyBookCount({'e1g1': 40}, 'e1h1'), 40);
      expect(tobyBookCount({'e1h1': 40}, 'e1g1'), 40);
      expect(tobyBookCount({'e2e4': 40}, 'e1g1'), isNull);
      expect(tobyBookCount(null, 'e2e4'), isNull);
    });

    test('a strong move past the 24 kept still sets the best line', () {
      final payload = {
        'stage': 'final',
        'sideToMove': 'white',
        'moves': [
          for (var i = 0; i < 25; i++)
            {
              'uci': i == 24 ? 'c1g5' : 'h2h3',
              'san': i == 24 ? 'Bg5' : 'h3',
              'probability': i == 24 ? 0.001 : 0.039,
              'wdl':
                  i == 24
                      ? {'white': 0.40, 'draw': 0.30, 'black': 0.30}
                      : {'white': 0.23, 'draw': 0.30, 'black': 0.47},
            },
        ],
        'positionWdl': {'white': 0.35, 'draw': 0.30, 'black': 0.35},
        'otherProbability': 0,
        'otherMoveCount': 0,
      };
      final reading = TobyReading.fromJson(payload)!;
      expect(reading.candidates, hasLength(24));
      expect(reading.candidates.any((c) => c.uci == 'c1g5'), isFalse);
      expect(reading.outcomes, hasLength(25));
      // h3 (38%) is no longer the best line: Bg5 (55%) is. It hands over
      // 0.24 of the winning chances: a Mistake.
      expect(_classes(reading)['h2h3'], GameMoveClassification.mistake);
    });
  });

  group('lichess judgement on a winning-chance loss', () {
    test('the .3 / .2 / .1 table', () {
      expect(
        lichessJudgementForWinningChanceLoss(0.34),
        LichessJudgement.blunder,
      );
      expect(
        lichessJudgementForWinningChanceLoss(0.3),
        LichessJudgement.blunder,
      );
      expect(
        lichessJudgementForWinningChanceLoss(0.22),
        LichessJudgement.mistake,
      );
      expect(
        lichessJudgementForWinningChanceLoss(0.1),
        LichessJudgement.inaccuracy,
      );
      expect(lichessJudgementForWinningChanceLoss(0.09), isNull);
      expect(lichessJudgementForWinningChanceLoss(-0.5), isNull);
      expect(lichessJudgementForWinningChanceLoss(double.nan), isNull);
    });

    test('matches the centipawn advice it was lifted from', () {
      for (final (before, after) in [
        (0, -300),
        (50, -120),
        (0, -90),
        (20, 0),
      ]) {
        final viaAdvice = lichessAdvice(
          previous: CpScore(before),
          current: CpScore(after),
          moverIsWhite: true,
          engineBestUci: 'e2e4',
          playedUci: 'd2d4',
        );
        final loss =
            lichessWinningChances(before) - lichessWinningChances(after);
        expect(lichessJudgementForWinningChanceLoss(loss), viaAdvice);
      }
    });
  });

  group('colours', () {
    test('arrows take the class colour, or Toby\'s teal', () {
      for (final classification in GameMoveClassification.values) {
        expect(
          tobyArrowHue(classification),
          classificationColor(classification),
        );
      }
      expect(tobyArrowHue(null), kTobyArrowNeutral);
    });

    double luminance(Color c) => c.computeLuminance();
    double contrast(Color a, Color b) {
      final x = luminance(a), y = luminance(b);
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    test('every row tone clears 4.5:1 on a hovered row under its fill', () {
      for (final classification in GameMoveClassification.values) {
        final tone = kTobyClassRowTones[classification]!;
        final fill = classificationColor(
          classification,
        ).withValues(alpha: 0.13);
        for (final surface in [kBlack2Color, kBlack3Color]) {
          final under = Color.alphaBlend(fill, surface);
          expect(
            contrast(tone, under),
            greaterThanOrEqualTo(4.5),
            reason: '$classification on $surface',
          );
        }
      }
    });
  });

  group('board arrows and marks', () {
    test('the top three carry their class colour only', () {
      final reading = _reading({'c1g5': 55, 'a2a3': 49, 'h2h3': 33});
      final classes = _classes(reading);
      final arrows = tobyTopArrows(reading, classes: classes);
      expect(arrows.map((a) => a.color.withValues(alpha: 1)), [
        classificationColor(GameMoveClassification.blunder),
        kTobyArrowNeutral,
        classificationColor(GameMoveClassification.goodMove),
      ]);
    });

    test(
      'a hovered or pinned move adds its class mark on its square',
      () async {
        final controller = TobyPanelController(session: 'classes-test-0001');
        addTearDown(controller.dispose);
        final reading = _reading({'c1g5': 55, 'a2a3': 49, 'h2h3': 33});
        final classes = _classes(reading);
        controller.showReadingSoon(_white, reading, classes);
        await Future<void>.delayed(Duration.zero);
        expect(controller.boardArrows.value!.mark, isNull);

        controller.hover(_white, 'h2h3');
        final hovered = controller.boardArrows.value!;
        expect(hovered.exclusive, isTrue);
        expect(hovered.mark, (
          square: Square.h3,
          classification: GameMoveClassification.blunder,
        ));
        expect(
          hovered.arrows.single.color,
          classificationColor(
            GameMoveClassification.blunder,
          ).withValues(alpha: kTobyArrowAlpha),
        );

        controller.hover(_white, 'a2a3');
        expect(controller.boardArrows.value!.mark, isNull);

        controller
          ..clearHover()
          ..togglePin(_white, 'c1g5');
        final pinned = controller.boardArrows.value!;
        expect(pinned.exclusive, isFalse);
        expect(pinned.mark, (
          square: Square.g5,
          classification: GameMoveClassification.goodMove,
        ));
      },
    );
  });
}
