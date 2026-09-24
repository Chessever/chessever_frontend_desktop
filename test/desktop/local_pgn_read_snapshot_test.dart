import 'dart:convert';
import 'dart:io';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';

String game(String who, String note) =>
    '[Event "Test"]\r\n[White "$who"]\r\n[Black "B"]\r\n[Result "*"]\r\n\r\n1. e4 {$note} e5 *';
void main() {
  test(
    'read worker can retire idle and restart without losing requests',
    () async {
      final dir = await Directory.systemTemp.createTemp('idle-pgn-reader-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/source.pgn');
      await file.writeAsString(game('Before idle', 'x'));
      expect(
        await readLocalPgnRecordInBackground(path: file.path, indexInFile: 0),
        contains('Before idle'),
      );
      await Future<void>.delayed(const Duration(seconds: 31));
      await file.writeAsString(game('After idle', 'y'));
      final results = await Future.wait([
        for (var i = 0; i < 3; i++)
          readLocalPgnRecordInBackground(path: file.path, indexInFile: 0),
      ]);
      expect(results, everyElement(contains('After idle')));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'cached boundary proof requires every byte, even same size and mtime',
    () async {
      final dir = await Directory.systemTemp.createTemp('exact-snapshot-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/source.pgn');
      final a = game('Müller ♞', 'AAAA');
      final b = game('Piorun', 'BBBB');
      await file.writeAsString('\ufeff$a\r\n\r\n$b\r\n');
      final stamp = await file.lastModified();
      final first = await readLocalPgnRecordInBackground(
        path: file.path,
        indexInFile: 1,
        expectedFileGameCount: 2,
      );
      expect(first, b);
      final revised = game('Piorun', 'CCCC');
      await file.writeAsString('\ufeff$a\r\n\r\n$revised\r\n');
      await file.setLastModified(stamp);
      expect(
        await readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
          expectedFileGameCount: 2,
          expectedPgnFingerprint: localChessPgnFingerprint(b),
        ),
        revised,
      );
      await expectLater(
        readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
          expectedFileGameCount: 2,
          expectedRecordRevision: localPgnRecordRevision(b),
        ),
        throwsStateError,
      );
      // An earlier annotation grows and shifts the selected span.
      final grown = game('Müller ♞', 'a substantially longer comment');
      await file.writeAsString('\ufeff$grown\r\n\r\n$revised\r\n');
      expect(
        await readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
          expectedFileGameCount: 2,
        ),
        revised,
      );
      // Count and identity validation are still checked after snapshot reuse.
      await expectLater(
        readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
          expectedFileGameCount: 3,
        ),
        throwsStateError,
      );
      await expectLater(
        readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
          expectedFileGameCount: 2,
          expectedPgnFingerprint: localChessPgnFingerprint(a),
        ),
        throwsStateError,
      );
      await file.writeAsString(
        '$grown\n\n$revised\n\n${game('Third', 'last')}',
      );
      await expectLater(
        readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
          expectedFileGameCount: 2,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'overlapping reads preserve their own record and error result',
    () async {
      final dir = await Directory.systemTemp.createTemp('parallel-snapshot-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/source.pgn');
      final a = game('A', '{ bracket [Event fake]');
      final b = game('B', 'x');
      // malformed UTF-8 is decoded exactly as on the original synchronous path.
      await file.writeAsBytes([...utf8.encode('$a\n\n$b'), 0xfc]);
      final results = await Future.wait([
        for (final i in [0, 1, 0, 1])
          readLocalPgnRecordInBackground(
            path: file.path,
            indexInFile: i,
            expectedFileGameCount: 2,
          ),
      ]);
      for (var i = 0; i < results.length; i++) {
        expect(
          results[i],
          readLocalPgnRecord(path: file.path, indexInFile: i % 2),
        );
      }
      await file.delete();
      await expectLater(
        readLocalPgnRecordInBackground(path: file.path, indexInFile: 0),
        throwsA(isA<FileSystemException>()),
      );
      await file.writeAsString(game('Restored', 'y'));
      expect(
        await readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 0,
          expectedFileGameCount: 1,
        ),
        contains('Restored'),
      );
    },
  );
}
