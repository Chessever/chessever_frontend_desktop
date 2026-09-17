import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/desktop/services/local_pgn_source_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

String _game(String white, {String comment = '', String tail = ''}) =>
    '[Event "Fixture"]\n[Site "?"]\n[Date "2026.09.11"]\n[Round "1"]\n'
    '[White "$white"]\n[Black "Opponent"]\n[Result "*"]\n\n'
    '1. e4 ${comment.isEmpty ? '' : '$comment '}e5 2. Nf3 Nc6 '
    '${tail.isEmpty ? '' : '$tail '}*';

String _layout(List<String> records) => '${records.join('\n\n')}\n';

const String _fixtureName = 'fixture.pgn';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    LocalPgnSourceRecovery.debugResetRecoveryState();
    dir = await Directory.systemTemp.createTemp('pgn-recovery-');
    file = File('${dir.path}/$_fixtureName');
  });

  tearDown(() async {
    LocalPgnSourceRecovery.debugResetRecoveryState();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('matchLocalPgnRecordByIdentity', () {
    test('an appended game shifts the ordinal and the row still resolves', () {
      final row = _game('Row');
      final target = _game('Target');
      final identity = LocalPgnRecordIdentity(
        storedIndex: 1,
        mainlineFingerprint: localChessPgnFingerprint(target),
      );

      final grown = _layout([_game('Inserted'), row, target]);
      final resolved =
          matchLocalPgnRecordByIdentity(text: grown, identity: identity)
              as LocalPgnIdentityResolved;
      expect(resolved.resolution.indexInFile, 2);
      expect(resolved.resolution.fileGameCount, 3);
      expect(resolved.resolution.rawPgn, target.trim());
      expect(
        resolved.resolution.recordRevision,
        localPgnRecordRevision(target),
      );

      // The same identity still resolves at its original ordinal when the file
      // has not moved at all.
      final unchanged =
          matchLocalPgnRecordByIdentity(
                text: _layout([row, target]),
                identity: identity,
              )
              as LocalPgnIdentityResolved;
      expect(unchanged.resolution.indexInFile, 1);
    });

    test('an annotation-only edit keeps the mainline match and adopts the new '
        'revision', () {
      final target = _game('Target', comment: '{before}');
      final identity = LocalPgnRecordIdentity(
        storedIndex: 0,
        recordRevision: localPgnRecordRevision(target),
        mainlineFingerprint: localChessPgnFingerprint(target),
      );

      final annotated = _game('Target', comment: '{a much longer annotation}');
      expect(
        localChessPgnFingerprint(annotated),
        localChessPgnFingerprint(target),
      );
      expect(
        localPgnRecordRevision(annotated),
        isNot(localPgnRecordRevision(target)),
      );

      final resolved =
          matchLocalPgnRecordByIdentity(
                text: _layout([annotated]),
                identity: identity,
              )
              as LocalPgnIdentityResolved;
      expect(resolved.resolution.indexInFile, 0);
      expect(resolved.resolution.rawPgn, annotated.trim());
      expect(
        resolved.resolution.recordRevision,
        localPgnRecordRevision(annotated),
      );
    });

    test('a row with only a fingerprint resolves regardless of surrounding '
        'ordinals', () {
      final target = _game('Target', tail: 'Bb5');
      final identity = LocalPgnRecordIdentity(
        storedIndex: 9,
        mainlineFingerprint: localChessPgnFingerprint(target),
      );

      final resolved =
          matchLocalPgnRecordByIdentity(
                text: _layout([_game('A'), _game('B'), target]),
                identity: identity,
              )
              as LocalPgnIdentityResolved;
      expect(resolved.resolution.indexInFile, 2);
    });

    test('a row with no fingerprint falls back to header identity', () {
      final identity = const LocalPgnRecordIdentity(
        storedIndex: 0,
        white: 'Target',
        black: 'Opponent',
        round: '1',
        result: '*',
      );

      final resolved =
          matchLocalPgnRecordByIdentity(
                text: _layout([_game('Row'), _game('Target')]),
                identity: identity,
              )
              as LocalPgnIdentityResolved;
      expect(resolved.resolution.indexInFile, 1);
    });

    test('a duplicate record still opens at the stored ordinal', () {
      final target = _game('Target');
      final identity = LocalPgnRecordIdentity(
        storedIndex: 1,
        mainlineFingerprint: localChessPgnFingerprint(target),
      );

      final resolved =
          matchLocalPgnRecordByIdentity(
                text: _layout([target, target]),
                identity: identity,
              )
              as LocalPgnIdentityResolved;
      expect(resolved.resolution.indexInFile, 1);
    });

    test('duplicated headers with different moves refuse instead of guessing',
        () {
      const identity = LocalPgnRecordIdentity(
        storedIndex: 5,
        white: 'Target',
        black: 'Opponent',
        round: '1',
        result: '*',
      );

      final outcome = matchLocalPgnRecordByIdentity(
        text: _layout([
          _game('Target', tail: 'Bb5'),
          _game('Target', tail: 'd4'),
        ]),
        identity: identity,
      );
      expect(outcome, isA<LocalPgnIdentityAmbiguous>());
      expect((outcome as LocalPgnIdentityAmbiguous).matchCount, 2);
    });

    test('a game that is no longer in the file is reported as not found', () {
      final identity = LocalPgnRecordIdentity(
        storedIndex: 0,
        mainlineFingerprint: localChessPgnFingerprint(_game('Target')),
      );

      final outcome = matchLocalPgnRecordByIdentity(
        text: _layout([_game('Other')]),
        identity: identity,
      );
      expect(outcome, isA<LocalPgnIdentityNotFound>());
    });

    test('a row with no identity at all never resolves by position', () {
      final outcome = matchLocalPgnRecordByIdentity(
        text: _layout([_game('Target'), _game('Other')]),
        identity: const LocalPgnRecordIdentity(storedIndex: 0),
      );
      expect(outcome, isA<LocalPgnIdentityNotFound>());
    });
  });

  group('LocalPgnSourceRecovery', () {
    test('re-indexes a changed source and returns the fresh coordinates',
        () async {
      final row = _game('Row');
      final target = _game('Target');
      await file.writeAsString(_layout([row, target]));
      final identity = LocalPgnRecordIdentity(
        storedIndex: 1,
        mainlineFingerprint: localChessPgnFingerprint(target),
      );

      // The game was appended before the target after the row was captured.
      await file.writeAsString(_layout([_game('Inserted'), row, target]));

      final rescans = <String>[];
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (sourcePath) async {
          rescans.add(sourcePath);
          return true;
        },
      );

      final resolution = await recovery.recover(
        sourcePath: file.path,
        identity: identity,
      );
      expect(resolution.indexInFile, 2);
      expect(resolution.fileGameCount, 3);
      expect(resolution.rawPgn, target.trim());
      expect(
        resolution.mainlineFingerprint,
        localChessPgnFingerprint(target),
      );
      expect(rescans, <String>[file.path]);
    });

    test('a second open of the same file state does not scan again', () async {
      final target = _game('Target');
      await file.writeAsString(_layout([_game('Inserted'), target]));
      final identity = LocalPgnRecordIdentity(
        storedIndex: 0,
        white: 'Target',
        black: 'Opponent',
      );

      var rescans = 0;
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async {
          rescans++;
          return true;
        },
      );
      await recovery.recover(sourcePath: file.path, identity: identity);
      await recovery.recover(sourcePath: file.path, identity: identity);
      expect(rescans, 1);
    });

    test('concurrent opens coalesce into a single rescan', () async {
      final gate = Completer<void>();
      var rescans = 0;
      await file.writeAsString(_layout([_game('Row'), _game('Target')]));
      final identity =
          const LocalPgnRecordIdentity(
            storedIndex: 0,
            white: 'Target',
            black: 'Opponent',
          );
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async {
          rescans++;
          await gate.future;
          return true;
        },
      );

      final first = recovery.recover(sourcePath: file.path, identity: identity);
      final second = recovery.recover(sourcePath: file.path, identity: identity);
      gate.complete();
      final results = await Future.wait(<Future<LocalPgnIdentityResolution>>[
        first,
        second,
      ]);
      expect(rescans, 1);
      expect(results.first.indexInFile, 1);
      expect(results.last.indexInFile, 1);
    });

    test('concurrent opens of different rows keep their own games', () async {
      final row = _game('Row');
      final target = _game('Target');
      await file.writeAsString(_layout([row, target]));
      var rescans = 0;
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async {
          rescans++;
          return true;
        },
      );

      // Only the rescan is shared per source: each row must still resolve its
      // own identity, never join another row's resolution.
      final results = await Future.wait(<Future<LocalPgnIdentityResolution>>[
        recovery.recover(
          sourcePath: file.path,
          identity: LocalPgnRecordIdentity(
            storedIndex: 0,
            mainlineFingerprint: localChessPgnFingerprint(row),
          ),
        ),
        recovery.recover(
          sourcePath: file.path,
          identity: LocalPgnRecordIdentity(
            storedIndex: 1,
            mainlineFingerprint: localChessPgnFingerprint(target),
          ),
        ),
      ]);
      expect(results.first.indexInFile, 0);
      expect(results.first.rawPgn, row.trim());
      expect(results.last.indexInFile, 1);
      expect(results.last.rawPgn, target.trim());
      expect(rescans, 1);
    });

    test('an empty source path reports the source as unreadable', () async {
      var rescans = 0;
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async {
          rescans++;
          return true;
        },
      );
      await expectLater(
        recovery.recover(
          sourcePath: '   ',
          identity: const LocalPgnRecordIdentity(
            storedIndex: 0,
            white: 'Target',
          ),
        ),
        throwsA(
          isA<LocalPgnGameUnavailableException>().having(
            (error) => error.failure,
            'failure',
            LocalPgnRecoveryFailure.sourceUnreadable,
          ),
        ),
      );
      expect(rescans, 0);
    });

    test('a row with no identity refuses without touching the disk', () async {
      await file.writeAsString(_layout([_game('Target')]));
      var rescans = 0;
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async {
          rescans++;
          return true;
        },
      );
      await expectLater(
        recovery.recover(
          sourcePath: file.path,
          identity: const LocalPgnRecordIdentity(storedIndex: 0),
        ),
        throwsA(
          isA<LocalPgnGameUnavailableException>().having(
            (error) => error.failure,
            'failure',
            LocalPgnRecoveryFailure.noIdentity,
          ),
        ),
      );
      expect(rescans, 0);
    });

    test('a change landing during the rescan re-resolves the ordinal', () async {
      final row = _game('Row');
      final target = _game('Target');
      await file.writeAsString(_layout([row, target]));
      final identity = LocalPgnRecordIdentity(
        storedIndex: 1,
        mainlineFingerprint: localChessPgnFingerprint(target),
      );

      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async {
          // Another writer appends a game ahead of the target while the cache
          // is being rebuilt.
          await file.writeAsString(_layout([_game('Inserted'), row, target]));
          return true;
        },
      );

      final resolution = await recovery.recover(
        sourcePath: file.path,
        identity: identity,
      );
      expect(resolution.indexInFile, 2);
      expect(resolution.fileGameCount, 3);
      expect(resolution.rawPgn, target.trim());
    });

    test('a game that is genuinely gone reports human wording', () async {
      await file.writeAsString(_layout([_game('Other')]));
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async => true,
      );

      final identity = LocalPgnRecordIdentity(
        storedIndex: 1,
        mainlineFingerprint: localChessPgnFingerprint(_game('Target')),
      );
      await expectLater(
        recovery.recover(sourcePath: file.path, identity: identity),
        throwsA(
          isA<LocalPgnGameUnavailableException>()
              .having(
                (error) => error.failure,
                'failure',
                LocalPgnRecoveryFailure.gameMissing,
              )
              .having(
                (error) => error.message,
                'message',
                contains(_fixtureName),
              )
              .having(
                (error) => error.toString(),
                'toString',
                isNot(contains('Bad state')),
              ),
        ),
      );
    });

    test('an ambiguous identity refuses to open an unproven record', () async {
      await file.writeAsString(
        _layout([
          _game('Target', tail: 'Bb5'),
          _game('Target', tail: 'd4'),
        ]),
      );
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async => true,
      );

      await expectLater(
        recovery.recover(
          sourcePath: file.path,
          identity: const LocalPgnRecordIdentity(
            storedIndex: 5,
            white: 'Target',
            black: 'Opponent',
          ),
        ),
        throwsA(
          isA<LocalPgnGameUnavailableException>().having(
            (error) => error.failure,
            'failure',
            LocalPgnRecoveryFailure.ambiguousIdentity,
          ),
        ),
      );
    });

    test('an unreadable source is reported without a raw StateError', () async {
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async => true,
      );
      final missing = File('${dir.path}/missing.pgn');
      await expectLater(
        recovery.recover(
          sourcePath: missing.path,
          identity: const LocalPgnRecordIdentity(
            storedIndex: 0,
            white: 'Target',
            black: 'Opponent',
          ),
        ),
        throwsA(
          isA<LocalPgnGameUnavailableException>().having(
            (error) => error.failure,
            'failure',
            LocalPgnRecoveryFailure.sourceUnreadable,
          ),
        ),
      );
    });

    test('a failing rescan never fakes a recovery', () async {
      final target = _game('Target');
      await file.writeAsString(_layout([target]));
      final recovery = LocalPgnSourceRecovery(
        reindexSource: (_) async => false,
      );

      // The identity is still in the file, so the open proceeds even though the
      // cache could not be rebuilt.
      final resolution = await recovery.recover(
        sourcePath: file.path,
        identity: LocalPgnRecordIdentity(
          storedIndex: 0,
          mainlineFingerprint: localChessPgnFingerprint(target),
        ),
      );
      expect(resolution.indexInFile, 0);

      // A game that is missing stays missing.
      await expectLater(
        recovery.recover(
          sourcePath: file.path,
          identity: LocalPgnRecordIdentity(
            storedIndex: 0,
            mainlineFingerprint: localChessPgnFingerprint(_game('Gone')),
          ),
        ),
        throwsA(isA<LocalPgnGameUnavailableException>()),
      );
    });
  });

  group('localPgnOpenErrorMessage', () {
    test('strips the raw StateError framing users reported', () {
      expect(
        localPgnOpenErrorMessage(
          StateError('Refresh the database before opening this game.'),
        ),
        'Refresh the database before opening this game.',
      );
      expect(
        localPgnOpenErrorMessage(
          const LocalPgnGameUnavailableException(
            sourcePath: r'C:\databases\Lesson Plans.pgn',
            failure: LocalPgnRecoveryFailure.gameMissing,
          ),
        ),
        contains('Lesson Plans.pgn'),
      );
      expect(
        localPgnOpenErrorMessage(
          const LocalPgnGameUnavailableException(
            sourcePath: '/databases/Lesson Plans.pgn',
            failure: LocalPgnRecoveryFailure.gameMissing,
          ),
        ),
        contains('no longer in Lesson Plans.pgn'),
      );
    });
  });
}
