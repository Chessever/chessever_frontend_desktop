import 'dart:io';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'pgn_record_boundaries.dart';

import 'local_chess_pgn_fingerprint.dart';

/// Decodes PGN bytes the way the import scanner does: UTF-8 with malformed
/// sequences replaced, falling back to Latin-1 only when UTF-8 yields nothing.
/// Every fingerprint and revision is computed over text decoded this way, so
/// readers must not use `File.readAsString`, which throws on the Latin-1
/// files ChessBase and older tools still write.
String decodeLocalPgnText(List<int> bytes) {
  final utf = utf8.decode(bytes, allowMalformed: true);
  if (utf.trim().isNotEmpty) return utf;
  return latin1.decode(bytes, allowInvalid: true);
}

/// The replacement PGN was rejected before the file was touched: the local
/// database could not index it, and committing it anyway would drop the game
/// from the cache the moment the file was reconciled.
final class LocalChessPgnReplacementRejectedException implements Exception {
  const LocalChessPgnReplacementRejectedException(this.reason);

  final String reason;

  @override
  String toString() =>
      'The updated game could not be indexed for the local database '
      '($reason). The source file was left unchanged.';
}

/// Physical record boundaries, never deduplicated cache ordinals. Offsets are
/// Dart string offsets into the exact supplied snapshot (not cached byte spans).
class PgnGameRange {
  const PgnGameRange(this.start, this.end);

  final int start;
  final int end;
}

/// Exact-record revision, intentionally separate from mainline deduplication.
String localPgnRecordRevision(String raw) =>
    sha256.convert(utf8.encode(raw.trim())).toString();

List<PgnGameRange> pgnGameRanges(String text) {
  final bytes = utf8.encode(text);
  final byteRanges = <PgnGameRange>[];
  final boundary = PgnRecordBoundaryTracker();
  var start = 0;
  void flush(int end) {
    if (boundary.isRecord) byteRanges.add(PgnGameRange(start, end));
    boundary.reset();
  }

  final scanner = PgnByteLineScanner((line) {
    if (boundary.startsNewRecord(line)) flush(line.startOffset);
    final hadCurrent = boundary.hasCurrent;
    if (boundary.add(line) && !hadCurrent) start = line.contentStartOffset;
  });
  scanner.scanBytes(Uint8List.fromList(bytes));
  flush(bytes.length);
  // Map UTF-8 offsets to original UTF-16 offsets once, without normalizing CRs.
  final boundaries = {
    for (final r in byteRanges) ...[r.start, r.end],
  };
  final offsets = <int, int>{0: 0};
  var byteOffset = 0;
  var stringOffset = 0;
  for (final rune in text.runes) {
    byteOffset +=
        rune <= 0x7f
            ? 1
            : rune <= 0x7ff
            ? 2
            : rune <= 0xffff
            ? 3
            : 4;
    stringOffset += rune > 0xffff ? 2 : 1;
    if (boundaries.contains(byteOffset)) offsets[byteOffset] = stringOffset;
  }
  return [
    for (final r in byteRanges)
      PgnGameRange(offsets[r.start]!, offsets[r.end]!),
  ];
}

String localPgnRecordFromSnapshot({
  List<PgnGameRange>? recordRanges,
  required String text,
  required int indexInFile,
  int? expectedFileGameCount,
  String? expectedPgnFingerprint,
  String? expectedRecordRevision,
}) {
  final ranges = recordRanges ?? pgnGameRanges(text);
  if (expectedFileGameCount != null &&
      expectedFileGameCount > 0 &&
      ranges.length != expectedFileGameCount) {
    throw StateError(
      'The source PGN game count changed. Refresh the database.',
    );
  }
  if (indexInFile < 0 || indexInFile >= ranges.length) {
    throw StateError(
      'The original PGN record is missing. Refresh the database.',
    );
  }
  final range = ranges[indexInFile];
  final raw = text.substring(range.start, range.end).trim();
  final fingerprint = expectedPgnFingerprint?.trim() ?? '';
  if (fingerprint.isNotEmpty && localChessPgnFingerprint(raw) != fingerprint) {
    throw StateError(
      'The source PGN game changed. Refresh the database before opening or updating it.',
    );
  }
  if (expectedRecordRevision != null &&
      expectedRecordRevision.isNotEmpty &&
      localPgnRecordRevision(raw) != expectedRecordRevision) {
    throw StateError(
      'The source PGN annotations changed. Refresh before saving.',
    );
  }
  return raw;
}

