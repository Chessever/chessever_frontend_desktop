import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:libcompress/libcompress.dart';
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/compact_local_tree_index.dart';
import 'package:chessever/desktop/services/local_chess_file_access.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/services/time_control_classifier.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

const localChessSupportedExtensions = <String>{
  '.pgn',
  '.pgn.bz2',
  '.pgn.zst',
  '.bz2',
  '.zst',
};

const localChessRecognizedExtensions = <String>{
  ...localChessSupportedExtensions,
  '.cbh',
  '.cbv',
  '.cbf',
  '.cbg',
  '.cba',
  '.cbb',
  '.cbp',
  '.ctg',
};

const localChessPickerExtensions = <String>['pgn', 'bz2', 'zst'];

const localChessReadableFormatsLabel = 'PGN databases';

const localChessRecognizedFormatsLabel =
    '$localChessReadableFormatsLabel. Other chess database formats are not supported.';

const localChessDropFormatsMessage =
    'PGN files, compressed PGNs, and folders browse locally';

const localChessEmptyFolderFormatsMessage =
    'Only PGN databases are currently supported. Export other chess database '
    'formats as PGN, then import the PGN file.';

const localChessUnsupportedFormatMessage =
    'Only PGN databases are currently supported. Please export this database '
    'as PGN and import the PGN file.';

// Compressed PGNs are still decoded into memory by the current Dart codecs, so
// they keep a decoded-size guard. Raw .pgn files use a bounded in-memory fast
// path before falling back to streamed byte scanning for very large files.
const int _kMaxParseBytes = 64 * 1024 * 1024; // 64 MB
const int _kMaxTotalGames = 200000;
const int _kEagerTreeGameRowLimit = 10000;
const int _kEagerPositionGameRefLimit = 10000;
const int _kInlineRawPgnLimit = 10000;
const int _kPgnOffsetCheckpointStride = 128;
const int _kFastInMemoryPgnScanBytes = 96 * 1024 * 1024;
const int _kSingleWorkerTreeBuildBytes = 128 * 1024 * 1024;
const int _kTwoWorkerTreeBuildBytes = 64 * 1024 * 1024;
const Duration _kCpuIntensiveImportInactivityTimeout = Duration(minutes: 2);
const String _kStandardStartingFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

final RegExp _kPgnHeaderRegex = RegExp(
  r'^\[\s*(\w+)\s+"((?:[^"\\]|\\.)*)"\s*\]',
  multiLine: true,
);

final RegExp _kPgnHeaderLineRegex = RegExp(
  r'^\[\s*\w+\s+"(?:[^"\\]|\\.)*"\s*\]',
);

final RegExp _kPgnMoveHintRegex = RegExp(r'\b\d+\s*\.');

bool looksLikeLocalChessFile(String path) {
  final lower = path.toLowerCase();
  return localChessRecognizedExtensions.any(lower.endsWith);
}

bool isSupportedLocalChessFile(String path) {
  final lower = path.toLowerCase();
  return localChessSupportedExtensions.any(lower.endsWith);
}

String localChessEntryCountLabel(int count) =>
    '$count ${count == 1 ? 'entry' : 'entries'}';

String localChessDatabaseDisplayNameForPath(String path) {
  final base = _basename(path);
  final extension = _displayExtensionForBasename(base);
  final stem =
      extension.isEmpty
          ? base
          : base.substring(0, base.length - extension.length);
  if (!_shouldPolishLocalDatabaseStem(stem)) return base;
  return '${_polishLocalDatabaseStem(stem)}$extension';
}

String localChessDatabaseDisplayNameForPaths(List<String> paths) {
  final cleaned = paths
      .map((path) => path.trim())
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  if (cleaned.isEmpty) return 'Local database';
  if (cleaned.length == 1) {
    return localChessDatabaseDisplayNameForPath(cleaned.single);
  }

  final allPgnLike = cleaned.every((path) {
    final lower = path.toLowerCase();
    return localChessSupportedExtensions.any(lower.endsWith);
  });
  if (allPgnLike) {
    return '${cleaned.length} PGN files';
  }
  return '${cleaned.length} local databases';
}

@immutable
class LocalChessSource {
  const LocalChessSource({
    required this.id,
    required this.label,
    required this.paths,
    required this.rootPath,
    required this.scannedAt,
    required this.root,
  });

  final String id;
  final String label;
  final List<String> paths;
  final String rootPath;
  final DateTime scannedAt;
  final LocalChessFolderNode root;

  List<LocalChessGame> get games => root.gamesInSubtree;

  LocalChessNode? nodeForPath(String? path) {
    if (path == null) return root;
    return root.find(path);
  }

  List<LocalChessNode> breadcrumbNodesForPath(String? path) {
    final targetPath = path ?? root.path;
    return root.pathTo(targetPath) ?? <LocalChessNode>[root];
  }
}

@immutable
abstract class LocalChessNode {
  const LocalChessNode({
    required this.name,
    required this.path,
    required this.relativePath,
  });

  final String name;
  final String path;
  final String relativePath;
}

@immutable
class LocalChessFolderNode extends LocalChessNode {
  const LocalChessFolderNode({
    required super.name,
    required super.path,
    required super.relativePath,
    required this.children,
    required this.gameCount,
    required this.fileCount,
    required this.unsupportedCount,
    this.scanError,
  });

  factory LocalChessFolderNode.fromChildren({
    required String name,
    required String path,
    required String relativePath,
    required List<LocalChessNode> children,
    String? scanError,
  }) {
    var gameCount = 0;
    var fileCount = 0;
    var unsupportedCount = 0;
    for (final child in children) {
      switch (child) {
        case LocalChessFolderNode():
          gameCount += child.gameCount;
          fileCount += child.fileCount;
          unsupportedCount += child.unsupportedCount;
        case LocalChessFileNode():
          fileCount++;
          gameCount += child.gameCount;
          if (!child.isPlayable) unsupportedCount++;
      }
    }
    return LocalChessFolderNode(
      name: name,
      path: path,
      relativePath: relativePath,
      children: children,
      gameCount: gameCount,
      fileCount: fileCount,
      unsupportedCount: unsupportedCount,
      scanError: scanError,
    );
  }

  final List<LocalChessNode> children;
  final int gameCount;
  final int fileCount;
  final int unsupportedCount;
  final String? scanError;

  List<LocalChessFolderNode> get folders =>
      children.whereType<LocalChessFolderNode>().toList(growable: false);

  List<LocalChessFileNode> get files =>
      children.whereType<LocalChessFileNode>().toList(growable: false);

  List<LocalChessGame> get gamesInSubtree {
    final games = <LocalChessGame>[];
    for (final child in children) {
      switch (child) {
        case LocalChessFolderNode():
          games.addAll(child.gamesInSubtree);
        case LocalChessFileNode():
          games.addAll(child.games);
      }
    }
    return games;
  }

  int get playableDatabaseCount {
    var count = 0;
    void visit(LocalChessNode node) {
      switch (node) {
        case LocalChessFolderNode(:final children):
          for (final child in children) {
            visit(child);
          }
        case LocalChessFileNode(:final isPlayable):
          if (isPlayable) count++;
      }
    }

    for (final child in children) {
      visit(child);
    }
    return count;
  }

  LocalChessFileNode? get singlePlayableDatabaseInSubtree {
    LocalChessFileNode? match;
    var count = 0;

    void visit(LocalChessNode node) {
      if (count > 1) return;
      switch (node) {
        case LocalChessFolderNode(:final children):
          for (final child in children) {
            visit(child);
            if (count > 1) return;
          }
        case LocalChessFileNode(:final isPlayable):
          if (!isPlayable) return;
          match = node;
          count++;
      }
    }

    for (final child in children) {
      visit(child);
      if (count > 1) return null;
    }
    return count == 1 ? match : null;
  }

  LocalChessFileNode? get singleOpenableDatabaseInSubtree {
    LocalChessFileNode? match;
    var count = 0;

    void visit(LocalChessNode node) {
      if (count > 1) return;
      switch (node) {
        case LocalChessFolderNode(:final children):
          for (final child in children) {
            visit(child);
            if (count > 1) return;
          }
        case LocalChessFileNode(:final isOpenableDatabase):
          if (!isOpenableDatabase) return;
          match = node;
          count++;
      }
    }

    for (final child in children) {
      visit(child);
      if (count > 1) return null;
    }
    return count == 1 ? match : null;
  }

  LocalChessNode? find(String targetPath) {
    if (_samePath(path, targetPath)) return this;
    for (final child in children) {
      if (_samePath(child.path, targetPath)) return child;
      if (child is LocalChessFolderNode) {
        final nested = child.find(targetPath);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  List<LocalChessNode>? pathTo(String targetPath) {
    if (_samePath(path, targetPath)) return <LocalChessNode>[this];
    for (final child in children) {
      if (_samePath(child.path, targetPath)) {
        return <LocalChessNode>[this, child];
      }
      if (child is LocalChessFolderNode) {
        final nested = child.pathTo(targetPath);
        if (nested != null) return <LocalChessNode>[this, ...nested];
      }
    }
    return null;
  }
}

enum LocalChessFileStatus { parsed, noGames, unsupported, failed }

@immutable
class LocalChessFileNode extends LocalChessNode {
  LocalChessFileNode({
    required super.name,
    required super.path,
    required super.relativePath,
    required this.extension,
    required this.status,
    required List<LocalChessGame> games,
    required this.sizeBytes,
    this.modifiedAt,
    this.message,
    this.openingTreeIndex,
    this.pgnOffsetIndex,
    this.contentFingerprint = '',
    int? gameCount,
  }) : games = List<LocalChessGame>.unmodifiable(games),
       gameCount = gameCount ?? games.length;

  final String extension;
  final LocalChessFileStatus status;
  final List<LocalChessGame> games;
  final int gameCount;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String? message;
  final PlayerOpeningTreeIndex? openingTreeIndex;
  final LocalChessPgnOffsetIndex? pgnOffsetIndex;
  final String contentFingerprint;

  bool get isPlayable => status == LocalChessFileStatus.parsed;

  bool get isOpenableDatabase =>
      status == LocalChessFileStatus.parsed ||
      status == LocalChessFileStatus.noGames;
}

@immutable
class LocalChessPgnOffsetIndex {
  LocalChessPgnOffsetIndex({
    required this.path,
    required this.fileSizeBytes,
    required this.modifiedAt,
    required this.totalGames,
    required this.checkpointStride,
    required List<int> checkpointOffsets,
  }) : checkpointOffsets = List<int>.unmodifiable(checkpointOffsets);

  final String path;
  final int fileSizeBytes;
  final DateTime? modifiedAt;
  final int totalGames;
  final int checkpointStride;
  final List<int> checkpointOffsets;

  bool get isEmpty => checkpointOffsets.isEmpty;

  int? checkpointOffsetForGame(int gameIndex) {
    if (gameIndex < 0 || gameIndex >= totalGames || checkpointOffsets.isEmpty) {
      return null;
    }
    final checkpointIndex = gameIndex ~/ checkpointStride;
    if (checkpointIndex >= checkpointOffsets.length) {
      return checkpointOffsets.last;
    }
    return checkpointOffsets[checkpointIndex];
  }

  int checkpointGameIndexForGame(int gameIndex) {
    if (gameIndex < 0 || totalGames <= 0) return 0;
    final bounded = gameIndex >= totalGames ? totalGames - 1 : gameIndex;
    return (bounded ~/ checkpointStride) * checkpointStride;
  }

  bool matchesFileStat(FileStat stat) {
    return fileSizeBytes == stat.size && modifiedAt == stat.modified;
  }
}

LocalChessFileNode? selectedLocalChessDatabaseFile(LocalChessNode node) {
  return switch (node) {
    LocalChessFileNode(:final isOpenableDatabase) =>
      isOpenableDatabase ? node : null,
    LocalChessFolderNode() => node.singleOpenableDatabaseInSubtree,
    _ => null,
  };
}

@immutable
class LocalChessGame {
  const LocalChessGame({
    required this.id,
    required this.game,
    required String rawPgn,
    required this.sourcePath,
    required this.sourceRelativePath,
    required this.fileName,
    required this.indexInFile,
    required this.fileGameCount,
    required this.hasMoves,
    this.moveLine = const <String>[],
    this.pgnFingerprint = '',
    this.sourceByteStart,
    this.sourceByteEnd,
  }) : _rawPgn = rawPgn;

  final String id;
  final ChessGame game;
  final String _rawPgn;
  final String sourcePath;
  final String sourceRelativePath;
  final String fileName;
  final int indexInFile;
  final int fileGameCount;

  /// Mainline UCI moves prepared by the import worker. Lightweight previews
  /// leave this empty and hydrate a selected game from its byte range instead.
  final List<String> moveLine;
  final String pgnFingerprint;
  final int? sourceByteStart;
  final int? sourceByteEnd;
  // Mainline parsing is deferred to keep scans cheap. This flag mirrors
  // whether the raw PGN actually carries movetext, so list cards can still
  // show a "started" state without parsing every game.
  final bool hasMoves;

  bool get hasInlineRawPgn => _rawPgn.isNotEmpty;

  String get inlineRawPgn => _rawPgn;

  String get rawPgn {
    if (_rawPgn.isNotEmpty) return _rawPgn;
    final start = sourceByteStart;
    final end = sourceByteEnd;
    if (start == null || end == null || end <= start) return '';
    try {
      final raf = File(sourcePath).openSync();
      try {
        raf.setPositionSync(start);
        return _decodeTextBytes(raf.readSync(end - start)).trim();
      } finally {
        raf.closeSync();
      }
    } on Object {
      return '';
    }
  }

  String get title {
    final white = (game.metadata['White']?.toString().trim() ?? '');
    final black = (game.metadata['Black']?.toString().trim() ?? '');
    final event = (game.metadata['Event']?.toString().trim() ?? '');
    final isPosition =
        !hasMoves &&
        (game.metadata['SetUp']?.toString().trim() == '1' ||
            game.metadata['FEN']?.toString().trim().isNotEmpty == true);
    if (isPosition && event.isNotEmpty && event != '?') return event;
    return '${white.isEmpty ? 'White' : white} vs '
        '${black.isEmpty ? 'Black' : black}';
  }
}

@immutable
class LocalChessFileImportStart {
  const LocalChessFileImportStart({
    required this.path,
    required this.relativePath,
    required this.extension,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.totalEntries,
    required this.contentFingerprint,
    this.pgnOffsetIndex,
  });

  final String path;
  final String relativePath;
  final String extension;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final int totalEntries;
  final String contentFingerprint;
  final LocalChessPgnOffsetIndex? pgnOffsetIndex;
}

@immutable
class LocalChessFileImportBatch {
  const LocalChessFileImportBatch({
    required this.games,
    required this.acceptedCount,
    required this.totalEntries,
  });

  final List<LocalChessGame> games;
  final int acceptedCount;
  final int totalEntries;
}

LocalChessGame? localChessGameFromRawPgnChunk({
  required String rawPgn,
  required String sourcePath,
  required String rootPath,
  required int indexInFile,
  required int fileGameCount,
  int? sourceByteStart,
  int? sourceByteEnd,
}) {
  final entry = _entryFromPgnChunk(rawPgn.trim());
  if (entry == null || !entry.hasMoves) return null;
  final id = 'local_${_stableId('$sourcePath#$indexInFile')}';
  final relativePath = _relative(rootPath, sourcePath);
  return LocalChessGame(
    id: id,
    game: entry.game.copyWith(gameId: id),
    rawPgn: entry.rawPgn,
    sourcePath: sourcePath,
    sourceRelativePath: relativePath,
    fileName: _basename(sourcePath),
    indexInFile: indexInFile,
    fileGameCount: fileGameCount,
    hasMoves: entry.hasMoves,
    pgnFingerprint: localChessPgnFingerprint(entry.rawPgn),
    sourceByteStart: sourceByteStart,
    sourceByteEnd: sourceByteEnd,
  );
}

Future<LocalChessFileNode> scanLocalChessFileNodeForImportWithProgress({
  required String path,
  required String rootPath,
  bool deduplicateGames = true,
  int maxDecodedBytes = _kMaxParseBytes,
  int maxGames = _kMaxTotalGames,
  int previewGameLimit = 1000,
  int batchSize = 4096,
  void Function(LocalChessScanProgress progress)? onProgress,
  Future<void> Function(LocalChessFileImportStart start)? onImportStart,
  Future<void> Function(LocalChessFileImportBatch batch)? onGameBatch,
  Duration inactivityTimeout = const Duration(seconds: 30),
  @visibleForTesting Duration? debugWorkerStartDelay,
}) async {
  final scanPath = path.trim();
  if (scanPath.isEmpty) {
    throw ArgumentError('No file was provided.');
  }
  if (maxDecodedBytes <= 0) {
    throw ArgumentError.value(
      maxDecodedBytes,
      'maxDecodedBytes',
      'must be > 0',
    );
  }
  if (maxGames <= 0) {
    throw ArgumentError.value(maxGames, 'maxGames', 'must be > 0');
  }
  if (inactivityTimeout <= Duration.zero) {
    throw ArgumentError.value(
      inactivityTimeout,
      'inactivityTimeout',
      'must be > 0',
    );
  }
  if (!looksLikeLocalChessFile(scanPath)) {
    throw ArgumentError(
      'No recognized chess file was found at ${_basename(scanPath)}. '
      'Open $localChessRecognizedFormatsLabel.',
    );
  }

  final Directory snapshotDirectory;
  try {
    snapshotDirectory = await Directory.systemTemp.createTemp(
      'chessever_pgn_import_',
    );
  } on FileSystemException catch (error) {
    throw LocalChessFileAccessException.from(error, path: scanPath);
  }

  // Only CPU/file work crosses this isolate boundary. Import callbacks stay on
  // the caller isolate because they own the already-open, globally serialized
  // resqlite writer. Each callback must finish before its ACK lets the worker
  // parse and enqueue another batch.
  final receivePort = ReceivePort();
  final completer = Completer<LocalChessFileNode>();
  final workerExited = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  Isolate? isolate;
  Timer? inactivityTimer;

  void completeWithError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    inactivityTimer?.cancel();
    completer.completeError(error, stackTrace);
    isolate?.kill(priority: Isolate.immediate);
  }

  void armInactivityWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(inactivityTimeout, () {
      completeWithError(
        LocalChessFileAccessException.stalled(path: scanPath),
        StackTrace.current,
      );
    });
  }

  void pauseInactivityWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = null;
  }

