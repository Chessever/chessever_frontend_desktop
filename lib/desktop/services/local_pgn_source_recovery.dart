import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

import '../state/tournament_games.dart';
import 'local_chess_file_scanner.dart' show localChessInputPathKey;
import 'local_chess_pgn_fingerprint.dart';
import 'local_pgn_source.dart';

/// Recovers a retained local-PGN row whose stored coordinates can no longer be
/// verified against its file.
///
/// Opening a row from a local database normally re-reads the physical record at
/// the stored path/index/count/fingerprint. When the file changed after it was
/// indexed (games appended, an external editor rewrote it, or the row came from
/// an older cache) that validation fails. The guard is correct — the row's
/// stored identity cannot be trusted — but it must not dead-end the open.
///
/// This service re-resolves the *same game by identity* (never index-only)
/// against a fresh snapshot of the file, heals the stale cache for that source,
/// and returns coordinates the ordinary reader can verify again. It never
/// writes the user's PGN file or any annotation, and it refuses (rather than
/// guessing) when the identity is ambiguous.

/// Identity signals a retained database row still carries.
///
/// The strongest signals are the exact record revision (annotations included)
/// and the mainline fingerprint (annotation-insensitive dedupe hash). Rows that
/// were never fully captured — lightweight catalogs, legacy caches — fall back
/// to header identity (players, round, result) plus the stored ordinal.
class LocalPgnRecordIdentity {
  const LocalPgnRecordIdentity({
    required this.storedIndex,
    this.recordRevision = '',
    this.mainlineFingerprint = '',
    this.inlinePgn = '',
    this.white = '',
    this.black = '',
    this.round = '',
    this.result = '',
  });

  /// Builds the identity a retained summary can still prove.
  ///
  /// An inline PGN (a fully captured record) is turned into the exact revision
  /// and the mainline fingerprint, so even a row whose stored revision is
  /// missing can be matched without falling back to position alone.
  factory LocalPgnRecordIdentity.forSummary(TournamentGameSummary game) {
    final source = game.localPgnSource;
    final inline = (game.pgn ?? '').trim();
    final revision = source?.recordRevision.trim() ?? '';
    final fingerprint = source?.pgnFingerprint.trim() ?? '';
    return LocalPgnRecordIdentity(
      storedIndex: source?.sourceIndex ?? -1,
      recordRevision:
          revision.isNotEmpty
              ? revision
              : inline.isEmpty
              ? ''
              : localPgnRecordRevision(inline),
      mainlineFingerprint:
          fingerprint.isNotEmpty
              ? fingerprint
              : inline.isEmpty
              ? ''
              : localChessPgnFingerprint(inline),
      inlinePgn: inline,
      white: game.whitePlayer.trim(),
      black: game.blackPlayer.trim(),
      round: game.roundLabel.trim(),
      result: _resultTag(game.status),
    );
  }

  /// Physical ordinal the stale row was captured at. Only ever used to break a
  /// tie between records that already carry the same proven identity.
  final int storedIndex;
  final String recordRevision;
  final String mainlineFingerprint;
  final String inlinePgn;
  final String white;
  final String black;
  final String round;
  final String result;

  /// True when the row can be matched without relying on position at all.
  bool get hasStrongIdentity =>
      recordRevision.trim().isNotEmpty ||
      mainlineFingerprint.trim().isNotEmpty ||
      inlinePgn.trim().isNotEmpty;

  /// True when at least one header tag survived into the retained row.
  bool get hasHeaderIdentity =>
      _isKnownTag(white) ||
      _isKnownTag(black) ||
      _isKnownTag(round) ||
      _isKnownTag(result);

  bool get hasAnyIdentity => hasStrongIdentity || hasHeaderIdentity;
}

/// One record of the current file, matched to a retained row.
class LocalPgnIdentityResolution {
  const LocalPgnIdentityResolution({
    required this.indexInFile,
    required this.fileGameCount,
    required this.rawPgn,
    required this.mainlineFingerprint,
    required this.recordRevision,
  });

  /// Physical ordinal in the snapshot this resolution was proven against.
  final int indexInFile;
  final int fileGameCount;
  final String rawPgn;
  final String mainlineFingerprint;
  final String recordRevision;

  /// Exact-record equality. Used to detect another writer changing the file
  /// between the recovery read and the read that follows the rescan.
  bool sameRecordAs(LocalPgnIdentityResolution other) =>
      recordRevision == other.recordRevision &&
      mainlineFingerprint == other.mainlineFingerprint;

