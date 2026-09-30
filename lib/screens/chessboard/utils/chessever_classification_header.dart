/// ChessEver's private move-classification carrier: a PGN **header tag**.
///
/// ## Why a header tag
///
/// A game copied out of ChessEver must import in stricter consumers, and those
/// consumers only know the standard NAGs `$1`–`$6`. Those collapse our eight
/// classes (`good`/`best` → `!`, `missedWin`/`inaccuracy` → `?!`, blunder and
/// book have no honest equivalent), and our own native block `$240`–`$247` is
/// outside the range a foreign importer accepts at all. Losing a class costs a
/// badge, never a move — but a copied game that comes home should still show
/// the exact ChessEver label it left with.
///
/// The first attempt carried the class in the move's comment payload as
/// `[%ce 247]`. ChessBase *stores* that verbatim, so the user saw
/// `1.e4 0.39 [%ce 247] 1...e6 0.44` in the notation list: a private machine
/// tag printed as if it were prose. A comment directive cannot be trusted to
/// stay invisible in a viewer that shows comments.
///
/// A **tag pair in the game's header section** has the property we actually
/// need: every reader keeps it as metadata, none of them renders it in the
/// notation, and it travels with a full-PGN copy/paste. So this module owns
/// one grammar, used by the copy boundary that writes it and by import, which
/// reads it back into the native `$240`–`$247` block.
///
/// ## Grammar
///
///     tag    := "[ChessEverClassification \"" value "\"]"
///     value  := entry (SP+ entry)*
///     entry  := key "=" code
///     key    := ply                        ; a mainline move
///             | anchor "v" alt "." index   ; a variation move
///     ply    := 1-based position of the move in the mainline move sequence
///     anchor := the key of the move the variation block follows
///     alt    := 1-based index of that block among the blocks following the move
///     index  := 1-based position of the move inside that block
///     code   := a ChessEver classification code, 240..247
///
/// The address is exactly the walk the importer already makes, so restoration
/// is positional and exact:
///
/// * the first move of the game is ply `1` — for a game that starts from a FEN
///   with black to move that first move is black's, and `1... e5` is still
///   ply `1`, because the sequence is what is being addressed, not the colour;
/// * a variation block written after a move is addressed *from that move*:
///   `[ChessEverClassification "1=244 2=247 3v1.1=240"]` means mainline move 1
///   is inaccuracy, move 2 is book, and the first move of the first variation
///   that follows mainline move 3 is brilliant;
/// * nesting repeats the step: `3v1.2v1.1` is the first move of the first
///   variation following the second move of the first variation after move 3;
/// * each game of a multi-game blob carries its own tag, and its plies restart
///   at `1` — the tag belongs to the header block of the game it describes.
///
/// Example, one game, one class on the third move:
///
///     [Event "Test Open"]
///     [Result "1-0"]
///     [ChessEverClassification "3=244"]
///
///     1. e4 e5 2. Nf3 { [%eval -0.32] [%clk 1:30:53] } 1-0
///
/// A move's class stays one code: the app itself shows the first `$24x` a move
/// carries, so the header records that same code and a hand-edited PGN with two
/// codes cannot make the two readers disagree.
///
/// The tag is written only when at least one class exists, it lives inside the
/// header block so a copy/paste carries it, and it is dropped when the PGN
/// becomes a game — a private carrier must not ride back into the user's own
/// files, where the native `$240`–`$247` block is the format.
library;

/// The private header tag name. Stable: it is the only thing that lets a copied
/// game come back into ChessEver with its exact classes.
const String kChesseverClassificationHeaderTag = 'ChessEverClassification';

/// The ChessEver classification codes, mirroring
/// `kChesseverClassificationNags`: `$240`–`$247`, one per report class.
///
/// Kept as a plain code set (not the enum-keyed table) so this module has no
/// imports: the writer, the importer and their regressions can all execute it
/// on a bare Dart VM. A regression asserts this set equals
/// `kChesseverClassificationNags.values`.
const Set<int> kChesseverClassificationCodes = {
  240,
  241,
  242,
  243,
  244,
  245,
  246,
  247,
};

/// Whether [nag] belongs to the ChessEver classification block.
bool isChesseverClassificationCode(int nag) =>
    kChesseverClassificationCodes.contains(nag);