  Future<void> handleImportStart(_ScanImportWorkerStart message) async {
    // Caller-isolate callbacks may legitimately wait on or write to the
    // serialized local database. They cannot be canceled safely, so never let
    // the worker watchdog complete the outer import while one is still using
    // the writer session.
    pauseInactivityWatchdog();
    try {
      await onImportStart?.call(message.start);
      if (!completer.isCompleted) {
        message.ackPort.send(const _ScanImportWorkerAck());
        armInactivityWatchdog();
      }
    } catch (error, stackTrace) {
      // Callback failures (including OperationCanceledException) originate on
      // this isolate. Preserve the exact object so callers retain their normal
      // cancellation behavior instead of receiving a remote wrapper error.
      completeWithError(error, stackTrace);
    }
  }

  Future<void> handleGameBatch(_ScanImportWorkerBatch message) async {
    pauseInactivityWatchdog();
    try {
      await onGameBatch?.call(message.batch);
      if (!completer.isCompleted) {
        message.ackPort.send(const _ScanImportWorkerAck());
        armInactivityWatchdog();
      }
    } catch (error, stackTrace) {
      completeWithError(error, stackTrace);
    }
  }

  subscription = receivePort.listen((message) {
    if (message == null) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (!completer.isCompleted) {
        completeWithError(
          StateError(
            'PGN import scan worker exited before returning a result.',
          ),
          StackTrace.current,
        );
      }
      return;
    }
    if (completer.isCompleted) return;
    switch (message) {
      case LocalChessScanProgress progress:
        armInactivityWatchdog();
        try {
          onProgress?.call(progress);
        } catch (error, stackTrace) {
          completeWithError(error, stackTrace);
        }
      case _ScanImportWorkerStart start:
        unawaited(handleImportStart(start));
      case _ScanImportWorkerBatch batch:
        unawaited(handleGameBatch(batch));
      case _ScanWorkerInactivityWindow(:final timeout):
        inactivityTimer?.cancel();
        inactivityTimer = Timer(timeout, () {
          completeWithError(
            LocalChessFileAccessException.stalled(path: scanPath),
            StackTrace.current,
          );
        });
      case _ScanImportWorkerSuccess(:final file):
        pauseInactivityWatchdog();
        completer.complete(file);
      case _ScanWorkerFailure(:final message, :final stackTrace):
        completeWithError(
          ArgumentError(message),
          StackTrace.fromString(stackTrace),
        );
    }
  });

  try {
    armInactivityWatchdog();
    isolate = await Isolate.spawn(
      _scanLocalChessFileNodeForImportWorker,
      _ScanImportWorkerRequest(
        sendPort: receivePort.sendPort,
        path: scanPath,
        rootPath: rootPath,
        maxDecodedBytes: maxDecodedBytes,
        maxGames: maxGames,
        deduplicateGames: deduplicateGames,
        previewGameLimit: previewGameLimit,
        batchSize: batchSize,
        snapshotDirectoryPath: snapshotDirectory.path,
        debugWorkerStartDelay: debugWorkerStartDelay,
      ),
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    return await completer.future;
  } catch (error, stackTrace) {
    completeWithError(error, stackTrace);
    return await completer.future;
  } finally {
    inactivityTimer?.cancel();
    isolate?.kill(priority: Isolate.immediate);
    if (isolate != null && !workerExited.isCompleted) {
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Continue with bounded cleanup retries. Isolate.kill is asynchronous,
        // but a terminated worker normally signals onExit immediately.
      }
    }
    receivePort.close();
    await subscription.cancel();
    await _deleteImportSnapshotDirectoryBestEffort(snapshotDirectory);
  }
}

Future<void> _deleteImportSnapshotDirectoryBestEffort(
  Directory directory,
) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (attempt == 4) return;
      await Future<void>.delayed(Duration(milliseconds: 50 << attempt));
    }
  }
}

Future<LocalChessFileNode> _scanLocalChessFileNodeForImportInline({
  required String path,
  required String rootPath,
  required bool deduplicateGames,
  required int maxDecodedBytes,
  required int maxGames,
  required int previewGameLimit,
  required int batchSize,
  String? snapshotDirectoryPath,
  void Function(LocalChessScanProgress progress)? onProgress,
  void Function(Duration timeout)? onInactivityWindow,
  Future<void> Function(LocalChessFileImportStart start)? onImportStart,
  Future<void> Function(LocalChessFileImportBatch batch)? onGameBatch,
}) async {
  final scanPath = path.trim();
  if (scanPath.isEmpty) {
    throw ArgumentError('No file was provided.');
  }
  if (maxDecodedBytes <= 0) {
    throw ArgumentError.value(
      maxDecodedBytes,
      'maxDecodedBytes',
      'must be > 0',
    );
  }
  if (maxGames <= 0) {
    throw ArgumentError.value(maxGames, 'maxGames', 'must be > 0');
  }

  void emit(double fraction, String message) {
    onProgress?.call(
      LocalChessScanProgress(fraction: fraction, message: message),
    );
  }

  if (!looksLikeLocalChessFile(scanPath)) {
    throw ArgumentError(
      'No recognized chess file was found at ${_basename(scanPath)}. '
      'Open $localChessRecognizedFormatsLabel.',
    );
  }

  final extension = _extensionForPath(scanPath);
  final FileStat stat;
  try {
    stat = await File(scanPath).stat();
  } on FileSystemException catch (e) {
    return _failedFileNodeFromFileSystemException(
          scanPath,
          rootPath: rootPath,
          extension: extension,
          exception: e,
        ) ??
        LocalChessFileNode(
          name: localChessDatabaseDisplayNameForPath(scanPath),
          path: scanPath,
          relativePath: _relative(rootPath, scanPath),
          extension: extension,
          status: LocalChessFileStatus.failed,
          games: const <LocalChessGame>[],
          sizeBytes: 0,
          modifiedAt: null,
          message: 'Could not scan this file: $e',
        );
  }

  if (!isSupportedLocalChessFile(scanPath)) {
    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(scanPath),
      path: scanPath,
      relativePath: _relative(rootPath, scanPath),
      extension: extension,
      status: LocalChessFileStatus.unsupported,
      games: const <LocalChessGame>[],
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
      message: _unsupportedMessage(extension),
    );
  }

  if (_requiresFullDecode(extension) && stat.size > maxDecodedBytes) {
    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(scanPath),
      path: scanPath,
      relativePath: _relative(rootPath, scanPath),
      extension: extension,
      status: LocalChessFileStatus.unsupported,
      games: const <LocalChessGame>[],
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
      message: _tooLargeMessage(stat.size),
    );
  }

  final relativePath = _relative(rootPath, scanPath);
  var sourceSizeBytes = stat.size;
  DateTime? sourceModifiedAt = stat.modified;
  FileStat? stableSourceStat;
  var sourceContentFingerprint = '';
  try {
    emit(0.03, 'Scanning PGN...');
    final preview = <LocalChessGame>[];
    final pendingBatch = <LocalChessGame>[];
    final seenFingerprints = deduplicateGames ? <String>{} : null;
    final sourceEntryFingerprintPrefix =
        deduplicateGames ? '' : 'source-entry:${_stableId(scanPath)}';
    var duplicateCount = 0;
    var acceptedCount = 0;
    var totalEntries = 0;
    LocalChessPgnOffsetIndex? offsetIndex;

    Future<void> flushBatch() async {
      if (pendingBatch.isEmpty) return;
      final batch = LocalChessFileImportBatch(
        games: List<LocalChessGame>.unmodifiable(pendingBatch),
        acceptedCount: acceptedCount,
        totalEntries: totalEntries,
      );
      pendingBatch.clear();
      await onGameBatch?.call(batch);
    }

    Future<void> acceptEntry(
      int sourceIndex,
      _ParsedLocalChessGame entry, {
      required int fileGameCount,
      required bool inlineRawPgn,
    }) async {
      final fingerprint =
          deduplicateGames
              ? localChessPgnFingerprint(entry.rawPgn)
              : '$sourceEntryFingerprintPrefix:$sourceIndex';
      if (deduplicateGames && !seenFingerprints!.add(fingerprint)) {
        duplicateCount++;
        return;
      }
      if (acceptedCount >= maxGames) return;

      final id = 'local_${_stableId('$scanPath#$sourceIndex')}';
      final game = LocalChessGame(
        id: id,
        game: entry.game.copyWith(gameId: id),
        rawPgn: inlineRawPgn ? entry.rawPgn : '',
        sourcePath: scanPath,
        sourceRelativePath: relativePath,
        fileName: _basename(scanPath),
        indexInFile: sourceIndex,
        fileGameCount: fileGameCount,
        hasMoves: entry.hasMoves,
        moveLine: _mainlineUciFromRawPgn(id, entry.rawPgn),
        pgnFingerprint: fingerprint,
        sourceByteStart: entry.sourceByteStart,
        sourceByteEnd: entry.sourceByteEnd,
      );
      acceptedCount++;
      if (preview.length < previewGameLimit) {
        preview.add(game);
      }
      pendingBatch.add(game);
      if (pendingBatch.length >= batchSize) {
        await flushBatch();
      }
    }

    switch (extension.toLowerCase()) {
      case '.pgn':
        final scan = await _scanPgnFileRanges(
          scanPath,
          maxEntries: maxGames,
          snapshotDirectoryPath: snapshotDirectoryPath,
          onScanProgress:
              (fraction) => emit(0.03 + (fraction * 0.27), 'Scanning PGN...'),
        );
        try {
          totalEntries = scan.totalEntries;
          offsetIndex = scan.offsetIndex;
          sourceSizeBytes = scan.offsetIndex.fileSizeBytes;
          sourceModifiedAt = scan.offsetIndex.modifiedAt;
          stableSourceStat = scan.sourceStat;
          sourceContentFingerprint = scan.contentFingerprint;
          if (scan.ranges.isEmpty) {
            await validateLocalChessFileSnapshotSource(
              scanPath,
              expectedStat: scan.sourceStat,
              expectedContentFingerprint: scan.contentFingerprint,
            );
            return LocalChessFileNode(
              name: localChessDatabaseDisplayNameForPath(scanPath),
              path: scanPath,
              relativePath: relativePath,
              extension: extension,
              status: LocalChessFileStatus.noGames,
              games: const <LocalChessGame>[],
              sizeBytes: scan.offsetIndex.fileSizeBytes,
              modifiedAt: scan.offsetIndex.modifiedAt,
              message: 'No playable entries were found.',
              contentFingerprint: scan.contentFingerprint,
            );
          }
          await onImportStart?.call(
            LocalChessFileImportStart(
              path: scanPath,
              relativePath: relativePath,
              extension: extension,
              sizeBytes: scan.offsetIndex.fileSizeBytes,
              modifiedAt: scan.offsetIndex.modifiedAt,
              totalEntries: totalEntries,
              contentFingerprint: scan.contentFingerprint,
              pgnOffsetIndex: offsetIndex,
            ),
          );
          final inlineRawPgn = totalEntries <= _kInlineRawPgnLimit;
          await _forEachParsedPgnRange(
            scanPath,
            scan,
            onEntry: (sourceIndex, entry) async {
              await acceptEntry(
                sourceIndex,
                entry,
                fileGameCount: totalEntries,
                inlineRawPgn: inlineRawPgn,
              );
            },
            onReadProgress:
                (fraction) =>
                    emit(0.30 + (fraction * 0.64), 'Importing games...'),
          );
        } finally {
          await scan.dispose();
        }
      case '.pgn.bz2':
      case '.bz2':
      case '.pgn.zst':
      case '.zst':
        emit(0.04, 'Reading PGN file...');
        final textSnapshot = await _readTextFileSnapshot(
          scanPath,
          extension,
          maxDecodedBytes: maxDecodedBytes,
          onReadProgress:
              (fraction) =>
                  emit(0.04 + (fraction * 0.20), 'Reading PGN file...'),
          beforeDecode:
              () => onInactivityWindow?.call(
                _kCpuIntensiveImportInactivityTimeout,
              ),
        );
        stableSourceStat = textSnapshot.sourceStat;
        sourceSizeBytes = textSnapshot.sourceStat.size;
        sourceModifiedAt = textSnapshot.sourceStat.modified;
        sourceContentFingerprint = textSnapshot.contentFingerprint;
        emit(0.30, 'Importing games...');
        onInactivityWindow?.call(_kCpuIntensiveImportInactivityTimeout);
        final parseResult = _parsePgnText(
          textSnapshot.text,
          maxEntries: maxGames,
        );
        totalEntries = parseResult.totalEntries;
        if (parseResult.entries.isEmpty) {
          await validateLocalChessFileSnapshotSource(
            scanPath,
            expectedStat: textSnapshot.sourceStat,
            expectedContentFingerprint: textSnapshot.contentFingerprint,
          );
          return LocalChessFileNode(
            name: localChessDatabaseDisplayNameForPath(scanPath),
            path: scanPath,
            relativePath: relativePath,
            extension: extension,
            status: LocalChessFileStatus.noGames,
            games: const <LocalChessGame>[],
            sizeBytes: sourceSizeBytes,
            modifiedAt: sourceModifiedAt,
            message: 'No playable entries were found.',
            contentFingerprint: sourceContentFingerprint,
          );
        }
        await onImportStart?.call(
          LocalChessFileImportStart(
            path: scanPath,
            relativePath: relativePath,
            extension: extension,
            sizeBytes: sourceSizeBytes,
            modifiedAt: sourceModifiedAt,
            totalEntries: totalEntries,
            contentFingerprint: sourceContentFingerprint,
          ),
        );
        for (final (sourceIndex, entry) in parseResult.entries.indexed) {
          await acceptEntry(
            sourceIndex,
            entry,
            fileGameCount: totalEntries,
            inlineRawPgn: true,
          );
          if (parseResult.entries.length <= 1 ||
              sourceIndex % 256 == 0 ||
              sourceIndex == parseResult.entries.length - 1) {
            emit(
              0.30 + (((sourceIndex + 1) / parseResult.entries.length) * 0.64),
              'Importing games...',
            );
          }
        }
        parseResult.entries.clear();
      default:
        return LocalChessFileNode(
          name: localChessDatabaseDisplayNameForPath(scanPath),
          path: scanPath,
          relativePath: relativePath,
          extension: extension,
          status: LocalChessFileStatus.unsupported,
          games: const <LocalChessGame>[],
          sizeBytes: sourceSizeBytes,
          modifiedAt: sourceModifiedAt,
          message: _unsupportedMessage(extension),
        );
    }

    await flushBatch();
    seenFingerprints?.clear();
    emit(0.97, 'Finalizing PGN...');
    final expectedStat = stableSourceStat;
    if (sourceContentFingerprint.isEmpty) {
      throw StateError('Stable PGN source metadata was not captured.');
    }
    await validateLocalChessFileSnapshotSource(
      scanPath,
      expectedStat: expectedStat,
      expectedContentFingerprint: sourceContentFingerprint,
    );

    if (acceptedCount == 0) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(scanPath),
        path: scanPath,
        relativePath: relativePath,
        extension: extension,
        status: LocalChessFileStatus.noGames,
        games: const <LocalChessGame>[],
        gameCount: 0,
        sizeBytes: sourceSizeBytes,
        modifiedAt: sourceModifiedAt,
        message: 'No playable entries were found.',
        pgnOffsetIndex: offsetIndex,
        contentFingerprint: sourceContentFingerprint,
      );
    }

    final messages = <String>[
      if (acceptedCount + duplicateCount < totalEntries)
        'Showing first $acceptedCount of $totalEntries entries; the rest were '
            'skipped to stay within the index cap.',
      'Opening tree queued for background build.',
      if (duplicateCount > 0)
        'Skipped $duplicateCount duplicate PGN ${duplicateCount == 1 ? 'entry' : 'entries'}.',
    ];

    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(scanPath),
      path: scanPath,
      relativePath: relativePath,
      extension: extension,
      status: LocalChessFileStatus.parsed,
      games: preview,
      gameCount: acceptedCount,
      sizeBytes: sourceSizeBytes,
      modifiedAt: sourceModifiedAt,
      message: messages.join(' '),
      pgnOffsetIndex: offsetIndex,
      contentFingerprint: sourceContentFingerprint,
    );
  } on FileSystemException catch (e) {
    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(scanPath),
      path: scanPath,
      relativePath: relativePath,
      extension: extension,
      status: LocalChessFileStatus.failed,
      games: const <LocalChessGame>[],
      sizeBytes: sourceSizeBytes,
      modifiedAt: sourceModifiedAt,
      message:
          LocalChessFileAccessException.from(e, path: scanPath).userMessage,
    );
  } on LocalChessFileAccessException catch (e) {
    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(scanPath),
      path: scanPath,
      relativePath: relativePath,
      extension: extension,
      status: LocalChessFileStatus.failed,
      games: const <LocalChessGame>[],
      sizeBytes: sourceSizeBytes,
      modifiedAt: sourceModifiedAt,
      message: e.userMessage,
    );
  } on _DecodedPgnTooLargeException catch (e) {
    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(scanPath),
      path: scanPath,
      relativePath: relativePath,
      extension: extension,
      status: LocalChessFileStatus.unsupported,
      games: const <LocalChessGame>[],
      sizeBytes: sourceSizeBytes,
      modifiedAt: sourceModifiedAt,
      message: _tooLargeMessage(e.sizeBytes),
    );
  } on _CompressedPgnDecodeException catch (e) {
    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(scanPath),
      path: scanPath,
      relativePath: relativePath,
      extension: extension,
      status: LocalChessFileStatus.failed,
      games: const <LocalChessGame>[],
      sizeBytes: sourceSizeBytes,
      modifiedAt: sourceModifiedAt,
      message: e.toString(),
    );
  }
}

