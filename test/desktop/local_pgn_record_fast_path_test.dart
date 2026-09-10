import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

String _game(String white, {String comment = '', String tail = ''}) =>
    '[Event "Fixture"]\n[Site "?"]\n[Date "2026.09.11"]\n[Round "1"]\n'
    '[White "$white"]\n[Black "Opponent"]\n[Result "*"]\n\n'
    '1. e4 ${comment.isEmpty ? '' : '$comment '}e5 2. Nf3 Nc6 '
    '${tail.isEmpty ? '' : '$tail '}*';

/// `Müller` with the ü as the single Latin-1 byte 0xFC, which is not UTF-8.
List<int> _latin1Game() => <int>[
  ...latin1.encode(
    '[Event "Fixture"]\n[Site "?"]\n[Date "2026.09.11"]\n[Round "1"]\n'
    '[White "M',
  ),
  0xFC,
  ...latin1.encode(
    'ller"]\n[Black "Opponent"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *',
  ),
];

/// Lays records out like a real file and returns the byte spans the import
/// scanner caches for them: from the first tag line to the next record's
/// first line (or the end of the file), blank separator included.
({List<int> bytes, List<(int, int)> spans}) _file(
  List<List<int>> records, {
  bool bom = false,
}) {
  final bytes = <int>[
    if (bom) ...const <int>[0xEF, 0xBB, 0xBF],
  ];
  final spans = <(int, int)>[];
  for (var i = 0; i < records.length; i++) {
    final start = bytes.length;
    bytes
      ..addAll(records[i])
      ..addAll(utf8.encode(i == records.length - 1 ? '\n' : '\n\n'));
    spans.add((start, bytes.length));
  }
  return (bytes: bytes, spans: spans);
}

LocalChessGame _cachedGame(
  File file,
  ({List<int> bytes, List<(int, int)> spans}) layout,
  int index, {
  int? indexInFile,
}) {
  final span = layout.spans[index];
  final raw = decodeLocalPgnText(layout.bytes.sublist(span.$1, span.$2)).trim();
  return LocalChessGame(
    id: 'game-$index',
    game: ChessGame.fromPgn('game-$index', raw),
    // Large databases skip the inline snapshot; every read goes to the file.
    rawPgn: '',
    sourcePath: file.path,
    sourceRelativePath: 'fixture.pgn',
    fileName: 'fixture.pgn',
    indexInFile: indexInFile ?? index,
    fileGameCount: layout.spans.length,
    hasMoves: true,
    pgnFingerprint: localChessPgnFingerprint(raw),
    sourceByteStart: span.$1,
    sourceByteEnd: span.$2,
  );
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local-pgn-fast-path-');
    file = File('${dir.path}/fixture.pgn');
  });

  tearDown(() => dir.delete(recursive: true));

  group('LocalChessGame.rawPgn cached span', () {
    test('serves a verified span without re-resolving the file', () async {
      final layout = _file([utf8.encode(_game('A')), utf8.encode(_game('B'))]);
      await file.writeAsBytes(layout.bytes);
      // An ordinal the slow path cannot satisfy: only the cached span can
      // produce this record, which proves the O(record) path was taken.
      final game = _cachedGame(file, layout, 1, indexInFile: 7);
      expect(game.rawPgn, _game('B'));
    });

    test('accepts the first record behind a UTF-8 BOM', () async {
      final layout = _file([
        utf8.encode(_game('A')),
        utf8.encode(_game('B')),
      ], bom: true);
      await file.writeAsBytes(layout.bytes);
      expect(layout.spans.first.$1, 3);
      final game = _cachedGame(file, layout, 0, indexInFile: 7);
      expect(game.rawPgn, _game('A'));
    });

    test('decodes Latin-1 files the way the import scanner does', () async {
      final layout = _file([_latin1Game(), utf8.encode(_game('B'))]);
      await file.writeAsBytes(layout.bytes);
      final game = _cachedGame(file, layout, 0);
      final raw = game.rawPgn;
      expect(raw, contains('M�ller'));
      // The fingerprint captured at import was computed over the same
      // decoding, so the physical record still verifies on both paths.
      expect(localChessPgnFingerprint(raw), game.pgnFingerprint);
      expect(
        readLocalPgnRecord(
          path: file.path,
          indexInFile: 0,
          expectedPgnFingerprint: game.pgnFingerprint,
        ),
        raw,
      );
    });

    test('re-resolves a span shifted by an edit earlier in the file', () async {
      final layout = _file([utf8.encode(_game('A')), utf8.encode(_game('B'))]);
      await file.writeAsBytes(layout.bytes);
      final game = _cachedGame(file, layout, 1);
      // A longer annotation in game A moves game B further into the file.
      await file.writeAsString(
        '${_game('A', comment: '{a much longer annotation than before}')}\n\n'
        '${_game('B')}\n',
      );
      expect(game.rawPgn, _game('B'));
    });

    test('re-resolves a span an in-record edit truncated', () async {
      const trailing = '{a long trailing comment on the last move}';
      final layout = _file([
        utf8.encode(_game('A', tail: trailing)),
        utf8.encode(_game('B')),
      ]);
      await file.writeAsBytes(layout.bytes);
      final game = _cachedGame(file, layout, 0);
      // Grow game A itself: the cached end now falls inside its own tail,
      // where the mainline (and so the fingerprint) is still intact.
      final grownA = _game('A', comment: '{x}', tail: trailing);
      await file.writeAsString('$grownA\n\n${_game('B')}\n');
      expect(game.rawPgn, grownA);
    });

    test('rejects a span whose record now belongs to another game', () async {
      final layout = _file([utf8.encode(_game('A')), utf8.encode(_game('B'))]);
      await file.writeAsBytes(layout.bytes);
      final game = _cachedGame(file, layout, 0);
      await file.writeAsString('${_game('C')}\n\n${_game('B')}\n');
      expect(() => game.rawPgn, throwsStateError);
    });
  });

  group('readLocalPgnRecordInBackground', () {
    test('matches the synchronous reader and keeps its errors', () async {
      await file.writeAsString('${_game('A')}\n\n${_game('B')}\n');
      expect(
        await readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
          expectedFileGameCount: 2,
        ),
        readLocalPgnRecord(path: file.path, indexInFile: 1),
      );
      await expectLater(
        readLocalPgnRecordInBackground(
          path: file.path,
          indexInFile: 1,
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
  });

  group('hydrateRetainedLocalPgn', () {
    test('opens a Latin-1 database game', () async {
      final layout = _file([_latin1Game(), utf8.encode(_game('B'))]);
      await file.writeAsBytes(layout.bytes);
      final span = layout.spans.first;
      final record =
          decodeLocalPgnText(layout.bytes.sublist(span.$1, span.$2)).trim();
      final row = TournamentGameSummary(
        id: 'latin',
        name: 'Müller vs Opponent',
        whitePlayer: 'Müller',
        blackPlayer: 'Opponent',
        hasPgn: true,
        pgn: record,
        localPgnSource: TournamentGameLocalPgnSource(
          sourcePath: file.path,
          sourceIndex: 0,
          sourceFileGameCount: 2,
          pgnFingerprint: localChessPgnFingerprint(record),
          title: 'Müller vs Opponent',
        ),
      );
      final hydrated = await hydrateRetainedLocalPgn(row);
      expect(hydrated.pgn, record);
      expect(
        hydrated.localPgnSource?.recordRevision,
        localPgnRecordRevision(record),
      );
    });
  });
}
