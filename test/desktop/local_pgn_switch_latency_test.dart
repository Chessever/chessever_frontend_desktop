import 'dart:io';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = String.fromEnvironment('SWITCH_PGN');
  test(
    'actual Piorun record retains physical count without multi-pass scan',
    () async {
      final watch = Stopwatch()..start();
      final pgn = await readLocalPgnRecordInBackground(
        path: source,
        indexInFile: 88,
        expectedFileGameCount: 80386,
      );
      expect(pgn, contains('[White "Piorun, Kacper"]'));
      expect(pgn, contains('[Black "Nakamura, Hikaru"]'));
      expect(
        watch.elapsedMilliseconds,
        lessThan(5000),
        reason: 'Selected-record read must not decode/re-encode/map all 228MB',
      );
      watch.reset();
      final previous = await readLocalPgnRecordInBackground(
        path: source,
        indexInFile: 3,
        expectedFileGameCount: 80386,
      );
      expect(previous, contains('[Black "Praggnanandhaa R"]'));
      expect(
        watch.elapsedMilliseconds,
        lessThan(1000),
        reason: 'Unchanged source must not repeat the full boundary scan',
      );
    },
    skip: source.isEmpty || !File(source).existsSync(),
  );
}
