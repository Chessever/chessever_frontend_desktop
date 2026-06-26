import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart' show Chess;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/sqlite/local_chess_schema.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

export 'package:chessever/repository/sqlite/local_chess_schema.dart'
    show createLocalChessDatabaseSchema;

class LocalChessGameAnalysis {
  const LocalChessGameAnalysis({
    required this.gameId,
    required this.databaseId,
    required this.analysisState,
    required this.variationComments,
    required this.moveNags,
    required this.lastViewedPosition,
    this.notes,
    this.isFavorite = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String gameId;
  final String databaseId;
  final Map<String, dynamic> analysisState;
  final Map<String, String> variationComments;
  final Map<String, List<int>> moveNags;
  final int lastViewedPosition;
  final String? notes;
  final bool isFavorite;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class LocalChessDatabaseRepository {
  const LocalChessDatabaseRepository({
    required Future<Database> Function() database,
  }) : _database = database;

  final Future<Database> Function() _database;

  Future<void> persistSource(LocalChessSource source) async {
    for (final file in _playableFiles(source.root)) {
      await persistFileNode(file, sourceLabel: source.label);
    }
  }

  Future<void> persistFileNode(
    LocalChessFileNode file, {
    required String sourceLabel,
  }) async {
    if (!file.isPlayable || file.openingTreeIndex == null) return;
    final db = await _database();
    await db.transaction((txn) async {
      await _replaceFileNode(txn, file, sourceLabel: sourceLabel);
    });
  }

  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
  }) async {
    if (paths.isEmpty) return null;
    try {
      if (paths.length == 1) {
        return await _loadFreshSingleSource(
          paths.single,
          sourceLabel: sourceLabel,
        );
      }

      final children = <LocalChessNode>[];
      for (final path in paths) {
        final type = await FileSystemEntity.type(path, followLinks: false);
        switch (type) {
          case FileSystemEntityType.directory:
            final node = await _loadFreshDirectory(
              path,
              rootPath: path,
              force: true,
            );
            children.add(node);
          case FileSystemEntityType.file:
            final parent = p.dirname(path);
            final node = await _loadFreshFileNodeOrUnsupported(
              path,
              rootPath: parent,
            );
            if (node != null) children.add(node);
          case FileSystemEntityType.link:
          case FileSystemEntityType.notFound:
          case FileSystemEntityType.pipe:
          case FileSystemEntityType.unixDomainSock:
            throw const _LocalChessCacheMiss();
        }
      }
      if (children.isEmpty) return null;
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
    } on _LocalChessCacheMiss {
      return null;
    }
  }

  Future<LocalChessFileNode?> loadFreshFileNode(
    String path, {
    required String rootPath,
  }) async {
    try {
      return await _loadFreshFileNode(path, rootPath: rootPath);
    } on _LocalChessCacheMiss {
      return null;
    }
  }

  Future<void> saveLocalGameAnalysis(LocalChessGameAnalysis analysis) async {
    final db = await _database();
    await db.insert(localChessGameAnalysisTable, <String, Object?>{
      'game_id': analysis.gameId,
      'database_id': analysis.databaseId,
      'analysis_state': jsonEncode(analysis.analysisState),
      'variation_comments': jsonEncode(analysis.variationComments),
      'move_nags': jsonEncode(analysis.moveNags),
      'last_viewed_position': analysis.lastViewedPosition,
      'notes': analysis.notes,
      'is_favorite': analysis.isFavorite ? 1 : 0,
      'created_at_ms': analysis.createdAt.millisecondsSinceEpoch,
      'updated_at_ms': analysis.updatedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<LocalChessGameAnalysis?> localGameAnalysis(String gameId) async {
    final db = await _database();
    final rows = await db.query(
      localChessGameAnalysisTable,
      where: 'game_id = ?',
      whereArgs: <Object?>[gameId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return LocalChessGameAnalysis(
      gameId: row['game_id'] as String,
      databaseId: row['database_id'] as String,
      analysisState: _jsonMap(row['analysis_state']),
      variationComments: _stringMap(row['variation_comments']),
      moveNags: _nagsMap(row['move_nags']),
      lastViewedPosition: _readInt(row['last_viewed_position'], fallback: -1),
      notes: row['notes'] as String?,
      isFavorite: _readInt(row['is_favorite']) == 1,
      createdAt: _dateFromMillis(row['created_at_ms']) ?? DateTime.now(),
      updatedAt: _dateFromMillis(row['updated_at_ms']) ?? DateTime.now(),
    );
  }

  Future<LocalChessSource?> _loadFreshSingleSource(
    String path, {
    String? sourceLabel,
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      final root = await _loadFreshDirectory(path, rootPath: path, force: true);
      return LocalChessSource(
        id: _stableId(path),
        label: sourceLabel ?? localChessDatabaseDisplayNameForPath(path),
        paths: <String>[path],
        rootPath: path,
        scannedAt: DateTime.now(),
        root: root,
      );
    }
    if (type != FileSystemEntityType.file) return null;
    final parent = p.dirname(path);
    final node = await _loadFreshFileNode(path, rootPath: parent);
    final label = sourceLabel ?? localChessDatabaseDisplayNameForPath(path);
    final root = LocalChessFolderNode.fromChildren(
      name: label,
      path: 'local-file:${_stableId(path)}',
      relativePath: '',
      children: <LocalChessNode>[node],
    );
    return LocalChessSource(
      id: _stableId(path),
      label: label,
      paths: <String>[path],
      rootPath: parent,
      scannedAt: DateTime.now(),
      root: root,
    );
  }

  Future<LocalChessFolderNode> _loadFreshDirectory(
    String path, {
    required String rootPath,
    bool force = false,
  }) async {
    final children = <LocalChessNode>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          final child = await _loadFreshDirectory(
            entity.path,
            rootPath: rootPath,
            force: true,
          );
          if (child.children.isNotEmpty || child.scanError != null) {
            children.add(child);
          }
        case FileSystemEntityType.file:
          final node = await _loadFreshFileNodeOrUnsupported(
            entity.path,
            rootPath: rootPath,
          );
          if (node != null) children.add(node);
        case FileSystemEntityType.link:
        case FileSystemEntityType.notFound:
        case FileSystemEntityType.pipe:
        case FileSystemEntityType.unixDomainSock:
          break;
      }
    }
    _sortNodes(children);
    if (!force && children.isEmpty) throw const _LocalChessCacheMiss();
    return LocalChessFolderNode.fromChildren(
      name: localChessDatabaseDisplayNameForPath(path),
      path: path,
      relativePath: _relative(rootPath, path),
      children: children,
    );
  }

  Future<LocalChessNode?> _loadFreshFileNodeOrUnsupported(
    String path, {
    required String rootPath,
  }) async {
    if (!looksLikeLocalChessFile(path)) return null;
    if (!isSupportedLocalChessFile(path)) {
      final stat = await File(path).stat();
      return LocalChessFileNode(
        name: localChessDatabaseDisplayNameForPath(path),
        path: path,
        relativePath: _relative(rootPath, path),
        extension: _extensionForPath(path),
        status: LocalChessFileStatus.unsupported,
        games: const <LocalChessGame>[],
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
        message: localChessUnsupportedFormatMessage,
      );
    }
    return _loadFreshFileNode(path, rootPath: rootPath);
  }

  Future<LocalChessFileNode> _loadFreshFileNode(
    String path, {
    required String rootPath,
  }) async {
    final stat = await File(path).stat();
    final databaseId = _databaseId(path);
    final db = await _database();
    final databaseRows = await db.query(
      localChessDatabasesTable,
      where: 'id = ?',
      whereArgs: <Object?>[databaseId],
      limit: 1,
    );
    if (databaseRows.isEmpty) throw const _LocalChessCacheMiss();
    final databaseRow = databaseRows.single;
    final storedSize = _readInt(databaseRow['size_bytes']);
    final storedModified = _readNullableInt(databaseRow['modified_at_ms']);
    final modifiedMs = stat.modified.millisecondsSinceEpoch;
    if (storedSize != stat.size || storedModified != modifiedMs) {
      throw const _LocalChessCacheMiss();
    }

    final gameRows = await db.query(
      localChessGamesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
      orderBy: 'index_in_file ASC',
    );
    if (gameRows.isEmpty) throw const _LocalChessCacheMiss();
    final games = gameRows.map(_localGameFromRow).toList(growable: false);
    final index = await _loadOpeningTreeIndex(
      db,
      databaseId,
      generatedAtMs: databaseRow['updated_at_ms'],
    );

    return LocalChessFileNode(
      name: localChessDatabaseDisplayNameForPath(path),
      path: path,
      relativePath: _relative(rootPath, path),
      extension: _extensionForPath(path),
      status: LocalChessFileStatus.parsed,
      games: games,
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
      openingTreeIndex: index,
    );
  }

  Future<void> _replaceFileNode(
    Transaction txn,
    LocalChessFileNode file, {
    required String sourceLabel,
  }) async {
    final databaseId = _databaseId(file.path);
    final index = file.openingTreeIndex!;
    final now = DateTime.now().millisecondsSinceEpoch;

    final databaseRow = <String, Object?>{
      'id': databaseId,
      'path': file.path,
      'label': sourceLabel,
      'extension': file.extension,
      'size_bytes': file.sizeBytes,
      'modified_at_ms': file.modifiedAt?.millisecondsSinceEpoch,
      'file_count': 1,
      'game_count': file.games.length,
      'position_count': index.positionCount,
      'tree_snapshot': jsonEncode(_snapshotJson(index)),
      'imported_at_ms': now,
      'updated_at_ms': now,
    };
    await _upsertById(txn, localChessDatabasesTable, databaseRow);

    await _deleteDatabaseRows(txn, databaseId);

    final gameIds = <String>{for (final game in file.games) game.id};
    for (final game in file.games) {
      await _insertGame(txn, databaseId, game, index.gameRowsById[game.id]);
    }
    await _insertTree(txn, databaseId, index);
    await _insertPositionGameRefs(txn, databaseId, index, gameIds);
  }

  Future<void> _deleteDatabaseRows(Transaction txn, String databaseId) async {
    await txn.delete(
      localChessPositionGamesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
    );
    await txn.delete(
      localChessTreeMovesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
    );
    await txn.delete(
      localChessTreeNodesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
    );
    await txn.delete(
      localChessGamesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
    );
  }

  Future<void> _upsertById(
    Transaction txn,
    String table,
    Map<String, Object?> row,
  ) async {
    await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.update(
      table,
      row,
      where: 'id = ?',
      whereArgs: <Object?>[row['id']],
    );
  }

  Future<void> _insertGame(
    Transaction txn,
    String databaseId,
    LocalChessGame game,
    Map<String, dynamic>? treeRow,
  ) async {
    final metadata = game.game.metadata;
    final white = _cleanName(metadata['White'] ?? treeRow?['white']);
    final black = _cleanName(metadata['Black'] ?? treeRow?['black']);
    final event = _cleanName(metadata['Event'] ?? treeRow?['event']);
    final site = _cleanName(metadata['Site'] ?? treeRow?['site']);
    final whiteId = await _idForName(txn, localChessPlayersTable, white);
    final blackId = await _idForName(txn, localChessPlayersTable, black);
    final eventId = await _idForName(txn, localChessEventsTable, event);
    final siteId = await _idForName(txn, localChessSitesTable, site);
    final line = _lineFromRow(treeRow);

    final gameRow = <String, Object?>{
      'id': game.id,
      'database_id': databaseId,
      'event_id': eventId,
      'site_id': siteId,
      'date': treeRow?['date']?.toString() ?? metadata['Date']?.toString(),
      'utc_time': metadata['UTCTime']?.toString(),
      'round': metadata['Round']?.toString(),
      'white_id': whiteId,
      'white_elo': _rating(metadata['WhiteElo'] ?? treeRow?['whiteElo']),
      'black_id': blackId,
      'black_elo': _rating(metadata['BlackElo'] ?? treeRow?['blackElo']),
      'white_material': 39,
      'black_material': 39,
      'result':
          treeRow?['result']?.toString() ?? metadata['Result']?.toString(),
      'time_control':
          treeRow?['timeControl']?.toString() ??
          metadata['TimeControl']?.toString(),
      'eco': treeRow?['eco']?.toString() ?? metadata['ECO']?.toString(),
      'ply_count': line.length,
      'fen': game.game.startingFen,
      'moves': jsonEncode(line),
      'pawn_home': 65535,
      'raw_pgn': game.rawPgn,
      'headers_json': jsonEncode(metadata),
      'source_path': game.sourcePath,
      'source_relative_path': game.sourceRelativePath,
      'file_name': game.fileName,
      'index_in_file': game.indexInFile,
      'file_game_count': game.fileGameCount,
      'has_moves': game.hasMoves ? 1 : 0,
    };
    await _upsertById(txn, localChessGamesTable, gameRow);
  }

  Future<int> _idForName(Transaction txn, String table, String? rawName) async {
    final name = _normalizedName(rawName);
    if (name == null) return 0;
    await txn.insert(table, <String, Object?>{
      'name': name,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final rows = await txn.query(
      table,
      columns: const <String>['id'],
      where: 'name = ?',
      whereArgs: <Object?>[name],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError(
        'Failed to persist local chess metadata in $table: $name',
      );
    }
    return _readInt(rows.single['id']);
  }

  Future<void> _insertTree(
    Transaction txn,
    String databaseId,
    PlayerOpeningTreeIndex index,
  ) async {
    for (final node in index.nodesById.values) {
      await txn.insert(localChessTreeNodesTable, <String, Object?>{
        'database_id': databaseId,
        'node_id': node.id,
        'fen_key': node.fenKey,
        'ply': node.ply,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    final batch = txn.batch();
    for (final node in index.nodesById.values) {
      for (final move in node.moves) {
        batch.insert(localChessTreeMovesTable, <String, Object?>{
          'database_id': databaseId,
          'node_id': node.id,
          'uci': move.uci,
          'child_node_id': move.childNodeId,
          'white': move.white,
          'black': move.black,
          'draws': move.draws,
          'total': move.total,
          'last_played_ms': move.lastPlayed?.millisecondsSinceEpoch,
          'sample_game_id': move.sampleGameId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    await batch.commit(noResult: true);
  }

  Future<void> _insertPositionGameRefs(
    Transaction txn,
    String databaseId,
    PlayerOpeningTreeIndex index,
    Set<String> gameIds,
  ) async {
    final batch = txn.batch();
    for (final entry in index.gamesByFen.entries) {
      for (final ref in entry.value) {
        if (!gameIds.contains(ref.gameId)) {
          throw StateError(
            'Opening tree ref points to missing game: database=$databaseId fen=${entry.key} game=${ref.gameId}',
          );
        }
        batch.insert(
          localChessPositionGamesTable,
          <String, Object?>{
            'database_id': databaseId,
            'fen_key': entry.key,
            'fen': ref.fen,
            'game_id': ref.gameId,
            'ply': ref.ply,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
    await batch.commit(noResult: true);
  }

  Future<PlayerOpeningTreeIndex> _loadOpeningTreeIndex(
    Database db,
    String databaseId, {
    required Object? generatedAtMs,
  }) async {
    final nodeRows = await db.query(
      localChessTreeNodesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
      orderBy: 'node_id ASC',
    );
    final moveRows = await db.query(
      localChessTreeMovesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
      orderBy: 'node_id ASC, total DESC, uci ASC',
    );
    final movesByNode = <int, List<PlayerOpeningTreeMove>>{};
    for (final row in moveRows) {
      final nodeId = _readInt(row['node_id']);
      movesByNode
          .putIfAbsent(nodeId, () => <PlayerOpeningTreeMove>[])
          .add(
            PlayerOpeningTreeMove(
              uci: row['uci']?.toString() ?? '',
              childNodeId: _readInt(row['child_node_id']),
              white: _readInt(row['white']),
              black: _readInt(row['black']),
              draws: _readInt(row['draws']),
              total: _readInt(row['total']),
              lastPlayed: _dateFromMillis(row['last_played_ms']),
              sampleGameId: row['sample_game_id']?.toString(),
            ),
          );
    }

    if (nodeRows.isEmpty ||
        !nodeRows.any((row) => _readNullableInt(row['node_id']) == 0)) {
      throw const _LocalChessCacheMiss();
    }

    final nodesById = <int, PlayerOpeningTreeNode>{};
    final nodesByFenKey = <String, PlayerOpeningTreeNode>{};
    for (final row in nodeRows) {
      final node = PlayerOpeningTreeNode(
        id: _readInt(row['node_id']),
        fenKey: row['fen_key']?.toString() ?? '',
        ply: _readInt(row['ply']),
        moves: List<PlayerOpeningTreeMove>.unmodifiable(
          movesByNode[_readInt(row['node_id'])] ??
              const <PlayerOpeningTreeMove>[],
        ),
      );
      nodesById[node.id] = node;
      nodesByFenKey[node.fenKey] = node;
    }

    final gameRows = await db.query(
      localChessGamesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
      orderBy: 'index_in_file ASC',
    );
    final gameRowsById = <String, Map<String, dynamic>>{
      for (final row in gameRows) row['id'] as String: _treeGameRowFromDb(row),
    };

    final refRows = await db.query(
      localChessPositionGamesTable,
      where: 'database_id = ?',
      whereArgs: <Object?>[databaseId],
      orderBy: 'fen_key ASC, ply ASC',
    );
    final refsByFen = <String, List<PlayerOpeningTreeGameRef>>{};
    for (final row in refRows) {
      refsByFen
          .putIfAbsent(
            row['fen_key'] as String,
            () => <PlayerOpeningTreeGameRef>[],
          )
          .add(
            PlayerOpeningTreeGameRef(
              gameId: row['game_id'] as String,
              fen: row['fen'] as String,
              ply: _readInt(row['ply']),
            ),
          );
    }

    return PlayerOpeningTreeIndex(
      treeId: 'local:${_stableId(databaseId)}',
      playerId: databaseId,
      maxPly: _maxPly(nodesById.values),
      rootNodeId: 0,
      generatedAt: _dateFromMillis(generatedAtMs),
      nodesById: Map<int, PlayerOpeningTreeNode>.unmodifiable(nodesById),
      nodesByFenKey: Map<String, PlayerOpeningTreeNode>.unmodifiable(
        nodesByFenKey,
      ),
      gamesByFen: Map<String, List<PlayerOpeningTreeGameRef>>.unmodifiable({
        for (final entry in refsByFen.entries)
          entry.key: List<PlayerOpeningTreeGameRef>.unmodifiable(entry.value),
      }),
      gameRowsById: Map<String, Map<String, dynamic>>.unmodifiable(
        gameRowsById,
      ),
    );
  }

  LocalChessGame _localGameFromRow(Map<String, Object?> row) {
    final metadata = _jsonMap(row['headers_json']);
    final id = row['id'] as String;
    final startingFen = row['fen']?.toString().trim();
    return LocalChessGame(
      id: id,
      game: ChessGame(
        gameId: id,
        startingFen:
            startingFen == null || startingFen.isEmpty
                ? Chess.initial.fen
                : startingFen,
        metadata: metadata,
        mainline: const [],
      ),
      rawPgn: row['raw_pgn'] as String,
      sourcePath: row['source_path'] as String,
      sourceRelativePath: row['source_relative_path'] as String,
      fileName: row['file_name'] as String,
      indexInFile: _readInt(row['index_in_file']),
      fileGameCount: _readInt(row['file_game_count']),
      hasMoves: _readInt(row['has_moves']) == 1,
    );
  }

  Map<String, dynamic> _treeGameRowFromDb(Map<String, Object?> row) {
    final metadata = _jsonMap(row['headers_json']);
    String meta(String key) => metadata[key]?.toString().trim() ?? '';
    final line = _jsonList(row['moves'])
        .map((move) => move.toString().trim().toLowerCase())
        .where((move) => move.isNotEmpty)
        .toList(growable: false);
    return <String, dynamic>{
      'id': row['id'],
      'white': _fallback(meta('White'), 'White'),
      'black': _fallback(meta('Black'), 'Black'),
      'whiteElo': row['white_elo'],
      'blackElo': row['black_elo'],
      'result': row['result'] ?? '*',
      'date': row['date'] ?? meta('Date'),
      'timeControl': row['time_control'] ?? meta('TimeControl'),
      'eco': row['eco'] ?? meta('ECO'),
      'opening': meta('Opening'),
      'variation': meta('Variation'),
      'event': _fallback(meta('Event'), 'Local PGN'),
      'site': meta('Site'),
      'sourcePath': row['source_path'],
      'sourceRelativePath': row['source_relative_path'],
      'fileName': row['file_name'],
      'indexInFile': row['index_in_file'],
      'fileGameCount': row['file_game_count'],
      'startingFen': row['fen'],
      'line': line,
    }..removeWhere((_, value) => value == null || value == '');
  }

  List<LocalChessFileNode> _playableFiles(LocalChessNode node) {
    final out = <LocalChessFileNode>[];
    void visit(LocalChessNode node) {
      switch (node) {
        case LocalChessFileNode(:final isPlayable):
          if (isPlayable) out.add(node);
        case LocalChessFolderNode(:final children):
          for (final child in children) {
            visit(child);
          }
      }
    }

    visit(node);
    return out;
  }
}

final localChessDatabaseRepositoryProvider =
    Provider<LocalChessDatabaseRepository>(
      (ref) => LocalChessDatabaseRepository(
        database: () => ref.watch(appDatabaseProvider).database,
      ),
    );

class _LocalChessCacheMiss implements Exception {
  const _LocalChessCacheMiss();
}

String _databaseId(String path) {
  final normalized = p.normalize(path.trim());
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String _stableId(String value) => sha1.convert(utf8.encode(value)).toString();

String _relative(String rootPath, String path) {
  try {
    final relative = p.relative(path, from: rootPath);
    return relative == '.' ? '' : relative;
  } catch (_) {
    return path;
  }
}

void _sortNodes(List<LocalChessNode> nodes) {
  nodes.sort((a, b) {
    final af = a is LocalChessFolderNode;
    final bf = b is LocalChessFolderNode;
    if (af != bf) return af ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

String _extensionForPath(String path) {
  final lower = path.toLowerCase();
  for (final extension in localChessSupportedExtensions) {
    if (lower.endsWith(extension)) return extension;
  }
  return p.extension(path).toLowerCase();
}

String? _cleanName(Object? value) => _normalizedName(value?.toString());

String? _normalizedName(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == '?') return null;
  return trimmed;
}

int? _rating(Object? raw) {
  final value = int.tryParse(raw?.toString() ?? '');
  return value == null || value <= 0 ? null : value;
}

int _readInt(Object? raw, {int fallback = 0}) {
  return _readNullableInt(raw) ?? fallback;
}

int? _readNullableInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw.toString());
}

DateTime? _dateFromMillis(Object? raw) {
  final ms = _readNullableInt(raw);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

List<String> _lineFromRow(Map<String, dynamic>? row) {
  final raw = row?['line'];
  if (raw is! List) return const <String>[];
  return raw
      .map((move) => move.toString().trim().toLowerCase())
      .where((move) => move.isNotEmpty)
      .toList(growable: false);
}

Map<String, dynamic> _jsonMap(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is! String || raw.trim().isEmpty) return <String, dynamic>{};
  final decoded = jsonDecode(raw);
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return <String, dynamic>{};
}

List<dynamic> _jsonList(Object? raw) {
  if (raw is List) return raw;
  if (raw is! String || raw.trim().isEmpty) return const <dynamic>[];
  final decoded = jsonDecode(raw);
  return decoded is List ? decoded : const <dynamic>[];
}

Map<String, String> _stringMap(Object? raw) {
  final map = _jsonMap(raw);
  return map.map((key, value) => MapEntry(key, value.toString()));
}

Map<String, List<int>> _nagsMap(Object? raw) {
  final map = _jsonMap(raw);
  return map.map((key, value) {
    if (value is List) {
      return MapEntry(
        key,
        value.map((item) => _readInt(item)).toList(growable: false),
      );
    }
    return MapEntry(key, const <int>[]);
  });
}

String _fallback(String value, String fallback) {
  final trimmed = value.trim();
  return trimmed.isEmpty || trimmed == '?' ? fallback : trimmed;
}

int _maxPly(Iterable<PlayerOpeningTreeNode> nodes) {
  var out = 0;
  for (final node in nodes) {
    if (node.ply > out) out = node.ply;
  }
  return out;
}

Map<String, dynamic> _snapshotJson(PlayerOpeningTreeIndex index) {
  final fenKeys = index.nodesByFenKey.keys.toList(growable: false);
  final fenIndex = <String, int>{
    for (var i = 0; i < fenKeys.length; i++) fenKeys[i]: i,
  };
  return <String, dynamic>{
    'tid': index.treeId,
    'pid': index.playerId,
    'mp': index.maxPly,
    'r': index.rootNodeId,
    'g': index.generatedAt?.toIso8601String(),
    'fk': fenKeys,
    'n': [
      for (final node in index.nodesById.values)
        <String, dynamic>{
          'id': node.id,
          'f': fenIndex[node.fenKey] ?? -1,
          'p': node.ply,
          'm': [
            for (final move in node.moves)
              <String, dynamic>{
                'u': move.uci,
                'c': move.childNodeId,
                'w': move.white,
                'b': move.black,
                'd': move.draws,
                't': move.total,
                'lp': move.lastPlayed?.toIso8601String(),
                'sg': move.sampleGameId,
              }..removeWhere((_, value) => value == null),
          ],
        },
    ],
  }..removeWhere((_, value) => value == null);
}