  bool sameGameAs(LocalPgnIdentityResolution other) =>
      mainlineFingerprint == other.mainlineFingerprint;
}

/// Outcome of matching a retained row against one file snapshot.
sealed class LocalPgnIdentityOutcome {
  const LocalPgnIdentityOutcome();
}

final class LocalPgnIdentityResolved extends LocalPgnIdentityOutcome {
  const LocalPgnIdentityResolved(this.resolution);

  final LocalPgnIdentityResolution resolution;
}

/// No record in the snapshot carries this row's identity.
final class LocalPgnIdentityNotFound extends LocalPgnIdentityOutcome {
  const LocalPgnIdentityNotFound();
}

/// Several records carry the identity and none of them is the stored ordinal.
/// Guessing here could open a different game; the caller must refuse.
final class LocalPgnIdentityAmbiguous extends LocalPgnIdentityOutcome {
  const LocalPgnIdentityAmbiguous(this.matchCount, this.strength);

  final int matchCount;

  /// 3 = exact revision, 2 = mainline fingerprint, 1 = header identity.
  final int strength;
}

/// The file could not be read at all (missing, locked, permission denied).
final class LocalPgnIdentityUnreadable extends LocalPgnIdentityOutcome {
  const LocalPgnIdentityUnreadable(this.detail);

  final String detail;
}

/// Matches one retained row against a file snapshot, by identity only.
///
/// Records are scored by the strongest signal they can prove:
/// exact record revision (annotations included) > mainline fingerprint >
/// header identity. A unique best match wins. When several records tie, the
/// stored ordinal may break the tie *only* because those records already
/// proved the row's identity — a duplicate record in the same file must still
/// open where it was stored. Anything else is reported as ambiguous.
LocalPgnIdentityOutcome matchLocalPgnRecordByIdentity({
  required String text,
  required LocalPgnRecordIdentity identity,
  List<PgnGameRange>? recordRanges,
}) {
  final ranges = recordRanges ?? pgnGameRanges(text);
  final expectedRevision = identity.recordRevision.trim();
  final expectedFingerprint = identity.mainlineFingerprint.trim();
  final matches = <_IdentityCandidate>[];

  for (var index = 0; index < ranges.length; index++) {
    final range = ranges[index];
    if (range.end <= range.start) continue;
    final raw = text.substring(range.start, range.end).trim();
    if (raw.isEmpty) continue;

    var strength = 0;
    if (expectedRevision.isNotEmpty &&
        localPgnRecordRevision(raw) == expectedRevision) {
      strength = 3;
    } else if (expectedFingerprint.isNotEmpty &&
        localChessPgnFingerprint(raw) == expectedFingerprint) {
      strength = 2;
    } else if (_matchesHeaderIdentity(raw, identity)) {
      strength = 1;
    }
    if (strength > 0) {
      matches.add(_IdentityCandidate(index, raw, strength));
    }
  }

  if (matches.isEmpty) return const LocalPgnIdentityNotFound();

  var best = 0;
  for (final match in matches) {
    if (match.strength > best) best = match.strength;
  }
  final strongest = [
    for (final match in matches)
      if (match.strength == best) match,
  ];
  if (strongest.length == 1) {
    return LocalPgnIdentityResolved(
      _resolutionOf(ranges.length, strongest.single),
    );
  }
  final atStored = [
    for (final match in strongest)
      if (match.index == identity.storedIndex) match,
  ];
  if (atStored.length == 1) {
    return LocalPgnIdentityResolved(_resolutionOf(ranges.length, atStored.single));
  }
  return LocalPgnIdentityAmbiguous(strongest.length, best);
}

LocalPgnIdentityResolution _resolutionOf(
  int fileGameCount,
  _IdentityCandidate candidate,
) => LocalPgnIdentityResolution(
  indexInFile: candidate.index,
  fileGameCount: fileGameCount,
  rawPgn: candidate.raw,
  mainlineFingerprint: localChessPgnFingerprint(candidate.raw),
  recordRevision: localPgnRecordRevision(candidate.raw),
);

/// [matchLocalPgnRecordByIdentity] against the file as it is on disk right now,
/// on a worker isolate: the read, the whole-file boundary scan and the identity
/// hashing never touch the UI isolate.
Future<LocalPgnIdentityOutcome> resolveLocalPgnRecordByIdentityInBackground({
  required String path,
  required LocalPgnRecordIdentity identity,
}) async {
  final outcome = await Isolate.run(() {
    try {
      final text = decodeLocalPgnText(File(path).readAsBytesSync());
      return (
        outcome: matchLocalPgnRecordByIdentity(text: text, identity: identity),
        error: null,
      );
    } on FileSystemException catch (error) {
      return (outcome: null, error: error.message);
    }
  });
  final error = outcome.error;
  if (error != null) return LocalPgnIdentityUnreadable(error);
  return outcome.outcome!;
}

