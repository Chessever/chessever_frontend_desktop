import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:libcompress/libcompress.dart';

import 'package:chessever/desktop/services/local_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
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
// they keep a decoded-size guard. Raw .pgn files are streamed line by line.
const int _kMaxParseBytes = 64 * 1024 * 1024; // 64 MB
const int _kMaxTotalGames = 200000;
const int _kEagerPositionGameRefLimit = 10000;
const int _kInlineRawPgnLimit = 10000;
const int _kPgnOffsetCheckpointStride = 128;
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
          gameCount += child.games.length;
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
  }) : games = List<LocalChessGame>.unmodifiable(games);

  final String extension;
  final LocalChessFileStatus status;
  final List<LocalChessGame> games;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String? message;
  final PlayerOpeningTreeIndex? openingTreeIndex;
  final LocalChessPgnOffsetIndex? pgnOffsetIndex;

  bool get isPlayable => status == LocalChessFileStatus.parsed;
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
    LocalChessFileNode(:final isPlayable) => isPlayable ? node : null,
    LocalChessFolderNode() => node.singlePlayableDatabaseInSubtree,
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
  final int? sourceByteStart;
  final int? sourceByteEnd;
  // Mainline parsing is deferred to keep scans cheap. This flag mirrors
  // whether the raw PGN actually carries movetext, so list cards can still
  // show a "started" state without parsing every game.
  final bool hasMoves;

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

Future<LocalChessSource> scanLocalChessPaths(
  List<String> rawPaths, {
  String? sourceLabel,
  int maxDecodedBytes = _kMaxParseBytes,
  int maxGames = _kMaxTotalGames,
}) async {
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
  // Heavy filesystem walk + PGN parsing runs on its own isolate so the UI
  // thread stays responsive on huge databases.
  return Isolate.run(
    () => _runScan(
      paths,
      sourceLabel: sourceLabel,
      maxDecodedBytes: maxDecodedBytes,
      maxGames: maxGames,
    ),
  );
}