/// The standard NAG (`$1`–`$6`, or null) a *foreign* reader should see for each
/// ChessEver code.
///
/// Three collapses are unavoidable and deliberate: `goodMove` and `bestMove`
/// both mean "the move we would have played"; `missedWin` and `inaccuracy` both
/// land on the doubtful mark `?!`; `bookMove` has no standard equivalent at all.
///
/// `bestMove` is `$1` rather than "no NAG": it is by far the most common class
/// in a report and the glyph the report export already chose for it.
const Map<int, int?> kExternalNagForChesseverCode = {
  240: 3, // brilliant  !!  — the one unambiguous mark
  241: 1, // good move  !
  242: 1, // best move  !
  243: 6, // missed win ?!
  244: 6, // inaccuracy ?!
  245: 2, // mistake    ?
  246: 4, // blunder    ??
  247: null, // book move — no standard equivalent
};

/// The legacy in-comment marker tag (`{ [%ce 242] }`).
///
/// Builds up to 21.5.3 wrote the class into the move's comment payload, which
/// ChessBase printed in the notation list. The writer no longer produces it;
/// import still reads it, because copies already made by that build exist.
const String kChesseverMarkerTag = 'ce';

/// Marks a standard quality NAG ($1–$6) as a later ChessEver user override.
///
/// The paired `$1`–`$6` remains portable for other PGN readers. This marker
/// preserves edit provenance so a background report cannot reclaim the move
/// after Save/Copy/Share and reopen. It is a private code and never leaves the
/// app: the copy boundary drops it (`pgn_external_compat.dart`).
const int kChesseverUserQualityOverrideNag = 248;

final RegExp _chesseverMarkerDirective = RegExp(
  r'\[%\s*ce\s+([^\]]+?)\s*\]',
  caseSensitive: false,
);

final RegExp _moveKeyPattern = RegExp(r'^\d+(?:v\d+\.\d+)*$');

/// The address of the [index]-th (1-based) move of one movetext line.
///
/// A bare ply for the mainline ([parentKey] null, [variation] 0); otherwise the
/// anchor move's key plus the variation step. Null when the line has no anchor
/// to be addressed from (a variation before any move — no legal movetext).
String? chesseverMoveKey({
  String? parentKey,
  int variation = 0,
  required int index,
}) {
  if (parentKey == null) return variation == 0 ? '$index' : null;
  return '${parentKey}v$variation.$index';
}

/// The address of the move that continues [key]'s line.
String chesseverNextMoveKey(String key) {
  final dot = key.lastIndexOf('.');
  if (dot == -1) {
    final ply = int.tryParse(key);
    return ply == null ? key : '${ply + 1}';
  }
  final head = key.substring(0, dot);
  final tail = int.tryParse(key.substring(dot + 1));
  return tail == null ? key : '$head.${tail + 1}';
}

/// Whether [key] is a well-formed movetext address.
bool isChesseverMoveKey(String key) => _moveKeyPattern.hasMatch(key);

/// The header line for [codeByKey], or null when nothing is classified.
///
/// Entries are sorted so the same game always produces the same bytes, and each
/// address keeps the first code seen for it.
String? chesseverClassificationHeaderValue(Map<String, int> codeByKey) {
  final entries = <String>[];
  final seen = <String>{};
  for (final entry in codeByKey.entries) {
    final code = entry.value;
    if (!isChesseverClassificationCode(code)) continue;
    if (!isChesseverMoveKey(entry.key)) continue;
    if (!seen.add(entry.key)) continue;
    entries.add('${entry.key}=$code');
  }
  if (entries.isEmpty) return null;
  entries.sort(_compareMoveKeys);
  return '[$kChesseverClassificationHeaderTag "${entries.join(' ')}"]';
}

/// The classification codes a header value carries, keyed by movetext address.
///
/// Tolerant by design: unknown codes, malformed entries and duplicate
/// addresses are ignored, and an absent/unreadable tag yields an empty map (a
/// copy that lost its tag costs a badge, never a move).
Map<String, int> parseChesseverClassificationHeader(String? value) {
  if (value == null || value.trim().isEmpty) return const <String, int>{};
  final codes = <String, int>{};
  for (final part in value.split(RegExp(r'[\s,]+'))) {
    if (part.isEmpty) continue;
    final separator = part.indexOf('=');
    if (separator <= 0 || separator == part.length - 1) continue;
    final key = part.substring(0, separator);
    final code = int.tryParse(part.substring(separator + 1));
    if (code == null || !isChesseverClassificationCode(code)) continue;
    if (!isChesseverMoveKey(key)) continue;
    codes.putIfAbsent(key, () => code);
  }
  return codes;
}

/// The value of the private tag in [headers], or null when the PGN has none.
///
/// Tag names are compared case-insensitively so an app that normalizes header
/// case cannot hide the tag from import.
String? chesseverClassificationHeaderOf(Map<String, Object?>? headers) {
  if (headers == null) return null;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() ==
        kChesseverClassificationHeaderTag.toLowerCase()) {
      return entry.value?.toString();
    }
  }
  return null;
}

