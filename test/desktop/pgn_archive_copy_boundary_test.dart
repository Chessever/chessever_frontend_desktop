import 'dart:io';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/chessboard/utils/pgn_external_compat.dart';
import 'package:flutter_test/flutter_test.dart';

const _archiveTags = <String>[
  'ChessBaseAnnotationFrame',
  'ChessBaseAnnotatorRecord',
  'ChessBaseBlackRecord',
  'ChessBaseCommentEncoding',
  'ChessBaseCommentRendering',
  'ChessBaseEventRecord',
  'ChessBaseGuidingRendering',
  'ChessBaseGuidingText',
  'ChessBaseIndex',
  'ChessBaseMetadataEncoding',
  'ChessBasePreservation',
  'ChessBaseRawAnnotations',
  'ChessBaseRawText',
  'ChessBaseRecordType',
  'ChessBaseResult',
  'ChessBaseResultCode',
  'ChessBaseSourceRecord',
  'ChessBaseUnattachedAnnotations',
  'ChessBaseUnknownTextBytes',
  'ChessBaseWhiteRecord',
];
const _headers =
    '[Event "Copy boundary"]\n[Site "Test"]\n[Date "2008.02.28"]\n[Round "?"]\n[White "White"]\n[Black "Black"]\n[Result "0-1"]\n[ECO "B80"]\n[Annotator "Preserve author"]\n';
const _moves =
    r'1. e4 {Root and move prose} e5 (1... c5 $15 2. Nf3 d6 (2... Nc6 $40 3. Nc3)) 2. Nf3 $146 Nc6 0-1';