/// Why a retained row could not be recovered.
enum LocalPgnRecoveryFailure {
  /// The game is genuinely not in the file any more (deleted, or the file was
  /// replaced by a different database).
  gameMissing,

  /// The file still contains the row's headers but not in a way that proves
  /// which record it is. Opening one of them could open the wrong game.
  ambiguousIdentity,

  /// The file could not be read.
  sourceUnreadable,

  /// The row carries nothing that can be verified (no fingerprint, no revision,
  /// no usable headers).
  noIdentity,

  /// The file is being rewritten faster than the recovery can confirm it.
  sourceChanging,
}

/// A retained local-PGN game could not be recovered for opening.
///
/// The message is the user-facing wording: it is always human, never a raw
/// `Bad state: ...` string, and it tells the user the database can be refreshed
/// instead of implying the click failed for no reason.
class LocalPgnGameUnavailableException implements Exception {
  const LocalPgnGameUnavailableException({
    required this.sourcePath,
    required this.failure,
    this.title = '',
    this.detail = '',
  });

  final String sourcePath;
  final LocalPgnRecoveryFailure failure;
  final String title;
  final String detail;

  String get fileName {
    final normalized = sourcePath.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    final name = index < 0 ? normalized : normalized.substring(index + 1);
    return name.trim().isEmpty ? 'the local database' : name.trim();
  }

  String get message => switch (failure) {
    LocalPgnRecoveryFailure.gameMissing =>
      'That game is no longer in $fileName. The file changed since the '
          'database was indexed — refresh the database and try again.',
    LocalPgnRecoveryFailure.ambiguousIdentity =>
      '$fileName changed since the database was indexed and this game could '
          'not be matched safely. Refresh the database and try again.',
    LocalPgnRecoveryFailure.sourceUnreadable =>
      'Could not read $fileName. Check the file, then refresh the database.',
    LocalPgnRecoveryFailure.noIdentity =>
      'This game has no verifiable identity left in the database. Refresh the '
          'database and try again.',
    LocalPgnRecoveryFailure.sourceChanging =>
      '$fileName is being written right now. Try opening the game again in a '
          'moment.',
  };

  /// The user-facing wording. Also used by `toString()` so no surface can
  /// print a raw `Bad state: ...` frame for this failure.
  @override
  String toString() => message;
}

/// User-facing wording for a failure raised while opening a local database row.
///
/// Recovery failures use their own wording; anything else keeps its message
/// (the reader's StateErrors are already actionable) with the `Bad state: `
/// prefix — the raw Dart framing users reported seeing — stripped.
String localPgnOpenErrorMessage(Object error) {
  if (error is LocalPgnGameUnavailableException) return error.message;
  const statePrefix = 'Bad state: ';
  final text = error.toString().trim();
  if (text.startsWith(statePrefix)) return text.substring(statePrefix.length).trim();
  return text;
}

/// File state used as the memo key for "this source was already re-indexed".
class LocalPgnFileStat {
  const LocalPgnFileStat({required this.sizeBytes, required this.modifiedAtMs});

  final int sizeBytes;
  final int modifiedAtMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalPgnFileStat &&
          other.sizeBytes == sizeBytes &&
          other.modifiedAtMs == modifiedAtMs;

  @override
  int get hashCode => Object.hash(sizeBytes, modifiedAtMs);
}

typedef LocalPgnSourceReindexer = Future<bool> Function(String sourcePath);

typedef LocalPgnIdentityResolver =
    Future<LocalPgnIdentityOutcome> Function({
      required String path,
      required LocalPgnRecordIdentity identity,
    });

typedef LocalPgnFileStatReader = Future<LocalPgnFileStat?> Function(
  String sourcePath,
);

enum _ReindexOutcome { reindexed, alreadyCurrent, failed }

