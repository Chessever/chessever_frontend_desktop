import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/board_tab_pgn_resolver.dart';
import 'package:chessever/desktop/services/board_report_output.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/desktop/services/pgn_record_boundaries.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter_test/flutter_test.dart';

const _fen = '4k3/8/8/8/8/8/4P3/4K3 w - - 0 1';
String _position(String fen) =>
    '[Event "?"]\n[Date "2023.06.30"]\n'
    '[White "Position"]\n[Black "?"]\n[Result "*"]\n'
    '[SetUp "1"]\n[FEN "$fen"]\n[PlyCount "0"]\n\n*';

void main() {
  test(
    'Board resolver does not fetch remote notation for explicit setup',
    () async {
      final raw = _position(_fen);
      var remoteCalls = 0;
      final result = await resolveBoardTabPgn(
        gameId: 'local-position',
        initialPgn: raw,
        fetchSupabasePgn: (_) async {
          remoteCalls++;
          return '1. d4 *';
        },
        fetchGamebaseGameWithPgn: (_) async {
          remoteCalls++;
          return null;
        },
      );
      expect(result, raw);
      expect(remoteCalls, 0);
    },
  );
  test('date and quoted annotation headers are not notation move hints', () {
    final lines = <PgnByteLine>[];
    PgnByteLineScanner(lines.add).scanBytes(utf8.encode(_position(_fen)));
    expect(lines.where((line) => line.hasMoveHint), isEmpty);
  });

  test('setup-only raw chunk is retained, invalid FEN is not accepted', () {
    LocalChessGame? parse(String raw) => localChessGameFromRawPgnChunk(
      rawPgn: raw,
      sourcePath: 'positions.pgn',
      rootPath: '.',
      indexInFile: 3,
      fileGameCount: 42,
    );
    final row = parse(_position(_fen));
    expect(row, isNotNull);
    expect(row!.hasMoves, isFalse);
    expect(row.game.startingFen, _fen);
    expect(row.indexInFile, 3);
    expect(row.fileGameCount, 42);
    expect(parse(_position('broken')), isNull);
    expect(parse('[White "Empty"]\n\n*'), isNull);
  });

  final privatePath = Platform.environment['SETUP_POSITION_PGN'];
  test(
    'legacy move hint accepts only verified setup, not lost moves or changed FEN',
    () async {
      final directory = await Directory.systemTemp.createTemp('setup-guard-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/position.pgn');
      final raw = _position(_fen);
      await file.writeAsString(raw);
      LocalChessGame row({String? fingerprint}) => LocalChessGame(
        id: 'position',
        game: ChessGame.fromPgn('position', raw),
        rawPgn: '',
        sourcePath: file.path,
        sourceRelativePath: 'position.pgn',
        fileName: 'position.pgn',
        indexInFile: 0,
        fileGameCount: 1,
        hasMoves: true,
        sourceByteStart: 0,
        sourceByteEnd: utf8.encode(raw).length,
        pgnFingerprint: fingerprint ?? '',
      );
      expect(row().rawPgn, raw);
      // Valid different setup with the same sparse identity must not replace it.
      await file.writeAsString(_position(_fen.replaceFirst(' w ', ' b ')));
      expect(() => row().rawPgn, throwsStateError);
      expect(
        () => row(fingerprint: localChessPgnFingerprint(raw)).rawPgn,
        throwsStateError,
      );
      await file.writeAsString(_position('invalid'));
      expect(() => row().rawPgn, throwsStateError);
      await file.writeAsString('[White "Position"]\n\n*');
      expect(() => row().rawPgn, throwsStateError);
    },
  );

  test(
    'private setup record opens from actual catalog and retains source',
    () async {
      final bytes = File(privatePath!).readAsBytesSync();
      final source = await scanLocalChessPgnCatalog(privatePath);
      final rows = source.root.files.single.games;
      expect(rows, hasLength(42));
      final row = rows[3];
      for (final entry in rows) {
        // Includes the intentionally empty day-heading records; no neighbour
        // should poison the selected position's context window.
        expect(() => entry.rawPgn, returnsNormally);
      }
      expect(row.hasMoves, isFalse);
      final raw = row.rawPgn;
      expect(row.indexInFile, 3);
      expect(row.fileGameCount, 42);
      final game = ChessGame.fromPgn(row.id, raw);
      expect(game.mainline, isEmpty);
      expect(game.metadata['SetUp'], '1');
      expect(game.metadata['FEN'], Platform.environment['SETUP_POSITION_FEN']);
      final position = Chess.fromSetup(Setup.parseFen(game.startingFen));
      expect(position.legalMoves, isNotEmpty);
      // Same navigator used by Board.applyMove, starting from the empty root.
      final nav = _Navigator(game);
      final from = position.legalMoves.keys.first;
      final move = NormalMove(
        from: from,
        to: position.legalMoves[from]!.squares.first,
      );
      nav.makeOrGoToMove(move.uci);
      final edited = nav.current.game;
      expect(edited.mainline, hasLength(1));
      expect(edited.mainline.single.uci, move.uci);
      expect(edited.mainline.single.fen, position.play(move).fen);
      final output = await resolveBoardLibrarySaveGame(
        useOpeningSource: false,
        workingGame: edited,
        resolveOpeningSource: () async => throw StateError('wrong save source'),
      );
      final directory = await Directory.systemTemp.createTemp('setup-save-');
      addTearDown(() => directory.delete(recursive: true));
      final copy = File('${directory.path}/positions.pgn');
      await copy.writeAsBytes(bytes);
      final outcome = await updateLocalLibraryPgnGame(
        target: LocalLibraryGameUpdateTarget(
          sourcePath: copy.path,
          indexInFile: 3,
          fileGameCount: 42,
          pgnFingerprint: localChessPgnFingerprint(raw),
          recordRevision: localPgnRecordRevision(raw),
        ),
        game: output,
      );
      final reopenedRaw = readLocalPgnRecord(
        path: copy.path,
        indexInFile: 3,
        expectedFileGameCount: 42,
        expectedPgnFingerprint: outcome.updateTarget.pgnFingerprint,
        expectedRecordRevision: outcome.updateTarget.recordRevision,
      );
      final reopened = ChessGame.fromPgn(row.id, reopenedRaw);
      expect(reopened.startingFen, game.startingFen);
      expect(reopened.metadata['SetUp'], '1');
      expect(reopened.mainline.single.uci, move.uci);
      expect(reopened.mainline.single.fen, edited.mainline.single.fen);
      expect(
        ChessGame.fromPgn('again', exportGameToPgn(reopened)).startingFen,
        game.startingFen,
      );
      final originalText = decodeLocalPgnText(bytes);
      final originalRanges = pgnGameRanges(originalText);
      final savedText = await copy.readAsString();
      final savedRanges = pgnGameRanges(savedText);
      expect(savedRanges, hasLength(42));
      for (var i = 0; i < originalRanges.length; i++) {
        if (i == 3) continue;
        expect(
          savedText.substring(savedRanges[i].start, savedRanges[i].end),
          originalText.substring(
            originalRanges[i].start,
            originalRanges[i].end,
          ),
        );
      }
      expect(localChessPgnFingerprint(raw), isNotEmpty);
      expect(localPgnRecordRevision(raw), isNotEmpty);
      expect(File(privatePath).readAsBytesSync(), bytes);
    },
    skip: privatePath == null,
  );
}

class _Navigator extends ChessGameNavigator {
  _Navigator(super.game);
  ChessGameNavigatorState get current => state;
}
