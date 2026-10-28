import 'dart:io';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';

void main() {
  final source = Platform.environment['MY_GAMES_CBH_PGN'];
  test(
    'decoded staged controls survive actual edit/save/reopen',
    () async {
      final records =
          File(source!)
              .readAsStringSync()
              .split(RegExp(r'(?=^\[Event )', multiLine: true))
              .where((s) => s.trim().isNotEmpty)
              .toList();
      final dir = await Directory.systemTemp.createTemp('mygames-controls-');
      addTearDown(() => dir.delete(recursive: true));
      var count = 0;
      for (final raw in records) {
        if (!raw.contains('[TimeControl "40/5400+30:1800+30"]')) continue;
        final original = ChessGame.fromPgn('source', raw);
        final edited = original.copyWith(
          metadata: {...original.metadata, 'Event': 'Edited fixture'},
        );
        final file = File('${dir.path}/$count.pgn');
        await file.writeAsString(raw, flush: true);
        var target = LocalLibraryGameUpdateTarget(
          sourcePath: file.path,
          indexInFile: 0,
          fileGameCount: 1,
          recordRevision: localPgnRecordRevision(raw),
        );
        for (var pass = 0; pass < 2; pass++) {
          final saved = await updateLocalLibraryPgnGame(
            target: target,
            game: edited,
          );
          target = saved.updateTarget;
          final text = await file.readAsString();
          final reopened = ChessGame.fromPgn('reopened', text);
          expect(reopened.metadata['Event'], 'Edited fixture');
          expect(reopened.metadata['TimeControl'], '40/5400+30:1800+30');
          expect(
            reopened.metadata['ChessBaseRawAnnotations'],
            original.metadata['ChessBaseRawAnnotations'],
          );
          expect(
            PgnGame.parsePgn(text).comments,
            PgnGame.parsePgn(raw).comments,
          );
          expect(
            PgnGame.parsePgn(text).comments.join(' '),
            contains('Time control: 40/5400+30:1800+30 seconds'),
          );
        }
        count++;
      }
      expect(count, 10);
    },
    skip: source == null ? 'Set MY_GAMES_CBH_PGN' : false,
  );
  test(
    'actual My games preserves roots, prefaces, SAN and NAGs at every tree address',
    () {
      final records =
          File(source!)
              .readAsStringSync()
              .split(RegExp(r'(?=^\[Event )', multiLine: true))
              .where((s) => s.trim().isNotEmpty)
              .toList();
      expect(records.length, 2695);
      var roots = 0, starts = 0, nags = 0;
      void compare(
        PgnNode<PgnNodeData> before,
        PgnNode<PgnNodeData> after,
        String address,
      ) {
        expect(after.children.length, before.children.length, reason: address);
        for (var i = 0; i < before.children.length; i++) {
          final b = before.children[i], a = after.children[i];
          final here = '$address/$i';
          expect(a.data.san, b.data.san, reason: here);
          // Export groups clock/evaluation directives into a separate block.
          // Compare prose in order and directive identities independently.
          final directive = RegExp(r'\[%(clk|eval)\s+[^\]]+\]');
          String prose(List<String>? comments) => (comments ?? [])
              .map((c) => c.replaceAll(directive, '').trim())
              .where((c) => c.isNotEmpty)
              .join(' ');
          List<String> directives(List<String>? comments) =>
              directive
                  .allMatches((comments ?? []).join(' '))
                  .map((m) => m.group(0)!)
                  .toSet()
                  .toList()
                ..sort();
          expect(
            prose(a.data.comments),
            prose(b.data.comments),
            reason: '$here after-move prose',
          );
          expect(
            directives(a.data.comments),
            directives(b.data.comments),
            reason: '$here after-move directives',
          );
          expect(
            a.data.startingComments ?? [],
            b.data.startingComments ?? [],
            reason: '$here before-move text',
          );
          expect(
            a.data.nags ?? [],
            b.data.nags ?? [],
            reason: '$here NAG identity',
          );
          starts += b.data.startingComments?.length ?? 0;
          for (final nag in b.data.nags ?? <int>[]) {
            if (nag != 0) {
              expect(
                getNagDisplay(nag),
                isNotNull,
                reason: '$here invisible NAG $nag',
              );
            }
            nags++;
          }
          compare(b, a, here);
        }
      }

      for (var i = 0; i < records.length; i++) {
        final before = PgnGame.parsePgn(records[i]);
        final game = ChessGame.fromJson(
          ChessGame.fromPgn('$i', records[i]).copyWith().toJson(),
        );
        final after = PgnGame.parsePgn(exportGameToPgn(game));
        expect(after.comments, before.comments, reason: 'record ${i + 1} root');
        if (before.comments.isNotEmpty) roots++;
        compare(before.moves, after.moves, 'record ${i + 1}');
      }
      expect(roots, 201);
      expect(starts, 63);
      expect(nags, 12027);
    },
    skip:
        source == null
            ? 'Set MY_GAMES_CBH_PGN to a disposable My games conversion'
            : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
