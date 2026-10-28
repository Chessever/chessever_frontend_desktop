import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:chessever/desktop/services/cbh_move_tables.dart';
import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'default Dart import renders metadata TAB as space and archives its exact original bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-metadata-tab-');
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(root, black: 'Black\tName');
      final before = await _sourceHashes(root);
      final players = await File(p.join(root.path, 'sample.cbp')).readAsBytes();
      final originalBlack = players.sublist(28 + 67, 28 + 67 * 2);
      final service = CbhConversionService(
        destination: Directory(p.join(root.path, 'converted')),
      );
      expect(
        service.executable,
        isNull,
        reason: 'Exercise the real UI backend, not the optional native helper',
      );
      final result = await service.convert(source.path);
      expect(result, isNotNull);
      final text = await File(result!).readAsString();
      final parsed = PgnGame.parsePgn(text);
      expect(parsed.headers['Black'], 'Black Name');
      expect(text, contains('1. e4 e5 1-0'));
      expect(
        base64Decode(parsed.headers['ChessBaseBlackRecord']!),
        orderedEquals(originalBlack),
      );
      expect(originalBlack, contains(0x09));
      expect(await _sourceHashes(root), before);
    },
  );
  test(
    'successful TAB conversion discloses readable whitespace normalization in preservation details',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cbh-metadata-details-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(root, black: 'Black\tName');
      final service = CbhConversionService(
        destination: Directory(p.join(root.path, 'converted')),
      );
      expect(await service.convert(source.path), isNotNull);
      expect(service.preservationSummary, contains('1 record'));
      expect(
        service.preservationSummary,
        contains('metadata tabs displayed as spaces'),
      );
      expect(
        service.preservationSummary,
        contains('original metadata bytes are retained'),
      );
    },
  );

  test(
    'unknown metadata control remains strict with game field byte context and no partial publication',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'cbh-metadata-strict-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(
        root,
        black: 'Bad\u0001Name',
        gameCount: 2,
      );
      final before = await _sourceHashes(root);
      final out = Directory(p.join(root.path, 'converted'));
      await out.create();
      final previous = File(p.join(out.path, 'existing.pgn'));
      await previous.writeAsString('keep this user-owned previous copy');
      await expectLater(
        CbhConversionService(destination: out).convert(source.path),
        throwsA(
          isA<CbhFormatException>()
              .having((e) => e.message, 'game context', contains('Record 2'))
              .having(
                (e) => e.message,
                'field context',
                contains('Black surname'),
              )
              .having((e) => e.message, 'source companion', contains('.cbp'))
              .having((e) => e.message, 'offending byte', contains('0x01')),
        ),
      );
      expect(out.listSync().map((f) => p.basename(f.path)), ['existing.pgn']);
      expect(
        await previous.readAsString(),
        'keep this user-owned previous copy',
      );
      expect(await _sourceHashes(root), before);
    },
  );
  for (final byte in List<int>.generate(
    31,
    (i) => i + 1,
  ).where((b) => b != 0x09)) {
    test(
      'other control 0x${byte.toRadixString(16)} stays rejected without source mutation',
      () async {
        final root = await Directory.systemTemp.createTemp('cbh-control-');
        addTearDown(() => root.delete(recursive: true));
        final source = await _plainGame(
          root,
          black: 'A${String.fromCharCode(byte)}B',
        );
        final before = await _sourceHashes(root);
        final out = Directory(p.join(root.path, 'converted'));
        await expectLater(
          CbhConversionService(destination: out).convert(source.path),
          throwsA(
            isA<CbhFormatException>()
                .having((e) => e.message, 'field', contains('Black surname'))
                .having(
                  (e) => e.message,
                  'byte',
                  contains('0x${byte.toRadixString(16).padLeft(2, '0')}'),
                ),
          ),
        );
        expect(await out.exists(), isFalse);
        expect(await _sourceHashes(root), before);
      },
    );
  }
  for (final byte in [0x81, 0x8d, 0x8f, 0x90, 0x9d]) {
    test(
      'undefined Windows-1252 byte 0x${byte.toRadixString(16)} remains strict and contextual',
      () async {
        final root = await Directory.systemTemp.createTemp('cbh-undefined-');
        addTearDown(() => root.delete(recursive: true));
        final source = await _plainGame(
          root,
          black: 'A${String.fromCharCode(byte)}B',
        );
        await expectLater(
          CbhConversionService(
            destination: Directory(p.join(root.path, 'converted')),
          ).convert(source.path),
          throwsA(
            isA<CbhFormatException>()
                .having((e) => e.message, 'record', contains('Record 1'))
                .having(
                  (e) => e.message,
                  'byte',
                  contains('0x${byte.toRadixString(16)}'),
                ),
          ),
        );
      },
    );
  }
  for (final field in <(String, int, int, int, String, String)>[
    ('.cbp', 0, 67, 9, 'White', 'ChessBaseWhiteRecord'),
    ('.cbp', 0, 67, 39, 'White', 'ChessBaseWhiteRecord'),
    ('.cbp', 1, 67, 9, 'Black', 'ChessBaseBlackRecord'),
    ('.cbp', 1, 67, 39, 'Black', 'ChessBaseBlackRecord'),
    ('.cbt', 0, 99, 9, 'Event', 'ChessBaseEventRecord'),
    ('.cbt', 0, 99, 49, 'Site', 'ChessBaseEventRecord'),
    ('.cbc', 0, 62, 9, 'Annotator', 'ChessBaseAnnotatorRecord'),
    ('.cbs', 0, 68, 9, 'SourceTitle', 'ChessBaseSourceRecord'),
    ('.cbs', 0, 68, 34, 'Source', 'ChessBaseSourceRecord'),
  ]) {
    test(
      'TAB metadata ${field.$1} offset ${field.$4} stays lossless and counted once',
      () async {
        final root = await Directory.systemTemp.createTemp('cbh-field-tab-');
        addTearDown(() => root.delete(recursive: true));
        final source = await _plainGame(root);
        final file = File(p.join(root.path, 'sample${field.$1}'));
        final bytes = await file.readAsBytes();
        final at = 28 + field.$2 * field.$3;
        bytes.setRange(at + field.$4, at + field.$4 + 4, [65, 9, 66, 0]);
        await file.writeAsBytes(bytes);
        final original = bytes.sublist(at, at + field.$3);
        final service = CbhConversionService(
          destination: Directory(p.join(root.path, 'converted')),
        );
        final result = await service.convert(source.path);
        final game = PgnGame.parsePgn(await File(result!).readAsString());
        expect(game.headers[field.$5], contains('A B'));
        expect(base64Decode(game.headers[field.$6]!), orderedEquals(original));
        expect(
          service.preservationSummary,
          contains('1 record contains metadata tabs'),
        );
      },
    );
  }
  for (final entry in [
    (r'Black\tName', r'Black\tName', false),
    ('Black\u0000\u0001Hidden', 'Black', false),
    ('Mü\tName', 'Mü Name', true),
  ]) {
    test(
      'literal escapes NUL and accented text remain distinct: ${entry.$1.codeUnits}',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'cbh-text-boundary-',
        );
        addTearDown(() => root.delete(recursive: true));
        final source = await _plainGame(root, black: entry.$1);
        final service = CbhConversionService(
          destination: Directory(p.join(root.path, 'converted')),
        );
        final result = await service.convert(source.path);
        final game = PgnGame.parsePgn(await File(result!).readAsString());
        expect(game.headers['Black'], entry.$2);
        expect(service.preservationSummary != null, entry.$3);
      },
    );
  }
  test('TAB in a numeric metadata byte is not text normalization', () async {
    final root = await Directory.systemTemp.createTemp('cbh-numeric-tab-');
    addTearDown(() => root.delete(recursive: true));
    final source = await _plainGame(root);
    final file = File(p.join(root.path, 'sample.cbs'));
    final bytes = await file.readAsBytes();
    bytes[28 + 58] = 9;
    await file.writeAsBytes(bytes);
    final service = CbhConversionService(
      destination: Directory(p.join(root.path, 'converted')),
    );
    final result = await service.convert(source.path);
    final game = PgnGame.parsePgn(await File(result!).readAsString());
    expect(game.headers['SourceVersion'], '9');
    expect(service.preservationSummary, isNull);
    expect(
      base64Decode(game.headers['ChessBaseSourceRecord']!),
      orderedEquals(bytes.sublist(28)),
    );
  });
}

Future<Map<String, String>> _sourceHashes(Directory root) async => {
  for (final f in root.listSync().whereType<File>())
    p.basename(f.path): sha256.convert(await f.readAsBytes()).toString(),
};

Future<File> _plainGame(
  Directory root, {
  String black = 'Black',
  int gameCount = 1,
}) async {
  final index = Uint8List(46 * (gameCount + 1));
  index[2] = 0x2c;
  index[4] = 0x2e;
  index[5] = 1;
  index[9] = index.length ~/ 46; // Header count includes the index header.
  for (var i = 0; i < gameCount; i++) {
    final at = 46 * (i + 1);
    index[at + 4] = 26;
    index[at + 14] = i == gameCount - 1 ? 1 : 0;
    index[at + 27] = 2;
  }
  final source = File(p.join(root.path, 'sample.cbh'));
  await source.writeAsBytes(index);
  final players = Uint8List(28 + 67 * 2);
  players.setRange(28 + 9, 28 + 14, 'White'.codeUnits);
  players.setRange(28 + 67 + 9, 28 + 67 + 9 + black.length, black.codeUnits);
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
