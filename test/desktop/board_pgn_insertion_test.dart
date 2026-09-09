import 'dart:io' as io;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/board_pgn_insertion.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';

ChessGame _game(String pgn) => ChessGame.fromPgn('original', pgn);

Map<String, Object> _tree(ChessGame game) {
  final result = <String, Object>{};
  void visit(ChessLine line, List<String> prefix) {
    var path = prefix;
    for (final move in line) {
      final before = path;
      path = [...path, move.uci];
      final key = path.join(' ');
      expect(
        result.containsKey(key),
        isFalse,
        reason: 'Duplicate UCI path $key',
      );
      result[key] = {
        'comments': [
          for (final comment in move.comments ?? const <String>[])
            if (!comment.startsWith('[%src ')) comment.trim(),
        ],
        'nags': move.nags ?? const <int>[],
      };
      for (final variation in move.variations ?? const <ChessLine>[]) {
        if (variation.isEmpty) continue;
        visit(variation, variation.first.turn == move.turn ? before : path);
      }
    }
  }

  visit(game.mainline, []);
  return result;
}

// Independent raw PGN traversal catches lossy model conversions, including
// root RAVs and startingComments, instead of comparing two flattened results.
Map<String, Object> _pgnTree(String pgn) {
  final parsed = PgnGame.parsePgn(pgn);
  final result = <String, Object>{};
  void visit(PgnNode<PgnNodeData> node, Position pos, List<String> path) {
    for (final child in node.children) {
      final move = pos.parseSan(child.data.san);
      expect(move, isNotNull, reason: child.data.san);
      final nextPath = [...path, move!.uci];
      result[nextPath.join(' ')] = {
        'comments':
            [
              ...?child.data.startingComments,
              ...?child.data.comments,
            ].map((c) => c.trim()).toList(),
        'nags': child.data.nags ?? const <int>[],
      };
      visit(child, pos.play(move), nextPath);
    }
  }

  visit(parsed.moves, PgnGame.startingPosition(parsed.headers), []);
  return result;
}

