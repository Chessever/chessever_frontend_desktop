import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/cbh_conversion_origin.dart';

void main() {
  test(
    'rename intent preserves origin and original hash over edited PGN',
    () async {
      final dir = await Directory.systemTemp.createTemp('cbh_origin_');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/old.pgn');
      await source.writeAsString('user edits');
      final receipt = File('${dir.path}/conversion.json');
      await receipt.writeAsString(
        jsonEncode({
          'pgnFile': 'old.pgn',
          'pgnSha256': 'original-hash',
          'sourceSha256': {'.cbh': 'source-hash'},
        }),
      );
      await prepareCbhCopyRename(source.path, '${dir.path}/new.pgn');
      final saved = jsonDecode(await receipt.readAsString());
      expect(saved['pgnAliases'], ['old.pgn', 'new.pgn']);
      expect(saved['pgnSha256'], 'original-hash');
      expect(await source.readAsString(), 'user edits');
      expect(await File('${dir.path}/new.pgn').exists(), isFalse);
    },
  );
}
