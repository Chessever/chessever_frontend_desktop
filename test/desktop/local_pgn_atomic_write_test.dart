import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/local_pgn_atomic_write.dart';

void main() {
  group('writeLocalPgnAtomically', () {
    test('replaces an existing PGN without leaving a temporary file', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-atomic-pgn-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/database.pgn');
      await file.writeAsString('old');

      await writeLocalPgnAtomically(
        file: file,
        expectedText: 'old',
        nextText: 'new',
      );

      expect(await file.readAsString(), 'new');
      expect(
        dir.listSync().whereType<File>().map((entry) => entry.path),
        isNot(anyElement(endsWith('.tmp'))),
      );
    });

    test('rejects a stale source without changing the current PGN', () async {
      final dir = await Directory.systemTemp.createTemp(
        'chessever-stale-pgn-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/database.pgn');
      await file.writeAsString('external edit');

      expect(
        () => writeLocalPgnAtomically(
          file: file,
          expectedText: 'old snapshot',
          nextText: 'agent edit',
        ),
        throwsA(isA<StateError>()),
      );
      expect(await file.readAsString(), 'external edit');
    });
  });
}
