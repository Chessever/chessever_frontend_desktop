import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

const localChessSupportedExtensions = <String>{'.pgn'};

const localChessRecognizedExtensions = <String>{
  '.pgn',
  '.cbh',
  '.cbv',
  '.cbf',
  '.cbg',
  '.cba',
  '.cbb',
  '.cbp',
  '.ctg',
};

const localChessPickerExtensions = <String>['pgn'];

const localChessReadableFormatsLabel = 'PGN databases';

const localChessRecognizedFormatsLabel =
    '$localChessReadableFormatsLabel. Other chess database formats are not supported.';

const localChessDropFormatsMessage = 'PGN files and folders browse locally';

const localChessEmptyFolderFormatsMessage =
    'Only PGN databases are currently supported. Export other chess database '
    'formats as PGN, then import the PGN file.';

const localChessUnsupportedFormatMessage =
    'Only PGN databases are currently supported. Please export this database '
    'as PGN and import the PGN file.';

// Files larger than this are skipped during scan to avoid OOM. The user can
// still open them directly through the Board pane PGN importer.
const int _kMaxParseBytes = 64 * 1024 * 1024; // 64 MB
const int _kMaxTotalGames = 200000;
const String _kStandardStartingFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

final RegExp _kPgnHeaderRegex = RegExp(
  r'^\[\s*(\w+)\s+"((?:[^"\\]|\\.)*)"\s*\]',
  multiLine: true,
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
    return root.find(path) ?? root;
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
  const LocalChessFileNode({
    required super.name,
    required super.path,
    required super.relativePath,
    required this.extension,
    required this.status,
    required this.games,
    required this.sizeBytes,
    this.modifiedAt,
    this.message,
  });

  final String extension;
  final LocalChessFileStatus status;
  final List<LocalChessGame> games;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String? message;

  bool get isPlayable => status == LocalChessFileStatus.parsed;
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
    required this.rawPgn,
    required this.sourcePath,
    required this.sourceRelativePath,
    required this.fileName,
    required this.indexInFile,
    required this.fileGameCount,
    required this.hasMoves,
  });

  final String id;
  final ChessGame game;
  final String rawPgn;
  final String sourcePath;
  final String sourceRelativePath;
  final String fileName;
  final int indexInFile;
  final int fileGameCount;
  // Mainline parsing is deferred to keep scans cheap. This flag mirrors
  // whether the raw PGN actually carries movetext, so list cards can still
  // show a "started" state without parsing every game.
  final bool hasMoves;

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
}) async {
  final paths = dedupeLocalChessInputPaths(rawPaths);
  if (paths.isEmpty) {
    throw ArgumentError('No files or folders were provided.');
  }
  _localPgnScanLog(
    'scan start count=${paths.length} sourceLabel=${sourceLabel ?? 'null'} paths=$paths',
  );
  // Heavy filesystem walk + PGN parsing runs on its own isolate so the UI
  // thread stays responsive on huge databases.
  final stopwatch = Stopwatch()..start();
  final source = await Isolate.run(
    () => _runScan(paths, sourceLabel: sourceLabel),
  );
  stopwatch.stop();
  _localPgnScanLog(
    'scan isolate returned games=${source.root.gameCount} files=${source.root.fileCount} elapsedMs=${stopwatch.elapsedMilliseconds}',
  );
  return source;
}