Future<LocalChessSource> _runScan(
  List<String> paths, {
  String? sourceLabel,
  required int maxDecodedBytes,
  required int maxGames,
}) async {
  final worker = _ScanWorker(
    maxDecodedBytes: maxDecodedBytes,
    maxGames: maxGames,
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
  final root = LocalChessFolderNode.fromChildren(
    name: sourceLabel ?? 'Dropped chess files',
    path: 'local-batch:${_stableId(paths.join('|'))}',
    relativePath: '',
    children: children,
  );
  return LocalChessSource(
    id: _stableId(paths.join('|')),
    label: sourceLabel ?? 'Dropped chess files',
    paths: paths,
    rootPath: root.path,
    scannedAt: DateTime.now(),
    root: root,
  );
}

class _ScanWorker {
  _ScanWorker({required this.maxDecodedBytes, required this.maxGames});

  final int maxDecodedBytes;
  final int maxGames;

  int _totalGames = 0;

  bool get _atCap => _totalGames >= maxGames;

  int _claim(int count) {
    if (_atCap) return 0;
    final room = maxGames - _totalGames;
    final granted = count <= room ? count : room;
    _totalGames += granted;
    return granted;
  }

  Future<LocalChessSource> scanSingle(
    String path, {
    String? sourceLabel,
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
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
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
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

    try {
      final parseResult = await _parseSupportedFile(
        path: path,
        extension: extension,
        maxEntries: maxGames - _totalGames,
        maxDecodedBytes: maxDecodedBytes,
      );
      final entries = parseResult.entries;
      if (entries.isEmpty) {
        return LocalChessFileNode(
          name: localChessDatabaseDisplayNameForPath(path),
          path: path,
          relativePath: _relative(rootPath, path),
          extension: extension,
          status: LocalChessFileStatus.noGames,
          games: const <LocalChessGame>[],
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
          message: 'No playable entries were found.',
        );
      }

      final granted = _claim(entries.length);
      final accepted = entries.take(granted).toList(growable: false);
      final relativePath = _relative(rootPath, path);
      final canLazyLoadRawPgn = parseResult.offsetIndex != null;
      final inlineRawPgn =
          !canLazyLoadRawPgn || accepted.length <= _kInlineRawPgnLimit;
      final games = <LocalChessGame>[];
      final treeInputs = <LocalOpeningTreeGameInput>[];
      for (var i = 0; i < accepted.length; i++) {
        final entry = accepted[i];
        final id = 'local_${_stableId('$path#$i')}';
        final rawPgn = entry.rawPgn;
        games.add(
          LocalChessGame(
            id: id,
            game: entry.game.copyWith(gameId: id),
            rawPgn: inlineRawPgn ? rawPgn : '',
            sourcePath: path,
            sourceRelativePath: relativePath,
            fileName: _basename(path),
            indexInFile: i,
            fileGameCount: parseResult.totalEntries,
            hasMoves: entry.hasMoves,
            sourceByteStart: entry.sourceByteStart,
            sourceByteEnd: entry.sourceByteEnd,
          ),
        );
        treeInputs.add(
          LocalOpeningTreeGameInput(
            id: id,
            rawPgn: rawPgn,
            sourcePath: path,
            sourceRelativePath: relativePath,
            fileName: _basename(path),
            indexInFile: i,
            fileGameCount: parseResult.totalEntries,
          ),
        );
      }

      if (games.isEmpty) {
        return LocalChessFileNode(
          name: localChessDatabaseDisplayNameForPath(path),
          path: path,
          relativePath: relativePath,
          extension: extension,
          status: LocalChessFileStatus.unsupported,
          games: const <LocalChessGame>[],
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
          message: _capReachedMessage,
        );
      }

      final LocalOpeningTreeBuildResult buildResult;
      try {
        buildResult = buildLocalOpeningTreeIndexWithDiagnostics(
          treeId: 'local:${_stableId(path)}',
          databaseId: path,
          includePositionGameRefs: games.length <= _kEagerPositionGameRefLimit,
          games: treeInputs,
        );
      } on ArgumentError catch (e) {
        throw LocalOpeningTreeBuildException(path, e);
      } on Exception catch (e) {
        throw LocalOpeningTreeBuildException(path, e);
      }
      final openingTreeIndex = buildResult.index;
      final messages = <String>[
        if (granted < parseResult.totalEntries)
          'Showing first $granted of ${parseResult.totalEntries} entries; the rest were '
              'skipped to stay within the index cap.',
        if (buildResult.skippedGames.isNotEmpty)
          _openingTreeSkippedMessage(
            indexedGames: openingTreeIndex.downloadedGameCount,
            skippedGames: buildResult.skippedGames.length,
          ),
      ];

      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: relativePath,
        extension: extension,
        status: LocalChessFileStatus.parsed,
        games: games,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: messages.isEmpty ? null : messages.join(' '),
        openingTreeIndex: openingTreeIndex,
        pgnOffsetIndex: parseResult.offsetIndex,
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
        message: 'Could not read this file: $e',
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
    message: 'Could not scan this file: $exception',
  );
}

Future<String> _readTextFile(
  String path,
  String extension, {
  required int maxDecodedBytes,
}) async {
  final bytes = await File(path).readAsBytes();
  final pgnBytes = _decodePgnBytes(
    bytes,
    extension,
    maxDecodedBytes: maxDecodedBytes,
  );
  if (pgnBytes.length > maxDecodedBytes) {
    throw _DecodedPgnTooLargeException(pgnBytes.length);
  }
  return _decodeTextBytes(pgnBytes);
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
}) async {
  switch (extension.toLowerCase()) {
    case '.pgn':
      return _parsePgnFile(path, maxEntries: maxEntries);
    case '.pgn.bz2':
    case '.bz2':
    case '.pgn.zst':
    case '.zst':
      final raw = await _readTextFile(
        path,
        extension,
        maxDecodedBytes: maxDecodedBytes,
      );
      return _parsePgnText(raw, maxEntries: maxEntries);
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

  for (final line in text.split('\n')) {
    final trimmedLine = _stripBom(line).trimLeft();
    final isHeader = !inComment && _kPgnHeaderLineRegex.hasMatch(trimmedLine);
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
  }

  final tail = current.toString().trim();
  if (tail.isNotEmpty) chunks.add(tail);
  return chunks;
}

Future<_PgnParseResult> _parsePgnFile(
  String path, {
  required int maxEntries,
}) async {
  final entries = <_ParsedLocalChessGame>[];
  final current = BytesBuilder(copy: false);
  final checkpointOffsets = <int>[];
  var currentByteLength = 0;
  var currentStartOffset = 0;
  var sawMovetext = false;
  var inComment = false;
  var isFirstLine = true;
  var totalEntries = 0;
  var finalOffset = 0;

  void flushCurrent(int endOffset) {
    if (currentByteLength <= 0) return;
    final rawPgnBytes = current.takeBytes();
    currentByteLength = 0;
    final rawPgn = _decodeTextBytes(rawPgnBytes).trim();
    if (rawPgn.isEmpty) return;
    final entry = _entryFromPgnChunk(rawPgn);
    if (entry == null) return;
    final gameIndex = totalEntries;
    totalEntries++;
    if (gameIndex % _kPgnOffsetCheckpointStride == 0) {
      checkpointOffsets.add(currentStartOffset);
    }
    if (entries.length < maxEntries) {
      entries.add(
        entry.copyWithSourceByteRange(
          start: currentStartOffset,
          end: endOffset,
        ),
      );
    }
  }

  await _forEachPgnFileLine(path, (_RawPgnLine rawLine) {
    final stripBom = isFirstLine;
    final lineBytes = rawLine.contentBytesForParsing(stripUtf8Bom: stripBom);
    final rawBytes = rawLine.bytesForRawPgn(stripUtf8Bom: stripBom);
    final lineStartOffset =
        stripBom && rawLine.startsWithUtf8Bom
            ? rawLine.startOffset + _kUtf8Bom.length
            : rawLine.startOffset;
    isFirstLine = false;
    finalOffset = rawLine.endOffset;
    final line = _decodeTextBytes(lineBytes);
    final trimmedLine = line.trimLeft();
    final isHeader = !inComment && _kPgnHeaderLineRegex.hasMatch(trimmedLine);

    if (currentByteLength == 0 && trimmedLine.isEmpty) {
      inComment = _updatePgnCommentState(line, inComment);
      return;
    }

    if (isHeader && sawMovetext && currentByteLength > 0) {
      flushCurrent(rawLine.startOffset);
      sawMovetext = false;
    }

    if (currentByteLength == 0) {
      currentStartOffset = lineStartOffset;
    }
    current.add(rawBytes);
    currentByteLength += rawBytes.length;
    if (trimmedLine.isNotEmpty && !isHeader) {
      sawMovetext = true;
    }
    inComment = _updatePgnCommentState(line, inComment);
  });

  flushCurrent(finalOffset);

  final stat = await File(path).stat();
  return _PgnParseResult(
    entries: entries,
    totalEntries: totalEntries,
    offsetIndex: LocalChessPgnOffsetIndex(
      path: path,
      fileSizeBytes: stat.size,
      modifiedAt: stat.modified,
      totalGames: totalEntries,
      checkpointStride: _kPgnOffsetCheckpointStride,
      checkpointOffsets: checkpointOffsets,
    ),
  );
}

const _kUtf8Bom = <int>[0xEF, 0xBB, 0xBF];

Future<void> _forEachPgnFileLine(
  String path,
  void Function(_RawPgnLine line) onLine,
) async {
  final line = <int>[];
  var lineStartOffset = 0;
  var offset = 0;
  var pendingCr = false;

  void flushLine({required int endOffset}) {
    if (line.isEmpty && endOffset == lineStartOffset) return;
    onLine(
      _RawPgnLine(
        startOffset: lineStartOffset,
        endOffset: endOffset,
        bytes: List<int>.unmodifiable(line),
      ),
    );
    line.clear();
    lineStartOffset = endOffset;
  }

  await for (final chunk in File(path).openRead()) {
    for (final byte in chunk) {
      if (pendingCr) {
        if (byte == 0x0A) {
          offset++;
          line.add(byte);
          flushLine(endOffset: offset);
          pendingCr = false;
          continue;
        }
        flushLine(endOffset: offset);
        pendingCr = false;
      }

      offset++;
      line.add(byte);
      if (byte == 0x0D) {
        pendingCr = true;
      } else if (byte == 0x0A) {
        flushLine(endOffset: offset);
      }
    }
  }
  if (pendingCr) {
    flushLine(endOffset: offset);
  }
  flushLine(endOffset: offset);
}

class _RawPgnLine {
  const _RawPgnLine({
    required this.startOffset,
    required this.endOffset,
    required this.bytes,
  });

  final int startOffset;
  final int endOffset;
  final List<int> bytes;

  bool get startsWithUtf8Bom {
    return bytes.length >= _kUtf8Bom.length &&
        bytes[0] == _kUtf8Bom[0] &&
        bytes[1] == _kUtf8Bom[1] &&
        bytes[2] == _kUtf8Bom[2];
  }

  List<int> contentBytesForParsing({required bool stripUtf8Bom}) {
    var end = bytes.length;
    if (end > 0 && bytes[end - 1] == 0x0A) end--;
    if (end > 0 && bytes[end - 1] == 0x0D) end--;
    final start = stripUtf8Bom && startsWithUtf8Bom ? _kUtf8Bom.length : 0;
    if (start == 0 && end == bytes.length) return bytes;
    if (start >= end) return const <int>[];
    return bytes.sublist(start, end);
  }

  List<int> bytesForRawPgn({required bool stripUtf8Bom}) {
    if (!stripUtf8Bom || !startsWithUtf8Bom) return bytes;
    if (bytes.length == _kUtf8Bom.length) return const <int>[];
    return bytes.sublist(_kUtf8Bom.length);
  }
}

bool _requiresFullDecode(String extension) => extension.toLowerCase() != '.pgn';

String _stripBom(String line) {
  if (line.startsWith('\uFEFF')) return line.substring(1);
  return line;
}

bool _updatePgnCommentState(String line, bool inComment) {
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

class _PgnParseResult {
  const _PgnParseResult({
    required this.entries,
    required this.totalEntries,
    this.offsetIndex,
  });

  final List<_ParsedLocalChessGame> entries;
  final int totalEntries;
  final LocalChessPgnOffsetIndex? offsetIndex;
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
