import 'package:dartchess/dartchess.dart';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/utils/pgn_clock_utils.dart';

/// A fully prepared edit. The caller publishes it with one undo snapshot.
class BoardPgnInsertion {
  const BoardPgnInsertion({required this.game, required this.landingPath});

  final ChessGame game;
  final List<String> landingPath;
}

/// Inserts a complete annotated continuation, preferring the current position,
/// then its nearest ancestor on the active (possibly non-mainline) move path.
/// Neither the game nor the active path is mutated, including on failure.
BoardPgnInsertion? insertBoardPgn({
  required ChessGame game,
  required List<ChessMove> activePath,
  required String pgn,
  String? sourceLabel,
}) {
  try {
    _validatePgnTokens(pgn);
    final parsed = PgnGame.parsePgn(pgn);
    final incoming = _PositionNode();
    final start = PgnGame.startingPosition(parsed.headers);
    _readPgn(incoming, parsed.moves, start);
    if (incoming.children.isEmpty) return null;
    // ChessMove has no before-move comment field. Keep all introductory prose
    // on the first move rather than silently dropping it as fromPgn does.
    final first = incoming.principal!;
    first.move = first.move!.copyWith(
      comments: _union(parsed.comments, first.move!.comments),
    );

    final candidates = <String, List<_PositionNode>>{};
    void index(_PositionNode node, String fen) {
      candidates.putIfAbsent(_positionKey(fen), () => []).add(node);
      for (final child in node.children) {
        index(child, child.move!.fen);
      }
    }

    index(incoming, start.fen);

    final root = _PositionNode();
    _readLine(root, game.mainline, principal: true);
    final ancestors = <_PositionNode>[root];
    var current = root;
    for (final move in activePath) {
      final found = current.children.where((n) => n.move!.uci == move.uci);
      if (found.isEmpty) return null;
      current = found.first;
      ancestors.add(current);
    }

    for (var depth = ancestors.length - 1; depth >= 0; depth--) {
      final target = ancestors[depth];
      final fen = depth == 0 ? game.startingFen : target.move!.fen;
      final matches = candidates[_positionKey(fen)];
      if (matches == null) continue;
      // Deterministic PGN order: principal continuation before sidelines.
      final usable = matches.where((n) => n.children.isNotEmpty);
      if (usable.isEmpty) continue;
      final source = usable.first;
      final suffix = <String>[];
      var tail = source.principal;
      while (tail != null) {
        suffix.add(tail.move!.uci);
        if (tail.principal == null) break;
        tail = tail.principal;
      }
      final label =
          sourceLabel
              ?.replaceAll(RegExp(r'[\[\]{}]'), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      if (tail != null && label != null && label.isNotEmpty) {
        final enriched =
            label.contains('=') && !RegExp(r'(^|\|)plies=').hasMatch(label)
                ? '$label|plies=${suffix.length}'
                : label;
        tail.move = tail.move!.copyWith(
          comments: _union(tail.move!.comments, ['[%src $enriched]']),
        );
      }
      _rebaseChildren(
        source,
        Position.setupPosition(
          start.rule,
          Setup.parseFen(fen),
          ignoreImpossibleCheck: true,
        ),
      );
      final onMainline =
          depth <= game.mainline.length &&
          Iterable<int>.generate(
            depth,
          ).every((i) => activePath[i].uci == game.mainline[i].uci);
      _merge(
        target,
        source,
        // Position equality alone is not predecessor identity (transpositions).
        mergeMove: target.move?.uci == source.move?.uci,
        allowExtension: !onMainline || game.allowMainlineExtension,
      );
      // An empty scratch root needs a move to carry the tree. Matching local
      // tails follow the normal mainline-extension policy; divergent incoming
      // continuations never displace an existing principal edge.
      root.principal ??= root.children.first;
      var mergedGame = game.copyWith(mainline: _writeRoot(root));
      final endingPly = game.gameEndingPlyIndex;
      if (endingPly != null &&
          mergedGame.mainline.length > game.mainline.length) {
        mergedGame = mergedGame.rememberGameEndingPlyIndex(endingPly);
      }
      return BoardPgnInsertion(
        game: mergedGame,
        landingPath: [
          for (final move in activePath.take(depth)) move.uci,
          ...suffix,
        ],
      );
    }
    return null;
  } catch (_) {
    return null;
  }
}

// Position-key matching ignores clocks, but retains turn/castling/en-passant.
String _positionKey(String fen) => fen.split(' ').take(4).join(' ');

/// Normalizes the model's two RAV conventions (same-turn replacement and
/// opposite-turn continuation) to edges from positions. Broadcast merge APIs
/// cannot be reused: they intentionally make the incoming mainline authoritative.
class _PositionNode {
  _PositionNode({this.move});
  ChessMove? move;
  final children = <_PositionNode>[];
  _PositionNode? principal;
}

void _readLine(
  _PositionNode parent,
  ChessLine line, {
  required bool principal,
}) {
  for (var i = 0; i < line.length; i++) {
    final move = line[i];
    final node = _PositionNode(
      move: move.copyWith(variations: null, overrideVariations: true),
    );
    parent.children.add(node);
    if (i > 0 || principal) parent.principal = node;
    for (final variation in move.variations ?? const <ChessLine>[]) {
      if (variation.isEmpty) continue;
      _readLine(
        variation.first.turn == move.turn ? parent : node,
        variation,
        principal: false,
      );
    }
    parent = node;
  }
}

void _readPgn(_PositionNode target, PgnNode<PgnNodeData> source, Position pos) {
  for (final child in source.children) {
    final data = child.data;
    final move = pos.parseSan(data.san);
    // Unlike ChessGame.fromPgn, do not silently truncate an illegal mainline or
    // RAV. Validate every incoming node before preparing any edit.
    if (move == null || !pos.isLegal(move)) {
      throw const FormatException('Illegal PGN move');
    }
    final next = pos.play(move);
    final comments = _union(data.startingComments, data.comments);
    String? clock;
    String? evaluation;
    for (final comment in comments ?? const <String>[]) {
      clock = extractPgnClockStringFromComment(comment) ?? clock;
      evaluation =
          RegExp(r'\[%eval ([^\]]+)\]').firstMatch(comment)?.group(1) ??
          evaluation;
    }
    final node = _PositionNode(
      move: ChessMove(
        num: pos.fullmoves,
        fen: next.fen,
        san: data.san,
        uci: move.uci,
        turn: pos.turn == Side.white ? ChessColor.white : ChessColor.black,
        comments: comments,
        nags: data.nags,
        clockTime: clock,
        eval: evaluation,
      ),
    );
    _readPgn(node, child, next);
    // Duplicate sibling UCIs may occur in hand-edited PGNs.
    final existing = target.children.where((n) => n.move!.uci == move.uci);
    if (existing.isEmpty) {
      target.children.add(node);
      target.principal ??= node;
    } else {
      _merge(existing.first, node);
    }
  }
}

void _rebaseChildren(_PositionNode node, Position position) {
  for (final child in node.children) {
    final move = Move.parse(child.move!.uci);
    if (move == null || !position.isLegal(move)) {
      throw const FormatException('Invalid continuation at destination');
    }
    final next = position.play(move);
    child.move = child.move!.copyWith(num: position.fullmoves, fen: next.fen);
    _rebaseChildren(child, next);
  }
}

void _merge(
  _PositionNode target,
  _PositionNode source, {
  bool mergeMove = true,
  bool allowExtension = true,
}) {
  if (mergeMove && target.move != null && source.move != null) {
    final old = target.move!;
    final added = source.move!;
    target.move = old.copyWith(
      comments: _union(old.comments, added.comments),
      nags: _union(old.nags, added.nags),
      clockTime: old.clockTime ?? added.clockTime,
      eval: old.eval ?? added.eval,
    );
  }
  for (final child in source.children) {
    final existing = target.children.where(
      (n) => n.move!.uci == child.move!.uci,
    );
    if (existing.isEmpty) {
      target.children.add(child);
    } else {
      _merge(
        existing.first,
        child,
        allowExtension:
            allowExtension || !identical(existing.first, target.principal),
      );
    }
  }
  if (allowExtension && target.principal == null && source.principal != null) {
    target.principal = target.children.firstWhere(
      (child) => child.move!.uci == source.principal!.move!.uci,
    );
  }
}

List<T>? _union<T>(List<T>? old, List<T>? added) {
  if (old == null && added == null) return null;
  return <T>{...?old, ...?added}.toList();
}

ChessLine _writeRoot(_PositionNode root) {
  final line = _writeLine(root.principal!);
  final alternatives = [
    for (final child in root.children)
      if (!identical(child, root.principal)) _writeLine(child),
  ];
  if (alternatives.isNotEmpty) {
    line[0] = line[0].copyWith(
      variations: [...alternatives, ...?line[0].variations],
      overrideVariations: true,
    );
  }
  return line;
}

ChessLine _writeLine(_PositionNode first) {
  final line = <ChessMove>[];
  _PositionNode? node = first;
  while (node != null) {
    final variations = [
      for (final child in node.children)
        if (!identical(child, node.principal)) _writeLine(child),
    ];
    line.add(
      node.move!.copyWith(
        variations: variations.isEmpty ? null : variations,
        overrideVariations: true,
      ),
    );
    node = node.principal;
  }
  return line;
}

// dartchess deliberately skips unknown tokens and accepts unclosed RAVs and
// comments. Reject these before parsing so a malformed paste cannot partly land.
void _validatePgnTokens(String pgn) {
  final token = RegExp(
    r'\s+|\uFEFF|\{[^}]*\}|;[^\r\n]*|%[^\r\n]*|'
    r'\[[A-Za-z0-9][A-Za-z0-9_+#=:-]*\s+"(?:[^"\\]|\\.)*"\]|'
    r'\d+\.(?:\.\.)?|\.\.\.|1/2-1/2|1-0|0-1|\*|'
    r'(?:[NBKRQ]?[a-h]?[1-8]?[-x]?[a-h][1-8](?:=?[nbrqkNBRQK])?|'
    r'O-O-O|0-0-0|O-O|0-0)[+#]?|\$\d{1,4}|[?!]{1,2}|\(|\)',
  );
  var offset = 0;
  var depth = 0;
  var ended = false;
  var movetextStarted = false;
  while (offset < pgn.length) {
    final match = token.matchAsPrefix(pgn, offset);
    if (match == null) throw const FormatException('Invalid PGN token');
    final value = match.group(0)!;
    final trivia =
        value.trim().isEmpty ||
        value == '\uFEFF' ||
        value.startsWith('{') ||
        value.startsWith(';') ||
        value.startsWith('%');
    if (ended && !trivia) throw const FormatException('Multiple PGN games');
    if (!trivia) {
      if (value.startsWith('[')) {
        // Once dartchess enters movetext it scans header values as SAN.
        // Reject misplaced tags before they can synthesize legal moves.
        if (movetextStarted) {
          throw const FormatException('PGN header after movetext');
        }
      } else {
        movetextStarted = true;
      }
    }
    if (value == '(') depth++;
    if (value == ')' && --depth < 0) {
      throw const FormatException('Unbalanced PGN variation');
    }
    if (depth == 0 && const ['*', '1-0', '0-1', '1/2-1/2'].contains(value)) {
      ended = true;
    }
    offset = match.end;
  }
  if (depth != 0) throw const FormatException('Unclosed PGN variation');
}