List<String> _mainlineUciFromRawPgn(String id, String rawPgn) {
  try {
    return ChessGame.fromPgn(id, rawPgn).mainline
        .map((move) => move.uci.trim().toLowerCase())
        .where((move) => move.isNotEmpty)
        .toList(growable: false);
  } on Object {
    return const <String>[];
  }
}

@immutable
class LocalChessScanProgress {
  LocalChessScanProgress({required double fraction, required this.message})
    : fraction = fraction.clamp(0.0, 1.0).toDouble();

  final double fraction;
  final String message;

  int get percent => (fraction * 100).round().clamp(0, 100).toInt();
}

/// Builds the compact Player opening-tree sidecar straight from a raw PGN.
///
/// Player databases are deliberately not materialized in the searchable local
/// chess cache. Keeping this as a killable worker preserves cancellation and
/// prevents parsing/finalization from blocking the Flutter UI isolate.
Future<CompactLocalTreeBuildResult> buildCompactLocalTreeFromPgn({
  required String path,
  int maxGames = _kMaxTotalGames,
  int maxPly = localOpeningTreeDefaultMaxPly,
  void Function(LocalChessScanProgress progress)? onProgress,
  OperationCancellationToken? cancellationToken,
  Duration inactivityTimeout = const Duration(minutes: 5),
}) async {
  final clean = path.trim();
  if (clean.isEmpty) throw ArgumentError('No PGN file was provided.');
  if (!clean.toLowerCase().endsWith('.pgn')) {
    throw ArgumentError('Player tree building requires a PGN file.');
  }
  if (maxGames <= 0) {
    throw ArgumentError.value(maxGames, 'maxGames', 'must be > 0');
  }
  if (maxPly <= 0) {
    throw ArgumentError.value(maxPly, 'maxPly', 'must be > 0');
  }
  if (inactivityTimeout <= Duration.zero) {
    throw ArgumentError.value(
      inactivityTimeout,
      'inactivityTimeout',
      'must be > 0',
    );
  }
  cancellationToken?.throwIfCanceled();

  final receivePort = ReceivePort();
  final completer = Completer<CompactLocalTreeBuildResult>();
  final workerExited = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  Isolate? isolate;
  Timer? inactivityTimer;
  void Function() removeCancellationListener = () {};
  CompactLocalTreeBuildResult? workerResult;
  Object? workerError;
  StackTrace? workerStackTrace;
  SendPort? workerCancellationPort;

  void completeWithError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    inactivityTimer?.cancel();
    completer.completeError(error, stackTrace);
    isolate?.kill(priority: Isolate.immediate);
  }

  void armWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(inactivityTimeout, () {
      completeWithError(
        LocalChessFileAccessException.stalled(path: clean),
        StackTrace.current,
      );
    });
  }

  subscription = receivePort.listen((message) {
    if (message == null) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (completer.isCompleted) return;
      final result = workerResult;
      if (result != null) {
        inactivityTimer?.cancel();
        completer.complete(result);
      } else if (workerError != null) {
        inactivityTimer?.cancel();
        completer.completeError(
          workerError!,
          workerStackTrace ?? StackTrace.current,
        );
      } else {
        completeWithError(
          StateError(
            'Player PGN tree worker exited before returning a result.',
          ),
          StackTrace.current,
        );
      }
      return;
    }
    if (completer.isCompleted) return;
    armWatchdog();
    switch (message) {
      case LocalChessScanProgress progress:
        onProgress?.call(progress);
      case _CompactPgnTreeWorkerReady(:final cancellationPort):
        workerCancellationPort = cancellationPort;
        if (cancellationToken?.isCanceled == true) {
          cancellationPort.send(null);
        }
      case _CompactPgnTreeWorkerSuccess(:final result):
        workerResult = result;
      case _ScanWorkerFailure(:final message, :final stackTrace):
        workerError =
            isOperationCanceled(message)
                ? const OperationCanceledException()
                : StateError(message);
        workerStackTrace = StackTrace.fromString(stackTrace);
    }
  });

  try {
    armWatchdog();
    isolate = await Isolate.spawn(
      _buildCompactPgnTreeWorker,
      _CompactPgnTreeWorkerRequest(
        sendPort: receivePort.sendPort,
        path: clean,
        maxGames: maxGames,
        maxPly: maxPly,
      ),
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    removeCancellationListener =
        cancellationToken?.addListener(() {
          workerCancellationPort?.send(null);
        }) ??
        () {};
    return await completer.future;
  } catch (error, stackTrace) {
    completeWithError(error, stackTrace);
    return await completer.future;
  } finally {
    removeCancellationListener();
    inactivityTimer?.cancel();
    if (isolate != null && !workerExited.isCompleted) {
      try {
        await workerExited.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        isolate.kill(priority: Isolate.immediate);
      }
    }
    receivePort.close();
    await subscription.cancel();
  }
}

Future<LocalChessSource> scanLocalChessPaths(
  List<String> rawPaths, {
  String? sourceLabel,
  int maxDecodedBytes = _kMaxParseBytes,
  int maxGames = _kMaxTotalGames,
  bool buildOpeningTree = true,
}) async {
  return scanLocalChessPathsWithProgress(
    rawPaths,
    sourceLabel: sourceLabel,
    maxDecodedBytes: maxDecodedBytes,
    maxGames: maxGames,
    buildOpeningTree: buildOpeningTree,
  );
}

Future<LocalChessSource> scanLocalChessPathsWithProgress(
  List<String> rawPaths, {
  String? sourceLabel,
  int maxDecodedBytes = _kMaxParseBytes,
  int maxGames = _kMaxTotalGames,
  bool buildOpeningTree = true,
  bool fastPgnPreview = false,
  bool fullPgnCatalog = false,
  void Function(LocalChessScanProgress progress)? onProgress,
  Duration inactivityTimeout = const Duration(minutes: 2),
}) async {
  final paths = _validateScanInputs(
    rawPaths,
    maxDecodedBytes: maxDecodedBytes,
    maxGames: maxGames,
  );
  if (inactivityTimeout <= Duration.zero) {
    throw ArgumentError.value(
      inactivityTimeout,
      'inactivityTimeout',
      'must be > 0',
    );
  }
  final receivePort = ReceivePort();
  final completer = Completer<LocalChessSource>();
  final workerExited = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  Isolate? isolate;
  Timer? inactivityTimer;

  void completeWithError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    inactivityTimer?.cancel();
    completer.completeError(error, stackTrace);
    isolate?.kill(priority: Isolate.immediate);
  }

  void armWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(inactivityTimeout, () {
      completeWithError(
        LocalChessFileAccessException.stalled(
          path: paths.length == 1 ? paths.single : null,
        ),
        StackTrace.current,
      );
    });
  }

  subscription = receivePort.listen((message) {
    if (message == null) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (!completer.isCompleted) {
        completeWithError(
          StateError('PGN scan worker exited before returning a result.'),
          StackTrace.current,
        );
      }
      return;
    }
    if (completer.isCompleted) return;
    armWatchdog();
    switch (message) {
      case LocalChessScanProgress progress:
        onProgress?.call(progress);
      case _ScanWorkerSuccess(:final source):
        inactivityTimer?.cancel();
        completer.complete(source);
      case _ScanWorkerFailure(:final message, :final stackTrace):
        completeWithError(
          ArgumentError(message),
          StackTrace.fromString(stackTrace),
        );
    }
  });

  try {
    armWatchdog();
    isolate = await Isolate.spawn(
      _scanLocalChessPathsWorker,
      _ScanWorkerRequest(
        sendPort: receivePort.sendPort,
        paths: paths,
        sourceLabel: sourceLabel,
        maxDecodedBytes: maxDecodedBytes,
        maxGames: maxGames,
        buildOpeningTree: buildOpeningTree,
        fastPgnPreview: fastPgnPreview,
        fullPgnCatalog: fullPgnCatalog,
      ),
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    return await completer.future;
  } catch (error, stackTrace) {
    completeWithError(error, stackTrace);
    return await completer.future;
  } finally {
    inactivityTimer?.cancel();
    isolate?.kill(priority: Isolate.immediate);
    if (isolate != null && !workerExited.isCompleted) {
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The worker has already received an immediate kill request.
      }
    }
    receivePort.close();
    await subscription.cancel();
  }
}

/// Reads only enough of a raw PGN to render its first [maxGames] games.
///
/// Unlike the normal scanner this deliberately does not walk the entire file,
/// calculate the final game total, build an offset index, or fingerprint the
/// source. The complete import performs those jobs in the background after
/// this session-only preview is visible.
Future<LocalChessSource> scanLocalChessPgnPreview(
  String path, {
  String? sourceLabel,
  int maxGames = 200,
  Duration inactivityTimeout = const Duration(seconds: 30),
}) {
  return scanLocalChessPathsWithProgress(
    <String>[path],
    sourceLabel: sourceLabel,
    maxGames: maxGames,
    buildOpeningTree: false,
    fastPgnPreview: true,
    inactivityTimeout: inactivityTimeout,
  );
}

Future<LocalChessFileNode> scanLocalChessFileNodeWithProgress({
  required String path,
  required String rootPath,
  int maxDecodedBytes = _kMaxParseBytes,
  int maxGames = _kMaxTotalGames,
  bool buildOpeningTree = true,
  void Function(LocalChessScanProgress progress)? onProgress,
  Duration inactivityTimeout = const Duration(minutes: 2),
}) async {
  final scanPath = path.trim();
  if (scanPath.isEmpty) {
    throw ArgumentError('No file was provided.');
  }
  if (maxDecodedBytes <= 0) {
    throw ArgumentError.value(
      maxDecodedBytes,
      'maxDecodedBytes',
      'must be > 0',
    );
  }
  if (maxGames <= 0) {
    throw ArgumentError.value(maxGames, 'maxGames', 'must be > 0');
  }
  if (inactivityTimeout <= Duration.zero) {
    throw ArgumentError.value(
      inactivityTimeout,
      'inactivityTimeout',
      'must be > 0',
    );
  }

  final receivePort = ReceivePort();
  final completer = Completer<LocalChessFileNode>();
  final workerExited = Completer<void>();
  late final StreamSubscription<dynamic> subscription;
  Isolate? isolate;
  Timer? inactivityTimer;

  void completeWithError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    inactivityTimer?.cancel();
    completer.completeError(error, stackTrace);
    isolate?.kill(priority: Isolate.immediate);
  }

  void armWatchdog() {
    inactivityTimer?.cancel();
    inactivityTimer = Timer(inactivityTimeout, () {
      completeWithError(
        LocalChessFileAccessException.stalled(path: scanPath),
        StackTrace.current,
      );
    });
  }

  subscription = receivePort.listen((message) {
    if (message == null) {
      if (!workerExited.isCompleted) workerExited.complete();
      if (!completer.isCompleted) {
        completeWithError(
          StateError('PGN file scan worker exited before returning a result.'),
          StackTrace.current,
        );
      }
      return;
    }
    if (completer.isCompleted) return;
    armWatchdog();
    switch (message) {
      case LocalChessScanProgress progress:
        onProgress?.call(progress);
      case _ScanFileWorkerSuccess(:final file):
        inactivityTimer?.cancel();
        completer.complete(file);
      case _ScanWorkerFailure(:final message, :final stackTrace):
        completeWithError(
          ArgumentError(message),
          StackTrace.fromString(stackTrace),
        );
    }
  });

  try {
    armWatchdog();
    isolate = await Isolate.spawn(
      _scanLocalChessFileNodeWorker,
      _ScanFileWorkerRequest(
        sendPort: receivePort.sendPort,
        path: scanPath,
        rootPath: rootPath,
        maxDecodedBytes: maxDecodedBytes,
        maxGames: maxGames,
        buildOpeningTree: buildOpeningTree,
      ),
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
    );
    return await completer.future;
  } catch (error, stackTrace) {
    completeWithError(error, stackTrace);
    return await completer.future;
  } finally {
    inactivityTimer?.cancel();
    isolate?.kill(priority: Isolate.immediate);
    if (isolate != null && !workerExited.isCompleted) {
      try {
        await workerExited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // The worker has already received an immediate kill request.
      }
    }
    receivePort.close();
    await subscription.cancel();
  }
}

