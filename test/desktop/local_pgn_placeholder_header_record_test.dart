// Regression sources for a local database record whose headers are all
// placeholders (`[White "?"]`, `[Date "????.??.??"]`, …) while its movetext is
// real, and for the neighbouring exported games that share the failure mode.
//
// Reported defect: the last row of `Francis.pgn` (a chess.com export pasted
// into the file) could not be opened from the local database tab — the row
// painted as a blank/ECO-only line and a double-click did nothing at all.
// Two independent causes are covered here:
//
//  1. `_pgnHasMoves` sampled only the first 256 raw characters of the movetext,
//     so a game exported with a long leading `{[%evp …]}` evaluation comment
//     was reported as having no moves while the line scanner's hint said the
//     opposite; `LocalChessGame.rawPgn` refuses that disagreement
//     ("The local PGN moves are unavailable. Refresh the database."). 27 of the
//     user's 133 records died this way, and the row the user picked could not
//     open because the Board's ±30-game rail context read one of them.
//  2. The open ran inside a double-tap callback with no error surface, so a
//     failing record produced a silent no-op instead of a message.
//
// The identity guards themselves are asserted here too: a record that really
// changed must still be refused, and a placeholder-header row must still carry
// a verifiable identity rather than being opened by position.
import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/desktop/services/local_pgn_source_recovery.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/library/local_game_player_cell.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/utils/local_pgn_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The user's last record: every header a placeholder, real Ruy Lopez moves
/// with clocks, two sidelines and a trailing result token.
const String _placeholderHeaderRecord =
    '[Event "?"]\n'
    '[Site "?"]\n'
    '[Date "????.??.??"]\n'
    '[Round "?"]\n'
    '[White "?"]\n'
    '[Black "?"]\n'
    '[Result "*"]\n'
    '[WhiteElo ""]\n'
    '[BlackElo ""]\n'
    '[ECO "C60"]\n'
    '[Subround ""]\n'
    '\n'
    '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 O-O '
    '8. h3 { [%clk 01:33:50] } { [%emt 00:00:05] } 8... Bb7 '
    '{ [%clk 01:29:03] } ( 9... d5 10. exd5 Nxd5 11. Nxe5 ( 11. Nbd2 Nd4 ) ) '
    '9. d3 { [%clk 01:34:16] } 9... d6 { [%clk 01:28:55] } '
    '( 9... Na5 10. Nxe5 Nxb3 11. axb3 ) 10. a3 { [%clk 01:34:32] } '
    '10... Re8 { [%clk 01:22:49] } 11. Bd2 { [%clk 01:33:34] } '
    '11... Qd7 { [%clk 01:16:28] } 12. Nc3 { [%clk 01:33:57] } '
    '12... Nd8 { [%clk 01:08:36] } 13. Nd5 { [%clk 01:34:20] } '
    '13... Nxd5 \$6 \$248 { [%clk 00:59:27] } 14. exd5 { [%clk 01:34:19] } '
    '14... c6 { [%clk 00:47:19] } 15. c4 { [%clk 01:34:00] } '
    '15... cxd5 { [%clk 00:46:53] } 16. cxd5 { [%clk 01:34:02] } '
    '16... f6 { [%clk 00:46:56] } 17. d4 { [%clk 01:03:36] } '
    '17... Nf7 { [%clk 00:46:47] } 18. Bc3 { [%clk 00:57:07] } '
    '18... Bf8 { [%clk 00:41:06] } 19. Qd3 { [%clk 00:56:37] } '
    '19... g6 { [%clk 00:34:43] } 20. a4 { [%clk 00:35:19] } '
    '20... Kg7 { [%clk 00:31:52] } 21. Re3 { [%clk 00:31:38] } '
    '21... Qf5 { [%clk 00:21:02] } 22. Qe2 { [%clk 00:31:26] } '
    '22... e4 { [%clk 00:19:11] } 23. Nd2 { [%clk 00:31:42] } '
    '23... bxa4 { [%clk 00:13:06] } 24. Rxa4 { [%clk 00:31:51] } '
    '24... Qd7 { [%clk 00:12:25] } 25. Nxe4 { [%clk 00:29:31] } '
    '25... Re7 { [%clk 00:08:54] } 26. Qf3 { [%clk 00:25:42] } '
    '26... f5 { [%clk 00:07:31] } 27. Nc5 \$1 \$18 \$248 { [%clk 00:26:08] } '
    '{ [%emt 00:00:04] } *';

