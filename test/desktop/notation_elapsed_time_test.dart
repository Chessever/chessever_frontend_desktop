import 'dart:convert';

import 'package:chessever/desktop/utils/notation_move_timing.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_pointer.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

ChessGame _import(String moves, {String? tc = '60+2', String? fen}) {
  return ChessGame.fromPgn('elapsed-regression', '''
[Event "Notation timing regression"]
[Result "*"]
${tc == null ? '' : '[TimeControl "$tc"]'}
${fen == null ? '' : '[SetUp "1"]\n[FEN "$fen"]'}

$moves *
''');
}

NotationMoveTiming _entry(NotationMoveTimingIndex index, List<int> pointer) {
  final entry = index.at(pointer);
  expect(
    entry,
    isNotNull,
    reason: 'Rendered move ${NotationPointer.encode(pointer)}',
  );
  return entry!;
}

void _elapsed(
  NotationMoveTimingIndex index,
  List<int> pointer,
  int? millis, {
  bool recorded = false,
}) {
  final entry = _entry(index, pointer);
  expect(
    entry.elapsed,
    millis == null ? isNull : Duration(milliseconds: millis),
    reason: 'Elapsed at ${NotationPointer.encode(pointer)}',
  );
  expect(
    entry.isRecorded,
    recorded,
    reason: 'Recorded provenance at ${NotationPointer.encode(pointer)}',
  );
}

Iterable<List<int>> _pointers(
  ChessLine line, [
  List<int> prefix = const [],
]) sync* {
  for (var i = 0; i < line.length; i++) {
    final pointer = [...prefix, i];
    yield pointer;
    final variations = line[i].variations ?? const <ChessLine>[];
    for (var v = 0; v < variations.length; v++) {
      yield* _pointers(variations[v], [...pointer, v]);
    }
  }
}

const _mainline = '''
1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]}
2. Nf3 {[%clk 0:00:55]} Nc6 {[%clk 0:00:53]}
''';

const _nested = '''
1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]}
(1... c5 {[%clk 0:00:56]} 2. Nf3 {[%clk 0:00:54]}
 d6 {[%clk 0:00:53]}
 (2... Nc6 {[%clk 0:00:51]} 3. Bb5 {[%clk 0:00:50]})
 3. d4 {[%clk 0:00:49]})
2. Nf3 {[%clk 0:00:55]} Nc6 {[%clk 0:00:53]}
''';

const _periodMoves = '''
1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]}
2. Nf3 {[%clk 0:00:55]} Nc6 {[%clk 0:00:53]}
3. Bb5 {[%clk 0:01:30]} a6 {[%clk 0:01:28]}
4. Ba4 {[%clk 0:01:25]} Nf6 {[%clk 0:01:23]}
5. O-O {[%clk 0:01:21]} Be7 {[%clk 0:01:18]}
''';

