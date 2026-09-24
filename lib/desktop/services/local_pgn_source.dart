import 'dart:async';
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

/// Resolve one record from an immutable byte snapshot. Keep the same physical
/// boundary tracker/count checks as the mutation reader, but decode only the
/// selected record, avoiding whole-file UTF-16 conversion and offset mapping.
/// No cached spans or file stamps are trusted; no cache writer queue is entered.
String _readLocalPgnRecordBytes({
  required String path,
  required int indexInFile,
  int? expectedFileGameCount,
  String? expectedPgnFingerprint,
  String? expectedRecordRevision,
}) {
  final bytes = File(path).readAsBytesSync();
  var snapshot = _workerSnapshot;
  if (snapshot == null ||
      snapshot.path != path ||
      !_samePgnBytes(snapshot.bytes, bytes)) {
    final ranges = <PgnGameRange>[];
    final boundary = PgnRecordBoundaryTracker();
    var start = 0;
    void flush(int end) {
      if (boundary.isRecord) ranges.add(PgnGameRange(start, end));
      boundary.reset();
    }

    PgnByteLineScanner((line) {
      if (boundary.startsNewRecord(line)) flush(line.startOffset);
      final hadCurrent = boundary.hasCurrent;
      if (boundary.add(line) && !hadCurrent) start = line.contentStartOffset;
    }).scanBytes(bytes);
    flush(bytes.length);
    snapshot = _PgnByteSnapshot(path, bytes, ranges);
    // One source only, bounded, owned by the worker (never copied to the UI).
    // Oversized sources retain correctness but do not retain their bytes.
    _workerSnapshot = bytes.length <= 256 * 1024 * 1024 ? snapshot : null;
  }
  final count = snapshot.ranges.length;
  if (expectedFileGameCount != null &&
      expectedFileGameCount > 0 &&
      count != expectedFileGameCount) {
    throw StateError(
      'The source PGN game count changed. Refresh the database.',
    );
  }
  if (indexInFile < 0 || indexInFile >= count) {
    throw StateError(
      'The original PGN record is missing. Refresh the database.',
    );
  }
  final range = snapshot.ranges[indexInFile];
  final raw = decodeLocalPgnText(
    Uint8List.sublistView(bytes, range.start, range.end),
  );
  return localPgnRecordFromSnapshot(
    text: raw,
    recordRanges: [PgnGameRange(0, raw.length)],
    indexInFile: 0,
    expectedPgnFingerprint: expectedPgnFingerprint,
    expectedRecordRevision: expectedRecordRevision,
  );
}

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
  // A worker may retire during the send/idle boundary. Retry that transport
  // race once; source-validation failures are never retried or hidden here.
  for (var attempt = 0; ; attempt++) {
    final worker = _readWorker ??= _PgnReadWorker();
    try {
      return await worker.read([
        path,
        indexInFile,
        expectedFileGameCount,
        expectedPgnFingerprint,
        expectedRecordRevision,
      ]);
    } on _PgnWorkerClosed {
      if (attempt > 0) rethrow;
    }
  }
}

class _PgnByteSnapshot {
  _PgnByteSnapshot(this.path, this.bytes, this.ranges);
  final String path;
  final Uint8List bytes;
  final List<PgnGameRange> ranges;
}

// These bytes exist only on the read worker. Reuse requires exact equality of
// EVERY byte in a fresh read, not sampled hashes, length/mtime or cached offsets.
_PgnByteSnapshot? _workerSnapshot;
bool _samePgnBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  final words = a.length ~/ 8;
  final aw = a.buffer.asUint64List(a.offsetInBytes, words);
  final bw = b.buffer.asUint64List(b.offsetInBytes, words);
  for (var i = 0; i < words; i++) {
    if (aw[i] != bw[i]) return false;
  }
  for (var i = words * 8; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

_PgnReadWorker? _readWorker;

class _PgnWorkerClosed implements Exception {}

class _PgnReadWorker {
  _PgnReadWorker() {
    _replies.listen(_receive);
    Isolate.spawn(
      _runPgnReads,
      _replies.sendPort,
      onExit: _replies.sendPort,
      onError: _replies.sendPort,
    ).catchError((Object error, StackTrace stack) {
      _close(error, stack);
      throw error;
    }).ignore();
  }
  final _replies = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<String>>{};
  var _next = 0;
  bool _closed = false;

  Future<String> read(List<Object?> args) async {
    final port = await _ready.future;
    if (_closed) throw _PgnWorkerClosed();
    final id = _next++;
    final result = Completer<String>();
    _pending[id] = result;
    port.send([id, ...args]);
    return result.future;
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      _ready.complete(message);
    } else if (message == null) {
      _close(_PgnWorkerClosed(), StackTrace.current);
    } else if (message is List && message.first is int) {
      final result = _pending.remove(message[0]);
      if (result == null) return;
      switch (message[1]) {
        case 'ok':
          result.complete(message[2] as String);
        case 'state':
          result.completeError(StateError(message[2]));
        case 'file':
          result.completeError(
            FileSystemException(message[2] as String, message[3] as String),
          );
        default:
          result.completeError(
            RemoteError(message[2].toString(), message[3].toString()),
          );
      }
    } else {
      _close(RemoteError(message.toString(), ''), StackTrace.current);
    }
  }

  void _close(Object error, StackTrace stack) {
    if (_closed) return;
    _closed = true;
    if (identical(_readWorker, this)) _readWorker = null;
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    for (final result in _pending.values) {
      result.completeError(error, stack);
    }
    _pending.clear();
    _replies.close();
  }
}

void _runPgnReads(SendPort replies) {
  final requests = ReceivePort();
  Timer? idle;
  void retireWhenIdle() {
    idle?.cancel();
    // The snapshot and all retained bytes disappear with the worker. This
    // timer lives off the UI isolate and cannot keep a disposed widget alive.
    idle = Timer(const Duration(seconds: 30), () => Isolate.exit());
  }

  replies.send(requests.sendPort);
  retireWhenIdle();
  requests.listen((dynamic request) {
    idle?.cancel();
    final args = request as List;
    final id = args[0] as int;
    try {
      final pgn = _readLocalPgnRecordBytes(
        path: args[1] as String,
        indexInFile: args[2] as int,
        expectedFileGameCount: args[3] as int?,
        expectedPgnFingerprint: args[4] as String?,
        expectedRecordRevision: args[5] as String?,
      );
      replies.send([id, 'ok', pgn]);
    } on StateError catch (error) {
      replies.send([id, 'state', error.message]);
    } on FileSystemException catch (error) {
      replies.send([id, 'file', error.message, error.path]);
    } catch (error, stack) {
      replies.send([id, 'other', error.toString(), stack.toString()]);
    }
    retireWhenIdle();
  });
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