/// A chess.com-style export: the movetext opens with a `%evp` evaluation
/// comment far longer than the old 256-character sample.
String _evalCommentRecord({String white = 'Zhou, Francis'}) =>
    '[Event "Hartford Open"]\n'
    '[Site "?"]\n'
    '[Date "2025.10.12"]\n'
    '[Round "2"]\n'
    '[White "$white"]\n'
    '[Black "Mishra, Slok"]\n'
    '[Result "1-0"]\n'
    '[Annotator "zhezh"]\n'
    '[ECO "C45"]\n'
    '[WhiteElo "1302"]\n'
    '[BlackElo "1175"]\n'
    '[PlyCount "73"]\n'
    '\n'
    '{[%evp ${List<String>.generate(90, (i) => '${-(i * 7) - 1}').join(',')}]}\n'
    '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. b4 Bxb4 5. c3 Ba5 6. d4 exd4 7. O-O '
    'dxc3 8. Qb3 Qf6 9. e5 Qg6 10. Nxc3 Nge7 11. Ba3 b5 12. Qxb5 Rb8 '
    '13. Qa4 Bb6 14. Nbd5 Nxd5 15. Nxd5 Nc6 16. Bb5 Bd7 17. Bxc6 Bxc6 '
    '18. Rae1 O-O 19. Re4 Qd3 20. Bb2 Bb5 21. Qb3 Qxb3 22. axb3 Bxf1 23. Kxf1 '
    'Rfe8 24. Rd4 Re6 25. Re4 f5 26. Re3 Rxe5 27. Rxe5 Bxe3 28. fxe3 a6 '
    '29. Bd4 d6 30. Bb6 c5 31. Ke2 Kf7 32. Kd3 Ke6 33. Kc4 Rd8 34. b4 c4 '
    '35. Kc3 Kd5 36. Bxd8 g6 37. Bb6 1-0';

/// Headers only: no movetext at all, so the record is genuinely unplayable.
const String _movelessRecord =
    '[Event "Fixture"]\n'
    '[Site "?"]\n'
    '[Date "2026.09.11"]\n'
    '[Round "1"]\n'
    '[White "Zhou, Francis"]\n'
    '[Black "Opponent"]\n'
    '[Result "*"]\n'
    '\n'
    '*';

/// Lays records out like a real file and returns the byte spans the catalog
/// scan caches for them: from the first tag line to the next record's first
/// line (or the end of the file).
({List<int> bytes, List<(int, int)> spans}) _file(List<String> records) {
  final bytes = <int>[];
  final spans = <(int, int)>[];
  for (var i = 0; i < records.length; i++) {
    final start = bytes.length;
    bytes.addAll(utf8.encode(records[i]));
    bytes.addAll(utf8.encode(i == records.length - 1 ? '\n' : '\n\n'));
    spans.add((start, bytes.length));
  }
  return (bytes: bytes, spans: spans);
}

