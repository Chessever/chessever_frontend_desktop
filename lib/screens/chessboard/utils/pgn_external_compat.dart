import 'package:chessever/screens/chessboard/notation/pgn_move_number_repair.dart';
import 'package:chessever/screens/chessboard/utils/chessever_classification_header.dart';

/// PGN text that is about to leave the app for another program.
///
/// ChessEver's own wire format writes its move classes as the private
/// `$240`–`$247` block *beside* the standard verdict (see
/// `kChesseverClassificationNags`) and keeps the whole movetext on one very
/// long line. That is deliberate for our own files — it is how a report travels
/// between our apps byte-for-byte — but it is not what a stricter consumer
/// accepts. The PGN spec defines standard NAGs only through `$139`; a web
/// importer that range-checks NAGs, or that needs a wrapped movetext and a
/// terminated file, either refuses the game or drops everything it cannot
/// place.
///
/// This module is the compatibility boundary: it takes PGN text that is already
/// serialized and rewrites only what a foreign reader cannot cope with, so a
/// copied game imports anywhere. It never changes what is written to the user's
/// own files — saving to a local database and the cloud format keep the native
/// `$240`–`$247` block, unwrapped above the columns required by PGN.
///
/// What it does:
///
/// * maps every ChessEver classification NAG onto the nearest **standard** NAG
///   (see `kExternalNagForClassification`) and carries the exact class in the
///   private `[ChessEverClassification "…"]` **header tag**
///   (`kChesseverClassificationHeaderTag`), which other applications store and
///   never render in the notation;
/// * drops the whole `$240`–`$248` block from the movetext;
/// * wraps the movetext at [kExternalPgnColumns] with intact move numbering;
/// * terminates the game with its Result token and a trailing newline.
///
/// What it preserves verbatim: every header tag, the SAN of every move, RAV
/// variations, prose comments, and the `[%eval …]` / `[%clk …]` payloads.
///
/// An earlier build put the class in the move's comment payload
/// (`{ [%ce 247] }`). ChessBase stores comments, so the user saw that private
/// tag printed inside the notation list. The comment form is gone from the
/// writer for good; import still reads it, because copies made by that build
/// exist (see `restoreChesseverClassificationNags`).
///
/// This module imports nothing but pure Dart helpers and the private
/// classification vocabulary, so the whole external-compatibility boundary can
/// be executed on a bare Dart VM when the repository is under an analyze-only
/// policy.

/// Wraps the movetext at this many columns. PGN's export format has no fixed
/// limit; 80 is what every producer uses and what importers are tested against.
const int kExternalPgnColumns = 80;

/// The movetext of one game in external form, plus the classes it carries.
class ExternalPgnMovetext {
  const ExternalPgnMovetext({
    required this.lines,
    required this.classificationCodes,
  });

  /// The movetext, wrapped, standard NAGs only, terminated.
  final List<String> lines;

  /// Movetext address -> native ChessEver code. See
  /// [kChesseverClassificationHeaderTag] for the grammar.
  final Map<String, int> classificationCodes;
}