/// Re-indexes one changed local-PGN source and re-resolves the requested game.
///
/// Rescans are single-flight per source: rapid switching between stale rows
/// joins the scan already running instead of starting another one, and a source
/// that was already reconciled for its current size/mtime is not re-imported
/// again.
class LocalPgnSourceRecovery {
  LocalPgnSourceRecovery({
    required LocalPgnSourceReindexer reindexSource,
    LocalPgnIdentityResolver? resolver,
    LocalPgnFileStatReader? readStat,
  }) : _reindexSource = reindexSource,
       _resolveInBackground =
           resolver ?? resolveLocalPgnRecordByIdentityInBackground,
       _readStat = readStat ?? _statFile;

  final LocalPgnSourceReindexer _reindexSource;
  final LocalPgnIdentityResolver _resolveInBackground;
  final LocalPgnFileStatReader _readStat;

  static final Map<String, Future<LocalPgnIdentityResolution>> _inFlight =
      <String, Future<LocalPgnIdentityResolution>>{};
  static final Map<String, LocalPgnFileStat> _reconciled =
      <String, LocalPgnFileStat>{};

  /// Clears the process-wide single-flight/memo state. Tests only.
  @visibleForTesting
  static void debugResetRecoveryState() {
    _inFlight.clear();
    _reconciled.clear();
  }

  /// Re-indexes the source (when it is actually stale) and returns the
  /// requested game resolved against the newest file snapshot.
  ///
  /// Throws [LocalPgnGameUnavailableException] when the game cannot be proven
  /// to exist any more.
  Future<LocalPgnIdentityResolution> recover({
    required String sourcePath,
    required LocalPgnRecordIdentity identity,
  }) {
    final trimmed = sourcePath.trim();
    final key = trimmed.isEmpty ? '' : localChessInputPathKey(trimmed);
    if (key.isEmpty) {
      throw LocalPgnGameUnavailableException(
        sourcePath: sourcePath,
        failure: LocalPgnRecoveryFailure.sourceUnreadable,
      );
    }
    final running = _inFlight[key];
    if (running != null) return running;

    final future = _recover(
      key: key,
      sourcePath: sourcePath,
      identity: identity,
    );
    _inFlight[key] = future;
    // Joiners await `future` itself; the cleanup future's own result (including
    // a duplicate error) is deliberately dropped.
    future
        .whenComplete(() {
          if (identical(_inFlight[key], future)) _inFlight.remove(key);
        })
        .ignore();
    return future;
  }

  Future<LocalPgnIdentityResolution> _recover({
    required String key,
    required String sourcePath,
    required LocalPgnRecordIdentity identity,
  }) async {
    if (!identity.hasAnyIdentity) {
      throw LocalPgnGameUnavailableException(
        sourcePath: sourcePath,
        failure: LocalPgnRecoveryFailure.noIdentity,
      );
    }

    var outcome = await _resolveInBackground(path: sourcePath, identity: identity);
    switch (outcome) {
      case LocalPgnIdentityUnreadable(:final detail):
        throw LocalPgnGameUnavailableException(
          sourcePath: sourcePath,
          failure: LocalPgnRecoveryFailure.sourceUnreadable,
          detail: detail,
        );
      case LocalPgnIdentityAmbiguous():
        throw LocalPgnGameUnavailableException(
          sourcePath: sourcePath,
          failure: LocalPgnRecoveryFailure.ambiguousIdentity,
        );
      case LocalPgnIdentityNotFound():
        // The stored ordinal no longer exists. Append shifted the file rather
        // than removed the game, so re-index before declaring it gone — and
        // still re-resolve afterwards, because the file may have been rewritten
        // while the rescan ran.
        await _reindexOnce(key: key, sourcePath: sourcePath);
        outcome = await _resolveInBackground(path: sourcePath, identity: identity);
        switch (outcome) {
          case LocalPgnIdentityUnreadable(:final detail):
            throw LocalPgnGameUnavailableException(
              sourcePath: sourcePath,
              failure: LocalPgnRecoveryFailure.sourceUnreadable,
              detail: detail,
            );
          case LocalPgnIdentityAmbiguous():
            throw LocalPgnGameUnavailableException(
              sourcePath: sourcePath,
              failure: LocalPgnRecoveryFailure.ambiguousIdentity,
            );
          case LocalPgnIdentityNotFound():
            throw LocalPgnGameUnavailableException(
              sourcePath: sourcePath,
              failure: LocalPgnRecoveryFailure.gameMissing,
            );
          case LocalPgnIdentityResolved():
            break;
        }
      case LocalPgnIdentityResolved():
        break;
    }

    final first = outcome.resolution;
    final statBefore = await _readStat(sourcePath);
    final reindexed = await _reindexOnce(
      key: key,
      sourcePath: sourcePath,
      current: statBefore,
    );
    if (reindexed != _ReindexOutcome.reindexed) {
      // Either the cache was already rebuilt for this exact file state, or the
      // rescan failed — neither rewrites the PGN, so the proven resolution for
      // this file state still stands.
      return first;
    }
    final statAfter = await _readStat(sourcePath);
    if (statBefore != null && statAfter == statBefore) {
      return first;
    }
    // Another writer (a save, an append, an external editor) touched the file
    // while it was re-indexed: resolve again against the newest snapshot so the
    // caller never opens coordinates that were captured before the change.
    final refreshed = await _resolveInBackground(path: sourcePath, identity: identity);
    return switch (refreshed) {
      LocalPgnIdentityResolved(:final resolution) => resolution,
      LocalPgnIdentityAmbiguous() => throw LocalPgnGameUnavailableException(
        sourcePath: sourcePath,
        failure: LocalPgnRecoveryFailure.ambiguousIdentity,
      ),
      LocalPgnIdentityNotFound() => throw LocalPgnGameUnavailableException(
        sourcePath: sourcePath,
        failure: LocalPgnRecoveryFailure.gameMissing,
      ),
      LocalPgnIdentityUnreadable(:final detail) =>
        throw LocalPgnGameUnavailableException(
          sourcePath: sourcePath,
          failure: LocalPgnRecoveryFailure.sourceUnreadable,
          detail: detail,
        ),
    };
  }