List<String> _validateScanInputs(
  List<String> rawPaths, {
  required int maxDecodedBytes,
  required int maxGames,
}) {
  if (maxDecodedBytes <= 0) {
    throw ArgumentError.value(
      maxDecodedBytes,
      'maxDecodedBytes',
      'must be > 0',
    );
  }
  if (maxGames <= 0) {
    throw ArgumentError.value(maxGames, 'maxGames', 'must be > 0');
  }
  final paths = dedupeLocalChessInputPaths(rawPaths);
  if (paths.isEmpty) {
    throw ArgumentError('No files or folders were provided.');
  }
  return paths;
}

class _ScanWorkerRequest {
  const _ScanWorkerRequest({
    required this.sendPort,
    required this.paths,
    required this.maxDecodedBytes,
    required this.maxGames,
    required this.buildOpeningTree,
    required this.fastPgnPreview,
    required this.fullPgnCatalog,
    this.sourceLabel,
  });

  final SendPort sendPort;
  final List<String> paths;
  final String? sourceLabel;
  final int maxDecodedBytes;
  final int maxGames;
  final bool buildOpeningTree;
  final bool fastPgnPreview;
  final bool fullPgnCatalog;
}

class _ScanFileWorkerRequest {
  const _ScanFileWorkerRequest({
    required this.sendPort,
    required this.path,
    required this.rootPath,
    required this.maxDecodedBytes,
    required this.maxGames,
    required this.buildOpeningTree,
  });

  final SendPort sendPort;
  final String path;
  final String rootPath;
  final int maxDecodedBytes;
  final int maxGames;
  final bool buildOpeningTree;
}

/// Reads a raw PGN once and returns every game's lightweight headers and byte
/// range without parsing moves, fingerprinting games, or writing a cache.
///
/// This is the Library's immediate browsing source. Opening an individual game
/// hydrates its PGN from [LocalChessGame.sourceByteStart]/`sourceByteEnd`.
Future<LocalChessSource> scanLocalChessPgnCatalog(
  String path, {
  String? sourceLabel,
  int maxGames = _kMaxTotalGames,
  Duration inactivityTimeout = const Duration(minutes: 2),
  void Function(LocalChessScanProgress progress)? onProgress,
}) {
  return scanLocalChessPathsWithProgress(
    <String>[path],
    sourceLabel: sourceLabel,
    maxGames: maxGames,
    buildOpeningTree: false,
    fullPgnCatalog: true,
    inactivityTimeout: inactivityTimeout,
    onProgress: onProgress,
  );
}

class _CompactPgnTreeWorkerRequest {
  const _CompactPgnTreeWorkerRequest({
    required this.sendPort,
    required this.path,
    required this.maxGames,
    required this.maxPly,
  });

  final SendPort sendPort;
  final String path;
  final int maxGames;
  final int maxPly;
}

class _CompactPgnTreeWorkerReady {
  const _CompactPgnTreeWorkerReady(this.cancellationPort);

  final SendPort cancellationPort;
}

class _CompactPgnTreeWorkerSuccess {
  const _CompactPgnTreeWorkerSuccess(this.result);

  final CompactLocalTreeBuildResult result;
}

class _ScanImportWorkerRequest {
  const _ScanImportWorkerRequest({
    required this.sendPort,
    required this.path,
    required this.rootPath,
    required this.maxDecodedBytes,
    required this.maxGames,
    required this.deduplicateGames,
    required this.previewGameLimit,
    required this.batchSize,
    required this.snapshotDirectoryPath,
    this.debugWorkerStartDelay,
  });

  final SendPort sendPort;
  final String path;
  final String rootPath;
  final int maxDecodedBytes;
  final int maxGames;
  final bool deduplicateGames;
  final int previewGameLimit;
  final int batchSize;
  final String snapshotDirectoryPath;
  final Duration? debugWorkerStartDelay;
}

class _ScanImportWorkerStart {
  const _ScanImportWorkerStart(this.start, this.ackPort);

  final LocalChessFileImportStart start;
  final SendPort ackPort;
}

class _ScanImportWorkerBatch {
  const _ScanImportWorkerBatch(this.batch, this.ackPort);

  final LocalChessFileImportBatch batch;
  final SendPort ackPort;
}

class _ScanWorkerInactivityWindow {
  const _ScanWorkerInactivityWindow(this.timeout);

  final Duration timeout;
}

class _ScanImportWorkerAck {
  const _ScanImportWorkerAck();
}

class _ScanWorkerSuccess {
  const _ScanWorkerSuccess(this.source);

  final LocalChessSource source;
}

class _ScanFileWorkerSuccess {
  const _ScanFileWorkerSuccess(this.file);

  final LocalChessFileNode file;
}

class _ScanImportWorkerSuccess {
  const _ScanImportWorkerSuccess(this.file);

  final LocalChessFileNode file;
}

class _ScanWorkerFailure {
  const _ScanWorkerFailure(this.message, this.stackTrace);

  final String message;
  final String stackTrace;
}

Future<void> _scanLocalChessPathsWorker(_ScanWorkerRequest request) async {
  void emit(LocalChessScanProgress progress) {
    request.sendPort.send(progress);
  }

  try {
    emit(LocalChessScanProgress(fraction: 0, message: 'Preparing PGN...'));
    final source = await _runScan(
      request.paths,
      sourceLabel: request.sourceLabel,
      maxDecodedBytes: request.maxDecodedBytes,
      maxGames: request.maxGames,
      buildOpeningTree: request.buildOpeningTree,
      fastPgnPreview: request.fastPgnPreview,
      fullPgnCatalog: request.fullPgnCatalog,
      onProgress: emit,
    );
    emit(LocalChessScanProgress(fraction: 1, message: 'PGN ready.'));
    request.sendPort.send(_ScanWorkerSuccess(source));
  } catch (error, stackTrace) {
    request.sendPort.send(
      _ScanWorkerFailure(_scanWorkerErrorMessage(error), stackTrace.toString()),
    );
  }
}

Future<void> _scanLocalChessFileNodeForImportWorker(
  _ScanImportWorkerRequest request,
) async {
  try {
    final debugDelay = request.debugWorkerStartDelay;
    if (debugDelay != null) await Future<void>.delayed(debugDelay);
    final file = await _scanLocalChessFileNodeForImportInline(
      path: request.path,
      rootPath: request.rootPath,
      maxDecodedBytes: request.maxDecodedBytes,
      maxGames: request.maxGames,
      deduplicateGames: request.deduplicateGames,
      previewGameLimit: request.previewGameLimit,
      batchSize: request.batchSize,
      snapshotDirectoryPath: request.snapshotDirectoryPath,
      onProgress: request.sendPort.send,
      onInactivityWindow:
          (timeout) =>
              request.sendPort.send(_ScanWorkerInactivityWindow(timeout)),
      onImportStart:
          (start) => _sendImportWorkerMessageWithBackpressure(
            request.sendPort,
            (ackPort) => _ScanImportWorkerStart(start, ackPort),
          ),
      onGameBatch:
          (batch) => _sendImportWorkerMessageWithBackpressure(
            request.sendPort,
            (ackPort) => _ScanImportWorkerBatch(batch, ackPort),
          ),
    );
    request.sendPort.send(_ScanImportWorkerSuccess(file));
  } catch (error, stackTrace) {
    request.sendPort.send(
      _ScanWorkerFailure(_scanWorkerErrorMessage(error), stackTrace.toString()),
    );
  }
}

Future<void> _sendImportWorkerMessageWithBackpressure(
  SendPort sendPort,
  Object Function(SendPort ackPort) createMessage,
) async {
  final ackPort = ReceivePort();
  try {
    sendPort.send(createMessage(ackPort.sendPort));
    await ackPort.first;
  } finally {
    ackPort.close();
  }
}

Future<void> _scanLocalChessFileNodeWorker(
  _ScanFileWorkerRequest request,
) async {
  void emit(LocalChessScanProgress progress) {
    request.sendPort.send(progress);
  }

  try {
    emit(LocalChessScanProgress(fraction: 0, message: 'Preparing PGN...'));
    final file = await _runFileNodeScan(
      request.path,
      rootPath: request.rootPath,
      maxDecodedBytes: request.maxDecodedBytes,
      maxGames: request.maxGames,
      buildOpeningTree: request.buildOpeningTree,
      onProgress: emit,
    );
    emit(LocalChessScanProgress(fraction: 1, message: 'PGN ready.'));
    request.sendPort.send(_ScanFileWorkerSuccess(file));
  } catch (error, stackTrace) {
    request.sendPort.send(
      _ScanWorkerFailure(_scanWorkerErrorMessage(error), stackTrace.toString()),
    );
  }
}

Future<void> _buildCompactPgnTreeWorker(
  _CompactPgnTreeWorkerRequest request,
) async {
  void emit(double fraction, String message) {
    request.sendPort.send(
      LocalChessScanProgress(fraction: fraction, message: message),
    );
  }

  _PgnRangeScanResult? scan;
  CompactLocalTreeIndexBuilder? builder;
  resqlite.Database? gameDatabase;
  String? temporaryGameIndexPath;
  var gameIndexPublished = false;
  final cancellationPort = ReceivePort();
  var canceled = false;
  final cancellationSubscription = cancellationPort.listen((_) {
    canceled = true;
  });
  request.sendPort.send(_CompactPgnTreeWorkerReady(cancellationPort.sendPort));
  void throwIfCanceled() {
    if (canceled) throw const OperationCanceledException();
  }

  try {
    final file = File(request.path);
    if (!await file.exists()) {
      throw FileSystemException('Player PGN file was not found.', request.path);
    }
    emit(0.01, 'Scanning PGN...');
    scan = await _scanPgnFileRanges(
      request.path,
      maxEntries: request.maxGames,
      createStableSnapshot: false,
      shouldStop: () => canceled,
      onScanProgress: (fraction) {
        emit(0.01 + (fraction * 0.14), 'Scanning PGN...');
      },
    );
    throwIfCanceled();
    if (scan.totalEntries <= 0) {
      throw StateError('No playable PGN games were found.');
    }
    if (scan.totalEntries > request.maxGames) {
      throw StateError(
        'Player PGN has ${scan.totalEntries} games, above the '
        '${request.maxGames}-game tree limit.',
      );
    }
    final completedScan = scan;

    final relativePath = p.basename(request.path);
    final compactBuilder = CompactLocalTreeIndexBuilder(
      targetPath: compactLocalTreeIndexPath(request.path),
      maxPly: request.maxPly,
    );
    builder = compactBuilder;
    final gameIndexPath = compactLocalTreeGameIndexPath(request.path);
    temporaryGameIndexPath =
        '$gameIndexPath.build-${DateTime.now().microsecondsSinceEpoch}';
    final temporaryGameIndex = File(temporaryGameIndexPath);
    if (await temporaryGameIndex.exists()) await temporaryGameIndex.delete();
    gameDatabase = await resqlite.Database.open(temporaryGameIndexPath);
    await _createCompactPgnGameDatabase(gameDatabase);
    final databaseId = _compactPgnDatabaseId(request.path);
    var processed = 0;
    emit(0.15, 'Building tree...');
    await gameDatabase.transaction((transaction) async {
      final pendingRows = <List<Object?>>[];
      Future<void> flushRows() async {
        if (pendingRows.isEmpty) return;
        await transaction.executeBatch(
          _compactPgnGameInsertSql,
          List<List<Object?>>.of(pendingRows),
        );
        pendingRows.clear();
      }

      await _forEachParsedPgnRange(
        request.path,
        completedScan,
        onEntry: (sourceIndex, entry) async {
          throwIfCanceled();
          final metadata = <String, String>{
            for (final item in entry.game.metadata.entries)
              if (item.value != null) item.key: item.value.toString(),
          };
          final gameId = 'local_${_stableId('${request.path}#$sourceIndex')}';
          final input = LocalOpeningTreeGameInput(
            id: gameId,
            rawPgn: entry.rawPgn,
            metadata: metadata,
            startingFen: entry.game.startingFen,
            sourcePath: request.path,
            sourceRelativePath: relativePath,
            fileName: p.basename(request.path),
            indexInFile: sourceIndex,
            fileGameCount: completedScan.totalEntries,
            sourceByteStart: entry.sourceByteStart,
            sourceByteEnd: entry.sourceByteEnd,
          );
          final line = compactBuilder.addGame(input);
          if (line != null) {
            pendingRows.add(
              _compactPgnGameRow(
                databaseId: databaseId,
                gameId: gameId,
                sourceIndex: sourceIndex,
                totalGames: completedScan.totalEntries,
                path: request.path,
                relativePath: relativePath,
                entry: entry,
                metadata: metadata,
                line: line,
              ),
            );
            if (pendingRows.length >= 512) await flushRows();
          }
          throwIfCanceled();
          processed++;
          if (processed == completedScan.totalEntries || processed % 128 == 0) {
            final fraction = processed / completedScan.totalEntries;
            emit(
              0.15 + (fraction * 0.75),
              'Building tree... $processed of ${completedScan.totalEntries} games',
            );
          }
        },
      );
      await flushRows();
    });
    throwIfCanceled();

    final after = await file.stat();
    if (!_samePgnPreviewFileStat(completedScan.sourceStat, after)) {
      throw LocalChessFileAccessException.changed(path: request.path);
    }
    emit(0.92, 'Finalizing tree...');
    final result = compactBuilder.finish();
    if (result.metadata.positionCount <= 0) {
      deleteCompactLocalTreeIndexBestEffort(request.path);
      throw StateError('Opening tree build did not produce an index.');
    }
    await gameDatabase.close();
    gameDatabase = null;
    _publishCompactPgnGameIndex(
      temporaryPath: temporaryGameIndexPath,
      targetPath: gameIndexPath,
    );
    gameIndexPublished = true;
    emit(1, 'Tree ready.');
    request.sendPort.send(_CompactPgnTreeWorkerSuccess(result));
  } catch (error, stackTrace) {
    if (!gameIndexPublished) {
      deleteCompactLocalTreeIndexBestEffort(request.path);
    }
    request.sendPort.send(
      _ScanWorkerFailure(_scanWorkerErrorMessage(error), stackTrace.toString()),
    );
  } finally {
    builder?.abort();
    await gameDatabase?.close();
    final temporaryPath = temporaryGameIndexPath;
    if (temporaryPath != null) {
      try {
        final temporaryFile = File(temporaryPath);
        if (await temporaryFile.exists()) await temporaryFile.delete();
      } on FileSystemException {
        // A failed/canceled build never owns the published sidecar.
      }
    }
    await scan?.dispose();
    await cancellationSubscription.cancel();
    cancellationPort.close();
  }
}

const String _compactPgnGameInsertSql = '''
  INSERT INTO local_chess_games (
    id, database_id, event_id, site_id, date, utc_time, round,
    white_id, white_elo, black_id, black_elo,
    white_material, black_material, result,
    time_control, time_control_category, is_online, eco, ply_count,
    fen, moves, pawn_home, raw_pgn, headers_json,
    source_path, source_relative_path, file_name,
    index_in_file, file_game_count, has_moves, pgn_hash,
    source_byte_start, source_byte_end
  ) VALUES (
    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
  )
''';

