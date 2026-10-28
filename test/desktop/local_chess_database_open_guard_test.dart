import 'dart:io';

import 'package:chessever/desktop/services/local_chess_database_open_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression sources for the intermittent
/// `Failed to open database at "<path>"` dead-end reported when a player's
/// opening-tree store (`<database>.pgn.cetg`) was being published while the
/// position games table opened it for reading.
void main() {
  group('open failure classification', () {
    test('recognizes the resqlite open-failure wording', () {
      expect(
        isLocalChessDatabaseOpenFailure(
          Exception('Failed to open database at "C:/ws/X.pgn.cetg"'),
        ),
        isTrue,
      );
      expect(
        isLocalChessDatabaseOpenFailure(
          Exception('unable to open database file'),
        ),
        isTrue,
      );
    });

    test('does not classify a closed connection or a real error as an open '
        'failure', () {
      expect(
        isLocalChessDatabaseOpenFailure(Exception('Database is closed.')),
        isFalse,
      );
      expect(
        isLocalChessDatabaseOpenFailure(StateError('bad state')),
        isFalse,
      );
    });

    test('treats an open failure and lock contention as retryable, and a '
        'programming error as not retryable', () {
      expect(
        isRetryableLocalChessDatabaseFailure(
          Exception('Failed to open database at "X.pgn.cetg"'),
        ),
        isTrue,
      );
      expect(
        isRetryableLocalChessDatabaseFailure(Exception('database is locked')),
        isTrue,
      );
      expect(
        isRetryableLocalChessDatabaseFailure(StateError('bad state')),
        isFalse,
      );
    });
  });

  group('bounded retry', () {
    const transient = 'Failed to open database at "C:/ws/X.pgn.cetg"';

    test('retries a transient open failure and returns the handle', () async {
      var calls = 0;
      final result = await openLocalChessResourceWithRetry<String>(
        path: 'C:/ws/X.pgn.cetg',
        operation: LocalChessDatabaseOperation.open,
        open: (path) async {
          calls += 1;
          if (calls <= 2) throw Exception(transient);
          return 'handle';
        },
        pathExists: (path) async => true,
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

      expect(result, 'handle');
      // Two failures, then the successful third attempt: bounded, no spin.
      expect(calls, 3);
    });

    test('surfaces user wording after the retries are spent on a file that is '
        'still present', () async {
      var calls = 0;
      await expectLater(
        openLocalChessResourceWithRetry<String>(
          path: 'C:/ws/CHESSEVER_1_X.pgn.cetg',
          operation: LocalChessDatabaseOperation.open,
          purpose: 'opening-tree game index',
          open: (path) async {
            calls += 1;
            throw Exception(transient);
          },
          pathExists: (path) async => true,
          retryDelays: const <Duration>[Duration.zero, Duration.zero],
        ),
        throwsA(
          isA<LocalChessDatabaseUnavailableException>()
              .having((error) => error.attempts, 'attempts', 3)
              .having((error) => error.retryable, 'retryable', isTrue)
              .having(
                (error) => error.fileName,
                'fileName names the user PGN, not the sidecar',
                'CHESSEVER_1_X.pgn',
              )
              .having(
                (error) => error.message,
                'message is actionable',
                allOf(contains('Retry'), contains('CHESSEVER_1_X.pgn')),
              )
              .having(
                (error) => error.message,
                'message never leaks the raw native string',
                isNot(contains('Failed to open database at')),
              ),
        ),
      );
      expect(calls, 3);
    });

    test('falls back instead of failing when the file vanished mid-open', () async {
      var calls = 0;
      final result = await openLocalChessResourceWithRetry<String>(
        path: 'C:/ws/X.pgn.cetg',
        operation: LocalChessDatabaseOperation.open,
        open: (path) async {
          calls += 1;
          throw Exception(transient);
        },
        pathExists: (path) async => false,
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

      // The caller reuses its existing connection; no retry is spent on a path
      // that is not there.
      expect(result, isNull);
      expect(calls, 1);
    });

    test('a missing file still fails when the caller cannot continue without '
        'it', () async {
      await expectLater(
        openLocalChessResourceWithRetry<String>(
          path: 'C:/ws/X.pgn.cetg',
          operation: LocalChessDatabaseOperation.open,
          absentPolicy: LocalChessDatabaseAbsentPolicy.fail,
          open: (path) async => throw Exception(transient),
          pathExists: (path) async => false,
          retryDelays: const <Duration>[Duration.zero],
        ),
        throwsA(isA<LocalChessDatabaseUnavailableException>()),
      );
    });

    test('never retries or masks an error that is not an open failure', () async {
      var calls = 0;
      await expectLater(
        openLocalChessResourceWithRetry<String>(
          path: 'C:/ws/X.pgn.cetg',
          operation: LocalChessDatabaseOperation.open,
          open: (path) async {
            calls += 1;
            throw StateError('database disk image is malformed');
          },
          pathExists: (path) async => true,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'database disk image is malformed',
          ),
        ),
      );
      expect(calls, 1);
    });
  });

  group('user wording', () {
    test('turns a raw resqlite open failure into an actionable sentence', () {
      final message = localChessDatabaseUserMessage(
        Exception('Failed to open database at "C:/ws/X.pgn.cetg"'),
      );

      expect(message, contains('Retry'));
      expect(message, isNot(contains('Failed to open database at')));
      expect(message, isNot(contains('.cetg')));
    });

    test('keeps the label supplied by the caller', () {
      final message = localChessDatabaseUserMessage(
        const LocalChessDatabaseUnavailableException(
          path: 'C:/ws/X.pgn.cetg',
          operation: LocalChessDatabaseOperation.open,
          attempts: 4,
          label: 'CHESSEVER_1_X.pgn',
        ),
      );

      expect(message, contains('CHESSEVER_1_X.pgn'));
      expect(message, isNot(contains('X.pgn.cetg')));
      expect(message, contains('4 attempts'));
    });

    test('strips the Dart exception-type prefix from other failures', () {
      expect(
        localChessDatabaseUserMessage(StateError('Bad state: nope')),
        'nope',
      );
    });
  });

  group('diagnostic probe', () {
    test('reports existence, size, parent and the SQLite journal version', () async {
      final directory = await Directory.systemTemp.createTemp('ce-open-guard-');
      addTearDown(() => directory.delete(recursive: true));
      final store = File('${directory.path}${Platform.pathSeparator}X.pgn.cetg');
      final bytes = List<int>.filled(4096, 0);
      // SQLite file-format write/read version = 2 means WAL mode.
      bytes[18] = 2;
      bytes[19] = 2;
      await store.writeAsBytes(bytes);

      final probe = await localChessDatabasePathProbe(store.path);

      expect(probe['exists'], isTrue);
      expect(probe['parentExists'], isTrue);
      expect(probe['sizeBytes'], 4096);
      expect(probe['journalWriteVersion'], 2);
      expect(probe['journalReadVersion'], 2);
      expect(probe['walMode'], isTrue);
      expect(probe['osReadable'], isTrue);
    });

    test('reports a missing path without throwing', () async {
      final missing =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'ce-open-guard-missing-${DateTime.now().microsecondsSinceEpoch}'
          '${Platform.pathSeparator}X.pgn.cetg';

      final probe = await localChessDatabasePathProbe(missing);

      expect(probe['exists'], isFalse);
      expect(probe['parentExists'], isFalse);
      expect(probe.containsKey('walMode'), isFalse);
    });
  });

  group('sidecar naming', () {
    test('strips generated sidecar suffixes and staged build names', () {
      const base = 'C:/ws/player/CHESSEVER_1_X.pgn';
      for (final suffix in const <String>['.cetg', '.ceti', '.cetg-wal']) {
        expect(
          LocalChessDatabaseUnavailableException(
            path: '$base$suffix',
            operation: LocalChessDatabaseOperation.open,
            attempts: 1,
          ).fileName,
          'CHESSEVER_1_X.pgn',
          reason: suffix,
        );
      }
      expect(
        const LocalChessDatabaseUnavailableException(
          path: '$base.cetg.build-1234',
          operation: LocalChessDatabaseOperation.open,
          attempts: 1,
        ).fileName,
        'CHESSEVER_1_X.pgn',
      );
    });
  });
}