void main() {
  group('formatNotationElapsed', () {
    const cases = <int, String>{
      0: '0s',
      250000: '0.25s',
      28000000: '28s',
      72000000: '1m12s',
      3723000000: '1h2m3s',
      60000000: '1m',
      3600000000: '1h',
      3603000000: '1h3s',
      3720000000: '1h2m',
      72250000: '1m12.25s',
      1: '0.000001s',
    };
    for (final entry in cases.entries) {
      test('formats ${entry.key} microseconds as ${entry.value}', () {
        expect(
          formatNotationElapsed(Duration(microseconds: entry.key)),
          entry.value,
        );
      });
    }
    test('rejects negative elapsed rather than showing a fake zero', () {
      expect(
        () => formatNotationElapsed(const Duration(microseconds: -1)),
        throwsArgumentError,
      );
    });
  });

  group('recorded post-move EMT', () {
    test('needs neither a clock nor TimeControl', () {
      final game = _import('1. e4 {prose [%emt 0:00:28]} e5', tc: null);
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0], 28000, recorded: true);
      expect(_entry(index, [0]).remaining, isNull);
      _elapsed(index, [1], null);
    });

    test('takes precedence over an otherwise valid inferred elapsed', () {
      final game = _import('1. e4 {[%emt 0:01:12] [%clk 0:00:59]}');
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0], 72000, recorded: true);
      expect(_entry(index, [0]).remaining, const Duration(seconds: 59));
    });

    test('retains fractional EMT precision', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import('1. e4 {[%emt 0:00:00.250001]}', tc: '?'),
      );
      expect(_entry(index, [0]).elapsed, const Duration(microseconds: 250001));
      expect(_entry(index, [0]).isRecorded, isTrue);
    });

    test('a recorded zero is known and remains recorded', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import('1. e4 {[%emt 0:00:00]}', tc: null),
      );
      _elapsed(index, [0], 0, recorded: true);
    });

    test('identical repeated EMT directives are not a conflict', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import('1. e4 {[%emt 0:00:03]} {[%emt 0:00:03.000]}'),
      );
      _elapsed(index, [0], 3000, recorded: true);
    });

    for (final directive in <String>[
      '[%emt nonsense]',
      '[%emt 0:03]',
      '[%emt 0:00:03', // Missing closing bracket.
      '[%emt -0:00:03]',
      '[%emt 0:60:00]',
      '[%emt 0:00:60]',
      '[%emt 0:00:03junk]',
      '[%emt 0:00:03] [%emt 0:00:04]',
      '[%emt 0:00:03] [%emt broken]',
    ]) {
      test('malformed/conflicting $directive suppresses clock inference', () {
        final index = NotationMoveTimingIndex.fromGame(
          _import('1. e4 {$directive [%clk 0:00:59]}'),
        );
        _elapsed(index, [0], null);
      });
    }

    test('root comments are not timing for the first move', () {
      final game = _import('{[%emt 0:00:28] [%clk 0:00:59]} 1. e4');
      expect(game.rootComments, isNotEmpty);
      _elapsed(NotationMoveTimingIndex.fromGame(game), [0], null);
    });

    test('imported RAV starting comments do not time the following move', () {
      final game = _import(
        '1. e4 e5 ({[%emt 0:00:28] [%clk 0:00:56]} 1... c5)',
      );
      final branch = game.mainline[0].variations!.single.single;
      expect(branch.startingComments, isNotEmpty);
      expect(branch.comments ?? const <String>[], isEmpty);
      expect(branch.clockTime, isNull);
      _elapsed(NotationMoveTimingIndex.fromGame(game), [0, 0, 0], null);
    });
  });

  group('remaining-clock inference', () {
    test('60+2 machine PGN means sixty seconds, not sixty minutes', () {
      final game = _import(_mainline);
      expect(game.startingFen, Chess.initial.fen);
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0], 3000);
      _elapsed(index, [1], 4000);
      _elapsed(index, [2], 6000);
      _elapsed(index, [3], 7000);
      expect(_entry(index, [2]).remaining, const Duration(seconds: 55));
    });

    test('plain numeric sudden-death control has zero increment', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import(_mainline, tc: '60'),
      );
      _elapsed(index, [0], 1000);
      _elapsed(index, [2], 4000);
    });

    for (final clocks in <String>[
      '[%clk broken]',
      '[%clk 0:00:60]',
      '[%clk 0:60:00]',
      '[%clk 0:00:59] [%clk 0:00:58]',
      '[%clk 0:00:59] [%clk broken]',
    ]) {
      test(
        'malformed/conflicting remaining directives $clocks do not infer',
        () {
          final index = NotationMoveTimingIndex.fromGame(
            _import('1. e4 {$clocks}'),
          );
          _elapsed(index, [0], null);
        },
      );
    }

    test('identical repeated remaining directives are usable', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import('1. e4 {[%clk 0:00:59]} {[%clk 0:00:59]}'),
      );
      _elapsed(index, [0], 3000);
    });

    test(
      'valid direct EMT does not depend on malformed remaining directives',
      () {
        final index = NotationMoveTimingIndex.fromGame(
          _import('1. e4 {[%emt 0:00:03] [%clk broken]}', tc: null),
        );
        _elapsed(index, [0], 3000, recorded: true);
      },
    );

    test('genuine zero spent is not unknown', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import('1. e4 {[%clk 0:01:02]} e5 {[%clk 0:01:02]}'),
      );
      _elapsed(index, [0], 0);
      _elapsed(index, [1], 0);
      expect(formatNotationElapsed(_entry(index, [0]).elapsed!), '0s');
    });

    test('negative inference remains unknown instead of being clamped', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import('1. e4 {[%clk 0:01:03]} e5 {[%clk 0:00:58]}'),
      );
      _elapsed(index, [0], null);
      expect(_entry(index, [0]).remaining, const Duration(seconds: 63));
    });

    test('fractional raw clocks refine the importer-truncated model', () {
      final game = _import('''
1. e4 {[%clk 0:00:59.75]} e5 {[%clk 0:00:58]}
2. Nf3 {[%clk 0:00:58.50]}
''');
      expect(game.mainline[0].clockTime, '0:00:59');
      expect(game.mainline[2].clockTime, '0:00:58');
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0], 2250);
      _elapsed(index, [2], 3250);
      expect(_entry(index, [0]).remaining, const Duration(milliseconds: 59750));
      expect(game.mainline[0].clockTime, '0:00:59');
    });

    test(
      'stale raw clock cannot replace a different authoritative model second',
      () {
        final original = _import('1. e4 {[%clk 0:00:59.75]}');
        final game = original.copyWith(
          mainline: [original.mainline.single.copyWith(clockTime: '0:00:58')],
        );
        final entry = _entry(NotationMoveTimingIndex.fromGame(game), [0]);
        expect(entry.remaining, const Duration(seconds: 58));
        expect(entry.elapsed, const Duration(seconds: 4));
      },
    );

    test(
      'missing own clock breaks only that sides chain and then recovers',
      () {
        final game = _import('''
1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]}
2. Nf3 Nc6 {[%clk 0:00:53]}
3. Bb5 {[%clk 0:00:50]} a6 {[%clk 0:00:49]}
4. Ba4 {[%clk 0:00:47]}
''');
        final index = NotationMoveTimingIndex.fromGame(game);
        _elapsed(index, [2], null);
        _elapsed(index, [3], 7000);
        _elapsed(index, [4], null);
        _elapsed(index, [6], 5000);
      },
    );

    test(
      'late first reading cannot borrow base after an unclocked first move',
      () {
        final index = NotationMoveTimingIndex.fromGame(
          _import('1. e4 e5 {[%clk 0:00:58]} 2. Nf3 {[%clk 0:00:55]}'),
        );
        _elapsed(index, [0], null);
        _elapsed(index, [1], 4000);
        _elapsed(index, [2], null);
      },
    );

    for (final tc in <String?>[
      null,
      '?',
      '-',
      '',
      'standard',
      '*60',
      '60d2',
      '60+2d3',
      '1:00+2',
      '60 seconds',
      '-60+2',
      '60+-2',
      '0/60',
      '3/60:0/30',
      '60:30',
      '3/60::30',
      '3/60:30:20',
    ]) {
      test(
        'does not infer unsupported/invalid control ${tc ?? "<absent>"}',
        () {
          final index = NotationMoveTimingIndex.fromGame(
            _import(_mainline, tc: tc),
          );
          for (var i = 0; i < 4; i++) {
            _elapsed(index, [i], null);
          }
          expect(_entry(index, [2]).remaining, const Duration(seconds: 55));
        },
      );
    }

    test('direct EMT still works with unsupported sandclock control', () {
      final index = NotationMoveTimingIndex.fromGame(
        _import('1. e4 {[%emt 0:00:03] [%clk 0:00:59]}', tc: '*60'),
      );
      _elapsed(index, [0], 3000, recorded: true);
    });

    test(
      'middle-FEN starts have no invented base but own adjacent pairs work',
      () {
        final game = _import('''
12. e4 {[%clk 0:00:40]} e5 {[%clk 0:00:38]}
13. Nf3 {[%clk 0:00:37]} Nc6 {[%clk 0:00:34]}
''', fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 12');
        expect(game.mainline[0].num, 12);
        final index = NotationMoveTimingIndex.fromGame(game);
        _elapsed(index, [0], null);
        _elapsed(index, [1], null);
        _elapsed(index, [2], 5000);
        _elapsed(index, [3], 6000);
      },
    );

    test('black-to-move FEN does not seed either players first reading', () {
      final game = _import('''
12... e5 {[%clk 0:00:38]} 13. e4 {[%clk 0:00:40]}
Nc6 {[%clk 0:00:34]} 14. Nf3 {[%clk 0:00:37]}
''', fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 12');
      expect(game.mainline.first.turn, ChessColor.black);
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0], null);
      _elapsed(index, [1], null);
      _elapsed(index, [2], 6000);
      _elapsed(index, [3], 5000);
    });

    test(
      'nonstandard fullmove-one FEN is not mistaken for initial position',
      () {
        final game = _import(
          '1. e4 {[%clk 0:00:59]}',
          fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1',
        );
        _elapsed(NotationMoveTimingIndex.fromGame(game), [0], null);
      },
    );

    test('null moves do not get inferred spent time', () {
      final game = _import('1. -- {[%clk 0:00:59]} e5 {[%clk 0:00:58]}');
      expect(game.mainline.first.uci, '0000');
      _elapsed(NotationMoveTimingIndex.fromGame(game), [0], null);
    });
  });

  group('multi-period controls', () {
    test(
      'suppresses each bonus boundary and the following same-player move',
      () {
        final index = NotationMoveTimingIndex.fromGame(
          _import(_periodMoves, tc: '3/60+2:30+5'),
        );
        _elapsed(index, [0], 3000);
        _elapsed(index, [2], 6000);
        for (final i in [4, 5, 6, 7]) {
          _elapsed(index, [i], null);
        }
        _elapsed(index, [8], 9000);
        _elapsed(index, [9], 10000);
      },
    );

    test('recorded EMT survives the conservative period-boundary guard', () {
      final moves = _periodMoves
          .replaceFirst('0:01:30]}', '0:01:30] [%emt 0:00:07]}')
          .replaceFirst('0:01:25]}', '0:01:25] [%emt 0:00:08]}');
      final index = NotationMoveTimingIndex.fromGame(
        _import(moves, tc: '3/60+2:30+5'),
      );
      _elapsed(index, [4], 7000, recorded: true);
      _elapsed(index, [6], 8000, recorded: true);
    });

    test(
      'terminal bounded period repeats instead of becoming sudden death',
      () {
        final game = _import('''
1. Nf3 {[%clk 0:00:59]} Nf6 2. Ng1 {[%clk 0:00:55]} Ng8
3. Nf3 {[%clk 0:01:40]} Nf6 4. Ng1 {[%clk 0:01:38]} Ng8
5. Nf3 {[%clk 0:01:34]} Nf6 6. Ng1 {[%clk 0:02:20]} Ng8
7. Nf3 {[%clk 0:02:18]} Nf6 8. Ng1 {[%clk 0:02:14]} Ng8
''', tc: '3/60+2');
        final index = NotationMoveTimingIndex.fromGame(game);
        for (final i in [4, 6, 10, 12]) {
          _elapsed(index, [i], null);
        }
        _elapsed(index, [8], 6000);
        _elapsed(index, [14], 6000);
      },
    );
  });

  group('complete tree pointers and branch-local clock history', () {
    test('importer next-ply alternatives inherit after-parent clock state', () {
      final game = _import(_nested);
      final anchor = game.mainline.first;
      final branch = anchor.variations!.single;
      expect(anchor.turn, ChessColor.white);
      expect(branch.first.turn, ChessColor.black);
      expect(branch.first.num, anchor.num);
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0, 0, 0], 6000);
      _elapsed(index, [0, 0, 1], 7000);
      _elapsed(index, [0, 0, 2], 5000);
      _elapsed(index, [0, 0, 3], 7000);
      _elapsed(index, [2], 6000);
      _elapsed(index, [3], 7000);
    });

    test(
      'nested alternatives never borrow mainline or sibling later readings',
      () {
        final game = _import(_nested);
        final nested =
            game.mainline.first.variations!.single[1].variations!.single;
        expect(nested.map((move) => move.san), ['Nc6', 'Bb5']);
        final index = NotationMoveTimingIndex.fromGame(game);
        _elapsed(index, [0, 0, 1, 0, 0], 7000);
        _elapsed(index, [0, 0, 1, 0, 1], 6000);
        expect(NotationPointer.encode([0, 0, 1, 0, 1]), '0-0-1-0-1');
      },
    );

    test('root same-ply alternatives inherit before-parent state', () {
      final game = _import('''
1. e4 {[%clk 0:00:59]}
(1. d4 {[%clk 0:00:57]} d5 {[%clk 0:00:55]} 2. c4 {[%clk 0:00:52]})
e5 {[%clk 0:00:58]}
''');
      final branch = game.mainline.first.variations!.single;
      expect(branch.first.num, game.mainline.first.num);
      expect(branch.first.turn, game.mainline.first.turn);
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0, 0, 0], 5000);
      _elapsed(index, [0, 0, 1], 7000);
      _elapsed(index, [0, 0, 2], 7000);
      _elapsed(index, [0], 3000);
    });

    test('legacy same-ply nonroot anchoring also uses before-parent state', () {
      final imported = _import('''
1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]}
(1... c5 {[%clk 0:00:56]} 2. Nf3 {[%clk 0:00:54]})
2. Nf3 {[%clk 0:00:55]}
''');
      // Re-anchor real imported moves as the legacy same-ply tree layout.
      final branch = imported.mainline[0].variations!.single;
      final game = imported.copyWith(
        mainline: [
          imported.mainline[0].copyWith(overrideVariations: true),
          imported.mainline[1].copyWith(
            variations: [branch],
            overrideVariations: true,
          ),
          imported.mainline[2],
        ],
      );
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [1, 0, 0], 6000);
      _elapsed(index, [1, 0, 1], 7000);
    });

    test('multiple root siblings cannot leak readings into one another', () {
      final game = _import('''
1. e4 {[%clk 0:00:59]}
(1. d4 {[%clk 0:00:57]} d5 {[%clk 0:00:55]} 2. c4 {[%clk 0:00:52]})
(1. c4 {[%clk 0:00:54]} e5 {[%clk 0:00:53]} 2. Nc3 {[%clk 0:00:49]})
e5 {[%clk 0:00:58]}
''');
      expect(game.mainline.first.variations, hasLength(2));
      final index = NotationMoveTimingIndex.fromGame(game);
      _elapsed(index, [0, 0, 0], 5000);
      _elapsed(index, [0, 1, 0], 8000);
      _elapsed(index, [0, 1, 2], 7000);
    });

    test(
      'unclocked branch move breaks own history without mainline fallback',
      () {
        final game = _import('''
1. e4 {[%clk 0:00:59]} e5 {[%clk 0:00:58]}
(1... c5 2. Nf3 {[%clk 0:00:54]} d6 {[%clk 0:00:50]})
2. Nf3 {[%clk 0:00:55]} Nc6 {[%clk 0:00:53]}
''');
        final index = NotationMoveTimingIndex.fromGame(game);
        _elapsed(index, [0, 0, 0], null);
        _elapsed(index, [0, 0, 1], 7000);
        _elapsed(index, [0, 0, 2], null);
        _elapsed(index, [3], 7000);
      },
    );

    test(
      'every rendered move has an entry even when all timing is unknown',
      () {
        final game = _import(
          '1. e4 (1. d4 d5) e5 (1... c5 2. Nf3) 2. Nf3',
          tc: null,
        );
        final pointers = _pointers(game.mainline).toList();
        expect(pointers, hasLength(7));
        final index = NotationMoveTimingIndex.fromGame(game);
        for (final pointer in pointers) {
          _elapsed(index, pointer, null);
          expect(_entry(index, pointer).remaining, isNull);
        }
      },
    );

    test('unknown, incomplete, root and negative pointers return null', () {
      final index = NotationMoveTimingIndex.fromGame(_import(_nested));
      for (final pointer in <List<int>>[
        [],
        [-1],
        [99],
        [0, 0],
        [0, 99, 0],
        [0, 0, 99],
        [0, 0, 1, 0],
      ]) {
        expect(index.at(pointer), isNull, reason: '$pointer is not a move');
      }
    });

    test(
      'caller mutation of a lookup pointer cannot corrupt index identity',
      () {
        final index = NotationMoveTimingIndex.fromGame(_import(_nested));
        final pointer = [0, 0, 1];
        final entry = index.at(pointer);
        pointer[2] = 2;
        expect(index.at([0, 0, 1])?.elapsed, entry?.elapsed);
        _elapsed(index, [0, 0, 1], 7000);
        _elapsed(index, pointer, 5000);
      },
    );
  });

  group('malformed model sequence (not legal PGN)', () {
    test('nonpositive move numbers cannot seed later clock history', () {
      final original = _import(_mainline);
      final game = original.copyWith(
        mainline: [
          original.mainline[0].copyWith(num: 0),
          original.mainline[1].copyWith(num: 0),
          ...original.mainline,
        ],
      );
      _elapsed(NotationMoveTimingIndex.fromGame(game), [2], null);
    });
    test(
      'null moves ignore EMT and clear invented clock history for both sides',
      () {
        final game = _import(
          '1. -- {[%emt 0:00:08] [%clk 0:00:59]} e5 {[%clk 0:00:58]}',
        );
        final index = NotationMoveTimingIndex.fromGame(game);
        _elapsed(index, [0], null);
        _elapsed(index, [1], null);
      },
    );
    for (final mutation
        in <String, ChessMove Function(ChessMove)>{
          'wrong move number': (move) => move.copyWith(num: 9),
          'wrong player': (move) => move.copyWith(turn: ChessColor.black),
        }.entries) {
      test('${mutation.key} cannot infer a mainline move', () {
        final original = _import(_mainline);
        final game = original.copyWith(
          mainline: [
            ...original.mainline.take(2),
            mutation.value(original.mainline[2]),
            original.mainline[3],
          ],
        );
        _elapsed(NotationMoveTimingIndex.fromGame(game), [2], null);
      });
    }

    test('missing intervening ply cannot bridge clock history', () {
      final original = _import(_mainline);
      final game = original.copyWith(
        mainline: [
          original.mainline[0],
          original.mainline[2],
          original.mainline[3],
        ],
      );
      _elapsed(NotationMoveTimingIndex.fromGame(game), [1], null);
    });

    test('inconsistent branch head cannot inherit either anchor state', () {
      final original = _import(_nested);
      final branch = original.mainline.first.variations!.single;
      final game = original.copyWith(
        mainline: [
          original.mainline.first.copyWith(
            variations: [
              [branch.first.copyWith(num: 9), ...branch.skip(1)],
            ],
            overrideVariations: true,
          ),
          ...original.mainline.skip(1),
        ],
      );
      _elapsed(NotationMoveTimingIndex.fromGame(game), [0, 0, 0], null);
    });

    test(
      'malformed model clock does not become zero or leak previous history',
      () {
        final original = _import(_mainline);
        final game = original.copyWith(
          mainline: [
            original.mainline[0].copyWith(clockTime: '--:--', comments: []),
            ...original.mainline.skip(1),
          ],
        );
        final index = NotationMoveTimingIndex.fromGame(game);
        _elapsed(index, [0], null);
        expect(_entry(index, [0]).remaining, isNull);
        _elapsed(index, [2], null);
      },
    );
  });

  group('display-only immutability and fresh metadata', () {
    test(
      'native PGN save and reopen retain explicit EMT and inferred clocks',
      () {
        final game = _import(
          _nested.replaceFirst(
            '[%clk 0:00:59]',
            '[%clk 0:00:59] [%emt 0:00:03.25]',
          ),
        );
        final original = NotationMoveTimingIndex.fromGame(game);
        final saved = exportGameToPgn(game);
        final reopened = ChessGame.fromPgn('reopened', saved);
        final after = NotationMoveTimingIndex.fromGame(reopened);
        for (final pointer in _pointers(game.mainline)) {
          expect(
            _entry(after, pointer).elapsed,
            _entry(original, pointer).elapsed,
            reason: '$pointer',
          );
          expect(
            _entry(after, pointer).isRecorded,
            _entry(original, pointer).isRecorded,
          );
        }
        expect(
          reopened.mainline.first.clockTime,
          game.mainline.first.clockTime,
        );
        expect(saved, contains('[%emt 0:00:03.25]'));
      },
    );
    test(
      'resolver and formatter leave JSON, exported PGN and clocks unchanged',
      () {
        final game = _import(
          _nested.replaceFirst(
            '[%clk 0:00:59]',
            'human prose [%clk 0:00:59.75] [%emt 0:00:03]',
          ),
        );
        final beforeJson = jsonEncode(game.toJson());
        final beforePgn = exportGameToPgn(game);
        final index = NotationMoveTimingIndex.fromGame(game);
        for (final pointer in _pointers(game.mainline)) {
          final elapsed = _entry(index, pointer).elapsed;
          if (elapsed != null) formatNotationElapsed(elapsed);
        }
        expect(jsonEncode(game.toJson()), beforeJson);
        expect(exportGameToPgn(game), beforePgn);
        expect(game.mainline.first.clockTime, '0:00:59');
        expect(
          game.mainline.first.comments!.join(' '),
          contains('[%clk 0:00:59.75]'),
        );
      },
    );

    test(
      'copied game rebuild uses changed TimeControl without stale results',
      () {
        final game = _import(_mainline);
        final originalIndex = NotationMoveTimingIndex.fromGame(game);
        final changed = game.copyWith(
          metadata: {...game.metadata, 'TimeControl': '60+5'},
        );
        final changedIndex = NotationMoveTimingIndex.fromGame(changed);
        _elapsed(originalIndex, [0], 3000);
        _elapsed(changedIndex, [0], 6000);
        _elapsed(originalIndex, [2], 6000);
        _elapsed(changedIndex, [2], 9000);
        expect(game.timeControl, '60+2');
        expect(changed.mainline, same(game.mainline));
      },
    );

    test(
      'same model metadata refresh gets a fresh index without mutating old one',
      () {
        final game = _import(_mainline);
        final originalIndex = NotationMoveTimingIndex.fromGame(game);
        game.metadata['TimeControl'] = '60+5';
        final refreshedIndex = NotationMoveTimingIndex.fromGame(game);
        _elapsed(originalIndex, [0], 3000);
        _elapsed(refreshedIndex, [0], 6000);
      },
    );

    test('empty game has no synthetic root timing', () {
      final index = NotationMoveTimingIndex.fromGame(_import(''));
      expect(index.at([]), isNull);
      expect(index.at([0]), isNull);
    });
  });
}