Future<void> _createCompactPgnGameDatabase(resqlite.Database db) async {
  await db.execute('''
    CREATE TABLE local_chess_players (
      id INTEGER PRIMARY KEY,
      name TEXT,
      elo INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE local_chess_events (
      id INTEGER PRIMARY KEY,
      name TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE local_chess_sites (
      id INTEGER PRIMARY KEY,
      name TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE local_chess_games (
      id TEXT PRIMARY KEY,
      database_id TEXT NOT NULL,
      event_id INTEGER NOT NULL DEFAULT 0,
      site_id INTEGER NOT NULL DEFAULT 0,
      date TEXT,
      utc_time TEXT,
      round TEXT,
      white_id INTEGER NOT NULL DEFAULT 0,
      white_elo INTEGER,
      black_id INTEGER NOT NULL DEFAULT 0,
      black_elo INTEGER,
      white_material INTEGER NOT NULL DEFAULT 39,
      black_material INTEGER NOT NULL DEFAULT 39,
      result TEXT,
      time_control TEXT,
      time_control_category TEXT,
      is_online INTEGER,
      eco TEXT,
      ply_count INTEGER NOT NULL DEFAULT 0,
      fen TEXT,
      moves TEXT NOT NULL DEFAULT '[]',
      pawn_home INTEGER NOT NULL DEFAULT 65535,
      raw_pgn TEXT NOT NULL DEFAULT '',
      headers_json TEXT NOT NULL DEFAULT '{}',
      source_path TEXT NOT NULL,
      source_relative_path TEXT NOT NULL,
      file_name TEXT NOT NULL,
      index_in_file INTEGER NOT NULL,
      file_game_count INTEGER NOT NULL,
      has_moves INTEGER NOT NULL DEFAULT 0,
      pgn_hash TEXT,
      source_byte_start INTEGER,
      source_byte_end INTEGER
    )
  ''');
  await db.execute('''
    CREATE INDEX idx_local_chess_games_database_index
    ON local_chess_games(database_id, index_in_file)
  ''');
}

List<Object?> _compactPgnGameRow({
  required String databaseId,
  required String gameId,
  required int sourceIndex,
  required int totalGames,
  required String path,
  required String relativePath,
  required _ParsedLocalChessGame entry,
  required Map<String, String> metadata,
  required List<String> line,
}) {
  String meta(String key) => metadata[key]?.trim() ?? '';
  int? rating(String key) {
    final value = int.tryParse(meta(key));
    return value != null && value > 0 ? value : null;
  }

  final timeControl = meta('TimeControl');
  final timeControlCategory =
      classifyTimeControlCategory(
        timeControl,
        event: meta('Event'),
        site: meta('Site'),
        source: meta('ChessEverSource'),
      ) ??
      classifyPgnTimeControlCategory(meta('ChessEverTimeControlCategory')) ??
      'unknown';
  return <Object?>[
    gameId,
    databaseId,
    sourceIndex * 4 + 1,
    sourceIndex * 4 + 2,
    meta('Date'),
    meta('UTCTime'),
    meta('Round'),
    sourceIndex * 4 + 3,
    rating('WhiteElo'),
    sourceIndex * 4 + 4,
    rating('BlackElo'),
    39,
    39,
    meta('Result'),
    timeControl,
    timeControlCategory,
    _compactPgnIsOnline(metadata, path) ? 1 : 0,
    meta('ECO'),
    line.length,
    entry.game.startingFen,
    jsonEncode(line),
    65535,
    '',
    jsonEncode(metadata),
    path,
    relativePath,
    p.basename(path),
    sourceIndex,
    totalGames,
    entry.hasMoves ? 1 : 0,
    '',
    entry.sourceByteStart,
    entry.sourceByteEnd,
  ];
}

bool _compactPgnIsOnline(Map<String, String> metadata, String path) {
  final haystack = <String>[
    for (final key in const <String>[
      'Site',
      'Event',
      'Source',
      'ChessEverSource',
      'Annotator',
      'WhiteTeam',
      'BlackTeam',
    ])
      metadata[key] ?? '',
    metadata['TimeControl'] ?? '',
    path,
  ].join(' ').toLowerCase();
  return haystack.contains('lichess') ||
      haystack.contains('chess.com') ||
      haystack.contains('chess24') ||
      haystack.contains('playchess') ||
      haystack.contains('fics') ||
      haystack.contains('internet chess club') ||
      haystack.contains('chessclub.com') ||
      haystack.contains('tornelo') ||
      haystack.contains('online');
}

String _compactPgnDatabaseId(String path) {
  final normalized = p.normalize(path.trim());
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

void _publishCompactPgnGameIndex({
  required String temporaryPath,
  required String targetPath,
}) {
  final temporary = File(temporaryPath);
  final target = File(targetPath);
  final backup = File('$targetPath.previous');
  try {
    if (backup.existsSync()) backup.deleteSync();
    if (target.existsSync()) target.renameSync(backup.path);
    temporary.renameSync(target.path);
    if (backup.existsSync()) backup.deleteSync();
  } catch (_) {
    if (!target.existsSync() && backup.existsSync()) {
      backup.renameSync(target.path);
    }
    rethrow;
  }
}

String _scanWorkerErrorMessage(Object error) {
  if (error is LocalChessFileAccessException) return error.userMessage;

  if (error is ArgumentError) {
    final message = error.message;
    if (message != null) {
      final text = message.toString().trim();
      if (text.isNotEmpty) return text;
    }
  }

  if (error is FileSystemException) {
    return LocalChessFileAccessException.from(error).userMessage;
  }

  return error.toString();
}

Future<LocalChessFileNode> _runFileNodeScan(
  String path, {
  required String rootPath,
  required int maxDecodedBytes,
  required int maxGames,
  required bool buildOpeningTree,
  void Function(LocalChessScanProgress progress)? onProgress,
}) async {
  final worker = _ScanWorker(
    maxDecodedBytes: maxDecodedBytes,
    maxGames: maxGames,
    buildOpeningTree: buildOpeningTree,
    onProgress: onProgress,
  );
  final node = await worker.scanPath(
    path,
    rootPath: rootPath,
    force: true,
    followLinks: true,
  );
  if (node is LocalChessFileNode) return node;
  if (node == null) {
    throw ArgumentError(
      'No recognized chess file was found at ${_basename(path)}. '
      'Open $localChessRecognizedFormatsLabel.',
    );
  }
  throw ArgumentError(
    'Expected a local chess file but found a folder at ${_basename(path)}.',
  );
}

Future<LocalChessSource> _runScan(
  List<String> paths, {
  String? sourceLabel,
  required int maxDecodedBytes,
  required int maxGames,
  required bool buildOpeningTree,
  bool fastPgnPreview = false,
  bool fullPgnCatalog = false,
  void Function(LocalChessScanProgress progress)? onProgress,
}) async {
  final worker = _ScanWorker(
    maxDecodedBytes: maxDecodedBytes,
    maxGames: maxGames,
    buildOpeningTree: buildOpeningTree,
    fastPgnPreview: fastPgnPreview,
    fullPgnCatalog: fullPgnCatalog,
    onProgress: onProgress,
  );

  if (paths.length == 1) {
    return worker.scanSingle(paths.single, sourceLabel: sourceLabel);
  }

  final children = <LocalChessNode>[];
  for (final path in paths) {
    final node = await worker.scanPath(
      path,
      rootPath: p.dirname(path),
      force: true,
      followLinks: true,
    );
    if (node != null) children.add(node);
  }
  if (children.isEmpty) {
    throw ArgumentError(
      'No recognized chess files or folders were provided. '
      'Open $localChessRecognizedFormatsLabel.',
    );
  }
  _sortNodes(children);
  final label = sourceLabel ?? localChessDatabaseDisplayNameForPaths(paths);
  final root = LocalChessFolderNode.fromChildren(
    name: label,
    path: 'local-batch:${_stableId(paths.join('|'))}',
    relativePath: '',
    children: children,
  );
  return LocalChessSource(
    id: _stableId(paths.join('|')),
    label: label,
    paths: paths,
    rootPath: root.path,
    scannedAt: DateTime.now(),
    root: root,
  );
}

class _ScanWorker {
  _ScanWorker({
    required this.maxDecodedBytes,
    required this.maxGames,
    required this.buildOpeningTree,
    this.fastPgnPreview = false,
    this.fullPgnCatalog = false,
    this.onProgress,
  });

  final int maxDecodedBytes;
  final int maxGames;
  final bool buildOpeningTree;
  final bool fastPgnPreview;
  final bool fullPgnCatalog;
  final void Function(LocalChessScanProgress progress)? onProgress;

  int _totalGames = 0;

  bool get _atCap => _totalGames >= maxGames;

  int _claim(int count) {
    if (_atCap) return 0;
    final room = maxGames - _totalGames;
    final granted = count <= room ? count : room;
    _totalGames += granted;
    return granted;
  }

  void _emitProgress(double fraction, String message) {
    onProgress?.call(
      LocalChessScanProgress(fraction: fraction, message: message),
    );
  }

  Future<LocalChessSource> scanSingle(
    String path, {
    String? sourceLabel,
  }) async {
    _emitProgress(0.01, 'Opening PGN...');
    final type = await FileSystemEntity.type(path, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('File or folder does not exist', path);
    }

    if (type == FileSystemEntityType.directory) {
      final root =
          await _scanDirectory(path, rootPath: path, force: true) ??
          LocalChessFolderNode.fromChildren(
            name: localChessDatabaseDisplayNameForPath(path),
            path: path,
            relativePath: '',
            children: const <LocalChessNode>[],
          );
      return LocalChessSource(
        id: _stableId(path),
        label: sourceLabel ?? localChessDatabaseDisplayNameForPath(path),
        paths: <String>[path],
        rootPath: path,
        scannedAt: DateTime.now(),
        root: root,
      );
    }

    _emitProgress(0.02, 'Reading PGN file...');
    final parent = p.dirname(path);
    final node = await _scanFile(path, rootPath: parent);
    if (node == null) {
      throw ArgumentError(
        'No recognized chess file was found at ${_basename(path)}. '
        'Open $localChessRecognizedFormatsLabel.',
      );
    }
    final label = sourceLabel ?? localChessDatabaseDisplayNameForPath(path);
    final root = switch (node) {
      LocalChessFolderNode() => LocalChessFolderNode.fromChildren(
        name: label,
        path: node.path,
        relativePath: '',
        children: node.children,
        scanError: node.scanError,
      ),
      LocalChessNode() => LocalChessFolderNode.fromChildren(
        name: label,
        path: 'local-file:${_stableId(path)}',
        relativePath: '',
        children: <LocalChessNode>[node],
      ),
    };
    return LocalChessSource(
      id: _stableId(path),
      label: label,
      paths: <String>[path],
      rootPath: parent,
      scannedAt: DateTime.now(),
      root: root,
    );
  }

  Future<LocalChessNode?> scanPath(
    String path, {
    required String rootPath,
    required bool force,
    bool followLinks = false,
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: followLinks);
    switch (type) {
      case FileSystemEntityType.directory:
        return _scanDirectory(path, rootPath: rootPath, force: force);
      case FileSystemEntityType.file:
        return _scanFile(path, rootPath: rootPath);
      case FileSystemEntityType.link:
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        return null;
    }
    return null;
  }

  Future<LocalChessFolderNode?> _scanDirectory(
    String path, {
    required String rootPath,
    bool force = false,
  }) async {
    final children = <LocalChessNode>[];
    String? scanError;
    try {
      await for (final entity in Directory(path).list(followLinks: false)) {
        _emitProgress(0.02, 'Scanning folder...');
        try {
          final node = await scanPath(
            entity.path,
            rootPath: rootPath,
            force: false,
          );
          if (node != null) children.add(node);
        } on FileSystemException catch (e) {
          final node = _failedFileNodeFromFileSystemException(
            entity.path,
            rootPath: rootPath,
            exception: e,
          );
          if (node != null) {
            children.add(node);
          } else {
            scanError ??= e.toString();
          }
        }
      }
    } on FileSystemException catch (e) {
      scanError = e.toString();
    }

    _sortNodes(children);
    if (!force && children.isEmpty && scanError == null) return null;
    return LocalChessFolderNode.fromChildren(
      name: localChessDatabaseDisplayNameForPath(path),
      path: path,
      relativePath: _relative(rootPath, path),
      children: children,
      scanError: scanError,
    );
  }

  Future<LocalChessNode?> _scanFile(
    String path, {
    required String rootPath,
  }) async {
    if (!looksLikeLocalChessFile(path)) return null;

    final extension = _extensionForPath(path);
    final FileStat stat;
    try {
      stat = await File(path).stat();
    } on FileSystemException catch (e) {
      return _failedFileNodeFromFileSystemException(
        path,
        rootPath: rootPath,
        extension: extension,
        exception: e,
      );
    }

    if (!isSupportedLocalChessFile(path)) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.unsupported,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: _unsupportedMessage(extension),
      );
    }

    if (_requiresFullDecode(extension) && stat.size > maxDecodedBytes) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.unsupported,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: _tooLargeMessage(stat.size),
      );
    }

    if (_atCap) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.unsupported,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: _capReachedMessage,
      );
    }

    if (fullPgnCatalog && extension.toLowerCase() == '.pgn') {
      final file = await _scanPgnCatalogFile(
        path,
        rootPath: rootPath,
        maxGames: maxGames - _totalGames,
        onProgress: _emitProgress,
      );
      _claim(file.games.length);
      return file;
    }

    try {
      _emitProgress(0.03, 'Scanning PGN...');
      final parseResult = await _parseSupportedFile(
        path: path,
        extension: extension,
        maxEntries: maxGames - _totalGames,
        maxDecodedBytes: maxDecodedBytes,
        fastPgnPreview: fastPgnPreview,
        onPgnScanProgress:
            (fraction) =>
                _emitProgress(0.03 + (fraction * 0.27), 'Scanning PGN...'),
        onPgnReadProgress:
            (fraction) =>
                _emitProgress(0.30 + (fraction * 0.10), 'Reading games...'),
      );
      final entries = parseResult.entries;
      final totalEntries = parseResult.totalEntries;
      final offsetIndex = parseResult.offsetIndex;
      final parsedSourceStat = parseResult.sourceStat ?? stat;
      final contentFingerprint = parseResult.contentFingerprint;
      if (entries.isEmpty) {
        if (contentFingerprint.isNotEmpty) {
          await validateLocalChessFileSnapshotSource(
            path,
            expectedStat: parsedSourceStat,
            expectedContentFingerprint: contentFingerprint,
          );
        }
        return LocalChessFileNode(
          name: localChessDatabaseDisplayNameForPath(path),
          path: path,
          relativePath: _relative(rootPath, path),
          extension: extension,
          status: LocalChessFileStatus.noGames,
          games: const <LocalChessGame>[],
          sizeBytes: parsedSourceStat.size,
          modifiedAt: parsedSourceStat.modified,
          message: 'No playable entries were found.',
          contentFingerprint: contentFingerprint,
        );
      }

      final uniqueEntries = <_UniqueParsedLocalChessGame>[];
      final seenFingerprints = <String>{};
      var duplicateCount = 0;
      for (final (sourceIndex, entry) in entries.indexed) {
        final fingerprint = localChessPgnFingerprint(entry.rawPgn);
        if (!seenFingerprints.add(fingerprint)) {
          duplicateCount++;
          continue;
        }
        uniqueEntries.add(
          _UniqueParsedLocalChessGame(
            sourceIndex: sourceIndex,
            fingerprint: fingerprint,
            entry: entry,
          ),
        );
      }
      entries.clear();
      seenFingerprints.clear();

      final granted = _claim(uniqueEntries.length);
      final accepted = uniqueEntries.take(granted).toList(growable: true);
      uniqueEntries.clear();
      final acceptedCount = accepted.length;
      final relativePath = _relative(rootPath, path);
      final canLazyLoadRawPgn = offsetIndex != null;
      final inlineRawPgn =
          !canLazyLoadRawPgn || acceptedCount <= _kInlineRawPgnLimit;
      final treeWorkerCount =
          buildOpeningTree
              ? _treeWorkerCountForLocalFile(
                fileSizeBytes: parsedSourceStat.size,
                gameCount: acceptedCount,
              )
              : null;
      final treeMaxPly =
          buildOpeningTree
              ? _treeMaxPlyForLocalFile(
                fileSizeBytes: parsedSourceStat.size,
                gameCount: acceptedCount,
              )
              : localOpeningTreeDefaultMaxPly;
      _emitProgress(0.41, 'Preparing game list...');
      final games = <LocalChessGame>[];
      for (final acceptedEntry in accepted) {
        final entry = acceptedEntry.entry;
        final sourceIndex = acceptedEntry.sourceIndex;
        final id = 'local_${_stableId('$path#$sourceIndex')}';
        final rawPgn = entry.rawPgn;
        games.add(
          LocalChessGame(
            id: id,
            game: entry.game.copyWith(gameId: id),
            rawPgn: inlineRawPgn ? rawPgn : '',
            sourcePath: path,
            sourceRelativePath: relativePath,
            fileName: _basename(path),
            indexInFile: sourceIndex,
            fileGameCount: totalEntries,
            hasMoves: entry.hasMoves,
            pgnFingerprint: acceptedEntry.fingerprint,
            sourceByteStart: entry.sourceByteStart,
            sourceByteEnd: entry.sourceByteEnd,
          ),
        );
      }

      if (games.isEmpty) {
        accepted.clear();
        if (contentFingerprint.isNotEmpty) {
          await validateLocalChessFileSnapshotSource(
            path,
            expectedStat: parsedSourceStat,
            expectedContentFingerprint: contentFingerprint,
          );
        }
        return LocalChessFileNode(
          name: localChessDatabaseDisplayNameForPath(path),
          path: path,
          relativePath: relativePath,
          extension: extension,
          status: LocalChessFileStatus.unsupported,
          games: const <LocalChessGame>[],
          sizeBytes: parsedSourceStat.size,
          modifiedAt: parsedSourceStat.modified,
          message: _capReachedMessage,
          contentFingerprint: contentFingerprint,
        );
      }

      LocalOpeningTreeBuildResult? buildResult;
      String? treeBuildMessage;
      if (buildOpeningTree) {
        final includeTreeGameRows = games.length <= _kEagerTreeGameRowLimit;
        final includePositionGameRefs =
            games.length <= _kEagerPositionGameRefLimit;
        try {
          _emitProgress(0.45, 'Building opening tree...');
          if (treeWorkerCount == 1) {
            try {
              buildResult = buildLocalOpeningTreeIndexWithDiagnosticsIterable(
                treeId: 'local:${_stableId(path)}',
                databaseId: path,
                maxPly: treeMaxPly,
                includePositionGameRefs: includePositionGameRefs,
                includeGameRows: includeTreeGameRows,
                games: _treeInputsForAcceptedEntries(
                  accepted: accepted,
                  path: path,
                  relativePath: relativePath,
                  totalEntries: totalEntries,
                ),
              );
              _emitProgress(0.95, 'Building opening tree...');
            } finally {
              accepted.clear();
            }
          } else {
            final treeInputs = _treeInputsForAcceptedEntries(
              accepted: accepted,
              path: path,
              relativePath: relativePath,
              totalEntries: totalEntries,
            ).toList(growable: true);
            accepted.clear();
            try {
              buildResult =
                  await buildLocalOpeningTreeIndexWithDiagnosticsAsync(
                    treeId: 'local:${_stableId(path)}',
                    databaseId: path,
                    maxPly: treeMaxPly,
                    includePositionGameRefs: includePositionGameRefs,
                    includeGameRows: includeTreeGameRows,
                    workerCount: treeWorkerCount,
                    games: treeInputs,
                    onShardComplete: (completedShards, totalShards) {
                      if (totalShards <= 0) return;
                      final fraction = completedShards / totalShards;
                      _emitProgress(
                        0.45 + (fraction * 0.50),
                        'Building opening tree...',
                      );
                    },
                  );
            } finally {
              treeInputs.clear();
            }
          }
        } on ArgumentError catch (e) {
          treeBuildMessage = LocalOpeningTreeBuildException(path, e).toString();
        } on Exception catch (e) {
          treeBuildMessage = LocalOpeningTreeBuildException(path, e).toString();
        }
      } else {
        accepted.clear();
        treeBuildMessage = 'Opening tree queued for background build.';
      }
      final openingTreeIndex = buildResult?.index;
      _emitProgress(0.97, 'Finalizing PGN...');
      if (contentFingerprint.isNotEmpty) {
        await validateLocalChessFileSnapshotSource(
          path,
          expectedStat: parsedSourceStat,
          expectedContentFingerprint: contentFingerprint,
        );
      }
      final messages = <String>[
        if (granted < totalEntries)
          'Showing first $granted of $totalEntries entries; the rest were '
              'skipped to stay within the index cap.',
        if (treeBuildMessage != null) treeBuildMessage,
        if (buildResult != null && buildResult.skippedGames.isNotEmpty)
          _openingTreeSkippedMessage(
            indexedGames: openingTreeIndex!.downloadedGameCount,
            skippedGames: buildResult.skippedGames.length,
          ),
        if (duplicateCount > 0)
          'Skipped $duplicateCount duplicate PGN ${duplicateCount == 1 ? 'entry' : 'entries'}.',
      ];

      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: relativePath,
        extension: extension,
        status: LocalChessFileStatus.parsed,
        games: games,
        sizeBytes: parsedSourceStat.size,
        modifiedAt: parsedSourceStat.modified,
        message: messages.isEmpty ? null : messages.join(' '),
        openingTreeIndex: openingTreeIndex,
        pgnOffsetIndex: offsetIndex,
        contentFingerprint: contentFingerprint,
      );
    } on FileSystemException catch (e) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: LocalChessFileAccessException.from(e, path: path).userMessage,
      );
    } on LocalChessFileAccessException catch (e) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: e.userMessage,
      );
    } on _DecodedPgnTooLargeException catch (e) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.unsupported,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: _tooLargeMessage(e.sizeBytes),
      );
    } on _CompressedPgnDecodeException catch (e) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: e.toString(),
      );
    } on LocalOpeningTreeBuildException catch (e) {
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: e.toString(),
      );
    }
  }
}