void main() {
  test(
    'full exact Navara-Stellwagen tree survives root fallback and reopen',
    () {
      final pgn =
          io.File(
            'test/fixtures/navara_stellwagen_corus_2006.pgn',
          ).readAsStringSync();
      final original = _game('[White "My analysis"]\n\n1. d4 {mine} *');
      final before = original.toJson();
      final insertion =
          insertBoardPgn(
            game: original,
            activePath: original.mainline,
            pgn: pgn,
            sourceLabel: 'Navara-Stellwagen',
          )!;
      expect(original.toJson(), before);
      expect(insertion.game.metadata, original.metadata);
      expect(insertion.game.gameId, original.gameId);
      expect(insertion.game.mainline.map((m) => m.uci), ['d2d4']);
      expect(insertion.game.mainline.first.comments, ['mine']);
      final expected = _pgnTree(pgn);
      expect(expected.length, greaterThan(117));
      final inserted = _tree(insertion.game)..remove('d2d4');
      expect(inserted, expected);
      expect(insertion.landingPath.first, 'e2e4');

      final reopened = _game(exportGameToPgn(insertion.game));
      expect(reopened.mainline.map((m) => m.uci), ['d2d4']);
      expect(_tree(reopened), _tree(insertion.game));
      final insertedLine = reopened.mainline.first.variations!.single;
      expect(insertedLine.last.comments, contains('[%src Navara-Stellwagen]'));
    },
  );

  test('full exact fixture also survives matching the current e4 position', () {
    final pgn =
        io.File(
          'test/fixtures/navara_stellwagen_corus_2006.pgn',
        ).readAsStringSync();
    final original = _game('1. e4 c5 *');
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline.take(1).toList(),
          pgn: pgn,
        )!;
    expect(result.game.mainline.map((m) => m.uci), ['e2e4', 'c7c5']);
    final actual = _tree(result.game)..remove('e2e4 c7c5');
    expect(actual, _pgnTree(pgn));
    expect(_tree(_game(exportGameToPgn(result.game))), _tree(result.game));
  });

  test('current-position match in incoming RAV wins over root fallback', () {
    final original = _game('1. d4 d5 2. c4 *');
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline.take(1).toList(),
          pgn: '1. e4 (1. d4 Nf6 {RAV} 2. c4) e5 (1... c5) *',
        )!;
    final tree = _tree(result.game);
    expect(tree.containsKey('e2e4'), isFalse);
    expect(tree.containsKey('d2d4 g8f6 c2c4'), isTrue);
    expect(result.game.mainline.map((m) => m.uci), ['d2d4', 'd7d5', 'c2c4']);
  });

  test('nearest ancestor on active variation, not unrelated mainline', () {
    final original = _game('1. e4 e5 (1... c5 2. Nf3 d6) *');
    final path =
        ChessGameNavigatorState(
          game: original,
          movePointer: [0, 0, 2],
        ).fullMovePath;
    final result =
        insertBoardPgn(
          game: original,
          activePath: path,
          pgn: '1. e4 c5 2. Nc3 {nearest} *',
        )!;
    expect(result.landingPath, ['e2e4', 'c7c5', 'b1c3']);
    expect(_tree(result.game).containsKey('e2e4 c7c5 g1f3 d7d6'), isTrue);
  });

  test('same-UCI merge preserves principal, prose, NAGs and is idempotent', () {
    final original = _game('1. e4 {old} e5 2. Nf3 *');
    const pgn = '1. e4 {new} \$1 e5 2. Bc4 {tail} (2. Nc3 \$5) *';
    final first =
        insertBoardPgn(
          game: original,
          activePath: [],
          pgn: pgn,
          sourceLabel: 'test',
        )!;
    final second =
        insertBoardPgn(
          game: first.game,
          activePath: [],
          pgn: pgn,
          sourceLabel: 'test',
        )!;
    expect(_tree(first.game), _tree(second.game));
    expect(first.game.mainline.first.comments, ['old', 'new']);
    expect(first.game.mainline.first.nags, [1]);
    expect(first.game.mainline.map((m) => m.uci), ['e2e4', 'e7e5', 'g1f3']);
    expect(_tree(first.game).containsKey('e2e4 e7e5 f1c4'), isTrue);
    expect(_tree(first.game).containsKey('e2e4 e7e5 b1c3'), isTrue);
    expect(_tree(_game(exportGameToPgn(first.game))), _tree(first.game));
  });

  test('FEN start is matched without requiring a standard-start prefix', () {
    final original = _game('1. e4 e5 2. Nf3 *');
    final fen = original.mainline.first.fen;
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline.take(1).toList(),
          pgn: '[SetUp "1"]\n[FEN "$fen"]\n\n1... c5 {Sicilian} 2. Nf3 *',
        )!;
    expect(result.game.startingFen, original.startingFen);
    expect(result.game.metadata, original.metadata);
    expect(_tree(result.game).containsKey('e2e4 c7c5 g1f3'), isTrue);
  });

  test(
    'matching local tail extends without replacing prior mainline moves',
    () {
      final original = _game('1. e4 *');
      final result =
          insertBoardPgn(
            game: original,
            activePath: original.mainline,
            pgn: '1. e4 e5 2. Nf3 *',
          )!;
      expect(result.game.mainline.map((m) => m.uci), ['e2e4', 'e7e5', 'g1f3']);
      expect(_tree(_game(exportGameToPgn(result.game))), _tree(result.game));
    },
  );

  test('extending a decided game retains its original result marker', () {
    final original = _game('1. e4 e5 1-0');
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline,
          pgn: '1. e4 e5 2. Nf3 Nc6 *',
        )!;
    expect(result.game.mainline.length, 4);
    expect(result.game.metadata['Result'], '1-0');
    expect(result.game.gameEndingPlyIndex, original.gameEndingPlyIndex);
    expect(
      original.metadata.containsKey(ChessGame.metadataGameEndingPlyIndexKey),
      isFalse,
    );
  });

  test('legal initial headers are not interpreted as moves', () {
    final original = _game('1. d4 *');
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline,
          pgn: '[Event "e5"]\n[Site "Nf3"]\n\n1. e4 e6 *',
        )!;
    expect(result.landingPath, ['e2e4', 'e7e6']);
    expect(result.game.mainline.single.uci, 'd2d4');
  });

  test('live terminal mainline retains the existing extension protection', () {
    final original = _game(
      '1. e4 *',
    ).copyWith(metadata: {ChessGame.metadataIsLiveKey: true});
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline,
          pgn: '1. e4 e5 *',
        )!;
    expect(result.game.mainline.map((m) => m.uci), ['e2e4']);
    expect(result.game.mainline.first.variations!.single.first.uci, 'e7e5');
  });

  test('FEN clocks and move numbers are rebased to the destination', () {
    final original = _game('1. e4 e5 *');
    final incomingFen = original.mainline.first.fen
        .split(' ')
        .take(4)
        .join(' ');
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline.take(1).toList(),
          pgn: '[FEN "$incomingFen 25 42"]\n\n42... c5 43. Nf3 *',
        )!;
    final variation = result.game.mainline.first.variations!.single;
    expect(variation.first.num, 1);
    expect(variation.last.num, 2);
    Position position = Chess.fromSetup(
      Setup.parseFen(original.mainline.first.fen),
    );
    for (final move in variation) {
      position = position.play(Move.parse(move.uci)!);
      expect(move.fen, position.fen);
    }
  });

  test('transposition does not copy unrelated predecessor annotations', () {
    final original = _game('1. Nf3 Nf6 2. g3 g6 {mine} 3. Bg2 *');
    final result =
        insertBoardPgn(
          game: original,
          activePath: original.mainline.take(4).toList(),
          pgn: '1. g3 g6 2. Nf3 Nf6 {unrelated} \$2 3. d4 *',
        )!;
    expect(result.game.mainline[3].comments, ['mine']);
    expect(result.game.mainline[3].nags, isNull);
    expect(result.landingPath, ['g1f3', 'g8f6', 'g2g3', 'g7g6', 'd2d4']);
  });

  test('export preserves prose and graphics sharing clock/eval comments', () {
    final original = _game(
      '{Introduction} 1. e4 '
      '{[%clk 0:01:02] prose [%cal Ge2e4]} '
      '{[%eval 0.25] more prose [%csl Re4]} *',
    );
    final reopened = _game(exportGameToPgn(original));
    final comments = reopened.mainline.first.comments!.join(' ');
    for (final text in [
      'Introduction',
      'prose',
      'more prose',
      '[%cal Ge2e4]',
      '[%csl Re4]',
    ]) {
      expect(comments, contains(text));
    }
    expect(
      reopened.mainline.first.clockTime,
      original.mainline.first.clockTime,
    );
    expect(reopened.mainline.first.eval, original.mainline.first.eval);
  });

  test('malformed or illegal PGN never partially changes the original', () {
    final original = _game('1. d4 d5 *');
    final before = original.toJson();
    for (final pgn in [
      'not PGN',
      '1. e4 e5 2. Bh6 *',
      '1. e4 e5 (1... Bh3) *',
      '1. e4 e5 (1... c5 *',
      '1. e4 {unclosed',
      '1. e4 garbage e5 *',
      '1. e4 * 1. d4 *',
      '1. e4 [Event "e5"] 2. Nf3 *',
      '1. e4\n\n[Event "e5"]\n2. Nf3 *',
      '1. e4 (1. [Event "d4"] d5) e5 *',
      '[SetUp "1"]\n[FEN "bad"]\n\n1. e4 *',
      '[SetUp "1"]\n[FEN "8/8/8/8/8/4k3/8/4K3 w - - 0 1"]\n\n1. Kd1 *',
    ]) {
      expect(
        insertBoardPgn(game: original, activePath: original.mainline, pgn: pgn),
        isNull,
        reason: pgn,
      );
      expect(original.toJson(), before);
    }
  });

  test('model/export retains root siblings and pre-variation prose', () {
    const pgn =
        '1. d4 ( {root intro} 1. e4 e5 '
        '( {nested intro} 1... c5 \$1)) d5 *';
    final original = _game(pgn);
    expect(_tree(original), _pgnTree(pgn));
    expect(_tree(_game(exportGameToPgn(original))), _pgnTree(pgn));
  });
}