  Future<_ReindexOutcome> _reindexOnce({
    required String key,
    required String sourcePath,
    LocalPgnFileStat? current,
  }) async {
    final stat = current ?? await _readStat(sourcePath);
    if (stat != null && _reconciled[key] == stat) {
      return _ReindexOutcome.alreadyCurrent;
    }
    final bool reindexed;
    try {
      reindexed = await _reindexSource(sourcePath);
    } on Object {
      return _ReindexOutcome.failed;
    }
    if (!reindexed) return _ReindexOutcome.failed;
    if (stat != null) _reconciled[key] = stat;
    return _ReindexOutcome.reindexed;
  }
}

Future<LocalPgnFileStat?> _statFile(String sourcePath) async {
  try {
    final stat = await File(sourcePath).stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return LocalPgnFileStat(
      sizeBytes: stat.size,
      modifiedAtMs: stat.modified.millisecondsSinceEpoch,
    );
  } on FileSystemException {
    return null;
  }
}

class _IdentityCandidate {
  const _IdentityCandidate(this.index, this.raw, this.strength);

  final int index;
  final String raw;
  final int strength;
}

String _resultTag(GameStatus status) => switch (status) {
  GameStatus.whiteWins => '1-0',
  GameStatus.blackWins => '0-1',
  GameStatus.draw => '1/2-1/2',
  GameStatus.ongoing => '*',
  GameStatus.unknown => '',
};

bool _isKnownTag(String value) {
  final trimmed = value.trim();
  return trimmed.isNotEmpty && trimmed != '?';
}

final RegExp _recordHeaderRegex = RegExp(
  r'^\s*\[([A-Za-z0-9_]+)\s+"((?:\\.|[^"\\])*)"\]\s*$',
  multiLine: true,
);

/// Header identity for a row that has no usable fingerprint: every tag the row
/// still knows must agree with the record. A row with no known tags can never
/// match this way, so an identity-less record is never opened by position.
bool _matchesHeaderIdentity(String raw, LocalPgnRecordIdentity identity) {
  final expected = <String, String>{};
  if (_isKnownTag(identity.white)) expected['white'] = identity.white.trim();
  if (_isKnownTag(identity.black)) expected['black'] = identity.black.trim();
  if (_isKnownTag(identity.round)) expected['round'] = identity.round.trim();
  if (_isKnownTag(identity.result)) expected['result'] = identity.result.trim();
  if (expected.isEmpty) return false;

  final found = <String, String>{};
  for (final match in _recordHeaderRegex.allMatches(raw)) {
    final tag = match.group(1)?.trim().toLowerCase();
    final value = match.group(2);
    if (tag == null || value == null) continue;
    if (!expected.containsKey(tag)) continue;
    found[tag] = _normalizeTagValue(value);
  }
  if (found.length != expected.length) return false;
  for (final entry in expected.entries) {
    if (found[entry.key] != _normalizeTagValue(entry.value)) return false;
  }
  return true;
}

String _normalizeTagValue(String value) => value
    .replaceAll(r'\"', '"')
    .replaceAll(r'\\', r'\')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();
