import 'package:dartchess/dartchess.dart';

// A transient sentinel used only while adapting dartchess. It never goes
// into a saved/copied PGN or into the application move tree.
const _marker = '\uE000CE-before:\uE001';
final _moveNumber = RegExp(r'^\d+\.{1,3}$');
final _lexeme = RegExp(
  r'\[[\w]+\s+"(?:\\.|[^"\\])*"\s*\]|\{[^}]*\}|[;%][^\r\n]*|\d+\.{1,3}|[^\s{}();\[\]]+|[^\s]',
);

/// Unlike dartchess's default ownership, `5... {plan} Nf6` belongs to
/// Nf6's before-comments. Unnumbered comments keep their existing ownership.
PgnGame<PgnNodeData> parsePgnWithNumberedComments(String pgn) {
  if (!RegExp(r'\.\s*\{').hasMatch(pgn)) return PgnGame.parsePgn(pgn);
  final tagged = StringBuffer();
  var end = 0;
  var afterNumber = false;
  for (final match in _lexeme.allMatches(pgn)) {
    final token = match[0]!;
    if (afterNumber && token.startsWith('{')) {
      tagged.write(pgn.substring(end, match.start + 1));
      tagged.write(_marker);
      end = match.start + 1;
    } else if (!token.startsWith(';') && !token.startsWith('%')) {
      afterNumber = _moveNumber.hasMatch(token);
    }
  }
  if (end == 0) return PgnGame.parsePgn(pgn);
  tagged.write(pgn.substring(end));
  final game = PgnGame.parsePgn(tagged.toString());

  void transfer(List<String>? comments, PgnChildNode<PgnNodeData>? next) {
    if (comments == null || !comments.any((s) => s.startsWith(_marker))) return;
    final before = <String>[];
    for (var i = 0; i < comments.length;) {
      final comment = comments[i];
      if (!comment.startsWith(_marker)) {
        i++;
        continue;
      }
      final text = comment.substring(_marker.length).trim();
      if (next == null) {
        comments[i++] = text; // A truncated line must not lose the prose.
      } else {
        before.add(text);
        comments.removeAt(i);
      }
    }
    if (next != null) {
      next.data.startingComments = [...before, ...?next.data.startingComments];
    }
  }

  transfer(game.comments, game.moves.children.firstOrNull);
  final pending = [...game.moves.children];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    final data = node.data;
    final starts = data.startingComments;
    if (starts != null && starts.any((s) => s.startsWith(_marker))) {
      data.startingComments = [
        for (final s in starts)
          s.startsWith(_marker) ? s.substring(_marker.length).trim() : s,
      ];
    }
    transfer(data.comments, node.children.firstOrNull);
    pending.addAll(node.children);
  }
  return game;
}

List<String>? tagPgnBeforeMoveComments(List<String>? comments) =>
    comments == null || comments.isEmpty
        ? null
        : [for (final comment in comments) '$_marker$comment'];

/// dartchess emits before-comments in front of the forced number. Put the
/// number first, so `… e4 {after} 1... {before} e5` is unambiguous on reimport.
String putPgnMoveNumbersBeforeComments(String pgn) {
  if (!pgn.contains(_marker)) return pgn;
  final out = StringBuffer();
  final comments = <String>[];
  var start = 0;
  var end = 0;
  for (final match in _lexeme.allMatches(pgn)) {
    final token = match[0]!;
    if (token.startsWith('{ $_marker')) {
      if (comments.isEmpty) start = match.start;
      comments.add(token.replaceFirst(_marker, ''));
      continue;
    }
    if (comments.isEmpty) continue;
    out.write(pgn.substring(end, start));
    if (_moveNumber.hasMatch(token)) {
      out.write('$token ${comments.join(' ')}');
      end = match.end;
    } else {
      out.write('${comments.join(' ')} ');
      end = match.start;
    }
    comments.clear();
  }
  if (comments.isNotEmpty) {
    out.write(pgn.substring(end, start));
    out.write(comments.join(' '));
    return out.toString();
  }
  return (out..write(pgn.substring(end))).toString();
}
