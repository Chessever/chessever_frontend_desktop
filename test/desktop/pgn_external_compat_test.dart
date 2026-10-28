import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/chessboard/utils/chessever_annotation.dart';
import 'package:chessever/screens/chessboard/utils/pgn_external_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// A game copied out of ChessEver and read by a stranger's importer.
///
/// The user's reports, in order:
///
/// 1. the same PGN imported in ChessBase, but chess.com "does not read it
///    properly" — the game was legal; what it carried was the private
///    `$240`–`$247` classification block (outside the standard NAG range), one
///    very long movetext line, and no trailing newline;
/// 2. ChessBase then *printed* the `[%ce 247]` marker our first fix put in the
///    move comment, because a comment is text a viewer shows.
///
/// So the private class now travels in a header tag
/// (`[ChessEverClassification "ply=code …"]`), which every consumer stores as
/// metadata and none renders in the notation, and the movetext carries nothing
/// bracketed at all. These regressions pin both halves: the external form is
/// standard-PGN only with no marker text anywhere in the movetext, and
/// ChessEver's exact classes survive the trip — including inside variations,
/// from a black-to-move start, and when book is the only class.
void main() {
  group('external NAG mapping', () {
    const expectations = <GameMoveClassification, int?>{
      GameMoveClassification.brilliant: 3,
      GameMoveClassification.goodMove: 1,
      GameMoveClassification.bestMove: 1,
      GameMoveClassification.missedWin: 6,
      GameMoveClassification.inaccuracy: 6,
      GameMoveClassification.mistake: 2,
      GameMoveClassification.blunder: 4,
      GameMoveClassification.bookMove: null,
    };

    test('the table covers every classification exactly once', () {
      expect(
        kExternalNagForClassification.keys.toSet(),
        GameMoveClassification.values.toSet(),
      );
      for (final entry in expectations.entries) {
        expect(
          kExternalNagForClassification[entry.key],
          entry.value,
          reason: '${entry.key.name} must map to ${entry.value}',
        );
      }
      // $5 (`!?`, speculative) belongs to no ChessEver class.
      expect(kExternalNagForClassification.values, isNot(contains(5)));
    });

    test('the code-addressed table and the enum table cannot drift', () {
      expect(
        kChesseverClassificationCodes.toSet(),
        kChesseverClassificationNags.values.toSet(),
      );
      for (final entry in kChesseverClassificationNags.entries) {
        expect(
          kExternalNagForChesseverCode[entry.value],
          kExternalNagForClassification[entry.key],
          reason: 'code ${entry.value} disagrees for ${entry.key.name}',
        );
      }
    });

    for (final entry in expectations.entries) {
      test('${entry.key.name} copies as a standard NAG plus the header tag', () {
        final native = exportGameToPgn(_gameWithClassification(entry.key));
        final external = toExternalCompatiblePgn(native);
        final code = kChesseverClassificationNags[entry.key]!;

        // The native code is what our own files keep; see the file-save group.
        expect(native, contains('\$$code'));
        expect(_hasOutOfRangeNag(external), isFalse);
        // No marker text of any kind, in the movetext or anywhere else.
        expect(external, isNot(contains('[%ce')));
        expect(_movetextOf(external), isNot(contains('[')));
        expect(
          _classificationHeaderOf(external),
          '[ChessEverClassification "1=$code"]',
        );

        final move = _movetextOf(external);
        if (entry.value == null) {
          expect(
            RegExp(r'\$[1-6]\b').hasMatch(move),
            isFalse,
            reason: 'book has no standard verdict to carry',
          );
        } else {
          expect(move, contains('\$${entry.value} '));
        }

        // And it comes back with the exact class it left with.
        final returned = ChessGame.fromPgn('returned', external);
        expect(returned.mainline.first.nags, contains(code));
        expect(
          classificationFromNags(returned.mainline.first.nags),
          entry.key,
        );
      });
    }

    test('a move without a comment still gets its class in the tag', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(ChessGame.fromPgn('no-comment', r'1. e4 $1 $241 e5 *')),
      );

      expect(_movetextOf(external), contains(r'1. e4 $1'));
      expect(external, isNot(contains(r'$241')));
      expect(
        _classificationHeaderOf(external),
        '[ChessEverClassification "1=241"]',
      );
      final returned = ChessGame.fromPgn('no-comment-back', external);
      expect(returned.mainline.first.nags, containsAll(<int>[1, 241]));
    });

    test('the portable verdict already on the move is not written twice', () {
      // A native export writes the class *beside* its portable verdict
      // (`$6 $244`), so the mapping must fill a gap, never stack a duplicate.
      final external = toExternalCompatiblePgn(
        exportGameToPgn(ChessGame.fromPgn('pair', r'1. e4 $6 $244 e5 *')),
      );

      expect(_movetextOf(external), contains(r'1. e4 $6'));
      expect(_movetextOf(external), isNot(contains(r'$244')));
      expect(external, isNot(contains(r'$6 $6')));
      expect(external, contains('"1=244"'));
    });

    test('a class never doubles a verdict the move already carries', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );

      for (final move in _nagGroupsOf(_movetextOf(external)).values) {
        expect(
          move.length,
          move.toSet().length,
          reason: 'no NAG repeated on one move: $move',
        );
      }
      // The one class whose classic glyph disagrees with the mapped mark keeps
      // the move's existing verdict and adds the mapped one.
      expect(_movetextOf(external), contains(r'3. f4 $4 $6'));
    });

    test('book carries no standard verdict, only the header code', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );
      final lines = _movetextLinesOf(external).join(' ');

      expect(lines, contains(r'1... e5 { [%eval 0.16] [%clk 1:29:21] }'));
      expect(
        RegExp(r'1\.\.\. e5 \$[1-6]').hasMatch(lines),
        isFalse,
        reason: 'book has no standard equivalent',
      );
      expect(_classificationHeaderOf(external), contains('2=247'));
    });
  });

  group('the private carrier is a header tag, never movetext text', () {
    test('the copied movetext contains no bracketed marker text', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );

      for (final line in _movetextLinesOf(external)) {
        // Only the public `[%eval …]` / `[%clk …]` payloads may survive as
        // bracketed text; nothing private is left for a viewer to print.
        final withoutPublicPayloads = line
            .replaceAll(RegExp(r'\[%eval [^\]]*\]'), '')
            .replaceAll(RegExp(r'\[%clk [^\]]*\]'), '');
        expect(withoutPublicPayloads, isNot(contains('[')), reason: line);
        expect(line, isNot(contains('[%ce')), reason: line);
        expect(line, isNot(contains('ChessEver')), reason: line);
      }
      expect(external, isNot(contains('[%ce')));
      // A fresh copy never carries the legacy marker the previous build wrote.
      expect(external, isNot(contains('[%ce 244]')));
      expect(external, isNot(contains('[%ce 247]')));
    });

    test('the tag sits inside the header block, ahead of the movetext', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );
      final tagIndex = external.indexOf('[ChessEverClassification');
      final firstMovetextIndex = external.indexOf('1. b3');

      expect(tagIndex, greaterThan(0));
      expect(tagIndex, lessThan(firstMovetextIndex));
      // Header block, then one blank line, then movetext.
      expect(external.substring(tagIndex), startsWith(
        '[ChessEverClassification "1=244 2=247 3=242 4=240 5=243 6=245 7=246 8=241"]\n\n',
      ));
      expect(
        _headerLinesOf(external).last,
        startsWith('[ChessEverClassification'),
      );
    });

    test('no tag is written when the game has no classification', () {
      expect(
        toExternalCompatiblePgn(
          exportGameToPgn(ChessGame.fromPgn('plain', '1. e4 e5 2. Nf3 *')),
        ),
        isNot(contains('ChessEverClassification')),
      );
      expect(
        toExternalCompatiblePgn('[Event "x"]\n[Result "*"]\n\n1. e4 e5 *'),
        isNot(contains('ChessEverClassification')),
      );
    });

    test('prose, eval and clock payloads travel verbatim', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );

      expect(external, contains('{ [%eval -0.32] [%clk 1:30:53] }'));
      expect(external, contains('{ [%eval 0.25] [%clk 1:29:34] }'));
      expect(external, contains('A real comment.'));
      // An unclassified move keeps its comment block byte-identical.
      expect(external, contains('{ [%eval 0.02] [%clk 1:26:00] }'));
      expect(external, isNot(contains('[%eval 0.02] [%clk 1:26:00] [%ce')));
    });

    test('the tag is dropped when the PGN becomes a game', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );
      final game = ChessGame.fromPgn('tagged', external);

      expect(chesseverClassificationHeaderOf(game.metadata), isNull);
      expect(game.metadata.keys, isNot(contains(kChesseverClassificationHeaderTag)));
      // …so it cannot ride back into the user's file on the next save.
      expect(exportGameToPgn(game), isNot(contains('ChessEverClassification')));
      expect(_tagOnlyInHeaderBlock(external), isTrue);
    });

    test('a legacy [%ce] marker is still readable and still never rendered', () {
      expect(chesseverCodesFromMarker(const ['[%ce 247]']), const [247]);
      expect(cleanPgnCommentText('[%eval 0.1] [%ce 247]'), '');
      expect(cleanPgnCommentText('Real prose [%ce 247]'), 'Real prose');

      final game = ChessGame.fromPgn(
        'legacy',
        r'1. e4 $6 { [%eval 0.1] [%ce 244] } e5 { [%ce 247] } *',
      );
      expect(classificationFromNags(game.mainline[0].nags),
          GameMoveClassification.inaccuracy);
      expect(classificationFromNags(game.mainline[1].nags),
          GameMoveClassification.bookMove);
      expect(
        (game.mainline[0].comments ?? const <String>[]).join(' '),
        isNot(contains('[%ce')),
      );
      expect(exportGameToPgn(game), isNot(contains('[%ce')));
    });
  });

  group('import restores the exact class from the header', () {
    test('the tag becomes the native block, per ply', () {
      const external = '''
[Event "?"]
[Result "1-0"]
[ChessEverClassification "1=240 2=245"]

1. e4 \$3 { [%eval 0.1] } 1... e5 \$2 1-0
''';
      final game = ChessGame.fromPgn('restored', external);

      expect(game.mainline[0].nags, containsAll(<int>[3, 240]));
      expect(game.mainline[1].nags, containsAll(<int>[2, 245]));
      expect(
        classificationFromNags(game.mainline[0].nags),
        GameMoveClassification.brilliant,
      );
      expect(
        classificationFromNags(game.mainline[1].nags),
        GameMoveClassification.mistake,
      );
      expect(chesseverClassificationHeaderOf(game.metadata), isNull);
    });

    test('a black-to-move start keeps the ply sequence', () {
      const native = '''
[Event "?"]
[Result "*"]
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]

1... e5 \$247 2. Nf3 \$6 \$244 *
''';
      final external = toExternalCompatiblePgn(
        exportGameToPgn(ChessGame.fromPgn('black', native)),
      );

      expect(_classificationHeaderOf(external), '"1=247 2=244"');
      final returned = ChessGame.fromPgn('black-back', external);
      // The first move of the game is the first ply, whatever colour plays it.
      expect(classificationFromNags(returned.mainline[0].nags),
          GameMoveClassification.bookMove);
      expect(classificationFromNags(returned.mainline[1].nags),
          GameMoveClassification.inaccuracy);
      expect(returned.mainline.map((m) => m.san).toList(), ['e5', 'Nf3']);
    });

    test('a game where book is the only class round trips', () {
      const native = '[Event "?"]\n[Result "*"]\n\n1. e4 \$247 e5 \$247 *';
      final external = toExternalCompatiblePgn(
        exportGameToPgn(ChessGame.fromPgn('book', native)),
      );

      expect(_classificationHeaderOf(external), '"1=247 2=247"');
      expect(_movetextOf(external), isNot(contains(r'$')));
      final returned = ChessGame.fromPgn('book-back', external);
      expect(classificationFromNags(returned.mainline[0].nags),
          GameMoveClassification.bookMove);
      expect(classificationFromNags(returned.mainline[1].nags),
          GameMoveClassification.bookMove);
    });

    test('variation classes are addressed and restored', () {
      const native = '''
[Event "?"]
[Result "1-0"]

1. e4 \$1 \$242 e5 \$6 \$244 (1... c5 \$1 \$241 2. Nf3 \$6 \$243) 2. Nf3 \$3 \$240 1-0
''';
      final external = toExternalCompatiblePgn(
        exportGameToPgn(ChessGame.fromPgn('var', native)),
      );

      // A block is addressed from the move it follows, and its moves from
      // there: the first variation after `e5` (ply 2) contributes `2v1.1`
      // (the alternative move) and `2v1.2` (its continuation).
      expect(
        _classificationHeaderOf(external),
        '"1=242 2=244 2v1.1=241 2v1.2=243 3=240"',
      );

      final returned = ChessGame.fromPgn('var-back', external);
      expect(classificationFromNags(returned.mainline[0].nags),
          GameMoveClassification.bestMove);
      expect(classificationFromNags(returned.mainline[2].nags),
          GameMoveClassification.brilliant);
      final variation = _firstVariationLine(returned.mainline);
      expect(variation, isNotNull);
      expect(classificationFromNags(variation!.first.nags),
          GameMoveClassification.goodMove);
      expect(classificationFromNags(variation[1].nags),
          GameMoveClassification.missedWin);
    });

    test('a native block already in the PGN always wins', () {
      const both = '''
[Event "?"]
[Result "*"]
[ChessEverClassification "1=247 2=241"]

1. e4 \$6 \$244 e5 *
''';
      final game = ChessGame.fromPgn('both', both);

      expect(game.mainline[0].nags, const <int>[6, 244]);
      // Nothing is ever annotated twice: the tag only fills a gap.
      expect(
        (game.mainline[0].nags ?? const <int>[])
            .where(isChesseverClassificationNag)
            .length,
        1,
      );
      expect(classificationFromNags(game.mainline[1].nags),
          GameMoveClassification.goodMove);
    });

    test('the header code is used only when the move has no native block', () {
      final restored = restoreChesseverClassificationNags(
        nags: const <int>[6, 244],
        comments: const <String>['[%ce 247]'],
        moveKey: '1',
        headerCodes: const <String, int>{'1': 247},
      );

      expect(restored, const <int>[6, 244]);
    });

    test('restore keeps null NAGs null when nothing addresses the move', () {
      expect(
        restoreChesseverClassificationNags(
          nags: null,
          comments: const <String>['[%clk 0:01:00]'],
          moveKey: '7',
          headerCodes: const <String, int>{'1': 244},
        ),
        isNull,
      );
    });

    test('unknown and malformed entries are ignored, never guessed', () {
      expect(parseChesseverClassificationHeader(null), isEmpty);
      expect(parseChesseverClassificationHeader(''), isEmpty);
      expect(parseChesseverClassificationHeader('1=999'), isEmpty);
      expect(parseChesseverClassificationHeader('1 = 244'), isEmpty);
      expect(parseChesseverClassificationHeader('x=244'), isEmpty);
      expect(parseChesseverClassificationHeader('=244'), isEmpty);
      expect(parseChesseverClassificationHeader('1=244'), const {'1': 244});
      expect(
        parseChesseverClassificationHeader('1=244 1=247'),
        const {'1': 244},
        reason: 'the first code is the one the app displays',
      );
      expect(parseChesseverClassificationHeader('2v1.3=243'), const {'2v1.3': 243});
      // The writer emits nothing when no code survives validation.
      expect(chesseverClassificationHeaderValue(const {}), isNull);
      expect(chesseverClassificationHeaderValue(const {'1': 999}), isNull);
    });

    test('an unknown marker code is neither restored nor discarded', () {
      const comments = <String>['[%ce 999]'];
      expect(
        restoreChesseverClassificationNags(nags: null, comments: comments),
        isNull,
      );
      expect(stripChesseverMarker(comments), comments);
    });

    test('a copied game survives the full round trip', () {
      final original = _analysedGame();
      final external = toExternalCompatiblePgn(exportGameToPgn(original));
      final returned = ChessGame.fromPgn('round-trip', external);

      final before = chesseverAnnotationsFromMainline(original);
      final after = chesseverAnnotationsFromMainline(returned);
      expect(after.length, before.length);
      for (final index in before.keys) {
        expect(after[index]!.type, before[index]!.type);
      }
      // Clocks and evals survive too.
      expect(returned.mainline.first.clockTime, '1:30:53');
      expect(returned.mainline.first.eval, '-0.32');

      // Saving the returned game writes the native block again — and never the
      // private tag the import consumed.
      final resaved = exportGameToPgn(returned);
      expect(resaved, contains(r'$240'));
      expect(resaved, contains(r'$247'));
      expect(resaved, isNot(contains('ChessEverClassification')));
      expect(resaved, isNot(contains('[%ce')));
    });

    test('prose beside a legacy marker is preserved on import', () {
      final game = ChessGame.fromPgn(
        'prose',
        r'1. e4 $6 { A real comment. [%eval 0.1] [%ce 244] } 1... e5 *',
      );

      expect(game.mainline[0].nags, containsAll(<int>[6, 244]));
      expect(game.mainline[0].comments, isNot(contains(contains('[%ce'))));
      expect(
        cleanPgnComments(game.mainline[0].comments),
        contains('A real comment.'),
      );
    });

    test('each game of a multi-game blob carries its own tag and plies', () {
      final one = exportGameToPgn(_analysedGame()).trim();
      final two = exportGameToPgn(ChessGame.fromPgn('book', '1. e4 \$247 *'))
          .trim();
      final blob = toExternalCompatiblePgn('$one\n\n$two');

      expect(
        RegExp(r'\[ChessEverClassification ').allMatches(blob).length,
        2,
      );
      // The second game's first move is ply 1 again.
      expect(blob, contains('[ChessEverClassification "1=247"]'));

      final parts = blob.split(RegExp(r'\n(?=\[Event )'));
      expect(parts.length, 2);
      expect(
        classificationFromNags(
          ChessGame.fromPgn('p1', parts.first).mainline[1].nags,
        ),
        GameMoveClassification.bookMove,
      );
      expect(
        classificationFromNags(ChessGame.fromPgn('p2', parts[1]).mainline.first.nags),
        GameMoveClassification.bookMove,
      );
    });
  });

  group('movetext shape', () {
    test('wraps at 80 columns with every move still numbered', () {
      final game = _longGame();
      final external = toExternalCompatiblePgn(exportGameToPgn(game));
      final lines = _movetextLinesOf(external);

      expect(lines.length, greaterThan(1));
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(80), reason: line);
      }
      // Wrapping is whitespace-only: the wrapped text is the same game.
      expect(
        ChessGame.fromPgn('wrapped', external).mainline.map((m) => m.san),
        game.mainline.map((m) => m.san),
      );
      // A line never ends on a stranded move number.
      for (final line in lines) {
        expect(line, isNot(matches(RegExp(r'\d+\.(?:\.\.)?$'))), reason: line);
      }
      // A long game with no classification still gets no tag.
      expect(external, isNot(contains('ChessEverClassification')));
    });

    test('a custom column budget is honoured', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_longGame()),
        columns: 40,
      );

      for (final line in _movetextLinesOf(external)) {
        expect(line.length, lessThanOrEqualTo(40), reason: line);
      }
    });

    test('the classification tag never counts as movetext', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );
      final movetext = _movetextLinesOf(external);

      expect(movetext.length, greaterThan(1));
      expect(_movetextOf(external), startsWith('1. b3'));
      for (final line in movetext) {
        expect(line, isNot(contains('ChessEverClassification')), reason: line);
      }
    });

    test('black to move keeps its 1... indicator', () {
      const blackToMove = '''
[Event "?"]
[Result "*"]
[SetUp "1"]
[FEN "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"]

1... e5 2. Nf3 *''';
      final external = toExternalCompatiblePgn(
        exportGameToPgn(ChessGame.fromPgn('black', blackToMove)),
      );

      expect(_movetextOf(external), startsWith('1...'));
      final returned = ChessGame.fromPgn('black-again', external);
      expect(returned.mainline.map((m) => m.san).toList(), ['e5', 'Nf3']);
    });

    test('the game is terminated with its Result token and a newline', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );

      expect(external, endsWith('1-0\n'));
    });

    test('a movetext without a result token still gets one and a newline', () {
      const noResult = '[Event "?"]\n\n1. e4 e5';
      expect(toExternalCompatiblePgn(noResult), endsWith('*\n'));

      const headerOnlyResult = '[Event "?"]\n[Result "0-1"]\n\n1. e4 e5';
      expect(toExternalCompatiblePgn(headerOnlyResult), endsWith('0-1\n'));
    });

    test('all headers are kept, including unknown ones', () {
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );

      expect(external, contains('[BroadcastName "Test Open"]'));
      expect(external, contains('[TimeControl "40/5400+30:1800+30"]'));
      expect(external, contains('[Result "1-0"]'));
      expect(external, contains('[Black "Nielsen, Frode Benedikt"]'));
      // Headers stay ahead of the movetext they belong to.
      expect(
        external.indexOf('[Result "1-0"]'),
        lessThan(external.indexOf('1. b3')),
      );
    });

    test('several copied games stay separate, terminated blocks', () {
      final one = toExternalCompatiblePgn(exportGameToPgn(_analysedGame()));
      final blob = toExternalCompatiblePgn('${one.trim()}\n\n${one.trim()}');

      expect(RegExp(r'\[Event ').allMatches(blob).length, 2);
      expect(RegExp(r'1-0\n').allMatches(blob).length, 2);
      expect(blob, endsWith('1-0\n'));
      expect(_hasOutOfRangeNag(blob), isFalse);
      for (final line in blob.split('\n')) {
        if (line.startsWith('[')) continue;
        expect(line.length, lessThanOrEqualTo(80), reason: line);
      }
    });

    test('text with no movetext is only newline-normalized', () {
      expect(toExternalCompatiblePgn(''), '');
      expect(toExternalCompatiblePgn('  \n '), '  \n ');

      const headersOnly = '[Event "a"]\n[Result "*"]\n';
      final normalized = toExternalCompatiblePgn(
        headersOnly.replaceAll('\n', '\r\n'),
      );
      expect(normalized, contains('[Event "a"]'));
      expect(normalized, isNot(contains('\r')));
    });
  });

  group('ChessEver file output is unchanged', () {
    test('the native export keeps the block, unwrapped, with no tag', () {
      // What a local database save and an in-place update write, byte for
      // byte: the standard verdict beside the exact ChessEver class.
      final native = exportGameToPgn(_analysedGame());

      expect(native, contains(r'$6 $244'));
      expect(native, contains(r'$247'));
      expect(native, contains(r'$1 $242'));
      expect(native, contains(r'$3 $240'));
      // One long movetext line, exactly as before this change.
      expect(_movetextLinesOf(native).length, 1);
      expect(native, isNot(contains('[%ce')));
      expect(native, isNot(contains('ChessEverClassification')));
      // The clipboard/export *source* text is untouched; only the clipboard
      // boundary applies `toExternalCompatiblePgn`.
      expect(exportGameToPgn(_analysedGame()), native);
    });

    test('what a local file save writes is untouched by the copy pass', () {
      // File writers call `exportGameToPgn(game).trim()` and join records with
      // blank lines. The compatibility pass must never reach that text.
      final fileText = exportGameToPgn(_analysedGame()).trim();

      expect(fileText, contains(r'$6 $244'));
      expect(fileText, contains(r'$247'));
      expect(fileText, isNot(contains('[%ce')));
      expect(fileText, isNot(contains('ChessEverClassification')));
      expect(
        fileText.split('\n').where((line) => !line.startsWith('[')).length,
        1,
      );
    });

    test('the private tag is not part of any header surface', () {
      // An import drops it, and the export filter refuses it even if it were
      // somehow present in metadata.
      final external = toExternalCompatiblePgn(
        exportGameToPgn(_analysedGame()),
      );
      final metadata = <String, dynamic>{
        ...ChessGame.fromPgn('game', external).metadata,
        kChesseverClassificationHeaderTag: '1=244',
      };

      expect(
        withoutChesseverClassificationHeader(metadata).keys,
        isNot(contains(kChesseverClassificationHeaderTag)),
      );
      expect(
        toExternalCompatiblePgn(
          exportGameToPgn(
            ChessGame.fromPgn('game', external).copyWith(metadata: metadata),
          ),
        ),
        isNot(contains('ChessEverClassification')),
      );
    });
  });
}