Iterable<LocalOpeningTreeGameInput> _treeInputsForAcceptedEntries({
  required List<_UniqueParsedLocalChessGame> accepted,
  required String path,
  required String relativePath,
  required int totalEntries,
}) sync* {
  for (final acceptedEntry in accepted) {
    final sourceIndex = acceptedEntry.sourceIndex;
    yield LocalOpeningTreeGameInput(
      id: 'local_${_stableId('$path#$sourceIndex')}',
      rawPgn: acceptedEntry.entry.rawPgn,
      sourcePath: path,
      sourceRelativePath: relativePath,
      fileName: _basename(path),
      indexInFile: sourceIndex,
      fileGameCount: totalEntries,
      sourceByteStart: acceptedEntry.entry.sourceByteStart,
      sourceByteEnd: acceptedEntry.entry.sourceByteEnd,
    );
  }
}

int? _treeWorkerCountForLocalFile({
  required int fileSizeBytes,
  required int gameCount,
}) {
  if (gameCount <= 1) return 1;
  if (fileSizeBytes >= _kSingleWorkerTreeBuildBytes) return 1;
  if (fileSizeBytes >= _kTwoWorkerTreeBuildBytes) return 2;
  return null;
}

int _treeMaxPlyForLocalFile({
  required int fileSizeBytes,
  required int gameCount,
}) {
  if (fileSizeBytes >= _kSingleWorkerTreeBuildBytes || gameCount >= 50000) {
    return localOpeningTreeLargeImportMaxPly;
  }
  return localOpeningTreeDefaultMaxPly;
}

LocalChessFileNode? _failedFileNodeFromFileSystemException(
  String path, {
  required String rootPath,
  required FileSystemException exception,
  String? extension,
}) {
  if (!looksLikeLocalChessFile(path)) return null;
  final resolvedExtension = extension ?? _extensionForPath(path);
  return LocalChessFileNode(
    name: localChessDatabaseDisplayNameForPath(path),
    path: path,
    relativePath: _relative(rootPath, path),
    extension: resolvedExtension,
    status: LocalChessFileStatus.failed,
    games: const <LocalChessGame>[],
    sizeBytes: 0,
    modifiedAt: null,
    message:
        LocalChessFileAccessException.from(exception, path: path).userMessage,
  );
}

final class _LocalChessTextSnapshot {
  const _LocalChessTextSnapshot({
    required this.text,
    required this.sourceStat,
    required this.contentFingerprint,
  });

  final String text;
  final FileStat sourceStat;
  final String contentFingerprint;
}

Future<_LocalChessTextSnapshot> _readTextFileSnapshot(
  String path,
  String extension, {
  required int maxDecodedBytes,
  void Function(double fraction)? onReadProgress,
  void Function()? beforeDecode,
}) async {
  final snapshot = await readStableLocalChessFileSnapshot(
    path,
    maxBytes: maxDecodedBytes,
    onProgress: onReadProgress,
  );
  final contentFingerprint = computeLocalChessBytesContentFingerprint(
    snapshot.bytes,
  );
  beforeDecode?.call();
  final pgnBytes = _decodePgnBytes(
    snapshot.bytes,
    extension,
    maxDecodedBytes: maxDecodedBytes,
  );
  if (pgnBytes.length > maxDecodedBytes) {
    throw _DecodedPgnTooLargeException(pgnBytes.length);
  }
  return _LocalChessTextSnapshot(
    text: _decodeTextBytes(pgnBytes),
    sourceStat: snapshot.sourceStat,
    contentFingerprint: contentFingerprint,
  );
}

Uint8List _decodePgnBytes(
  Uint8List bytes,
  String extension, {
  required int maxDecodedBytes,
}) {
  final lower = extension.toLowerCase();
  switch (lower) {
    case '.pgn.bz2':
    case '.bz2':
      return _decodeCompressedPgn(
        extension: lower,
        bytes: bytes,
        decode: () => _decodeBzip2Pgn(bytes, lower, maxDecodedBytes),
      );
    case '.pgn.zst':
    case '.zst':
      return _decodeCompressedPgn(
        extension: lower,
        bytes: bytes,
        decode:
            () => ZstdCodec(
              maxDecompressedSize: maxDecodedBytes,
            ).decompress(bytes),
      );
    default:
      return bytes;
  }
}

Uint8List _decodeBzip2Pgn(
  Uint8List bytes,
  String extension,
  int maxDecodedBytes,
) {
  final input = InputMemoryStream(bytes);
  final output = _CappedOutputMemoryStream(maxDecodedBytes);
  final decoded = BZip2Decoder().decodeStream(input, output, verify: true);
  if (!decoded) {
    throw _CompressedPgnDecodeException(extension, 'invalid bzip2 stream');
  }
  return output.getBytes();
}

class _CappedOutputMemoryStream extends OutputMemoryStream {
  _CappedOutputMemoryStream(this.maxBytes);

  final int maxBytes;

  void _ensureRoom(int additionalBytes) {
    if (length + additionalBytes > maxBytes) {
      throw _DecodedPgnTooLargeException(length + additionalBytes);
    }
  }

  @override
  void writeByte(int value) {
    _ensureRoom(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final byteCount = length ?? bytes.length;
    _ensureRoom(byteCount);
    super.writeBytes(bytes, length: byteCount);
  }

  @override
  void writeStream(InputStream stream) {
    _ensureRoom(stream.length);
    super.writeStream(stream);
  }
}

Uint8List _decodeCompressedPgn({
  required String extension,
  required Uint8List bytes,
  required Uint8List Function() decode,
}) {
  try {
    final decoded = decode();
    if (decoded.isEmpty && bytes.isNotEmpty) {
      throw _CompressedPgnDecodeException(
        extension,
        'decoder returned no PGN bytes',
      );
    }
    return decoded;
  } on _CompressedPgnDecodeException {
    rethrow;
  } on _DecodedPgnTooLargeException {
    rethrow;
  } on ZstdFormatException catch (error) {
    if (_isDeclaredZstdSizeOverLimit(error)) {
      throw _DecodedPgnTooLargeException(
        _declaredZstdContentSize(error) ?? _kMaxParseBytes + 1,
      );
    }
    throw _CompressedPgnDecodeException(extension, error);
  } on FormatException catch (error) {
    throw _CompressedPgnDecodeException(extension, error);
  } on RangeError catch (error) {
    throw _CompressedPgnDecodeException(extension, error);
  } on ArgumentError catch (error) {
    throw _CompressedPgnDecodeException(extension, error);
  } on StateError catch (error) {
    throw _CompressedPgnDecodeException(extension, error);
  }
}

bool _isDeclaredZstdSizeOverLimit(ZstdFormatException error) {
  return error.toString().contains('exceeds maximum allowed size');
}

int? _declaredZstdContentSize(ZstdFormatException error) {
  final match = RegExp(
    r'Declared content size (\d+) exceeds',
  ).firstMatch(error.toString());
  final rawSize = match?.group(1);
  return rawSize == null ? null : int.tryParse(rawSize);
}

class _DecodedPgnTooLargeException implements Exception {
  const _DecodedPgnTooLargeException(this.sizeBytes);

  final int sizeBytes;

  @override
  String toString() => _tooLargeMessage(sizeBytes);
}

class _CompressedPgnDecodeException implements Exception {
  const _CompressedPgnDecodeException(this.extension, this.cause);

  final String extension;
  final Object cause;

  @override
  String toString() => 'Could not decode compressed PGN ($extension): $cause';
}

String _decodeTextBytes(List<int> bytes) {
  final utf = utf8.decode(bytes, allowMalformed: true);
  if (utf.trim().isNotEmpty) return utf;
  return latin1.decode(bytes, allowInvalid: true);
}

Future<_PgnParseResult> _parseSupportedFile({
  required String path,
  required String extension,
  required int maxEntries,
  required int maxDecodedBytes,
  bool fastPgnPreview = false,
  void Function(double fraction)? onPgnScanProgress,
  void Function(double fraction)? onPgnReadProgress,
}) async {
  switch (extension.toLowerCase()) {
    case '.pgn':
      return _parsePgnFile(
        path,
        maxEntries: maxEntries,
        fastPgnPreview: fastPgnPreview,
        onScanProgress: onPgnScanProgress,
        onReadProgress: onPgnReadProgress,
      );
    case '.pgn.bz2':
    case '.bz2':
    case '.pgn.zst':
    case '.zst':
      onPgnScanProgress?.call(0);
      final snapshot = await _readTextFileSnapshot(
        path,
        extension,
        maxDecodedBytes: maxDecodedBytes,
      );
      onPgnScanProgress?.call(1);
      onPgnReadProgress?.call(0);
      final result = _parsePgnText(snapshot.text, maxEntries: maxEntries);
      await validateLocalChessFileSnapshotSource(
        path,
        expectedStat: snapshot.sourceStat,
        expectedContentFingerprint: snapshot.contentFingerprint,
      );
      onPgnReadProgress?.call(1);
      return _PgnParseResult(
        entries: result.entries,
        totalEntries: result.totalEntries,
        sourceStat: snapshot.sourceStat,
        contentFingerprint: snapshot.contentFingerprint,
      );
    default:
      return const _PgnParseResult(
        entries: <_ParsedLocalChessGame>[],
        totalEntries: 0,
      );
  }
}

// Splits a PGN blob into per-game chunks and lifts only the [Tag "value"]
// headers + a movetext-present hint. Movetext is left unparsed: the Board
// pane re-parses it on demand when the user opens a specific game.
_PgnParseResult _parsePgnText(String text, {required int maxEntries}) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final trimmed = normalized.trim();
  if (trimmed.isEmpty) {
    return const _PgnParseResult(
      entries: <_ParsedLocalChessGame>[],
      totalEntries: 0,
    );
  }

  final chunks = _splitPgnGameChunks(trimmed);
  final entries = <_ParsedLocalChessGame>[];
  var totalEntries = 0;
  for (final rawPgn in chunks) {
    if (rawPgn.isEmpty) continue;
    final entry = _entryFromPgnChunk(rawPgn);
    if (entry == null) continue;
    totalEntries++;
    if (entries.length < maxEntries) entries.add(entry);
  }
  return _PgnParseResult(entries: entries, totalEntries: totalEntries);
}

