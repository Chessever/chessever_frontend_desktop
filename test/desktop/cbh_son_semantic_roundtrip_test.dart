import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';

void main() {
  final source = Platform.environment['SON_CBH_PGN'];
  test(
    'actual Son preserves roots, prefaces, SAN and NAGs at every tree address',
    () {
      final records =
          File(source!)
              .readAsStringSync()
              .split(RegExp(r'(?=^\[Event )', multiLine: true))
              .where((s) => s.trim().isNotEmpty)
              .toList();
      expect(records.length, 1436);
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
              .where((c) => c.isNotEmpty).join(' ');
          List<String> directives(List<String>? comments) =>
              directive.allMatches((comments ?? []).join(' '))
                  .map((m) => m.group(0)!).toSet().toList()..sort();
          expect(prose(a.data.comments), prose(b.data.comments),
              reason: '$here after-move prose');
          expect(directives(a.data.comments), directives(b.data.comments),
              reason: '$here after-move directives');
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
      expect(roots, greaterThan(0));
      expect(starts, greaterThan(0));
      expect(nags, greaterThan(0));
    },
    skip:
        source == null
            ? 'Set SON_CBH_PGN to a disposable Son conversion'
            : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
