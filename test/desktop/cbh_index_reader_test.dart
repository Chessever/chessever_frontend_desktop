import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cbh-index-reader-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'reads a complete classic file set and preserves its raw index',
    () async {
      final index = await _writeDatabase(root);
      final result = await CbhIndexReader.open(index.path);

      expect(result.files.keys, containsAll(CbhIndexReader.extensions));
      expect(result.records, hasLength(1));
      expect(result.records.single.ordinal, 0);
      expect(result.records.single.gameOffset, 26);
      expect(result.records.single.whitePlayer, 0);
      expect(result.records.single.month, 1);
      expect(result.records.single.day, 2);
      expect(result.records.single.resultCode, 2);
      expect(result.records.single.raw, hasLength(46));
    },
  );

  test('rejects an index with a stale declared record count', () async {
    final index = await _writeDatabase(root);
    final bytes = await index.readAsBytes();
    bytes[9] = 2;
    await index.writeAsBytes(bytes);

    await expectLater(
      CbhIndexReader.open(index.path),
      throwsA(isA<CbhFormatException>()),
    );
  });

  test('rejects out of range companion record references', () async {
    final index = await _writeDatabase(root);
    final bytes = await index.readAsBytes();
    bytes[46 + 11] = 1;
    await index.writeAsBytes(bytes);

    await expectLater(
      CbhIndexReader.open(index.path),
      throwsA(isA<CbhFormatException>()),
    );
  });

  test('does not accept a missing companion file', () async {
    final index = await _writeDatabase(root);
    await File(p.join(root.path, 'sample.cba')).delete();

    await expectLater(
      CbhIndexReader.open(index.path),
      throwsA(isA<CbhFormatException>()),
    );
  });
}

Future<File> _writeDatabase(Directory root) async {
  final index = Uint8List(92);
  index[2] = 0x2c;
  index[4] = 0x2e;
  index[5] = 1;
  index[9] = 1;
  index[46 + 4] = 26;
  index[46 + 24] = 0x0f;
  index[46 + 25] = 0xc0;
  index[46 + 26] = 0x22;
  index[46 + 27] = 2;
  final file = File(p.join(root.path, 'sample.cbh'));
  await file.writeAsBytes(index);
  for (final entry in <(String, int)>[
    ('.cbp', 67),
    ('.cbt', 99),
    ('.cbc', 62),
    ('.cbs', 68),
  ]) {
    await File(
      p.join(root.path, 'sample${entry.$1}'),
    ).writeAsBytes(Uint8List(28 + entry.$2));
  }
  await File(p.join(root.path, 'sample.cbg')).writeAsBytes(Uint8List(30));
  await File(p.join(root.path, 'sample.cba')).writeAsBytes(Uint8List(26));
  return file;
}
