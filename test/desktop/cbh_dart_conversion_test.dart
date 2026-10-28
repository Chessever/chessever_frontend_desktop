import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/services/cbh_dart_conversion.dart';
import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:chessever/desktop/services/cbh_move_tables.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
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
    'rejects an annotated source without publishing a partial PGN',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-dart-reject-');
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(root);
      final index = await source.readAsBytes();
      index[54] = 26;
      await source.writeAsBytes(index);
      final annotation = Uint8List(47);
      annotation[39] = 21;
      annotation[45] = 7;
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
  index[9] = 1;
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
