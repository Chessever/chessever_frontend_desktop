import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/services/cbh_dart_conversion.dart';
import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:chessever/desktop/services/cbh_move_tables.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final badTrailer in [false, true]) {
    test(
      'v3 guiding text is inert and archived; badTrailer=$badTrailer',
      () async {
        final root = await Directory.systemTemp.createTemp('cbh-guiding-v3-');
        addTearDown(() => root.delete(recursive: true));
        final source = await _plainGame(root);
        final index = await source.readAsBytes();
        index[46] = 2;
        await source.writeAsBytes(index);
        final html = utf8.encode(
          '<html><body>Study <b>café</b> &amp; plan. {x}<script>hidden()</script></body></html>',
        );
        final frame = Uint8List.fromList([
          0x80,
          0,
          0,
          0,
          3,
          0,
          1,
          0,
          0,
          0,
          1,
          0,
          84,
          1,
          1,
          0,
          0,
          0,
          html.length,
          0,
          0,
          0,
          ...html,
          if (badTrailer) 1 else 0,
          0,
          0,
          0,
        ]);
        frame[3] = frame.length;
        await File(
          p.join(root.path, 'sample.cbg'),
        ).writeAsBytes([...Uint8List(26), ...frame]);
        final output = Directory(p.join(root.path, 'converted'));
        final c = CbhDartConversion(destination: output);
        if (badTrailer) {
          await expectLater(
            c.convert(source.path),
            throwsA(
              isA<CbhFormatException>().having(
                (e) => e.message,
                'message',
                contains('trailer'),
              ),
            ),
          );
          expect(await output.exists(), isFalse);
          return;
        }
        final pgn = await (await c.convert(source.path)).readAsString();
        expect(pgn, contains('[ChessBaseRecordType "GuidingText"]'));
        expect(
          pgn,
          contains('[ChessBaseGuidingText "${base64Encode(frame)}"]'),
        );
        expect(pgn, contains('Study café & plan. &#123;x&#125;'));
        expect(pgn, isNot(contains('hidden()')));
        expect(pgn.trimRight(), endsWith(' *'));
        final parsed = ChessGame.fromPgn('guiding', pgn);
        expect(parsed.mainline, isEmpty);
        expect(parsed.rootComments.single, contains('Title (language 0): T'));
        expect(parsed.rootComments.single, contains('Study café & plan.'));
      },
    );
  }

  test(
    'archives an unreadable optional source title without losing the game',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-source-title-');
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(root);
      final cbs = File(p.join(root.path, 'sample.cbs'));
      final bytes = await cbs.readAsBytes();
      bytes.setRange(37, 41, [0x19, 0xaa, 0x0e, 0xff]);
      bytes.setRange(62, 65, 'Pub'.codeUnits);
      await cbs.writeAsBytes(bytes);
      final service = CbhConversionService(
        destination: Directory(p.join(root.path, 'converted')),
      );
      final pgn =
          await File((await service.convert(source.path))!).readAsString();
      expect(pgn, isNot(contains('[SourceTitle ')));
      expect(pgn, contains('[Source "Pub"]'));
      expect(
        pgn,
        contains(
          '[ChessBaseSourceRecord "${base64Encode(bytes.sublist(28))}"]',
        ),
      );
      expect(pgn, contains('1. e4 e5 1-0'));
      expect(
        service.preservationSummary,
        contains('1 record has an unreadable ChessBase source title'),
      );
      expect(await cbs.readAsBytes(), bytes);
    },
  );

  test(
    'publishes a complete plain game as PGN without a native helper',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-dart-convert-');
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(root);
      final output = Directory(p.join(root.path, 'converted'));

      final result = await CbhConversionService(
        destination: output,
      ).convert(source.path);
      expect(result, isNotNull);
      final pgn = await File(result!).readAsString();

      expect(pgn, contains('[White "White"]'));
      expect(pgn, contains('[Black "Black"]'));
      expect(pgn, contains('1. e4 e5 1-0'));
      expect(result, endsWith('.pgn'));
    },
  );

  test(
    'rejects a malformed annotation frame without publishing a partial PGN',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-dart-reject-');
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(root);
      final index = await source.readAsBytes();
      index[54] = 26;
      await source.writeAsBytes(index);
      final annotation = Uint8List(47);
      annotation[39] = 21;
      annotation[45] = 5; // Below the six-byte annotation-entry header.
      annotation[46] = 42;
      await File(p.join(root.path, 'sample.cba')).writeAsBytes(annotation);
      final output = Directory(p.join(root.path, 'converted'));

      await expectLater(
        CbhDartConversion(destination: output).convert(source.path),
        throwsA(isA<CbhFormatException>()),
      );
      expect(await output.exists(), isFalse);
    },
  );
}

Future<File> _plainGame(Directory root) async {
  final index = Uint8List(92);
  index[2] = 0x2c;
  index[4] = 0x2e;
  index[5] = 1;
  index[9] = index.length ~/ 46; // Header count includes its own record.
  index[50] = 26;
  index[60] = 1;
  index[73] = 2;
  final source = File(p.join(root.path, 'sample.cbh'));
  await source.writeAsBytes(index);
  final players = Uint8List(28 + 67 * 2);
  players.setRange(28 + 9, 28 + 14, 'White'.codeUnits);
  players.setRange(28 + 67 + 9, 28 + 67 + 14, 'Black'.codeUnits);
  await File(p.join(root.path, 'sample.cbp')).writeAsBytes(players);
  final event = Uint8List(28 + 99);
  event[28 + 9] = 69;
  await File(p.join(root.path, 'sample.cbt')).writeAsBytes(event);
  await File(p.join(root.path, 'sample.cbc')).writeAsBytes(Uint8List(28 + 62));
  await File(p.join(root.path, 'sample.cbs')).writeAsBytes(Uint8List(28 + 68));
  final game = Uint8List(32);
  game[29] = 6;
  game[30] = cbhMoveLookup.indexOf(0x80);
  game[31] = (cbhMoveLookup.indexOf(0x80) + 1) & 255;
  await File(p.join(root.path, 'sample.cbg')).writeAsBytes(game);
  await File(p.join(root.path, 'sample.cba')).writeAsBytes(Uint8List(26));
  return source;
}
