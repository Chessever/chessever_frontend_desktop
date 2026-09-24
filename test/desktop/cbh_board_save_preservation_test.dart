import 'dart:io';

import 'package:chessever/desktop/services/board_report_output.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> preserved(ChessGame game) => Map.fromEntries(
  game.metadata.entries.where((e) => e.key.startsWith('ChessBase')),
);

void main() {
  final path = Platform.environment['CBH_ACCEPTANCE_PGN'];
  test(
    'every Son record survives Board export; rich and guiding records survive repeated save/reopen',
    () async {
      final source = await scanLocalChessPgnCatalog(path!);
      final entries = source.root.files.single.games;
      expect(entries, hasLength(1436));
      final dir = await Directory.systemTemp.createTemp('cbh-board-save-');
      addTearDown(() => dir.delete(recursive: true));
      var saved = 0;
      for (final entry in entries) {
        final raw = entry.rawPgn;
        final game = ChessGame.fromPgn('cbh-${entry.indexInFile}', raw);
        // These converter headers contain ASCII/base64, without PGN escapes.
        // Derive the expectation from source text, not the importer under test.
        final expected = {
          for (final match in RegExp(
            r'^\[(ChessBase\w+) "([^"]*)"\]$',
            multiLine: true,
          ).allMatches(raw))
            match.group(1)!: match.group(2)!,
        };
        expect(expected, isNotEmpty);
        expect(preserved(game), expected);
        final edited = game.copyWith(
          metadata: {...game.metadata, 'Event': 'Edited in Board'},
          mainline:
              game.mainline.isEmpty
                  ? game.mainline
                  : [
                    game.mainline.first.copyWith(
                      comments: [
                        ...?game.mainline.first.comments,
                        'Board edit retained',
                      ],
                    ),
                    ...game.mainline.skip(1),
                  ],
        );
        final output = await resolveBoardLibrarySaveGame(
          useOpeningSource: false,
          workingGame: edited,
          resolveOpeningSource:
              () async => throw StateError('must save working tree'),
        );
        final reopened = ChessGame.fromPgn('reopened', exportGameToPgn(output));
        expect(
          preserved(reopened),
          expected,
          reason: 'record ${entry.indexInFile}',
        );
        if (!expected.containsKey('ChessBaseRawAnnotations') &&
            !expected.containsKey('ChessBaseUnattachedAnnotations') &&
            expected['ChessBaseRecordType'] != 'GuidingText') {
          continue;
        }
        final file = File('${dir.path}/${entry.indexInFile}.pgn');
        await file.writeAsString(raw, flush: true);
        var target = LocalLibraryGameUpdateTarget(
          sourcePath: file.path,
          indexInFile: 0,
          fileGameCount: 1,
          recordRevision: localPgnRecordRevision(raw),
        );
        for (var pass = 0; pass < 2; pass++) {
          final result = await updateLocalLibraryPgnGame(
            target: target,
            game: output,
          );
          target = result.updateTarget;
          final text = await file.readAsString();
          expect(pgnGameRanges(text), hasLength(1));
          final disk = ChessGame.fromPgn('disk', text);
          expect(preserved(disk), expected);
          expect(disk.metadata['Event'], 'Edited in Board');
          if (disk.mainline.isNotEmpty) {
            expect(
              disk.mainline.first.comments!.join(' '),
              contains('Board edit retained'),
            );
          }
        }
        saved++;
      }
      expect(saved, 1368);
      // Prints an actual exercised count in the private acceptance log.
      // ignore: avoid_print
      print(
        'Board export/reparse: ${entries.length}; physical repeated saves: $saved',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: path == null ? 'Set CBH_ACCEPTANCE_PGN' : false,
  );
}
