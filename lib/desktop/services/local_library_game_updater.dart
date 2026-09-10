import 'dart:io';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_pgn_atomic_write.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';

export 'package:chessever/desktop/services/local_pgn_source.dart'
    show PgnGameRange, pgnGameRanges;

class LocalLibraryGameUpdateTarget {
  const LocalLibraryGameUpdateTarget({
    required this.sourcePath,
    required this.indexInFile,
    required this.fileGameCount,
    this.pgnFingerprint = '',
    this.recordRevision = '',
  });

  final String sourcePath;
  final int indexInFile;
  final int fileGameCount;
  final String pgnFingerprint;
  final String recordRevision;
}

class LocalLibraryGameUpdateOutcome {
  const LocalLibraryGameUpdateOutcome({
    required this.sourcePath,
    required this.updateTarget,
    required this.committedPgn,
    this.cacheRefreshWarning,
  });

  final String sourcePath;
  final String committedPgn;
  final LocalLibraryGameUpdateTarget updateTarget;
  final String? cacheRefreshWarning;
}

Future<LocalLibraryGameUpdateOutcome> updateLocalLibraryPgnGame({
  required LocalLibraryGameUpdateTarget target,
  required ChessGame game,
  LocalChessDatabaseRepository? repository,
}) async {
  final path = target.sourcePath.trim();
  if (!isLocalLibraryPgnUpdateSupported(path)) {
    throw UnsupportedError('Only PGN files can be updated in place.');
  }
  if (target.recordRevision.isEmpty) {
    throw StateError('Reopen this game before updating its source PGN.');
  }
  final nextPgn = exportGameToPgn(game).trim();
  if (nextPgn.isEmpty) {
    throw ArgumentError('Cannot update the source file with an empty PGN.');
  }
  final refreshedTarget = LocalLibraryGameUpdateTarget(
    sourcePath: path,
    indexInFile: target.indexInFile,
    fileGameCount: target.fileGameCount,
    pgnFingerprint: localChessPgnFingerprint(nextPgn),
    recordRevision: localPgnRecordRevision(nextPgn),
  );

  try {
    final cachedUpdate = await repository?.replaceLocalPgnGame(
      databasePath: path,
      indexInFile: target.indexInFile,
      rawPgn: nextPgn,
      expectedFileGameCount: target.fileGameCount,
      expectedPgnFingerprint: target.pgnFingerprint,
      expectedRecordRevision: target.recordRevision,
    );
    if (cachedUpdate == true) {
      return LocalLibraryGameUpdateOutcome(
        sourcePath: path,
        updateTarget: refreshedTarget,
        committedPgn: nextPgn,
      );
    }
    if (cachedUpdate == false) {
      throw StateError(
        'The source PGN changed. Refresh the database before updating it.',
      );
    }
  } on LocalChessPgnSavedCacheRefreshException catch (error) {
    return LocalLibraryGameUpdateOutcome(
      sourcePath: path,
      updateTarget: refreshedTarget,
      committedPgn: nextPgn,
      cacheRefreshWarning: error.toString(),
    );
  }

  await LocalChessDatabaseRepository.runLocalPgnFileWriteQueued(() async {
    final file = File(path);
    final text = await file.readAsString();
    await writeLocalPgnAtomically(
      file: file,
      expectedText: text,
      nextText: replaceLocalPgnRecordInSnapshot(
        text: text,
        indexInFile: target.indexInFile,
        rawPgn: nextPgn,
        expectedFileGameCount: target.fileGameCount,
        expectedPgnFingerprint: target.pgnFingerprint,
        expectedRecordRevision: target.recordRevision,
      ),
    );
  });
  return LocalLibraryGameUpdateOutcome(
    sourcePath: path,
    updateTarget: refreshedTarget,
    committedPgn: nextPgn,
  );
}

bool isLocalLibraryPgnUpdateSupported(String path) {
  return path.trim().toLowerCase().endsWith('.pgn');
}
