import 'dart:io';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final game = ChessGame.fromPgn(
    'manual-forward-boundary',
    '[Result "*"]\n\n1. e4 e5 (1... c5 2. Nf3 d6 (2... Nc6 3. Nc3)) 2. Nf3 Nc6 3. Bb5 a6 *',
  );

  test(
    'manual forward stays at a variation ending with a parent continuation',
    () {
      final p = _pointerTo(game, 'd6');
      expect(p.length, greaterThan(1));
      expect(traversalBoardForwardPointerForTesting(game, p), isNotNull);
      expect(manualBoardForwardPointerForTesting(game, p), isNull);
    },
  );

  test('manual forward stays at the end of a nested variation', () {
    final p = _pointerTo(game, 'Nc3');
    expect(p.length, greaterThan(3));
    expect(traversalBoardForwardPointerForTesting(game, p), isNotNull);
    expect(manualBoardForwardPointerForTesting(game, p), isNull);
  });

  test('repeated manual forward keeps selected pointer and FEN unchanged', () {
    var p = _pointerTo(game, 'Nc3');
    final original = List<int>.of(p);
    final fen = ChessGameNavigatorState(game: game, movePointer: p).currentFen;
    for (var i = 0; i < 4; i++) {
      final next = manualBoardForwardPointerForTesting(game, p);
      if (next != null) p = next;
      expect(p, original);
      expect(
        ChessGameNavigatorState(game: game, movePointer: p).currentFen,
        fen,
      );
    }
  });

  test('manual forward still advances within the selected variation', () {
    final p = _pointerTo(game, 'c5');
    final next = manualBoardForwardPointerForTesting(game, p)!;
    expect(next.sublist(0, next.length - 1), p.sublist(0, p.length - 1));
    expect(next.last, p.last + 1);
    expect(
      ChessGameNavigatorState(game: game, movePointer: next).currentMove?.san,
      'Nf3',
    );
  });

  test('manual forward retains root and mainline behavior', () {
    expect(manualBoardForwardPointerForTesting(game, const []), [0]);
    expect(manualBoardForwardPointerForTesting(game, const [0]), [1]);
    expect(
      manualBoardForwardPointerForTesting(game, [game.mainline.length - 1]),
      isNull,
    );
  });

  test(
    'shared traversal still leaves finished variations for other actions',
    () {
      final p = _pointerTo(game, 'Nc3');
      final next = traversalBoardForwardPointerForTesting(game, p)!;
      expect(
        ChessGameNavigatorState(game: game, movePointer: next).currentMove?.san,
        'd6',
      );
    },
  );

  test('interactive step and enabled state share the manual-forward resolver', () {
    final source = File('lib/desktop/panes/board_pane.dart').readAsStringSync();
    expect(
      RegExp(
        r'final\s+canStepForward\s*=\s*_nextManualPointer\(\s*chessGame\.value,\s*pointer\.value,?\s*\)\s*!=\s*null;',
      ).hasMatch(source),
      isTrue,
    );
    final interactive = source.substring(
      source.indexOf('Future<void> goNextInteractive()'),
      source.indexOf('bool stepNotationHorizontally'),
    );
    expect(
      RegExp(
        r'final\s+next\s*=\s*_nextManualPointer\(\s*chessGame\.value,\s*currentPointer,?\s*\);',
      ).hasMatch(interactive),
      isTrue,
    );
    expect(
      interactive.indexOf('if (next == null) return;'),
      lessThan(interactive.indexOf('resolveVariationForkOptions(')),
    );
  });

  final reported = Platform.environment['CHESSEVER_REPORTED_PGN'];
  test(
    'reported full PGN holds every terminal variation including 21.Nxb4',
    () {
      final full = ChessGame.fromPgn(
        'reported-private-repertoire',
        File(reported!).readAsStringSync(),
      );
      var ends = 0;
      var circled = 0;
      void visit(ChessLine line, List<int> prefix) {
        if (prefix.isNotEmpty && line.isNotEmpty) {
          final p = [...prefix, line.length - 1];
          expect(
            manualBoardForwardPointerForTesting(full, p),
            isNull,
            reason: 'variation endpoint $p',
          );
          ends++;
          if (line.last.num == 21 && line.last.san == 'Nxb4') circled++;
        }
        for (var i = 0; i < line.length; i++) {
          final variations = line[i].variations ?? const <ChessLine>[];
          for (var v = 0; v < variations.length; v++) {
            visit(variations[v], [...prefix, i, v]);
          }
        }
      }

      visit(full.mainline, const []);
      expect(ends, greaterThan(20));
      expect(circled, greaterThan(0));
    },
    skip:
        reported == null
            ? 'Set CHESSEVER_REPORTED_PGN for private reported-input coverage'
            : false,
  );
}

List<int> _pointerTo(ChessGame game, String san) {
  List<int>? found;
  void visit(ChessLine line, List<int> prefix) {
    for (var i = 0; i < line.length && found == null; i++) {
      final p = [...prefix, i];
      if (line[i].san == san) {
        found = p;
        return;
      }
      final variations = line[i].variations ?? const <ChessLine>[];
      for (var v = 0; v < variations.length && found == null; v++) {
        visit(variations[v], [...p, v]);
      }
    }
  }

  visit(game.mainline, const []);
  return found ?? (throw StateError('Fixture move missing: $san'));
}
