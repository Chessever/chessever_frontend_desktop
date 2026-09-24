# CBH helper — local Windows development scope

Native source: rolandlo/libcbh, upstream commit
9641c5c3949d8fb210b17dd9aa54455645843696 (repository remote recorded as
https://github.com/rolandlo/libcbh.git). Copied from the locally hardened evaluation,
not from a binary download. All original file copyright and permission notices
are retained. Native modifications include MSVC portability, strict CBG/CBA
framing/short-read checks, variation bounds, source NAG mapping, root annotations,
final clocks, variant identity, and reset-on-parse. Native JSON transport derives
from the locally written evaluation probe. The 0x07/0x21/0x24 binary layouts were
cross-checked against Morphy's annotation serializers (Yarin78/morphy); no Java
implementation is copied or bundled. Local paired export checks corroborate the
elapsed H/M/S fields and TimeControl values. Reference PGN evaluation values use
integer centipawns, unlike standard PGN pawn units: this converter emits pawn units.

The upstream LICENSE contains GPL version 2 text; several Roland Loetscher files
contain MIT-style permission notices, while Scid-derived files carry their original
GPL/copyright notices. ChessEver's root LICENSE contains GPL version 3 text.
These observations are NOT a distribution-compatibility clearance. This integration
is for local development; external release packaging/license review remains required.
The build copies original notices and native corresponding source beside the helper.
python-chess/chess 1.11.2 supplies legal replay and PGN serialization; its license is
copied from the installed pinned distribution. Python and PyInstaller notices are
also included. No binary or third-party fixture is checked into this integration.

## Supported scope

Windows x64, classic CBH with all seven core companion files. Metadata keeps the
selected Windows-1252 profile when valid. If that strict decoder rejects a field,
a complete strictly valid UTF-8 field is accepted instead, with its original bytes
in `ChessBaseRawText` (base64 ASCII JSON entries: `field`, `hex`, `encoding`). The
`ChessBaseMetadataEncoding` header and receipt `metadataEncoding` declare this
policy. These are original-source fields, not rebound after user edits. Ambiguous
strings valid in both encodings keep the legacy interpretation; no code-page
heuristics, character replacement, stripping, or mojibake repair is performed.
Metadata fields invalid in both encodings still reject atomically with record/field
context and require explicit source-encoding resolution. Game text comments use
UTF-8-if-valid, otherwise Windows-1252. In raw-preservation mode only, undefined
Windows-1252 bytes render visibly as `[ChessBase unknown byte 0x81]` (with the
actual two-digit hex identity), never as a guessed glyph/control or replacement
character. All defined bytes retain the selected rendering profile. This requires
matching original text in `ChessBaseRawAnnotations`; the publisher independently
verifies the complete frame against source bytes. Strict adapter callers and guiding
text decoding remain strict. `ChessBaseUnknownTextBytes` declares the limitation;
receipt `unknownTextByteRecords` and `uninterpretedRecords` expose affected one-based
record ordinals. This is recoverable preservation, NOT exact ChessBase display fidelity
or automatic encoding detection. Literal lookalike escape text is not decoded back:
recovery uses the ordered raw archive (including language bytes, type and original
move address), not string substitution. No source corruption is inferred from an
undefined byte. Orthodox/Chess960
moves, supported variations, text, NAGs, board arrows/squares, and stored final
clocks are preserved. Native null opcodes are explicit null moves. Engine scores
(0x21, ordinary/mate with nonnegative depth) use standard [%eval]; 0x07 elapsed
H/M/S uses [%emt], never [%clk]. Its auxiliary fourth byte is retained verbatim
as [%cbh_emt_flags N], not guessed or silently discarded; a paired export rounds
some nonzero-byte values differently. The auxiliary byte's semantics remain
unverified. Simple whole-second sudden-death 0x24 controls use TimeControl;
unverified stages, nonzero tails and fractional controls are retained as raw fields,
not rendered as guessed clock semantics.
Mandatory roster and decoded source/annotator tags are emitted. Unknown/partial
CBH date components remain PGN question marks. Result bytes 4/5/6 mean black/draw/
white by forfeit (Morphy's `CBUtil.decodeGameResult` and `GameResult`); they retain
their outcome with `Termination "forfeit"`, `ChessBaseResult`, and the raw
`ChessBaseResultCode`. Code 7 means both lost: PGN `Result "*"` plus explicit
`ChessBaseResult "0-0"` and code 7, never a fabricated draw. Codes above 7 and
invalid months still reject. Invalid moves and malformed annotation framing still
reject the complete database. Well-framed annotations outside the decoded move
address range are distinguished from illegal moves: their original addresses and
bytes are retained, with `ChessBaseUnattachedAnnotations "true"`; they are never
attached to an invented move. Strict adapter callers still refuse these unless
raw preservation is explicitly requested.

Every ordinary record retains its 46-byte index in `ChessBaseIndex` (base64), and
its complete referenced CBA frame in `ChessBaseAnnotationFrame` (base64). The
`ChessBaseRawAnnotations` header is base64 ASCII JSON containing the ordered
`move`, `type`, and hex payload inventory, independently checked against the
snapshot before publication. These are explicit version-1 preservation fields,
not promises that another PGN viewer renders ChessBase-only features. Unknown
annotations are not discarded or given guessed meanings. The receipt and helper
completion response enumerate records with uninterpreted or unattached fields.

Version-1 plain-text/formatting and version-3 HTML guiding containers become
distinct zero-move PGN records with all titles and language bodies, original
complete container in `ChessBaseGuidingText`, and original index bytes. Guiding
index bytes 7..9 are a tournament id, not part of a CBA pointer. The index and
container layouts are corroborated by the locally available Morphy
`GameHeaderIndex.deserializeItem`, `TextContentsModel`, and format/v1 documents;
no Java implementation is copied. Body decoding uses UTF-8-if-valid then strict
Windows-1252. HTML stays inert; image references have visible placeholders and
are never fetched. V1 formatting/object data remain archived, with an explicit
`ChessBaseGuidingRendering` limitation and receipt uninterpreted-record entry;
control-byte identities are visible, not discarded or invented diagrams.
Empty bodies stay empty documents. Version 2 and unknown flags/trailers still
reject; other unknown text encodings require explicit resolution.
Literal braces in game comments render as `&#123;`/`&#125;` only with a raw
annotation archive, avoiding PGN's silent closing-brace loss. The source bytes
remain exact; the `ChessBaseCommentRendering` header declares the rendering.
Morphy's public annotation-text specification corroborates direct numeric NAG
identities, including the additional stored 7/8/10/30 values; these are preserved
as numbers rather than color-dependent reinterpretations.

Proprietary external media, search indexes and extended biographies are not
claimed supported. Embedded unknown annotation payloads are preserved, not played
or fetched. Per-move clocks absent from the indexed source are not invented.
Round/subround follows source bytes, not a richer reference export. 512 MiB input,
100,000 records and a two-minute native decode limit currently apply.

The publisher verifies metadata record ranges before native parsing, snapshots sources,
checks SHA-256 again before publication, legally replays and round-trips every game,
and atomically renames a unique directory containing PGN plus provenance receipt.
It never overwrites an existing copy. Reuse requires source hashes + exact PGN hash;
edited copies remain untouched. Normal cancellation is cooperative and removes staging.
An OS crash/power loss can leave a hidden .cbh-* staging directory, never registered PGN.
macOS/Linux builds, adversarial fuzz certification and release signing are unverified.

## Build and test

`python tools/cbh_converter/build_windows.py` builds native code clean-first and freezes
a self-contained helper under `build/cbh_converter/dist/chessever_cbh/`. Runtime uses
only this bundle, not Python on PATH or the evaluation directory. The isolated Windows
builder invokes this step and installs the bundle alongside ChessEverDev.exe.
Tests take explicit `CBH_TEST_FIXTURE` and `CBH_TEST_PROBE` environment variables;
fixtures remain outside this repository. `test_converter.py` exercises real native
conversion and publication. The source test fixture is never modified.