Future<LocalChessSource> _runScan(
  List<String> paths, {
  String? sourceLabel,
}) async {
  _localPgnScanLog(
    'worker runScan start count=${paths.length} sourceLabel=${sourceLabel ?? 'null'}',
  );
  final worker = _ScanWorker();

  if (paths.length == 1) {
    final source = await worker.scanSingle(
      paths.single,
      sourceLabel: sourceLabel,
    );
    _localPgnScanLog(
      'worker runScan single complete games=${source.root.gameCount} files=${source.root.fileCount}',
    );
    return source;
  }

  final children = <LocalChessNode>[];
  for (final path in paths) {
    _localPgnScanLog('worker runScan scanning path=$path');
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
  final source = LocalChessSource(
    id: _stableId(paths.join('|')),
    label: sourceLabel ?? 'Dropped chess files',
    paths: paths,
    rootPath: root.path,
    scannedAt: DateTime.now(),
    root: root,
  );
  _localPgnScanLog(
    'worker runScan batch complete games=${source.root.gameCount} files=${source.root.fileCount}',
  );
  return source;
}

class _ScanWorker {
  _ScanWorker();

  int _totalGames = 0;

  bool get _atCap => _totalGames >= _kMaxTotalGames;

  int _claim(int count) {
    if (_atCap) return 0;
    final room = _kMaxTotalGames - _totalGames;
    final granted = count <= room ? count : room;
    _totalGames += granted;
    return granted;
  }

  Future<LocalChessSource> scanSingle(
    String path, {
    String? sourceLabel,
  }) async {
    _localPgnScanLog('worker scanSingle start path=$path');
    final type = await FileSystemEntity.type(path, followLinks: false);
    _localPgnScanLog('worker scanSingle type=$type path=$path');
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('File or folder does not exist', path);
    }

    if (type == FileSystemEntityType.directory) {
      final root =
          await _scanDirectory(path, rootPath: path, force: true) ??
          LocalChessFolderNode.fromChildren(
            name: _basename(path),
            path: path,
            relativePath: '',
            children: const <LocalChessNode>[],
          );
      return LocalChessSource(
        id: _stableId(path),
        label: sourceLabel ?? _basename(path),
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
    final label = sourceLabel ?? _basename(path);
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
        final node = await scanPath(
          entity.path,
          rootPath: rootPath,
          force: false,
        );
        if (node != null) children.add(node);
      }
    } catch (e) {
      scanError = e.toString();
    }

    _sortNodes(children);
    if (!force && children.isEmpty && scanError == null) return null;
    return LocalChessFolderNode.fromChildren(
      name: _basename(path),
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
    _localPgnScanLog('worker scanFile start path=$path');

    final extension = _extensionForPath(path);
    final stat = await File(path).stat();
    _localPgnScanLog(
      'worker scanFile stat path=$path extension=$extension bytes=${stat.size} modified=${stat.modified.toIso8601String()}',
    );

    if (!isSupportedLocalChessFile(path)) {
      _localPgnScanLog('worker scanFile unsupported path=$path');
      return LocalChessFileNode(
        name: _basename(path),
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

    if (stat.size > _kMaxParseBytes) {
      _localPgnScanLog(
        'worker scanFile too large path=$path bytes=${stat.size}',
      );
      return LocalChessFileNode(
        name: _basename(path),
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
      _localPgnScanLog('worker scanFile cap reached before path=$path');
      return LocalChessFileNode(
        name: _basename(path),
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
      final stopwatch = Stopwatch()..start();
      final raw = await _readTextFile(path);
      _localPgnScanLog(
        'worker scanFile read/decode path=$path chars=${raw.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      final entries = _parseSupportedFile(
        raw,
        path: path,
        extension: extension,
      );
      _localPgnScanLog(
        'worker scanFile parsed headers path=$path entries=${entries.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      if (entries.isEmpty) {
        return LocalChessFileNode(
          name: _basename(path),
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
      _localPgnScanLog(
        'worker scanFile claim path=$path entries=${entries.length} granted=$granted totalClaimed=$_totalGames',
      );
      final relativePath = _relative(rootPath, path);
      final games = <LocalChessGame>[];
      for (var i = 0; i < accepted.length; i++) {
        if (accepted.length >= 1000 && i > 0 && i % 1000 == 0) {
          _localPgnScanLog(
            'worker scanFile building games path=$path index=$i/${accepted.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
          );
        }
        final entry = accepted[i];
        final id = 'local_${_stableId('$path#$i')}';
        games.add(
          LocalChessGame(
            id: id,
            game: entry.game.copyWith(gameId: id),
            rawPgn: entry.rawPgn,
            sourcePath: path,
            sourceRelativePath: relativePath,
            fileName: _basename(path),
            indexInFile: i,
            fileGameCount: entries.length,
            hasMoves: entry.hasMoves,
          ),
        );
      }
      _localPgnScanLog(
        'worker scanFile built games path=$path games=${games.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );

      if (games.isEmpty) {
        return LocalChessFileNode(
          name: _basename(path),
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

      final node = LocalChessFileNode(
        name: _basename(path),
        path: path,
        relativePath: relativePath,
        extension: extension,
        status: LocalChessFileStatus.parsed,
        games: games,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message:
            granted < entries.length
                ? 'Showing first $granted of ${entries.length} '
                    'entries; the rest were skipped to stay within the index cap.'
                : null,
      );
      _localPgnScanLog(
        'worker scanFile complete path=$path games=${games.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return node;
    } catch (e) {
      _localPgnScanLog('worker scanFile failed path=$path error=$e');
      return LocalChessFileNode(
        name: _basename(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: extension,
        status: LocalChessFileStatus.failed,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: 'Could not read this file: $e',
      );
    }
  }
}

Future<String> _readTextFile(String path) async {
  final bytes = await File(path).readAsBytes();
  return _decodeTextBytes(bytes);
}

String _decodeTextBytes(List<int> bytes) {
  final utf = utf8.decode(bytes, allowMalformed: true);
  if (utf.trim().isNotEmpty) return utf;
  return latin1.decode(bytes, allowInvalid: true);
}

List<_ParsedLocalChessGame> _parseSupportedFile(
  String text, {
  required String path,
  required String extension,
}) {
  switch (extension.toLowerCase()) {
    case '.pgn':
      return _parsePgnHeadersOnly(text);
    default:
      return const <_ParsedLocalChessGame>[];
  }
}

// Splits a PGN blob into per-game chunks and lifts only the [Tag "value"]
// headers + a movetext-present hint. Movetext is left unparsed: the Board
// pane re-parses it on demand when the user opens a specific game.
List<_ParsedLocalChessGame> _parsePgnHeadersOnly(String text) {
  final stopwatch = Stopwatch()..start();
  _localPgnScanLog('worker parse headers start chars=${text.length}');
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final trimmed = normalized.trim();
  if (trimmed.isEmpty) return const <_ParsedLocalChessGame>[];

  final eventStarts = RegExp(
    r'^\[Event\s',
    multiLine: true,
  ).allMatches(trimmed).map((match) => match.start).toList(growable: false);
  _localPgnScanLog(
    'worker parse headers eventStarts=${eventStarts.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
  );

  final chunkRanges = <List<int>>[];
  if (eventStarts.isEmpty) {
    chunkRanges.add(<int>[0, trimmed.length]);
  } else {
    for (var i = 0; i < eventStarts.length; i++) {
      final start = eventStarts[i];
      final end =
          i + 1 < eventStarts.length ? eventStarts[i + 1] : trimmed.length;
      chunkRanges.add(<int>[start, end]);
    }
  }

  final entries = <_ParsedLocalChessGame>[];
  for (var i = 0; i < chunkRanges.length; i++) {
    if (chunkRanges.length >= 1000 && i > 0 && i % 1000 == 0) {
      _localPgnScanLog(
        'worker parse headers progress index=$i/${chunkRanges.length} accepted=${entries.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    }
    final range = chunkRanges[i];
    final rawPgn = trimmed.substring(range[0], range[1]).trim();
    if (rawPgn.isEmpty) continue;
    final entry = _entryFromPgnChunk(rawPgn);
    if (entry != null) entries.add(entry);
  }
  _localPgnScanLog(
    'worker parse headers complete chunks=${chunkRanges.length} accepted=${entries.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
  );
  return entries;
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
  return p.extension(path).toLowerCase();
}

class _ParsedLocalChessGame {
  const _ParsedLocalChessGame({
    required this.game,
    required this.rawPgn,
    required this.hasMoves,
  });

  final ChessGame game;
  final String rawPgn;
  final bool hasMoves;
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

void _localPgnScanLog(String message) {
  stdout.writeln(
    '[LOCAL_PGN_SCAN ${DateTime.now().toIso8601String()}] $message',
  );
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
