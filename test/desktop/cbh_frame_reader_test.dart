import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/services/cbh_frame_reader.dart';
import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('bounds game and annotation frames to their declared lengths', () async {
    final root = await Directory.systemTemp.createTemp('cbh-frames-');
    addTearDown(() => root.delete(recursive: true));
    final index = Uint8List(92);
    index[2] = 0x2c;
    index[4] = 0x2e;
    index[5] = 1;
    index[9] = 1;
    index[50] = 26;
    index[54] = 26;
    final cbh = File(p.join(root.path, 'sample.cbh'));
    await cbh.writeAsBytes(index);
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
    final game = Uint8List(35);
    game[29] = 9;
    game[30] = 1;
    await File(p.join(root.path, 'sample.cbg')).writeAsBytes(game);
    final annotations = Uint8List(47);
    annotations[39] = 21; // 14 byte header plus one 7 byte entry
    annotations[43] = 7;
    annotations[45] = 7;
    annotations[46] = 42;
    await File(p.join(root.path, 'sample.cba')).writeAsBytes(annotations);

    final files = await CbhIndexReader.open(cbh.path);
    final frames = CbhFrameReader(files);
    final record = files.records.single;
    final decodedGame = await frames.game(record);
    final decodedAnnotations = await frames.annotations(record);
    expect(decodedGame.moveBytes, [1, 0, 0, 0, 0]);
    expect(decodedAnnotations.entries, hasLength(1));
    expect(decodedAnnotations.entries.single.type, 7);
    expect(decodedAnnotations.entries.single.payload, [42]);
  });
}