bool _hasOutOfRangeNag(String text) =>
    RegExp(r'\$(?:24[0-8])(?!\d)').hasMatch(text);

/// The private carrier's line from a copied PGN, or null when it has none.
String? _classificationHeaderOf(String pgn) {
  for (final line in _headerLinesOf(pgn)) {
    if (line.startsWith('[$kChesseverClassificationHeaderTag ')) return line;
  }
  return null;
}

/// Whether the private carrier travelled only in the header block: the tag line
/// exists and no movetext line mentions it (so no reader can print it inline).
bool _tagOnlyInHeaderBlock(String pgn) =>
    _classificationHeaderOf(pgn) != null &&
    _movetextLinesOf(pgn).every(
      (line) => !line.contains(kChesseverClassificationHeaderTag),
    );

List<String> _headerLinesOf(String pgn) =>
    pgn.split('\n').where((line) => line.startsWith('[')).toList();

/// The `$n` NAGs on each move of a movetext, keyed by the move number that
/// introduces it.
Map<String, List<String>> _nagGroupsOf(String movetext) {
  final groups = <String, List<String>>{};
  var current = '';
  for (final match in RegExp(r'\$\d+|\d+\.(?:\.\.)?').allMatches(movetext)) {
    final token = match.group(0)!;
    if (token.startsWith(r'$')) {
      groups.putIfAbsent(current, () => <String>[]).add(token);
    } else {
      current = token;
    }
  }
  return groups;
}

