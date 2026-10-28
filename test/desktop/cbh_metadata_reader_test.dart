import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/services/cbh_index_reader.dart';
import 'package:chessever/desktop/services/cbh_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('reads names and metadata using Windows-1252', () async {
    final root = await Directory.systemTemp.createTemp('cbh-metadata-');
    addTearDown(() => root.delete(recursive: true));
    final index = Uint8List(92);
    index[2] = 0x2c;
    index[4] = 0x2e;
    index[5] = 1;
    index[9] = 1;
    index[50] = 26;
    final cbh = File(p.join(root.path, 'sample.cbh'));
    await cbh.writeAsBytes(index);

    final player = Uint8List(28 + 67);
    player[28 + 9] = 0x4d; // M
    player[28 + 10] = 0xfc; // ü in Windows-1252
    player[28 + 39] = 0x41; // A
    await File(p.join(root.path, 'sample.cbp')).writeAsBytes(player);
    final tournament = Uint8List(28 + 99);
    tournament[28 + 9] = 0x45; // E
    tournament[28 + 49] = 0x53; // S
    await File(p.join(root.path, 'sample.cbt')).writeAsBytes(tournament);
    await File(
      p.join(root.path, 'sample.cbc'),
    ).writeAsBytes(Uint8List(28 + 62));
    await File(
      p.join(root.path, 'sample.cbs'),
    ).writeAsBytes(Uint8List(28 + 68));
    await File(p.join(root.path, 'sample.cbg')).writeAsBytes(Uint8List(30));
    await File(p.join(root.path, 'sample.cba')).writeAsBytes(Uint8List(26));

    final files = await CbhIndexReader.open(cbh.path);
    final metadata = await CbhMetadataReader(files).read(files.records.single);
    expect(metadata.white, 'Mü, A');
    expect(metadata.black, 'Mü, A');
    expect(metadata.event, 'E');
    expect(metadata.site, 'S');
  });
}