List<String> _splitPgnGameChunks(String text) {
  final chunks = <String>[];
  final current = StringBuffer();
  var sawMovetext = false;
  var inComment = false;

  var start = 0;
  while (start <= text.length) {
    final newline = text.indexOf('\n', start);
    final isLastLine = newline == -1;
    final line =
        isLastLine ? text.substring(start) : text.substring(start, newline);
    final trimmedLine = _stripBom(line).trimLeft();
    final isHeader =
        !inComment &&
        trimmedLine.startsWith('[') &&
        _kPgnHeaderLineRegex.hasMatch(trimmedLine);
    if (isHeader && sawMovetext && current.isNotEmpty) {
      final chunk = current.toString().trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      current.clear();
      sawMovetext = false;
    }

    current.writeln(line);
    if (trimmedLine.isNotEmpty && !isHeader) {
      sawMovetext = true;
    }
    inComment = _updatePgnCommentState(line, inComment);
    if (isLastLine) break;
    start = newline + 1;
  }

  final tail = current.toString().trim();
  if (tail.isNotEmpty) chunks.add(tail);
  return chunks;
}

Future<_PgnParseResult> _parsePgnFile(
  String path, {
  required int maxEntries,
  bool fastPgnPreview = false,
  void Function(double fraction)? onScanProgress,
  void Function(double fraction)? onReadProgress,
}) async {
  final scan = await _scanPgnFileRanges(
    path,
    maxEntries: maxEntries,
    stopAfterMaxEntries: fastPgnPreview,
    onScanProgress: onScanProgress,
  );
  final entries = <_ParsedLocalChessGame>[];
  try {
    await _forEachParsedPgnRange(
      path,
      scan,
      onEntry: (_, entry) {
        entries.add(entry);
      },
      onReadProgress: onReadProgress,
    );
    if (fastPgnPreview) {
      final after = await File(path).stat();
      if (!_samePgnPreviewFileStat(scan.sourceStat, after)) {
        throw LocalChessFileAccessException.changed(path: path);
      }
    } else {
      await validateLocalChessFileSnapshotSource(
        path,
        expectedStat: scan.sourceStat,
        expectedContentFingerprint: scan.contentFingerprint,
      );
    }
    return _PgnParseResult(
      entries: entries,
      totalEntries: scan.totalEntries,
      offsetIndex: fastPgnPreview ? null : scan.offsetIndex,
      sourceStat: scan.sourceStat,
      contentFingerprint: scan.contentFingerprint,
    );
  } finally {
    await scan.dispose();
  }
}

Future<_PgnRangeScanResult> _scanPgnFileRanges(
  String path, {
  required int maxEntries,
  bool stopAfterMaxEntries = false,
  bool createStableSnapshot = true,
  bool Function()? shouldStop,
  void Function(double fraction)? onScanProgress,
  String? snapshotDirectoryPath,
}) async {
  final ranges = <_PgnByteRange>[];
  final checkpointOffsets = <int>[];
  var currentStartOffset = 0;
  var hasCurrent = false;
  var sawMovetext = false;
  var currentHasHeader = false;
  var currentHasMoveHint = false;
  var currentMaxMoveNumber = 0;
  var currentHeaderEndOffset = 0;
  var totalEntries = 0;
  var finalOffset = 0;
  var stopRequested = false;

  void flushCurrent(int endOffset) {
    if (!hasCurrent || endOffset <= currentStartOffset) {
      hasCurrent = false;
      sawMovetext = false;
      currentHasHeader = false;
      currentHasMoveHint = false;
      currentMaxMoveNumber = 0;
      currentHeaderEndOffset = 0;
      return;
    }
    if (!currentHasHeader && !currentHasMoveHint) {
      hasCurrent = false;
      sawMovetext = false;
      currentHasHeader = false;
      currentHasMoveHint = false;
      currentMaxMoveNumber = 0;
      currentHeaderEndOffset = 0;
      return;
    }
    final gameIndex = totalEntries;
    totalEntries++;
    if (gameIndex % _kPgnOffsetCheckpointStride == 0) {
      checkpointOffsets.add(currentStartOffset);
    }
    if (ranges.length < maxEntries) {
      ranges.add(
        _PgnByteRange(
          start: currentStartOffset,
          headerEnd: currentHeaderEndOffset,
          end: endOffset,
          hasMoveHint: currentHasMoveHint,
          maxMoveNumber: currentMaxMoveNumber,
        ),
      );
    }
    if (stopAfterMaxEntries && totalEntries >= maxEntries) {
      stopRequested = true;
    }
    hasCurrent = false;
    sawMovetext = false;
    currentHasHeader = false;
    currentHasMoveHint = false;
    currentMaxMoveNumber = 0;
    currentHeaderEndOffset = 0;
  }

  var stat = await File(path).stat();
  Directory? ownedSnapshotDirectory;
  String? snapshotPath;
  final scanner = _PgnByteLineScanner((line) {
    finalOffset = line.endOffset;

    if (!hasCurrent && line.isBlank) {
      return;
    }

    if (line.isHeader && sawMovetext && hasCurrent) {
      flushCurrent(line.startOffset);
      sawMovetext = false;
    }
    if (stopRequested) return;

    if (!hasCurrent) {
      currentStartOffset = line.contentStartOffset;
      hasCurrent = true;
    }
    if (line.isHeader) {
      currentHasHeader = true;
      currentHeaderEndOffset = line.endOffset;
    }
    if (line.hasMoveHint) {
      currentHasMoveHint = true;
    }
    if (!line.isHeader && line.maxMoveNumber > currentMaxMoveNumber) {
      currentMaxMoveNumber = line.maxMoveNumber;
    }
    if (!line.isBlank && !line.isHeader) {
      sawMovetext = true;
    }
  });
  if (stopAfterMaxEntries) {
    final before = stat;
    await scanner.scan(
      path,
      totalBytes: stat.size,
      shouldStop: () => stopRequested,
      onProgress: onScanProgress,
    );
    finalOffset = scanner.finalOffset;
    if (!stopRequested) flushCurrent(finalOffset);
    final after = await File(path).stat();
    if (!_samePgnPreviewFileStat(before, after)) {
      throw LocalChessFileAccessException.changed(path: path);
    }
    onScanProgress?.call(1);
    return _PgnRangeScanResult(
      ranges: ranges,
      totalEntries: totalEntries,
      offsetIndex: LocalChessPgnOffsetIndex(
        path: path,
        fileSizeBytes: after.size,
        modifiedAt: after.modified,
        totalGames: totalEntries,
        checkpointStride: _kPgnOffsetCheckpointStride,
        checkpointOffsets: checkpointOffsets,
      ),
      sourceStat: after,
      contentFingerprint: '',
    );
  }
  if (!createStableSnapshot) {
    final before = stat;
    await scanner.scan(
      path,
      totalBytes: stat.size,
      shouldStop: shouldStop,
      onProgress: onScanProgress,
    );
    if (shouldStop?.call() ?? false) {
      throw const OperationCanceledException();
    }
    finalOffset = scanner.finalOffset;
    flushCurrent(finalOffset);
    final after = await File(path).stat();
    if (!_samePgnPreviewFileStat(before, after)) {
      throw LocalChessFileAccessException.changed(path: path);
    }
    onScanProgress?.call(1);
    return _PgnRangeScanResult(
      ranges: ranges,
      totalEntries: totalEntries,
      offsetIndex: LocalChessPgnOffsetIndex(
        path: path,
        fileSizeBytes: after.size,
        modifiedAt: after.modified,
        totalGames: totalEntries,
        checkpointStride: _kPgnOffsetCheckpointStride,
        checkpointOffsets: checkpointOffsets,
      ),
      sourceStat: after,
      contentFingerprint: '',
    );
  }
  final LocalChessFileSnapshot? inMemorySnapshot =
      stat.size <= _kFastInMemoryPgnScanBytes
          ? await readStableLocalChessFileSnapshot(
            path,
            maxBytes: _kFastInMemoryPgnScanBytes,
            onProgress:
                onScanProgress == null
                    ? null
                    : (fraction) => onScanProgress(fraction * 0.5),
          )
          : null;
  final inMemoryBytes = inMemorySnapshot?.bytes;
  late final String contentFingerprint;
  try {
    if (inMemoryBytes != null) {
      stat = inMemorySnapshot!.sourceStat;
      contentFingerprint = computeLocalChessBytesContentFingerprint(
        inMemoryBytes,
      );
      scanner.scanBytes(
        inMemoryBytes,
        totalBytes: inMemoryBytes.length,
        onProgress:
            onScanProgress == null
                ? null
                : (fraction) => onScanProgress(0.5 + (fraction * 0.5)),
      );
    } else {
      final snapshotDirectory =
          snapshotDirectoryPath == null
              ? await Directory.systemTemp.createTemp('chessever_pgn_snapshot_')
              : Directory(snapshotDirectoryPath);
      if (snapshotDirectoryPath == null) {
        ownedSnapshotDirectory = snapshotDirectory;
      } else if (!await snapshotDirectory.exists()) {
        await snapshotDirectory.create(recursive: true);
      }
      snapshotPath = p.join(snapshotDirectory.path, 'source.snapshot.pgn');
      stat = await copyStableLocalChessFile(
        path,
        snapshotPath,
        onProgress:
            onScanProgress == null
                ? null
                : (fraction) => onScanProgress(fraction * 0.5),
      );
      contentFingerprint = await computeLocalChessFileContentFingerprint(
        snapshotPath,
        stat: stat,
      );
      await scanner.scan(
        snapshotPath,
        totalBytes: stat.size,
        onProgress:
            onScanProgress == null
                ? null
                : (fraction) => onScanProgress(0.5 + (fraction * 0.5)),
      );
    }
    finalOffset = scanner.finalOffset;

    flushCurrent(finalOffset);
    onScanProgress?.call(1);

    return _PgnRangeScanResult(
      ranges: ranges,
      totalEntries: totalEntries,
      offsetIndex: LocalChessPgnOffsetIndex(
        path: path,
        fileSizeBytes: stat.size,
        modifiedAt: stat.modified,
        totalGames: totalEntries,
        checkpointStride: _kPgnOffsetCheckpointStride,
        checkpointOffsets: checkpointOffsets,
      ),
      inMemoryBytes: inMemoryBytes,
      snapshotPath: snapshotPath,
      ownedSnapshotDirectoryPath: ownedSnapshotDirectory?.path,
      sourceStat: stat,
      contentFingerprint: contentFingerprint,
    );
  } catch (_) {
    await _deletePgnSnapshotBestEffort(
      snapshotPath: snapshotPath,
      ownedDirectoryPath: ownedSnapshotDirectory?.path,
    );
    rethrow;
  }
}

Future<LocalChessFileNode> _scanPgnCatalogFile(
  String path, {
  required String rootPath,
  required int maxGames,
  required void Function(double fraction, String message) onProgress,
}) async {
  onProgress(0.03, 'Reading game list...');
  final scan = await _scanPgnFileRanges(
    path,
    maxEntries: maxGames,
    createStableSnapshot: false,
    onScanProgress:
        (fraction) =>
            onProgress(0.03 + (fraction * 0.72), 'Reading game list...'),
  );
  final relativePath = _relative(rootPath, path);
  final games = <LocalChessGame>[];
  try {
    if (scan.ranges.isNotEmpty) {
      final raf = File(path).openSync();
      try {
        for (var index = 0; index < scan.ranges.length; index++) {
          final range = scan.ranges[index];
          _ParsedLocalChessGame? headerEntry;
          if (range.headerEnd > range.start) {
            raf.setPositionSync(range.start);
            final headerText = _decodeTextBytes(
              raf.readSync(range.headerEnd - range.start),
            ).trim();
            if (headerText.isNotEmpty) {
              headerEntry = _entryFromPgnChunk(headerText);
            }
          }
          final id = 'local_${_stableId('$path#$index')}';
          final headerGame = headerEntry?.game;
          final catalogGame =
              headerGame != null &&
                      range.maxMoveNumber > 0 &&
                      headerGame.metadata['PlyCount'] == null
                  ? headerGame.copyWith(
                    metadata: <String, dynamic>{
                      ...headerGame.metadata,
                      'PlyCount': '${range.maxMoveNumber * 2}',
                    },
                  )
                  : headerGame;
          games.add(
            LocalChessGame(
              id: id,
              game:
                  catalogGame?.copyWith(gameId: id) ??
                  ChessGame(
                    gameId: id,
                    startingFen: _kStandardStartingFen,
                    metadata: const <String, dynamic>{},
                    mainline: const [],
                  ),
              rawPgn: '',
              sourcePath: path,
              sourceRelativePath: relativePath,
              fileName: _basename(path),
              indexInFile: index,
              fileGameCount: scan.totalEntries,
              hasMoves: range.hasMoveHint,
              sourceByteStart: range.start,
              sourceByteEnd: range.end,
            ),
          );
          if (scan.ranges.length <= 1 ||
              index % 512 == 0 ||
              index == scan.ranges.length - 1) {
            onProgress(
              0.75 + (((index + 1) / scan.ranges.length) * 0.24),
              'Preparing game list...',
            );
          }
        }
      } finally {
        raf.closeSync();
      }
    }
  } finally {
    await scan.dispose();
  }

  onProgress(1, 'Game list ready.');
  if (games.isEmpty) {
    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(path),
      path: path,
      relativePath: relativePath,
      extension: '.pgn',
      status: LocalChessFileStatus.noGames,
      games: const <LocalChessGame>[],
      sizeBytes: scan.sourceStat.size,
      modifiedAt: scan.sourceStat.modified,
      message: 'No playable entries were found.',
      pgnOffsetIndex: scan.offsetIndex,
    );
  }
  return LocalChessFileNode(
    name: localChessDatabaseDisplayNameForPath(path),
    path: path,
    relativePath: relativePath,
    extension: '.pgn',
    status: LocalChessFileStatus.parsed,
    games: games,
    gameCount: games.length,
    sizeBytes: scan.sourceStat.size,
    modifiedAt: scan.sourceStat.modified,
    message:
        scan.totalEntries > games.length
            ? 'Showing the first ${games.length} games.'
            : null,
    pgnOffsetIndex: scan.offsetIndex,
  );
}

Future<void> _forEachParsedPgnRange(
  String path,
  _PgnRangeScanResult scan, {
  required FutureOr<void> Function(int sourceIndex, _ParsedLocalChessGame entry)
  onEntry,
  void Function(double fraction)? onReadProgress,
}) async {
  onReadProgress?.call(0);
  final ranges = scan.ranges;
  if (ranges.isEmpty) {
    onReadProgress?.call(1);
    return;
  }
  final inMemoryBytes = scan.inMemoryBytes;
  if (inMemoryBytes != null) {
    for (var i = 0; i < ranges.length; i++) {
      final range = ranges[i];
      final rawPgn =
          _decodeTextBytes(
            Uint8List.sublistView(inMemoryBytes, range.start, range.end),
          ).trim();
      if (rawPgn.isEmpty) continue;
      final entry = _entryFromPgnChunk(rawPgn);
      if (entry == null) continue;
      await onEntry(
        i,
        entry.copyWithSourceByteRange(start: range.start, end: range.end),
      );
      if (ranges.length <= 1 || i % 256 == 0 || i == ranges.length - 1) {
        onReadProgress?.call((i + 1) / ranges.length);
      }
    }
  } else {
    final raf = await File(scan.snapshotPath ?? path).open();
    try {
      for (var i = 0; i < ranges.length; i++) {
        final range = ranges[i];
        await raf.setPosition(range.start);
        final rawPgn =
            _decodeTextBytes(await raf.read(range.end - range.start)).trim();
        if (rawPgn.isEmpty) continue;
        final entry = _entryFromPgnChunk(rawPgn);
        if (entry == null) continue;
        await onEntry(
          i,
          entry.copyWithSourceByteRange(start: range.start, end: range.end),
        );
        if (ranges.length <= 1 || i % 256 == 0 || i == ranges.length - 1) {
          onReadProgress?.call((i + 1) / ranges.length);
        }
      }
    } finally {
      await raf.close();
    }
  }

  onReadProgress?.call(1);
}

const _kUtf8Bom = <int>[0xEF, 0xBB, 0xBF];