/// Cached byte ranges are only hints. Resolve the physical ordinal afresh so a
/// comment-length edit in an earlier record cannot hydrate a truncated neighbor.
///
/// Reads and scans the whole file synchronously; on the UI isolate prefer
/// [readLocalPgnRecordInBackground] for anything but small files.
String readLocalPgnRecord({
  required String path,
  required int indexInFile,
  int? expectedFileGameCount,
  String? expectedPgnFingerprint,
  String? expectedRecordRevision,
}) => localPgnRecordFromSnapshot(
  text: decodeLocalPgnText(File(path).readAsBytesSync()),
  indexInFile: indexInFile,
  expectedFileGameCount: expectedFileGameCount,
  expectedPgnFingerprint: expectedPgnFingerprint,
  expectedRecordRevision: expectedRecordRevision,
);

/// [readLocalPgnRecord] on a worker isolate, so a large database's read and
/// boundary scan never stall the UI isolate. Validation failures surface as
/// the same [StateError]s the synchronous reader throws.
Future<String> readLocalPgnRecordInBackground({
  required String path,
  required int indexInFile,
  int? expectedFileGameCount,
  String? expectedPgnFingerprint,
  String? expectedRecordRevision,
}) async {
  final outcome = await Isolate.run(() {
    try {
      return (
        pgn: readLocalPgnRecord(
          path: path,
          indexInFile: indexInFile,
          expectedFileGameCount: expectedFileGameCount,
          expectedPgnFingerprint: expectedPgnFingerprint,
          expectedRecordRevision: expectedRecordRevision,
        ),
        error: null,
      );
    } on StateError catch (error) {
      return (pgn: null, error: error.message);
    }
  });
  final error = outcome.error;
  if (error != null) throw StateError(error);
  return outcome.pgn!;
}

String replaceLocalPgnRecordInSnapshot({
  required String text,
  required int indexInFile,
  required String rawPgn,
  int? expectedFileGameCount,
  String? expectedPgnFingerprint,
  String? expectedRecordRevision,
}) {
  final ranges = pgnGameRanges(text);
  localPgnRecordFromSnapshot(
    recordRanges: ranges,
    text: text,
    indexInFile: indexInFile,
    expectedFileGameCount: expectedFileGameCount,
    expectedPgnFingerprint: expectedPgnFingerprint,
    expectedRecordRevision: expectedRecordRevision,
  );
  final replacement = rawPgn.trim();
  if (replacement.isEmpty || pgnGameRanges(replacement).length != 1) {
    throw ArgumentError(
      'An update must contain exactly one complete PGN record.',
    );
  }
  final range = ranges[indexInFile];
  final original = text.substring(range.start, range.end);
  final trailing = original.substring(original.trimRight().length);
  // Preserve every character outside the target, including BOM, CRLF, duplicate
  // records, unindexed games and the exact whitespace preceding the next game.
  return text.substring(0, range.start) +
      replacement +
      (trailing.isEmpty ? '\n\n' : trailing) +
      text.substring(range.end);
}

/// Delete only selected physical ranges; cached/deduplicated survivors are not
/// an authoritative representation of the user's file.
String removeLocalPgnRecordsFromSnapshot({
  required String text,
  required Set<int> indexesInFile,
  required Map<int, String> expectedRecordRevisions,
  int? expectedFileGameCount,
}) {
  final ranges = pgnGameRanges(text);
  for (final index in indexesInFile) {
    final revision = expectedRecordRevisions[index];
    if (revision == null || revision.isEmpty) {
      throw StateError('Reopen the selected games before deleting.');
    }
    localPgnRecordFromSnapshot(
      recordRanges: ranges,
      text: text,
      indexInFile: index,
      expectedFileGameCount: expectedFileGameCount,
      expectedRecordRevision: revision,
    );
  }
  var next = text;
  final descending = indexesInFile.toList()..sort((a, b) => b.compareTo(a));
  for (final index in descending) {
    final range = ranges[index];
    next = next.replaceRange(range.start, range.end, '');
  }
  return next;
}