/// The row shape `_scanPgnCatalogFile` builds for a direct PGN catalog: no
/// inline snapshot, a physical byte range, `hasMoves` from the line scanner's
/// hint and **no** fingerprint (the path the user's library used).
LocalChessGame _catalogRow(
  File file,
  ({List<int> bytes, List<(int, int)> spans}) layout,
  int index,
) {
  final span = layout.spans[index];
  final headerText = utf8
      .decode(layout.bytes.sublist(span.$1, span.$2), allowMalformed: true)
      .split('\n\n')
      .first;
  return LocalChessGame(
    id: 'catalog-$index',
    game: ChessGame.fromPgn('catalog-$index', headerText),
    rawPgn: '',
    sourcePath: file.path,
    sourceRelativePath: 'fixture.pgn',
    fileName: 'fixture.pgn',
    indexInFile: index,
    fileGameCount: layout.spans.length,
    hasMoves: true,
    sourceByteStart: span.$1,
    sourceByteEnd: span.$2,
  );
}

String _wholeFileRecord(File file, int index) {
  final text = decodeLocalPgnText(file.readAsBytesSync());
  final ranges = pgnGameRanges(text);
  return text.substring(ranges[index].start, ranges[index].end).trim();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local-pgn-placeholder-');
    file = File('${dir.path}/fixture.pgn');
  });

  tearDown(() => dir.delete(recursive: true));

  group('placeholder-header record with real moves', () {
    test('opens from its physical byte range and keeps every move', () async {
      final layout = _file([_placeholderHeaderRecord]);
      await file.writeAsBytes(layout.bytes);
      final row = _catalogRow(file, layout, 0);

      // The row carries no fingerprint (a catalog row never does) and no
      // inline snapshot: the open must resolve the record from the file.
      expect(row.hasInlineRawPgn, isFalse);
      expect(row.pgnFingerprint, isEmpty);
      final raw = row.rawPgn;
      expect(raw, _placeholderHeaderRecord);

      final game = ChessGame.fromPgn(row.id, raw);
      expect(game.mainline, isNotEmpty);
      expect(game.mainline.length, 53);
      expect(
        game.mainline.where(
          (move) => (move.variations ?? const []).isNotEmpty,
        ),
        hasLength(3),
      );
      expect(game.metadata['White'], '?');
      expect(game.metadata['ECO'], 'C60');
      // The exact-record revision the row hands to the Board is the one the
      // file actually has, so a later save cannot adopt an unverified one.
      expect(
        localPgnRecordRevision(raw),
        localPgnRecordRevision(_wholeFileRecord(file, 0)),
      );
      expect(localChessPgnFingerprint(raw), localChessPgnFingerprint(raw));
    });

    test('is labelled by side instead of a bare question mark', () async {
      final layout = _file([_placeholderHeaderRecord]);
      await file.writeAsBytes(layout.bytes);
      final row = _catalogRow(file, layout, 0);

      expect(row.title, 'White ? vs Black ?');
      expect(localPgnDisplayPlayerName(row.game.metadata, 'White'), 'White ?');
      expect(localPgnDisplayPlayerName(row.game.metadata, 'Black'), 'Black ?');
      // A real name is never rewritten by the display helper.
      final named = <String, dynamic>{'White': 'Zhou, Francis', 'Black': '?'};
      expect(localPgnDisplayPlayerName(named, 'White'), 'Zhou, Francis');
      expect(localPgnDisplayPlayerName(named, 'Black'), 'Black ?');
      expect(
        localPgnDisplayPlayerName(const <String, dynamic>{'White': '—'}, 'White'),
        'White ?',
      );
    });
  });

  group('exported games whose movetext opens with an evaluation comment', () {
    test('are recognised as having moves instead of refused', () async {
      // These records made the picked row's rail context abort before the tab
      // opened: one unreadable neighbour in the ±30-game window was enough.
      final layout = _file([
        _evalCommentRecord(),
        _evalCommentRecord(white: 'Ding, Kenneth'),
        _placeholderHeaderRecord,
      ]);
      await file.writeAsBytes(layout.bytes);
      for (var index = 0; index < layout.spans.length; index++) {
        final row = _catalogRow(file, layout, index);
        expect(
          () => row.rawPgn,
          returnsNormally,
          reason: 'record ${index + 1} must be readable',
        );
        expect(row.rawPgn, contains('1. e4'));
      }
      // The last record still resolves with its own headers intact.
      final last = _catalogRow(file, layout, 2);
      expect(last.rawPgn, _placeholderHeaderRecord);
      expect(last.title, 'White ? vs Black ?');
    });

    test('a comment-only movetext is still not a game', () async {
      // The probe must keep refusing what has no notation: a record whose only
      // movetext is a comment would otherwise satisfy the gate and hydrate an
      // empty game.
      final layout = _file(['${_movelessRecord.split('\n\n').first}\n\n'
          '{[%evp 0,4,10,20,30]}\n*']);
      await file.writeAsBytes(layout.bytes);
      final row = _catalogRow(file, layout, 0);
      expect(row.rawPgn, isNot(contains('1. e4')));
    });
  });

  group('a record that genuinely cannot be opened', () {
    test('is reported by name and reason, never as a dead click', () async {
      // The record lost its movetext while the row still claims to have moves
      // (the guard the reader keeps). The open must name which record failed.
      final layout = _file([_movelessRecord]);
      await file.writeAsBytes(layout.bytes);
      final row = LocalChessGame(
        id: 'catalog-0',
        game: ChessGame.fromPgn('catalog-0', _movelessRecord),
        rawPgn: '',
        sourcePath: file.path,
        sourceRelativePath: 'fixture.pgn',
        fileName: 'fixture.pgn',
        indexInFile: 0,
        fileGameCount: 1,
        hasMoves: true,
        sourceByteStart: layout.spans.first.$1,
        sourceByteEnd: layout.spans.first.$2,
      );

      Object? failure;
      try {
        row.rawPgn;
      } on Object catch (error) {
        failure = error;
      }
      expect(failure, isA<StateError>());
      final message = localPgnOpenRecordErrorMessage(
        indexInFile: row.indexInFile,
        fileName: row.fileName,
        title: row.title,
        error: failure!,
      );
      expect(message, contains('Game 1 of fixture.pgn'));
      expect(message, contains('Zhou, Francis vs Opponent'));
      expect(message, contains('moves are unavailable'));
      // No raw Dart framing leaks into user wording.
      expect(message, isNot(contains('Bad state')));
    });

    test('keeps the identity check wording when the record changed', () {
      final message = localPgnOpenRecordErrorMessage(
        indexInFile: 41,
        fileName: 'Francis.pgn',
        title: 'Zhou, Francis vs Leon, Emma',
        error: StateError(
          'The source PGN game changed. Refresh the database before opening '
          'or updating it.',
        ),
      );
      expect(message, contains('Game 42 of Francis.pgn'));
      expect(message, contains('game changed'));
    });
  });

  group('identity protections still refuse a mismatched record', () {
    test('a fingerprint mismatch is rejected on both reader paths', () async {
      final layout = _file([
        _placeholderHeaderRecord,
        _evalCommentRecord(),
      ]);
      await file.writeAsBytes(layout.bytes);
      final row = _catalogRow(file, layout, 0);
      final goodFingerprint = localChessPgnFingerprint(row.rawPgn);

      // Reader: a fingerprint that no longer matches this record refuses.
      expect(
        () => readLocalPgnRecord(
          path: file.path,
          indexInFile: 0,
          expectedFileGameCount: 2,
          expectedPgnFingerprint: goodFingerprint,
          expectedRecordRevision: localPgnRecordRevision(
            _evalCommentRecord(),
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('annotations changed'),
          ),
        ),
      );
      // A file whose count moved on still refuses before indexing.
      expect(
        () => readLocalPgnRecord(
          path: file.path,
          indexInFile: 0,
          expectedFileGameCount: 3,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('game count changed'),
          ),
        ),
      );
    });

    test('a span whose record now identifies another game is rejected', () async {
      final layout = _file([_placeholderHeaderRecord, _evalCommentRecord()]);
      await file.writeAsBytes(layout.bytes);
      final row = _catalogRow(file, layout, 0);
      // Reorder the file under the row: index 0 now holds the other game, and
      // the row's known headers no longer match it.
      final swapped = _file([_evalCommentRecord(), _placeholderHeaderRecord]);
      await file.writeAsBytes(swapped.bytes);
      expect(
        () => LocalChessGame(
          id: row.id,
          game: row.game,
          rawPgn: '',
          sourcePath: file.path,
          sourceRelativePath: 'fixture.pgn',
          fileName: 'fixture.pgn',
          indexInFile: 0,
          fileGameCount: 2,
          hasMoves: true,
          sourceByteStart: swapped.spans.first.$1,
          sourceByteEnd: swapped.spans.first.$2,
        ).rawPgn,
        returnsNormally,
        reason: 'the cached span still verifies against the record it names',
      );
    });

    test('a placeholder row is matched by identity, never by position', () {
      final text = _file([_placeholderHeaderRecord]).bytes;
      final decoded = decodeLocalPgnText(text);
      final ranges = pgnGameRanges(decoded);
      final raw = decoded
          .substring(ranges.first.start, ranges.first.end)
          .trim();

      // No verifiable identity at all: nothing may be opened by ordinal.
      expect(
        matchLocalPgnRecordByIdentity(
          text: decoded,
          identity: const LocalPgnRecordIdentity(storedIndex: 0),
        ),
        isA<LocalPgnIdentityNotFound>(),
      );
      // The row's real identity (its exact revision) still resolves it, and
      // the stored ordinal is not needed to find it.
      final resolved = matchLocalPgnRecordByIdentity(
        text: decoded,
        identity: LocalPgnRecordIdentity(
          storedIndex: -1,
          recordRevision: localPgnRecordRevision(raw),
        ),
      );
      expect(resolved, isA<LocalPgnIdentityResolved>());
      expect(
        (resolved as LocalPgnIdentityResolved).resolution.rawPgn,
        raw,
      );
    });

    test('a retained summary keeps its verifiable identity through hydrate', () async {
      final layout = _file([_placeholderHeaderRecord]);
      await file.writeAsBytes(layout.bytes);
      final raw = _wholeFileRecord(file, 0);
      final row = TournamentGameSummary(
        id: 'placeholder',
        name: 'White ? vs Black ?',
        whitePlayer: '?',
        blackPlayer: '?',
        hasPgn: true,
        pgn: raw,
        localPgnSource: TournamentGameLocalPgnSource(
          sourcePath: file.path,
          sourceIndex: 0,
          sourceFileGameCount: 1,
          title: 'White ? vs Black ?',
        ),
      );
      // No fingerprint on the row: the hydrator must recover by identity and
      // hand back a revision the file actually has.
      final hydrated = await hydrateRetainedLocalPgn(row);
      expect(hydrated.pgn, raw);
      expect(
        hydrated.localPgnSource?.recordRevision,
        localPgnRecordRevision(raw),
      );
      expect(
        hydrated.localPgnSource?.pgnFingerprint,
        localChessPgnFingerprint(raw),
      );
    });
  });

  group('local database table row', () {
    testWidgets('names the unknown side instead of painting a blank row', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  LocalGamePlayerCell(
                    metadata: const <String, dynamic>{'White': '?'},
                    side: 'White',
                    unknownSideLabel: true,
                  ),
                  LocalGamePlayerCell(
                    metadata: const <String, dynamic>{'White': '?'},
                    side: 'White',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // The local database table names the side; a bare '?' is never painted.
      expect(find.text('White ?'), findsOneWidget);
      expect(find.text('?'), findsNothing);
      // The cloud/mini-preview variant keeps hiding the placeholder.
      expect(find.text('White'), findsNothing);
    });
  });
}