void main() {
  test(
    'external PGN removes known conversion archive and diagnostic headers',
    () {
      final raw =
          '$_headers${_archiveTags.map((tag) => '[$tag "AA=="]\n').join()}\n$_moves';
      final copy = toExternalCompatiblePgn(raw);
      for (final tag in _archiveTags) {
        expect(_hasTag(copy, tag), isFalse, reason: tag);
      }
      expect(copy, toExternalCompatiblePgn('$_headers\n$_moves'));
    },
  );

  test(
    'external copy preserves legitimate and unfamiliar non-archive metadata',
    () {
      const extras =
          '[SetUp "0"]\n[TimeControl "300+5"]\n[Source "Source"]\n[WhiteTitle "GM"]\n[ChessBaseUserNote "User-owned metadata"]\n';
      final copy = toExternalCompatiblePgn(
        '$_headers$extras[ChessBaseIndex "AA=="]\n\n$_moves',
      );
      for (final tag in [
        'Event',
        'Site',
        'Date',
        'Round',
        'White',
        'Black',
        'Result',
        'ECO',
        'Annotator',
        'SetUp',
        'TimeControl',
        'Source',
        'WhiteTitle',
        'ChessBaseUserNote',
      ]) {
        expect(_hasTag(copy, tag), isTrue, reason: tag);
      }
      expect(copy, contains('[ChessBaseUserNote "User-owned metadata"]'));
    },
  );

  test('archive-looking text inside real commentary is not stripped', () {
    const moves =
        r'1. e4 {Keep [ChessBaseIndex "ordinary prose"] and [%eval 0.2] [%clk 0:05:00]} e5 *';
    final copy = toExternalCompatiblePgn(
      '[Event "Comments"]\n[Result "*"]\n[ChessBaseIndex "AA=="]\n\n$moves',
    );
    expect(_hasTag(copy, 'ChessBaseIndex'), isFalse);
    expect(
      copy,
      contains(
        r'{Keep [ChessBaseIndex "ordinary prose"] and [%eval 0.2] [%clk 0:05:00]}',
      ),
    );
  });

  test(
    'all native classifications still round trip on mainline and variations',
    () {
      for (var code = 240; code <= 247; code++) {
        final raw =
            '[Result "*"]\n[ChessBaseIndex "AA=="]\n\n1. e4 \$$code { [%eval 0.2] } e5 (1... c5 \$$code 2. Nf3 d6) 2. Nf3 Nc6 *';
        final native = exportGameToPgn(ChessGame.fromPgn('class-$code', raw));
        final copy = toExternalCompatiblePgn(native);
        expect(_hasTag(copy, 'ChessBaseIndex'), isFalse);
        expect(_hasTag(copy, 'ChessEverClassification'), isTrue);
        expect(RegExp(r'\$24[0-8]\b').hasMatch(copy), isFalse);
        expect(copy, contains('[%eval 0.2]'));
        final returned = ChessGame.fromPgn('class-return-$code', copy);
        expect(returned.mainline.first.nags, contains(code));
        expect(
          returned.mainline.first.variations!.first.first.nags,
          contains(code),
        );
      }
    },
  );

  test('native serialization retains archives and copy does not mutate it', () {
    final game = ChessGame.fromPgn(
      'native-archive',
      '$_headers[ChessBaseIndex "AA=="]\n[ChessBaseRawAnnotations "W10="]\n\n$_moves',
    );
    final native = exportGameToPgn(game);
    final copy = toExternalCompatiblePgn(native);
    expect(_hasTag(native, 'ChessBaseIndex'), isTrue);
    expect(_hasTag(native, 'ChessBaseRawAnnotations'), isTrue);
    expect(_hasTag(copy, 'ChessBaseIndex'), isFalse);
    expect(exportGameToPgn(game), native);
    expect(game.metadata['ChessBaseRawAnnotations'], 'W10=');
    final returned = ChessGame.fromPgn('copy-returned', copy);
    final expected = game.copyWith(
      metadata:
          Map<String, dynamic>.of(game.metadata)
            ..remove('ChessBaseIndex')
            ..remove('ChessBaseRawAnnotations'),
    );
    expect(exportGameToPgn(returned), exportGameToPgn(expected));
  });

  test('multiple copied games remove archives independently', () {
    final one = '$_headers[ChessBaseIndex "AA=="]\n\n$_moves';
    final copy = toExternalCompatiblePgn('$one\n\n$one');
    expect(_hasTag(copy, 'ChessBaseIndex'), isFalse);
    expect(
      RegExp(r'^\[Event ', multiLine: true).allMatches(copy),
      hasLength(2),
    );
    expect(
      copy,
      toExternalCompatiblePgn('$_headers\n$_moves\n\n$_headers\n$_moves'),
    );
  });

  test(
    'archive-only header blocks do not leave a fake visible header section',
    () {
      final copy = toExternalCompatiblePgn(
        '[ChessBaseIndex "AA=="]\n\n1. e4 e5 *',
      );
      expect(copy, toExternalCompatiblePgn('1. e4 e5 *'));
    },
  );

  test('guiding-text commentary remains while its raw container is omitted', () {
    final copy = toExternalCompatiblePgn(
      '[Event "Guiding text"]\n[Result "*"]\n[ChessBaseGuidingText "AA=="]\n[ChessBaseGuidingRendering "raw archive"]\n\n{Actual title and guiding text} *',
    );
    expect(copy, contains('{Actual title and guiding text}'));
    expect(_hasTag(copy, 'ChessBaseGuidingText'), isFalse);
    expect(_hasTag(copy, 'Event'), isTrue);
  });

  final reported = Platform.environment['CHESSEVER_REPORTED_PGN'];
  test(
    'reported PGN keeps its complete tree and annotations without raw headers',
    () {
      final game = ChessGame.fromPgn(
        'private-reported',
        File(reported!).readAsStringSync(),
      );
      final native = exportGameToPgn(game);
      final copy = toExternalCompatiblePgn(native);
      for (final tag in _archiveTags) {
        expect(_hasTag(copy, tag), isFalse, reason: tag);
      }
      final normalMetadata = Map<String, dynamic>.of(game.metadata);
      for (final tag in _archiveTags) {
        normalMetadata.remove(tag);
      }
      final returned = ChessGame.fromPgn('private-clean-return', copy);
      expect(
        exportGameToPgn(returned),
        exportGameToPgn(game.copyWith(metadata: normalMetadata)),
      );
      expect(exportGameToPgn(game), native);
      expect(game.metadata['ChessBaseAnnotationFrame'], isNotNull);
      expect(_countMoves(game.mainline), greaterThan(400));
      expect(_countMoves(returned.mainline), _countMoves(game.mainline));
    },
    skip:
        reported == null
            ? 'Set CHESSEVER_REPORTED_PGN for private reported-input coverage'
            : false,
  );
}

bool _hasTag(String text, String tag) =>
    RegExp('^\\[${RegExp.escape(tag)}\\s+', multiLine: true).hasMatch(text);
int _countMoves(ChessLine line) => line.fold(
  0,
  (sum, move) =>
      sum +
      1 +
      (move.variations ?? const <ChessLine>[]).fold<int>(
        0,
        (n, v) => n + _countMoves(v),
      ),
);