/// [headers] without the private classification tag.
///
/// Used the moment a PGN becomes a game: the classes now live in the moves'
/// native `$240`–`$247` block, so the carrier must not ride back into the game,
/// into the files it is saved to, or into any header the app shows the user.
Map<String, V> withoutChesseverClassificationHeader<V>(
  Map<String, V> headers,
) {
  final kept = <String, V>{};
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() ==
        kChesseverClassificationHeaderTag.toLowerCase()) {
      continue;
    }
    kept[entry.key] = entry.value;
  }
  return kept;
}

/// ChessEver classification codes carried by a legacy `[%ce …]` comment.
///
/// Unknown codes are ignored; the result is empty when no marker is present.
List<int> chesseverCodesFromMarker(Iterable<String>? comments) {
  if (comments == null) return const <int>[];
  final codes = <int>[];
  for (final comment in comments) {
    for (final match in _chesseverMarkerDirective.allMatches(comment)) {
      for (final part in match.group(1)!.split(RegExp(r'[\s,]+'))) {
        final code = int.tryParse(part);
        if (code == null) continue;
        if (!isChesseverClassificationCode(code)) continue;
        if (!codes.contains(code)) codes.add(code);
      }
    }
  }
  return codes;
}

/// The NAGs a move should carry after import.
///
/// Precedence, and nothing is ever annotated twice:
///
/// 1. a native `$240`–`$247` code already on the move is authoritative — that
///    block is what our own files, the cloud format and older builds carry;
/// 2. otherwise the private header tag's code for this move's address, which is
///    what the external-compatible copy path writes;
/// 3. otherwise a legacy `[%ce …]` comment marker, which copies made before
///    21.5.4 carry inside the movetext.
List<int>? restoreChesseverClassificationNags({
  required List<int>? nags,
  required Iterable<String>? comments,
  String? moveKey,
  Map<String, int>? headerCodes,
}) {
  final existing = nags ?? const <int>[];
  if (existing.any(isChesseverClassificationCode)) return nags;
  if (moveKey != null && headerCodes != null) {
    final code = headerCodes[moveKey];
    if (code != null && !existing.contains(code)) {
      return <int>[...existing, code];
    }
  }
  final codes = chesseverCodesFromMarker(comments);
  if (codes.isEmpty) return nags;
  final restored = <int>[...existing];
  for (final code in codes) {
    if (!restored.contains(code)) restored.add(code);
  }
  return restored;
}

/// Comments with a consumed legacy `[%ce …]` marker removed.
///
/// Once the marker's codes live in the move's NAGs, keeping the directive would
/// leave a private tag in the game — and in every file it is saved to
/// afterwards. A comment that held nothing but the marker disappears;
/// `[%eval …]` / `[%clk …]` payloads beside it are untouched.
///
/// A marker whose codes are all unknown is left alone: nothing was consumed, so
/// nothing may be discarded.
List<String>? stripChesseverMarker(Iterable<String>? comments) {
  if (comments == null) return null;
  if (chesseverCodesFromMarker(comments).isEmpty) return comments.toList();
  final stripped = <String>[];
  for (final comment in comments) {
    final remaining = comment
        .replaceAll(_chesseverMarkerDirective, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (remaining.isNotEmpty) stripped.add(remaining);
  }
  return stripped;
}

/// Orders addresses the way a reader walks them: plies numerically, then each
/// variation after the move it follows (a well-formed movetext writes a block
/// between its anchor move and the next move of the enclosing line, so this is
/// also the order the writer saw them).
int _compareMoveKeys(String a, String b) {
  final left = _moveKeySteps(a);
  final right = _moveKeySteps(b);
  final shared = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < shared; i++) {
    final step = left[i];
    final other = right[i];
    if (step.variation != other.variation) {
      return step.variation.compareTo(other.variation);
    }
    if (step.index != other.index) return step.index.compareTo(other.index);
  }
  return left.length.compareTo(right.length);
}

/// `3v1.2v1.1` -> ply 3, then variation 1 index 2, then variation 1 index 1.
List<({int variation, int index})> _moveKeySteps(String key) {
  final steps = <({int variation, int index})>[];
  final ply = RegExp(r'^\d+').firstMatch(key);
  steps.add((variation: 0, index: ply == null ? 0 : int.parse(ply.group(0)!)));
  for (final match in RegExp(r'v(\d+)\.(\d+)').allMatches(key)) {
    steps.add((
      variation: int.parse(match.group(1)!),
      index: int.parse(match.group(2)!),
    ));
  }
  return steps;
}