/// The external movetext of a single-game PGN, without headers.
String _movetextOf(String pgn) => _movetextLinesOf(pgn).join('\n');

List<String> _movetextLinesOf(String pgn) => pgn
    .split('\n')
    .where((line) => line.isNotEmpty && !line.startsWith('['))
    .toList(growable: false);

/// The first variation line reachable from a mainline's moves.
ChessLine? _firstVariationLine(ChessLine mainline) {
  for (final move in mainline) {
    final variations = move.variations ?? const <ChessLine>[];
    if (variations.isNotEmpty && variations.first.isNotEmpty) {
      return variations.first;
    }
  }
  return null;
}

/// A game whose moves carry eight different report classes plus a book move,
/// clocks on every move and one prose comment.
ChessGame _analysedGame() {
  const pgn = '''
[Event "Test Open"]
[Site "https://chessever.com/games/ghAKkSCe"]
[Date "2026.07.31"]
[Round "3"]
[White "Rewitz, Poul"]
[Black "Nielsen, Frode Benedikt"]
[Result "1-0"]
[TimeControl "40/5400+30:1800+30"]
[BroadcastName "Test Open"]

1. b3 { [%clk 1:30:53] } e5 { [%clk 1:29:21] } 2. Bb2 { [%clk 1:31:04] }
Nc6 { [%clk 1:29:34] } 3. f4 { [%clk 1:28:36] } Nf6 { [%clk 1:29:10] }
4. e3 { A real comment. [%clk 1:27:12] } d5 { [%clk 1:28:00] }
5. Nf3 { [%clk 1:26:00] } *''';
  final game = ChessGame.fromPgn('analysed', pgn);
  return mergeGameReportAnnotationsForExport(game, const [
    GameReportMove(
      ply: 1,
      san: 'b3',
      uci: 'b2b3',
      isWhite: true,
      classification: GameMoveClassification.inaccuracy,
      evaluation: GameReportLine(
        moves: <String>['b2b3'],
        depth: 18,
        centipawns: -32,
      ),
    ),
    GameReportMove(
      ply: 2,
      san: 'e5',
      uci: 'e7e5',
      isWhite: false,
      classification: GameMoveClassification.bookMove,
      evaluation: GameReportLine(
        moves: <String>['e7e5'],
        depth: 18,
        centipawns: 16,
      ),
    ),
    GameReportMove(
      ply: 3,
      san: 'Bb2',
      uci: 'c1b2',
      isWhite: true,
      classification: GameMoveClassification.bestMove,
      evaluation: GameReportLine(
        moves: <String>['c1b2'],
        depth: 18,
        centipawns: 14,
      ),
    ),
    GameReportMove(
      ply: 4,
      san: 'Nc6',
      uci: 'b8c6',
      isWhite: false,
      classification: GameMoveClassification.brilliant,
      evaluation: GameReportLine(
        moves: <String>['b8c6'],
        depth: 18,
        centipawns: 25,
      ),
    ),
    GameReportMove(
      ply: 5,
      san: 'f4',
      uci: 'f2f4',
      isWhite: true,
      classification: GameMoveClassification.missedWin,
      evaluation: GameReportLine(
        moves: <String>['f2f4'],
        depth: 18,
        centipawns: -16,
      ),
    ),
    GameReportMove(
      ply: 6,
      san: 'Nf6',
      uci: 'g8f6',
      isWhite: false,
      classification: GameMoveClassification.mistake,
      evaluation: GameReportLine(
        moves: <String>['g8f6'],
        depth: 18,
        centipawns: -13,
      ),
    ),
    GameReportMove(
      ply: 7,
      san: 'e3',
      uci: 'e2e3',
      isWhite: true,
      classification: GameMoveClassification.blunder,
      evaluation: GameReportLine(
        moves: <String>['e2e3'],
        depth: 18,
        centipawns: -25,
      ),
    ),
    GameReportMove(
      ply: 8,
      san: 'd5',
      uci: 'd7d5',
      isWhite: false,
      classification: GameMoveClassification.goodMove,
      evaluation: GameReportLine(
        moves: <String>['d7d5'],
        depth: 18,
        centipawns: 5,
      ),
    ),
    GameReportMove(
      ply: 9,
      san: 'Nf3',
      uci: 'g1f3',
      isWhite: true,
      classification: null,
      evaluation: GameReportLine(
        moves: <String>['g1f3'],
        depth: 18,
        centipawns: 2,
      ),
    ),
  ]);
}

/// One move, one report class — for the mapping table.
ChessGame _gameWithClassification(GameMoveClassification classification) {
  final game = ChessGame.fromPgn('single', '1. e4 e5 *');
  return mergeGameReportAnnotationsForExport(game, [
    GameReportMove(
      ply: 1,
      san: 'e4',
      uci: 'e2e4',
      isWhite: true,
      classification: classification,
      evaluation: GameReportLine(
        moves: <String>['e2e4'],
        depth: 18,
        centipawns: 20,
      ),
    ),
    GameReportMove(
      ply: 2,
      san: 'e5',
      uci: 'e7e5',
      isWhite: false,
      classification: null,
      evaluation: GameReportLine(
        moves: <String>['e7e5'],
        depth: 18,
        centipawns: 2,
      ),
    ),
  ]);
}

/// A legal 33-ply game — long enough that the movetext must wrap at 80 columns.
ChessGame _longGame() {
  const pgn = '''
[Event "Long"]
[Result "1-0"]

1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7
8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7
14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0''';
  return ChessGame.fromPgn('long', pgn);
}