class _PgnRangeScanResult {
  const _PgnRangeScanResult({
    required this.ranges,
    required this.totalEntries,
    required this.offsetIndex,
    this.inMemoryBytes,
    this.snapshotPath,
    this.ownedSnapshotDirectoryPath,
    required this.sourceStat,
    required this.contentFingerprint,
  });

  final List<_PgnByteRange> ranges;
  final int totalEntries;
  final LocalChessPgnOffsetIndex offsetIndex;
  final Uint8List? inMemoryBytes;
  final String? snapshotPath;
  final String? ownedSnapshotDirectoryPath;
  final FileStat sourceStat;
  final String contentFingerprint;

  Future<void> dispose() => _deletePgnSnapshotBestEffort(
    snapshotPath: snapshotPath,
    ownedDirectoryPath: ownedSnapshotDirectoryPath,
  );
}

Future<void> _deletePgnSnapshotBestEffort({
  required String? snapshotPath,
  required String? ownedDirectoryPath,
}) async {
  try {
    if (ownedDirectoryPath != null) {
      final directory = Directory(ownedDirectoryPath);
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    }
    if (snapshotPath != null) {
      final file = File(snapshotPath);
      if (await file.exists()) await file.delete();
    }
  } on FileSystemException {
    // The parent import worker also owns and cleans its unique temp directory.
  }
}

class _PgnByteRange {
  const _PgnByteRange({
    required this.start,
    required this.headerEnd,
    required this.end,
    required this.hasMoveHint,
    required this.maxMoveNumber,
  });

  final int start;
  final int headerEnd;
  final int end;
  final bool hasMoveHint;
  final int maxMoveNumber;
}

class _PgnByteLine {
  const _PgnByteLine({
    required this.startOffset,
    required this.contentStartOffset,
    required this.endOffset,
    required this.isHeader,
    required this.isBlank,
    required this.hasMoveHint,
    required this.maxMoveNumber,
  });

  final int startOffset;
  final int contentStartOffset;
  final int endOffset;
  final bool isHeader;
  final bool isBlank;
  final bool hasMoveHint;
  final int maxMoveNumber;
}

class _PgnByteLineScanner {
  _PgnByteLineScanner(this.onLine);

  final void Function(_PgnByteLine line) onLine;

  int finalOffset = 0;
  int _offset = 0;
  int _lineStartOffset = 0;
  int _lineByteCount = 0;
  bool _pendingCr = false;
  bool _isFirstLine = true;
  bool _lineStartedInComment = false;
  bool _inComment = false;
  bool _lineHasNonWhitespace = false;
  bool _lineHasMoveHint = false;
  int? _lineMoveNumberCandidate;
  int _lineMaxMoveNumber = 0;
  int _variationDepth = 0;
  bool _lineStartsWithUtf8Bom = false;
  int? _firstNonWhitespaceByte;

  Future<void> scan(
    String path, {
    int? totalBytes,
    void Function(double fraction)? onProgress,
    bool Function()? shouldStop,
  }) async {
    var lastProgressOffset = 0;
    void emitProgress({bool force = false}) {
      if (onProgress == null || totalBytes == null || totalBytes <= 0) return;
      if (!force && _offset - lastProgressOffset < 1024 * 1024) return;
      lastProgressOffset = _offset;
      onProgress((_offset / totalBytes).clamp(0.0, 1.0).toDouble());
    }

    emitProgress(force: true);
    scanLoop:
    await for (final chunk in File(path).openRead()) {
      for (final byte in chunk) {
        _readByte(byte);
        if (shouldStop?.call() ?? false) break scanLoop;
      }
      emitProgress();
    }
    if (!(shouldStop?.call() ?? false)) {
      if (_pendingCr) {
        _flushLine(_offset);
        _pendingCr = false;
      }
      if (_lineByteCount > 0 || _offset == _lineStartOffset) {
        _flushLine(_offset);
      }
    }
    finalOffset = _offset;
    emitProgress(force: true);
  }

  void scanBytes(
    Uint8List bytes, {
    int? totalBytes,
    void Function(double fraction)? onProgress,
  }) {
    var lastProgressOffset = 0;
    void emitProgress({bool force = false}) {
      if (onProgress == null || totalBytes == null || totalBytes <= 0) return;
      if (!force && _offset - lastProgressOffset < 1024 * 1024) return;
      lastProgressOffset = _offset;
      onProgress((_offset / totalBytes).clamp(0.0, 1.0).toDouble());
    }

    emitProgress(force: true);
    for (final byte in bytes) {
      _readByte(byte);
      if (_offset - lastProgressOffset >= 1024 * 1024) {
        emitProgress();
      }
    }
    if (_pendingCr) {
      _flushLine(_offset);
      _pendingCr = false;
    }
    if (_lineByteCount > 0 || _offset == _lineStartOffset) {
      _flushLine(_offset);
    }
    finalOffset = _offset;
    emitProgress(force: true);
  }

  void _readByte(int byte) {
    if (_pendingCr) {
      if (byte == 0x0A) {
        _offset++;
        _flushLine(_offset);
        _pendingCr = false;
        return;
      }
      _flushLine(_offset);
      _pendingCr = false;
    }

    _offset++;
    if (byte == 0x0D) {
      _pendingCr = true;
      return;
    }
    if (byte == 0x0A) {
      _flushLine(_offset);
      return;
    }
    _readContentByte(byte);
  }

  void _readContentByte(int byte) {
    if (_isFirstLine &&
        _lineByteCount < _kUtf8Bom.length &&
        byte == _kUtf8Bom[_lineByteCount]) {
      if (_lineByteCount == _kUtf8Bom.length - 1) {
        _lineStartsWithUtf8Bom = true;
      }
      _lineByteCount++;
      return;
    }

    _lineByteCount++;
    if (!_isWhitespaceByte(byte)) {
      _lineHasNonWhitespace = true;
      _firstNonWhitespaceByte ??= byte;
    }

    if (byte == 0x7B) {
      _inComment = true;
      _lineMoveNumberCandidate = null;
      return;
    } else if (byte == 0x7D) {
      _inComment = false;
      _lineMoveNumberCandidate = null;
      return;
    }
    if (_inComment) {
      _lineMoveNumberCandidate = null;
      return;
    }
    if (byte == 0x28) {
      _variationDepth++;
      _lineMoveNumberCandidate = null;
      return;
    }
    if (byte == 0x29) {
      if (_variationDepth > 0) _variationDepth--;
      _lineMoveNumberCandidate = null;
      return;
    }
    if (_variationDepth > 0) {
      _lineMoveNumberCandidate = null;
      return;
    }

    if (byte >= 0x30 && byte <= 0x39) {
      final digit = byte - 0x30;
      _lineMoveNumberCandidate = (_lineMoveNumberCandidate ?? 0) * 10 + digit;
    } else if (byte == 0x2E && _lineMoveNumberCandidate != null) {
      _lineHasMoveHint = true;
      if (_lineMoveNumberCandidate! > _lineMaxMoveNumber) {
        _lineMaxMoveNumber = _lineMoveNumberCandidate!;
      }
      _lineMoveNumberCandidate = null;
    } else {
      _lineMoveNumberCandidate = null;
    }
  }

  void _flushLine(int endOffset) {
    if (_lineByteCount == 0 && endOffset == _lineStartOffset) return;
    final startsWithBom = _isFirstLine && _startsWithUtf8Bom();
    onLine(
      _PgnByteLine(
        startOffset: _lineStartOffset,
        contentStartOffset:
            startsWithBom
                ? _lineStartOffset + _kUtf8Bom.length
                : _lineStartOffset,
        endOffset: endOffset,
        isHeader: !_lineStartedInComment && _firstNonWhitespaceByte == 0x5B,
        isBlank: !_lineHasNonWhitespace,
        hasMoveHint: _lineHasMoveHint,
        maxMoveNumber: _lineMaxMoveNumber,
      ),
    );
    _lineStartOffset = endOffset;
    _lineByteCount = 0;
    _lineHasNonWhitespace = false;
    _lineHasMoveHint = false;
    _lineMoveNumberCandidate = null;
    _lineMaxMoveNumber = 0;
    _lineStartsWithUtf8Bom = false;
    _firstNonWhitespaceByte = null;
    _lineStartedInComment = _inComment;
    _isFirstLine = false;
  }

  bool _startsWithUtf8Bom() {
    return _lineStartOffset == 0 && _lineStartsWithUtf8Bom;
  }
}

bool _samePgnPreviewFileStat(FileStat before, FileStat after) {
  return before.type == FileSystemEntityType.file &&
      after.type == FileSystemEntityType.file &&
      before.size == after.size &&
      before.modified == after.modified &&
      before.changed == after.changed;
}

bool _isWhitespaceByte(int byte) {
  return byte == 0x20 ||
      byte == 0x09 ||
      byte == 0x0A ||
      byte == 0x0D ||
      byte == 0x0B ||
      byte == 0x0C;
}

bool _requiresFullDecode(String extension) => extension.toLowerCase() != '.pgn';

String _stripBom(String line) {
  if (line.startsWith('\uFEFF')) return line.substring(1);
  return line;
}

bool _updatePgnCommentState(String line, bool inComment) {
  if (!inComment && !line.contains('{')) return false;
  var next = inComment;
  for (final codeUnit in line.codeUnits) {
    if (codeUnit == 0x7B) {
      next = true;
    } else if (codeUnit == 0x7D) {
      next = false;
    }
  }
  return next;
}

_ParsedLocalChessGame? _entryFromPgnChunk(String rawPgn) {
  final headers = <String, dynamic>{};
  var headerEnd = 0;
  for (final match in _kPgnHeaderRegex.allMatches(rawPgn)) {
    headers[match.group(1)!] = _unescapePgnHeader(match.group(2)!);
    if (match.end > headerEnd) headerEnd = match.end;
  }

  final movetext = rawPgn.substring(headerEnd).trim();
  final hasMoves = _pgnHasMoves(movetext);

  // A chunk that carries neither headers nor moves isn't a playable PGN.
  if (headers.isEmpty && !hasMoves) return null;

  final startingFen =
      (headers['FEN']?.toString().trim().isNotEmpty == true)
          ? headers['FEN'] as String
          : _kStandardStartingFen;

  return _ParsedLocalChessGame(
    game: ChessGame(
      gameId: 'pending',
      startingFen: startingFen,
      metadata: headers,
      mainline: const [],
    ),
    rawPgn: rawPgn,
    hasMoves: hasMoves,
  );
}

bool _pgnHasMoves(String movetext) {
  if (movetext.isEmpty) return false;
  // A cheap probe — a move-number token ("1.", "12.", etc.) within the first
  // chunk of movetext is a strong signal that real moves follow. We avoid
  // scrubbing comments/variations because that work would dominate the scan
  // on large databases.
  final sample = movetext.length > 256 ? movetext.substring(0, 256) : movetext;
  return _kPgnMoveHintRegex.hasMatch(sample);
}

String _unescapePgnHeader(String value) {
  return value.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
}

String _extensionForPath(String path) {
  final lower = path.toLowerCase();
  for (final extension in localChessSupportedExtensions) {
    if (lower.endsWith(extension)) return extension;
  }
  return p.extension(path).toLowerCase();
}

String _openingTreeSkippedMessage({
  required int indexedGames,
  required int skippedGames,
}) {
  final entry = skippedGames == 1 ? 'entry' : 'entries';
  if (indexedGames == 0) {
    return 'Opening tree skipped all $skippedGames invalid PGN $entry; the '
        'game list is still available.';
  }
  return 'Opening tree indexed $indexedGames games and skipped $skippedGames '
      'invalid PGN $entry.';
}

class _ParsedLocalChessGame {
  const _ParsedLocalChessGame({
    required this.game,
    required this.rawPgn,
    required this.hasMoves,
    this.sourceByteStart,
    this.sourceByteEnd,
  });

  final ChessGame game;
  final String rawPgn;
  final bool hasMoves;
  final int? sourceByteStart;
  final int? sourceByteEnd;

  _ParsedLocalChessGame copyWithSourceByteRange({
    required int start,
    required int end,
  }) {
    return _ParsedLocalChessGame(
      game: game,
      rawPgn: rawPgn,
      hasMoves: hasMoves,
      sourceByteStart: start,
      sourceByteEnd: end,
    );
  }
}

class _UniqueParsedLocalChessGame {
  const _UniqueParsedLocalChessGame({
    required this.sourceIndex,
    required this.fingerprint,
    required this.entry,
  });

  final int sourceIndex;
  final String fingerprint;
  final _ParsedLocalChessGame entry;
}

class _PgnParseResult {
  const _PgnParseResult({
    required this.entries,
    required this.totalEntries,
    this.offsetIndex,
    this.sourceStat,
    this.contentFingerprint = '',
  });

  final List<_ParsedLocalChessGame> entries;
  final int totalEntries;
  final LocalChessPgnOffsetIndex? offsetIndex;
  final FileStat? sourceStat;
  final String contentFingerprint;
}

void _sortNodes(List<LocalChessNode> nodes) {
  nodes.sort((a, b) {
    final af = a is LocalChessFolderNode;
    final bf = b is LocalChessFolderNode;
    if (af != bf) return af ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

String _relative(String rootPath, String path) {
  try {
    final relative = p.relative(path, from: rootPath);
    return relative == '.' ? '' : relative;
  } catch (_) {
    return path;
  }
}

String _basename(String path) {
  final normalized = p.normalize(path);
  final base = p.basename(normalized);
  return base.isEmpty ? normalized : base;
}

String _displayExtensionForBasename(String base) {
  final lower = base.toLowerCase();
  for (final extension in localChessSupportedExtensions) {
    if (lower.endsWith(extension)) {
      return base.substring(base.length - extension.length);
    }
  }
  return p.extension(base);
}

bool _shouldPolishLocalDatabaseStem(String stem) {
  if (stem.isEmpty) return false;
  if (!RegExp(r'[a-z]').hasMatch(stem)) return false;
  return RegExp(r'[_\-\s]|\d').hasMatch(stem);
}

String _polishLocalDatabaseStem(String stem) {
  return stem.replaceAllMapped(RegExp(r'[A-Za-z]+'), (match) {
    final word = match.group(0)!;
    if (word.toUpperCase() == word) return word;
    if (word.length <= 3) return word.toUpperCase();
    return '${word[0].toUpperCase()}${word.substring(1)}';
  });
}

String _stableId(String value) => sha1.convert(utf8.encode(value)).toString();

@visibleForTesting
List<String> dedupeLocalChessInputPaths(
  Iterable<String> rawPaths, {
  bool? windows,
}) {
  final deduped = <String>[];
  final seen = <String>{};
  for (final rawPath in rawPaths) {
    final path = rawPath.trim();
    if (path.isEmpty) continue;
    if (!seen.add(localChessInputPathKey(path, windows: windows))) continue;
    deduped.add(path);
  }
  deduped.sort(
    (a, b) => localChessInputPathKey(
      a,
      windows: windows,
    ).compareTo(localChessInputPathKey(b, windows: windows)),
  );
  return deduped;
}

String localChessInputPathKey(String path, {bool? windows}) {
  final isWindows = windows ?? Platform.isWindows;
  if (isWindows) {
    return p.Context(style: p.Style.windows).normalize(path).toLowerCase();
  }
  return p.normalize(path);
}

bool _samePath(String a, String b) {
  if (a.contains('::') || b.contains('::')) {
    return Platform.isWindows
        ? localChessInputPathKey(a) == localChessInputPathKey(b)
        : a == b;
  }
  if (Platform.isWindows) {
    return localChessInputPathKey(a) == localChessInputPathKey(b);
  }
  return p.normalize(a) == p.normalize(b);
}

String _unsupportedMessage(String extension) =>
    localChessUnsupportedFormatMessage;

String _tooLargeMessage(int sizeBytes) {
  final mb = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
  final limitMb = (_kMaxParseBytes / (1024 * 1024)).toStringAsFixed(0);
  return 'This PGN file is $mb MB, which is over the $limitMb MB scan limit. '
      'Open a smaller PGN file or split the database before importing.';
}

const String _capReachedMessage =
    'Skipped to keep the PGN index within the per-folder cap. Split the PGN '
    'database before importing more games.';