/// Movetext wrapped at 80 columns, terminated, standard NAGs only, with the
/// exact ChessEver classes carried out-of-band for the header tag.
///
/// [pgn] may hold one game or several blank-line separated games (the shape all
/// the "copy selected games" paths produce); headers are kept, everything else
/// is re-emitted in PGN export shape. Text that is empty or holds no movetext
/// is returned with line endings normalized and nothing else changed.
String toExternalCompatiblePgn(
  String pgn, {
  int columns = kExternalPgnColumns,
}) {
  final normalized = _normalizeNewlines(pgn);
  if (normalized.trim().isEmpty) return normalized;

  final blocks = _splitIntoGames(normalized);
  if (blocks.isEmpty) return normalized;

  final buffer = StringBuffer();
  for (var i = 0; i < blocks.length; i++) {
    if (i > 0) buffer.write('\n');
    final block = blocks[i];
    for (final header in block.headers) {
      buffer.writeln(header);
    }
    final movetext = externalCompatibleMovetext(
      block.movetext,
      result: _resultTokenFromHeaders(block.headers),
      columns: columns,
    );
    // The private carrier is the last line of the header block, so a foreign
    // reader keeps it as metadata and a full-PGN copy/paste carries it along.
    final classificationHeader = chesseverClassificationHeaderValue(
      movetext.classificationCodes,
    );
    if (classificationHeader != null) buffer.writeln(classificationHeader);
    if (block.headers.isNotEmpty || classificationHeader != null) {
      buffer.write('\n');
    }
    for (final line in movetext.lines) {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}

/// The externals of one game's movetext, with the ChessEver classes the copy
/// must carry out-of-band and the lines that go into the copied PGN.
///
/// Exposed for the copy-path regressions; production callers use
/// [toExternalCompatiblePgn] so headers and termination travel with it.
ExternalPgnMovetext externalCompatibleMovetext(
  String movetext, {
  String? result,
  int columns = kExternalPgnColumns,
}) {
  final tokens = _movetextTokens(movetext);
  if (tokens.isEmpty) {
    return const ExternalPgnMovetext(
      lines: <String>[],
      classificationCodes: <String, int>{},
    );
  }

  final rewritten = _rewriteAnnotations(tokens, result: result);
  // Numbering last, after our own edits: the standard wants `N...` before a
  // black move that does not follow its white partner (after a comment, a NAG
  // or a closed variation), and `_rewriteAnnotations` removes NAGs.
  final numbered = restoreBlackMoveNumbers(rewritten.tokens.join(' '));
  return ExternalPgnMovetext(
    lines: _wrapTokens(_movetextTokens(numbered), columns),
    classificationCodes: rewritten.classificationCodes,
  );
}

/// The movetext of one game, as the lines that go into a copied PGN.
List<String> externalCompatibleMovetextLines(
  String movetext, {
  String? result,
  int columns = kExternalPgnColumns,
}) => externalCompatibleMovetext(
  movetext,
  result: result,
  columns: columns,
).lines;

/// Maps the ChessEver block onto standard NAGs, drops the private block, and
/// records each classified move's address and code for the header tag.
///
/// A classification whose standard mark is already on the move is not written
/// twice: our own exports write the portable verdict *beside* the class
/// (`$6 $244`), so the mapping only fills a gap. Where the class and the
/// verdict disagree — a missed win whose classic glyph was `??` (`$4`) — both
/// marks stay, because the verdict is the move's existing annotation and the
/// task's rule is to keep `$1`–`$6`; the exact class is in the header either
/// way.
({List<String> tokens, Map<String, int> classificationCodes}) _rewriteAnnotations(
  List<String> tokens, {
  required String? result,
}) {
  final out = <String>[];
  final codes = <String, int>{};
  // Standard NAGs already written for this move, so the mapping cannot stack a
  // second copy of a mark the move already carries.
  final written = <int>{};
  // The movetext lines being walked. A `(` opens a block that follows the last
  // move of the enclosing line, which is what every address in the header is
  // built from; the frame keeps that move's key, so a second block on the same
  // move, or a nested one, is addressed exactly.
  final lines = <_MovetextLine>[_MovetextLine.mainline()];
  var sawResult = false;

  for (final token in tokens) {
    if (token.startsWith(r'$')) {
      final nag = int.tryParse(token.substring(1));
      if (nag == null) {
        written.clear();
        out.add(token);
        continue;
      }
      if (isChesseverClassificationCode(nag)) {
        // The class never reaches the movetext: it leaves in the header tag.
        // First code wins — that is the one the app displays.
        final key = lines.last.lastMoveKey;
        if (key != null) codes.putIfAbsent(key, () => nag);
        continue;
      }
      if (nag == kChesseverUserQualityOverrideNag) {
        // ChessEver's provenance flag for a user-edited verdict. Its meaning
        // (the paired `$1`–`$6`) is already in the movetext; the private code
        // itself must never leave the app — see
        // [kChesseverUserQualityOverrideNag].
        continue;
      }
      // An identical mark already written for this move adds nothing.
      if (!written.add(nag)) continue;
      out.add(token);
      continue;
    }

    if (token.startsWith('{')) {
      // Comments travel byte-identical; only the NAG run they end is reset.
      out.add(token);
      written.clear();
      continue;
    }

    if (token == '(') {
      final step = lines.last.openVariation();
      lines.add(
        _MovetextLine.variation(
          parentKey: step.parentKey,
          variation: step.variation,
        ),
      );
      out.add(token);
      written.clear();
      continue;
    }

    if (token == ')') {
      if (lines.length > 1) lines.removeLast();
      out.add(token);
      written.clear();
      continue;
    }

    if (_resultTokens.contains(token)) sawResult = true;

    if (_moveNumberToken.hasMatch(token)) {
      // A move number introduces the move that follows, not a move of its own.
      out.add(token);
      written.clear();
      continue;
    }

    lines.last.addMove();
    out.add(token);
    written.clear();
  }

  // A game handed to another app is a complete file: it needs its result
  // token, the header's value when we know it, `*` when the game has no
  // decided result.
  if (!sawResult) out.add(result ?? '*');
  return (tokens: out, classificationCodes: codes);
}

/// One line of the movetext being walked, so every classified move can be
/// addressed exactly (see the header-tag grammar).
class _MovetextLine {
  _MovetextLine.mainline()
    : _parentKey = null,
      _variation = 0;

  _MovetextLine.variation({required String? parentKey, required int variation})
    : _parentKey = parentKey,
      _variation = variation;

  final String? _parentKey;
  final int _variation;
  int _moves = 0;

  /// Address of the most recent move written in this line.
  String? lastMoveKey;

  /// Block counters, reset whenever the block anchor changes.
  String? _variationAnchor;
  int _variationsForAnchor = 0;

  /// Records the move just written and returns its address (null when the line
  /// has no anchor to be addressed from).
  void addMove() {
    _moves++;
    lastMoveKey = chesseverMoveKey(
      parentKey: _parentKey,
      variation: _variation,
      index: _moves,
    );
  }

  /// Opens a block: which move it follows, and which block of that move it is.
  ({String? parentKey, int variation}) openVariation() {
    if (_variationAnchor != lastMoveKey) {
      _variationAnchor = lastMoveKey;
      _variationsForAnchor = 0;
    }
    _variationsForAnchor++;
    return (parentKey: lastMoveKey, variation: _variationsForAnchor);
  }
}

const Set<String> _resultTokens = {'1-0', '0-1', '1/2-1/2', '*'};

/// Greedy wrap on whole tokens, keeping a move-number indicator with the move
/// it introduces so a line never ends on a stranded `1.` or `1...`.
List<String> _wrapTokens(List<String> tokens, int columns) {
  final lines = <String>[];
  var buffer = StringBuffer();
  var index = 0;

  void push(String unit) {
    if (buffer.isEmpty) {
      buffer.write(unit);
      return;
    }
    if (buffer.length + 1 + unit.length <= columns) {
      buffer.write(' ');
      buffer.write(unit);
      return;
    }
    lines.add(buffer.toString());
    buffer = StringBuffer(unit);
  }

  while (index < tokens.length) {
    var unit = tokens[index];
    final next = index + 1 < tokens.length ? tokens[index + 1] : null;
    if (_moveNumberToken.hasMatch(unit) &&
        next != null &&
        !_breaksMoveNumber(next)) {
      unit = '$unit $next';
      index++;
    }
    index++;
    push(unit);
  }
  if (buffer.isNotEmpty) lines.add(buffer.toString());
  return lines;
}

/// A token that must never be glued onto a preceding move number.
bool _breaksMoveNumber(String token) =>
    token == '(' ||
    token == ')' ||
    token.startsWith('{') ||
    token.startsWith(';') ||
    token.startsWith(r'$') ||
    _moveNumberToken.hasMatch(token);

final RegExp _moveNumberToken = RegExp(r'^\d+\.(?:\.\.)?$');

List<String> _movetextTokens(String text) => _movetextTokenPattern
    .allMatches(text)
    .map((match) => match.group(0)!)
    .toList(growable: false);

/// Comment, rest-of-line comment, NAG, variation parenthesis, or a bare token
/// (SAN, move number, result). Whitespace between tokens is not significant.
final RegExp _movetextTokenPattern = RegExp(
  r'\{[^}]*\}|;[^\n]*|\$\d+|[()]|[^\s(){};]+',
);

class _PgnTextBlock {
  const _PgnTextBlock(this.headers, this.movetext);

  final List<String> headers;
  final String movetext;
}

/// Split PGN text into games: each game is its run of header lines plus the
/// movetext that follows it. A header line always starts a new game.
List<_PgnTextBlock> _splitIntoGames(String text) {
  final blocks = <_PgnTextBlock>[];
  var headers = <String>[];
  final movetext = StringBuffer();

  void flush() {
    if (headers.isEmpty && movetext.isEmpty) return;
    blocks.add(_PgnTextBlock(headers, movetext.toString()));
    headers = <String>[];
    movetext.clear();
  }

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (_headerTagLine.hasMatch(line)) {
      // Headers never follow movetext inside one game.
      if (movetext.isNotEmpty) flush();
      headers.add(line);
      continue;
    }
    movetext.write(line);
    movetext.write(' ');
  }
  flush();
  return blocks;
}

/// A single PGN tag pair, entirely on one line. Movetext never starts with `[`.
final RegExp _headerTagLine = RegExp(
  r'^\[[A-Za-z0-9][A-Za-z0-9_+#=:-]*\s+"(?:[^"\\]|\\.)*"\]$',
);

/// The `Result` header as a movetext token, when the header holds a real one.
String? _resultTokenFromHeaders(List<String> headers) {
  for (final header in headers) {
    final match = _resultHeaderLine.firstMatch(header);
    if (match != null) {
      final value = match.group(1)!.trim();
      if (_resultTokens.contains(value)) return value;
    }
  }
  return null;
}

final RegExp _resultHeaderLine = RegExp(r'^\[Result\s+"([^"]*)"\]');

/// PGN forbids a bare CR anywhere; importers are not required to cope with one.
String _normalizeNewlines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
