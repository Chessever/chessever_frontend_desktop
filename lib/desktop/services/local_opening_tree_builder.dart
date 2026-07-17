import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';

final RegExp _pgnHeaderRegex = RegExp(
  r'^\[\s*(\w+)\s+"((?:[^"\\]|\\.)*)"\s*\]',
  multiLine: true,
);
final RegExp _moveNumberPrefixRegex = RegExp(r'^\d+\.(?:\.\.)?');
final RegExp _moveNumberOnlyRegex = RegExp(r'^\d+\.(?:\.\.)?$');
final RegExp _annotationSuffixRegex = RegExp(r'[!?]+$');

const int localOpeningTreeDefaultMaxPly = 50;
const int localOpeningTreeLargeImportMaxPly = 50;

@immutable
class LocalOpeningTreeGameInput {
  LocalOpeningTreeGameInput({
    required this.id,
    this.rawPgn = '',
    List<String> uciLine = const <String>[],
    Map<String, String> metadata = const <String, String>{},
    this.startingFen,
    required this.sourcePath,
    required this.sourceRelativePath,
    required this.fileName,
    required this.indexInFile,
    required this.fileGameCount,
    this.sourceByteStart,
    this.sourceByteEnd,
  }) : uciLine = List<String>.unmodifiable(uciLine),
       metadata = Map<String, String>.unmodifiable(metadata) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (rawPgn.trim().isEmpty && uciLine.isEmpty) {
      throw ArgumentError(
        'LocalOpeningTreeGameInput requires rawPgn or uciLine',
      );
    }
    if (sourcePath.trim().isEmpty) {
      throw ArgumentError.value(sourcePath, 'sourcePath', 'must not be empty');
    }
    if (sourceRelativePath.trim().isEmpty) {
      throw ArgumentError.value(
        sourceRelativePath,
        'sourceRelativePath',
        'must not be empty',
      );
    }
    if (fileName.trim().isEmpty) {
      throw ArgumentError.value(fileName, 'fileName', 'must not be empty');
    }
    if (indexInFile < 0) {
      throw ArgumentError.value(indexInFile, 'indexInFile', 'must be >= 0');
    }
    if (fileGameCount <= 0) {
      throw ArgumentError.value(fileGameCount, 'fileGameCount', 'must be > 0');
    }
    if (indexInFile >= fileGameCount) {
      throw ArgumentError.value(
        indexInFile,
        'indexInFile',
        'must be less than fileGameCount',
      );
    }
  }

  final String id;
  final String rawPgn;
  final List<String> uciLine;
  final Map<String, String> metadata;
  final String? startingFen;
  final String sourcePath;
  final String sourceRelativePath;
  final String fileName;
  final int indexInFile;
  final int fileGameCount;
  final int? sourceByteStart;
  final int? sourceByteEnd;
}

@immutable
class LocalOpeningTreePositionEvent {
  const LocalOpeningTreePositionEvent({
    required this.fenKey,
    required this.ply,
    this.nextUci,
  });

  final String fenKey;
  final int ply;
  final String? nextUci;
}

List<LocalOpeningTreePositionEvent> localOpeningTreePositionEventsForGame(
  LocalOpeningTreeGameInput input, {
  required int maxPly,
  Map<String, String?>? transitionCache,
}) {
  final parsed = _parseGame(
    input,
    maxPly: maxPly,
    transitionByFenKeyAndUci: transitionCache ?? <String, String?>{},
  );
  if (parsed.moves.isEmpty) {
    throw LocalOpeningTreeGameException(input, 'No legal mainline moves');
  }

  final events = <LocalOpeningTreePositionEvent>[];
  var currentKey = parsed.startingKey.fenKey;
  for (var ply = 0; ply < parsed.moves.length; ply++) {
    final move = parsed.moves[ply];
    events.add(
      LocalOpeningTreePositionEvent(
        fenKey: currentKey,
        ply: ply,
        nextUci: move.uci,
      ),
    );
    currentKey = move.key.fenKey;
  }
  events.add(
    LocalOpeningTreePositionEvent(fenKey: currentKey, ply: parsed.moves.length),
  );
  return List<LocalOpeningTreePositionEvent>.unmodifiable(events);
}

@immutable
class LocalOpeningTreeBuildResult {
  LocalOpeningTreeBuildResult({
    required this.index,
    required List<LocalOpeningTreeSkippedGame> skippedGames,
  }) : skippedGames = List<LocalOpeningTreeSkippedGame>.unmodifiable(
         skippedGames,
       );

  final PlayerOpeningTreeIndex index;
  final List<LocalOpeningTreeSkippedGame> skippedGames;
}

class LocalOpeningTreeIncrementalBuilder {
  LocalOpeningTreeIncrementalBuilder({
    required String treeId,
    required String databaseId,
    int maxPly = 0,
    bool includePositionGameRefs = true,
    bool includeGameRows = true,
    void Function(LocalOpeningTreePositionGameRef ref)? onPositionGameRef,
  }) : _accumulator = _LocalOpeningTreeAccumulator(
         treeId: treeId,
         databaseId: databaseId,
         maxPly: maxPly,
         includePositionGameRefs: includePositionGameRefs,
         includeGameRows: includeGameRows,
         onPositionGameRef: onPositionGameRef,
       ) {
    _validateBuildHeaderInputs(
      treeId: treeId,
      databaseId: databaseId,
      maxPly: maxPly,
    );
    _accumulator.ensureRoot();
  }

  final _LocalOpeningTreeAccumulator _accumulator;

  void addGames(Iterable<LocalOpeningTreeGameInput> games) {
    _accumulator.addGames(games);
  }

  LocalOpeningTreeBuildResult finish() => _accumulator.finish();

  /// Finalizes while releasing accumulator values as their immutable nodes are
  /// produced. Large cached-tree rebuilds use this after spilling position
  /// references to SQLite so peak memory does not contain two full tree graphs.
  LocalOpeningTreeBuildResult finishAndRelease() =>
      _accumulator.finish(releaseAccumulator: true);
}

@immutable
class LocalOpeningTreePositionGameRef {
  const LocalOpeningTreePositionGameRef({
    required this.fenKey,
    required this.gameId,
    required this.ply,
    required this.nextUci,
  });

  final String fenKey;
  final String gameId;
  final int ply;
  final String? nextUci;
}

@immutable
class LocalOpeningTreeSkippedGame {
  const LocalOpeningTreeSkippedGame({
    required this.id,
    required this.indexInFile,
    required this.message,
  });

  final String id;
  final int indexInFile;
  final String message;
}

class LocalOpeningTreeBuildException implements Exception {
  const LocalOpeningTreeBuildException(this.sourcePath, this.cause);

  final String sourcePath;
  final Object cause;

  @override
  String toString() => 'Could not build opening tree for $sourcePath: $cause';
}

class LocalOpeningTreeGameException implements Exception {
  const LocalOpeningTreeGameException(this.input, this.message);

  final LocalOpeningTreeGameInput input;
  final String message;

  @override
  String toString() =>
      'Could not index PGN entry ${input.indexInFile + 1}: $message';
}

PlayerOpeningTreeIndex buildLocalOpeningTreeIndex({
  required String treeId,
  required String databaseId,
  required List<LocalOpeningTreeGameInput> games,
  int maxPly = 0,
  bool includePositionGameRefs = true,
  bool includeGameRows = true,
}) {
  return buildLocalOpeningTreeIndexWithDiagnostics(
    treeId: treeId,
    databaseId: databaseId,
    games: games,
    maxPly: maxPly,
    includePositionGameRefs: includePositionGameRefs,
    includeGameRows: includeGameRows,
  ).index;
}

LocalOpeningTreeBuildResult buildLocalOpeningTreeIndexWithDiagnostics({
  required String treeId,
  required String databaseId,
  required List<LocalOpeningTreeGameInput> games,
  int maxPly = 0,
  bool includePositionGameRefs = true,
  bool includeGameRows = true,
}) {
  _validateBuildInputs(
    treeId: treeId,
    databaseId: databaseId,
    games: games,
    maxPly: maxPly,
  );
  return _LocalOpeningTreeAccumulator(
    treeId: treeId,
    databaseId: databaseId,
    maxPly: maxPly,
    includePositionGameRefs: includePositionGameRefs,
    includeGameRows: includeGameRows,
  ).build(List<LocalOpeningTreeGameInput>.unmodifiable(games));
}

LocalOpeningTreeBuildResult buildLocalOpeningTreeIndexWithDiagnosticsIterable({
  required String treeId,
  required String databaseId,
  required Iterable<LocalOpeningTreeGameInput> games,
  int maxPly = 0,
  bool includePositionGameRefs = true,
  bool includeGameRows = true,
}) {
  _validateBuildHeaderInputs(
    treeId: treeId,
    databaseId: databaseId,
    maxPly: maxPly,
  );
  return _LocalOpeningTreeAccumulator(
    treeId: treeId,
    databaseId: databaseId,
    maxPly: maxPly,
    includePositionGameRefs: includePositionGameRefs,
    includeGameRows: includeGameRows,
  ).build(games);
}

Future<LocalOpeningTreeBuildResult>
buildLocalOpeningTreeIndexWithDiagnosticsAsync({
  required String treeId,
  required String databaseId,
  required List<LocalOpeningTreeGameInput> games,
  int maxPly = 0,
  bool includePositionGameRefs = true,
  bool includeGameRows = true,
  int? workerCount,
  int minGamesPerWorker = 2000,
  void Function(int completedShards, int totalShards)? onShardComplete,
}) async {
  _validateBuildInputs(
    treeId: treeId,
    databaseId: databaseId,
    games: games,
    maxPly: maxPly,
  );
  if (games.isEmpty) {
    return buildLocalOpeningTreeIndexWithDiagnostics(
      treeId: treeId,
      databaseId: databaseId,
      games: games,
      maxPly: maxPly,
      includePositionGameRefs: includePositionGameRefs,
      includeGameRows: includeGameRows,
    );
  }

  final resolvedWorkers = _treeWorkerCount(
    gameCount: games.length,
    requestedWorkerCount: workerCount,
    minGamesPerWorker: minGamesPerWorker,
  );
  if (resolvedWorkers <= 1) {
    return buildLocalOpeningTreeIndexWithDiagnostics(
      treeId: treeId,
      databaseId: databaseId,
      games: games,
      maxPly: maxPly,
      includePositionGameRefs: includePositionGameRefs,
      includeGameRows: includeGameRows,
    );
  }

  final chunks = _chunkGames(games, resolvedWorkers);
  var completedShards = 0;
  final totalShards = chunks.length;
  final shardResults = await Future.wait(
    chunks.map((chunk) async {
      final result = await Isolate.run(
        () => buildLocalOpeningTreeIndexWithDiagnostics(
          treeId: treeId,
          databaseId: databaseId,
          games: chunk,
          maxPly: maxPly,
          includePositionGameRefs: includePositionGameRefs,
          includeGameRows: includeGameRows,
        ),
      );
      completedShards++;
      onShardComplete?.call(completedShards, totalShards);
      return result;
    }),
  );

  return _mergeBuildResults(
    treeId: treeId,
    databaseId: databaseId,
    maxPly: maxPly,
    results: shardResults,
  );
}

int _treeWorkerCount({
  required int gameCount,
  required int? requestedWorkerCount,
  required int minGamesPerWorker,
}) {
  if (gameCount <= 1) return 1;
  if (requestedWorkerCount != null) {
    return requestedWorkerCount.clamp(1, gameCount).toInt();
  }
  final processors = Platform.numberOfProcessors;
  final byCpu = math.max(1, math.min(processors - 1, 8));
  final byWork =
      minGamesPerWorker <= 1
          ? gameCount
          : math.max(1, gameCount ~/ minGamesPerWorker);
  return math.max(1, math.min(math.min(byCpu, byWork), gameCount));
}

List<List<LocalOpeningTreeGameInput>> _chunkGames(
  List<LocalOpeningTreeGameInput> games,
  int workerCount,
) {
  final chunkSize = (games.length / workerCount).ceil();
  final chunks = <List<LocalOpeningTreeGameInput>>[];
  for (var start = 0; start < games.length; start += chunkSize) {
    final end = math.min(start + chunkSize, games.length);
    chunks.add(
      List<LocalOpeningTreeGameInput>.unmodifiable(games.sublist(start, end)),
    );
  }
  return chunks;
}

LocalOpeningTreeBuildResult _mergeBuildResults({
  required String treeId,
  required String databaseId,
  required int maxPly,
  required List<LocalOpeningTreeBuildResult> results,
}) {
  if (results.length == 1) return results.single;
  final accumulator = _MergedOpeningTreeAccumulator(
    treeId: treeId,
    databaseId: databaseId,
    maxPly: maxPly,
  );
  final skipped = <LocalOpeningTreeSkippedGame>[];
  for (final result in results) {
    accumulator.merge(result.index);
    skipped.addAll(result.skippedGames);
  }
  return LocalOpeningTreeBuildResult(
    index: accumulator.toIndex(),
    skippedGames:
        skipped..sort((a, b) => a.indexInFile.compareTo(b.indexInFile)),
  );
}

void _validateBuildInputs({
  required String treeId,
  required String databaseId,
  required List<LocalOpeningTreeGameInput> games,
  required int maxPly,
}) {
  _validateBuildHeaderInputs(
    treeId: treeId,
    databaseId: databaseId,
    maxPly: maxPly,
  );
  final ids = <String>{};
  for (final game in games) {
    if (!ids.add(game.id)) {
      throw ArgumentError.value(game.id, 'games', 'duplicate game id');
    }
  }
}

void _validateBuildHeaderInputs({
  required String treeId,
  required String databaseId,
  required int maxPly,
}) {
  if (treeId.trim().isEmpty) {
    throw ArgumentError.value(treeId, 'treeId', 'must not be empty');
  }
  if (databaseId.trim().isEmpty) {
    throw ArgumentError.value(databaseId, 'databaseId', 'must not be empty');
  }
  if (maxPly < 0) {
    throw ArgumentError.value(maxPly, 'maxPly', 'must be >= 0');
  }
}

class _LocalOpeningTreeAccumulator {
  _LocalOpeningTreeAccumulator({
    required this.treeId,
    required this.databaseId,
    required this.maxPly,
    required this.includePositionGameRefs,
    required bool includeGameRows,
    this.onPositionGameRef,
  }) : includeGameRows = includeGameRows || includePositionGameRefs;

  final String treeId;
  final String databaseId;
  final int maxPly;
  final bool includePositionGameRefs;
  final bool includeGameRows;
  final void Function(LocalOpeningTreePositionGameRef ref)? onPositionGameRef;
  final Map<_PositionKey, _NodeAccumulator> _nodesByKey =
      <_PositionKey, _NodeAccumulator>{};
  final Map<String, Map<String, PlayerOpeningTreeGameRef>> _gamesByFen =
      <String, Map<String, PlayerOpeningTreeGameRef>>{};
  final Map<String, Map<String, dynamic>> _gameRowsById =
      <String, Map<String, dynamic>>{};
  final Map<String, String?> _transitionByFenKeyAndUci = <String, String?>{};
  final List<LocalOpeningTreeSkippedGame> _skippedGames =
      <LocalOpeningTreeSkippedGame>[];
  int _nextNodeId = 0;
  int _indexedGameCount = 0;

  LocalOpeningTreeBuildResult build(Iterable<LocalOpeningTreeGameInput> games) {
    ensureRoot();
    addGames(games);
    return finish();
  }

  void ensureRoot() {
    _rootNode();
  }

  void addGames(Iterable<LocalOpeningTreeGameInput> games) {
    for (final input in games) {
      try {
        _addGame(input);
      } on LocalOpeningTreeGameException catch (e) {
        _skippedGames.add(
          LocalOpeningTreeSkippedGame(
            id: e.input.id,
            indexInFile: e.input.indexInFile,
            message: e.message,
          ),
        );
      }
    }
  }

  LocalOpeningTreeBuildResult finish({bool releaseAccumulator = false}) {
    final root = _rootNode();
    final resolvedMaxPly = maxPly <= 0 ? _maxSeenPly : maxPly;
    _transitionByFenKeyAndUci.clear();
    final nodesById = <int, PlayerOpeningTreeNode>{};
    final frozenNodesByFen = <String, PlayerOpeningTreeNode>{};
    if (releaseAccumulator) {
      final keys = _nodesByKey.keys.toList(growable: false);
      for (final key in keys) {
        final node = _nodesByKey.remove(key);
        if (node == null) continue;
        final frozen = node.toNode();
        nodesById[frozen.id] = frozen;
        frozenNodesByFen[frozen.fenKey] = frozen;
      }
    } else {
      for (final node in _nodesByKey.values) {
        final frozen = node.toNode();
        nodesById[frozen.id] = frozen;
        frozenNodesByFen[frozen.fenKey] = frozen;
      }
    }

    final frozenGamesByFen = <String, List<PlayerOpeningTreeGameRef>>{};
    for (final entry in _gamesByFen.entries) {
      frozenGamesByFen[entry.key] = List<PlayerOpeningTreeGameRef>.unmodifiable(
        entry.value.values,
      );
    }

    final index = PlayerOpeningTreeIndex(
      treeId: treeId,
      playerId: databaseId,
      maxPly: resolvedMaxPly,
      rootNodeId: root.id,
      generatedAt: DateTime.now(),
      nodesById:
          releaseAccumulator
              ? UnmodifiableMapView<int, PlayerOpeningTreeNode>(nodesById)
              : Map<int, PlayerOpeningTreeNode>.unmodifiable(nodesById),
      nodesByFenKey:
          releaseAccumulator
              ? UnmodifiableMapView<String, PlayerOpeningTreeNode>(
                frozenNodesByFen,
              )
              : Map<String, PlayerOpeningTreeNode>.unmodifiable(
                frozenNodesByFen,
              ),
      gamesByFen: Map<String, List<PlayerOpeningTreeGameRef>>.unmodifiable(
        frozenGamesByFen,
      ),
      gameRowsById: Map<String, Map<String, dynamic>>.unmodifiable(
        _gameRowsById,
      ),
      persistedGameCount: includeGameRows ? null : _indexedGameCount,
    );

    return LocalOpeningTreeBuildResult(
      index: index,
      skippedGames: List<LocalOpeningTreeSkippedGame>.unmodifiable(
        _skippedGames,
      ),
    );
  }

  _NodeAccumulator _rootNode() =>
      _nodeForKey(_PositionKey.fromPosition(Chess.initial), 0);

  int get _maxSeenPly {
    var out = 0;
    for (final node in _nodesByKey.values) {
      if (node.ply > out) out = node.ply;
    }
    return out;
  }

  void _addGame(LocalOpeningTreeGameInput input) {
    final parsed = _parseGame(
      input,
      maxPly: maxPly,
      transitionByFenKeyAndUci: _transitionByFenKeyAndUci,
    );
    if (parsed.moves.isEmpty) {
      throw LocalOpeningTreeGameException(input, 'No legal mainline moves');
    }

    final result = _resultBucket(parsed.metadata['Result']);
    final date = _dateFromMetadata(parsed.metadata);
    final line = <String>[for (final move in parsed.moves) move.uci];
    _indexedGameCount++;

    if (includeGameRows) {
      _gameRowsById[input.id] = _rowForGame(
        input,
        parsed.metadata,
        line,
        date,
        startingFen: parsed.startingFen,
      );
    }

    var previousKey = parsed.startingKey;
    final pliesToIndex =
        maxPly <= 0
            ? parsed.moves.length
            : parsed.moves.length.clamp(0, maxPly).toInt();

    for (var ply = 0; ply < pliesToIndex; ply++) {
      final move = parsed.moves[ply];

      final parent = _nodeForKey(previousKey, ply);
      final child = _nodeForKey(move.key, ply + 1);
      parent.recordMove(
        uci: move.uci,
        childNodeId: child.id,
        result: result,
        date: date,
        gameId: input.id,
      );
      _recordGameRef(
        key: previousKey,
        gameId: input.id,
        ply: ply,
        nextUci: line[ply],
      );
      previousKey = move.key;
    }

    _recordGameRef(
      key: previousKey,
      gameId: input.id,
      ply: pliesToIndex,
      nextUci: null,
    );
  }

  _NodeAccumulator _nodeForKey(_PositionKey key, int ply) {
    final existing = _nodesByKey[key];
    if (existing != null) {
      if (ply < existing.ply) existing.ply = ply;
      return existing;
    }
    final node = _NodeAccumulator(
      id: _nextNodeId++,
      fenKey: key.fenKey,
      ply: ply,
    );
    _nodesByKey[key] = node;
    return node;
  }

  void _recordGameRef({
    required _PositionKey key,
    required String gameId,
    required int ply,
    String? nextUci,
  }) {
    onPositionGameRef?.call(
      LocalOpeningTreePositionGameRef(
        fenKey: key.fenKey,
        gameId: gameId,
        ply: ply,
        nextUci: nextUci,
      ),
    );
    if (!includePositionGameRefs) return;
    final fenKey = key.fenKey;
    _gamesByFen.putIfAbsent(
      fenKey,
      () => <String, PlayerOpeningTreeGameRef>{},
    )[gameId] = PlayerOpeningTreeGameRef(gameId: gameId, fen: fenKey, ply: ply);
  }
}

class _MergedOpeningTreeAccumulator {
  _MergedOpeningTreeAccumulator({
    required this.treeId,
    required this.databaseId,
    required this.maxPly,
  });

  final String treeId;
  final String databaseId;
  final int maxPly;
  final Map<String, _NodeAccumulator> _nodesByFenKey =
      <String, _NodeAccumulator>{};
  final Map<String, Map<String, PlayerOpeningTreeGameRef>> _gamesByFen =
      <String, Map<String, PlayerOpeningTreeGameRef>>{};
  final Map<String, Map<String, dynamic>> _gameRowsById =
      <String, Map<String, dynamic>>{};
  int _nextNodeId = 0;
  int _indexedGameCount = 0;

  void merge(PlayerOpeningTreeIndex index) {
    for (final node in index.nodesById.values) {
      final parent = _nodeForFenKey(node.fenKey, node.ply);
      for (final move in node.moves) {
        final childNode = index.nodesById[move.childNodeId];
        if (childNode == null) continue;
        final child = _nodeForFenKey(childNode.fenKey, childNode.ply);
        parent.mergeMove(move, childNodeId: child.id);
      }
    }

    for (final entry in index.gamesByFen.entries) {
      final refsByGame = _gamesByFen.putIfAbsent(
        entry.key,
        () => <String, PlayerOpeningTreeGameRef>{},
      );
      for (final ref in entry.value) {
        refsByGame[ref.gameId] = ref;
      }
    }

    _gameRowsById.addAll(index.gameRowsById);
    _indexedGameCount += index.downloadedGameCount;
  }

  PlayerOpeningTreeIndex toIndex() {
    final nodesById = <int, PlayerOpeningTreeNode>{};
    final frozenNodesByFen = <String, PlayerOpeningTreeNode>{};
    for (final node in _nodesByFenKey.values) {
      final frozen = node.toNode();
      nodesById[frozen.id] = frozen;
      frozenNodesByFen[frozen.fenKey] = frozen;
    }

    final frozenGamesByFen = <String, List<PlayerOpeningTreeGameRef>>{};
    for (final entry in _gamesByFen.entries) {
      frozenGamesByFen[entry.key] = List<PlayerOpeningTreeGameRef>.unmodifiable(
        entry.value.values,
      );
    }

    return PlayerOpeningTreeIndex(
      treeId: treeId,
      playerId: databaseId,
      maxPly: maxPly <= 0 ? _maxSeenPly : maxPly,
      rootNodeId: _nodeForFenKey(Chess.initial.fen, 0).id,
      generatedAt: DateTime.now(),
      nodesById: Map<int, PlayerOpeningTreeNode>.unmodifiable(nodesById),
      nodesByFenKey: Map<String, PlayerOpeningTreeNode>.unmodifiable(
        frozenNodesByFen,
      ),
      gamesByFen: Map<String, List<PlayerOpeningTreeGameRef>>.unmodifiable(
        frozenGamesByFen,
      ),
      gameRowsById: Map<String, Map<String, dynamic>>.unmodifiable(
        _gameRowsById,
      ),
      persistedGameCount: _gameRowsById.isEmpty ? _indexedGameCount : null,
    );
  }

  int get _maxSeenPly {
    var out = 0;
    for (final node in _nodesByFenKey.values) {
      if (node.ply > out) out = node.ply;
    }
    return out;
  }

  _NodeAccumulator _nodeForFenKey(String fenKey, int ply) {
    final key = _fenKey(fenKey);
    final existing = _nodesByFenKey[key];
    if (existing != null) {
      if (ply < existing.ply) existing.ply = ply;
      return existing;
    }
    final node = _NodeAccumulator(id: _nextNodeId++, fenKey: key, ply: ply);
    _nodesByFenKey[key] = node;
    return node;
  }
}

_ParsedLocalGame _parseGame(
  LocalOpeningTreeGameInput input, {
  required int maxPly,
  required Map<String, String?> transitionByFenKeyAndUci,
}) {
  if (input.uciLine.isNotEmpty) {
    return _parseCachedUciGame(
      input,
      maxPly: maxPly,
      transitionByFenKeyAndUci: transitionByFenKeyAndUci,
    );
  }

  final parsedHeaders = _parseHeaders(input.rawPgn);

  final Position start;
  try {
    start = PgnGame.startingPosition(parsedHeaders.headers);
  } on PositionSetupException catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid starting position: $e');
  } on FormatException catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid starting FEN: $e');
  } on ArgumentError catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid starting FEN: $e');
  }

  var position = start;
  final moves = <_ParsedLocalMove>[];

  for (final san in _mainlineSanTokens(input.rawPgn, parsedHeaders.headerEnd)) {
    final move = position.parseSan(san);
    if (move == null) {
      throw LocalOpeningTreeGameException(
        input,
        'Could not parse move "$san" at ply ${moves.length + 1}',
      );
    }
    final uci = move.uci.trim().toLowerCase();
    if (uci.isEmpty) {
      throw LocalOpeningTreeGameException(
        input,
        'Parsed an empty UCI at ply ${moves.length + 1}',
      );
    }
    final Position nextPosition;
    try {
      nextPosition = position.playUnchecked(move);
    } on Object catch (e) {
      throw LocalOpeningTreeGameException(
        input,
        'Could not play move "$san" at ply ${moves.length + 1}: $e',
      );
    }
    moves.add(
      _ParsedLocalMove(uci: uci, key: _PositionKey.fromPosition(nextPosition)),
    );
    position = nextPosition;
    if (maxPly > 0 && moves.length >= maxPly) break;
  }

  return _ParsedLocalGame(
    metadata: Map<String, String>.unmodifiable(parsedHeaders.headers),
    startingFen: start.fen,
    startingKey: _PositionKey.fromPosition(start),
    moves: moves,
  );
}

_ParsedLocalGame _parseCachedUciGame(
  LocalOpeningTreeGameInput input, {
  required int maxPly,
  required Map<String, String?> transitionByFenKeyAndUci,
}) {
  final rawStartingFen = input.startingFen?.trim() ?? '';
  final startingFen =
      rawStartingFen.isEmpty ? Chess.initial.fen : rawStartingFen;
  final initialFenKey = playerOpeningTreeFenKey(Chess.initial.fen);
  final normalizedStartingFen = playerOpeningTreeFenKey(startingFen);
  var parentFenKey =
      normalizedStartingFen.split(' ').length >= 4
          ? normalizedStartingFen
          : initialFenKey;
  final startingKey = _PositionKey(parentFenKey);
  final moves = <_ParsedLocalMove>[];
  final pliesToParse =
      maxPly <= 0
          ? input.uciLine.length
          : math.min(input.uciLine.length, maxPly);

  for (var ply = 0; ply < pliesToParse; ply++) {
    final uci = input.uciLine[ply].trim().toLowerCase();
    if (uci.isEmpty) {
      throw LocalOpeningTreeGameException(
        input,
        'Cached an empty UCI at ply ${ply + 1}',
      );
    }
    final transitionKey = '$parentFenKey|$uci';
    String? childFenKey;
    if (transitionByFenKeyAndUci.containsKey(transitionKey)) {
      childFenKey = transitionByFenKeyAndUci[transitionKey];
    } else {
      childFenKey =
          _applyUciToFenKey(parentFenKey, uci) ??
          _applyUciWithDartchess(parentFenKey, uci);
      transitionByFenKeyAndUci[transitionKey] = childFenKey;
    }
    if (childFenKey == null) {
      throw LocalOpeningTreeGameException(
        input,
        'Could not apply cached move "$uci" at ply ${ply + 1}',
      );
    }
    moves.add(_ParsedLocalMove(uci: uci, key: _PositionKey(childFenKey)));
    parentFenKey = childFenKey;
  }

  return _ParsedLocalGame(
    metadata: input.metadata,
    startingFen: startingFen,
    startingKey: startingKey,
    moves: moves,
  );
}

String? _applyUciWithDartchess(String parentFenKey, String uci) {
  try {
    final position = Chess.fromSetup(
      Setup.parseFen('$parentFenKey 0 1'),
      ignoreImpossibleCheck: true,
    );
    final move = position.normalizeMove(NormalMove.fromUci(uci));
    return playerOpeningTreeFenKey(position.playUnchecked(move).fen);
  } on Object {
    return null;
  }
}

String? _applyUciToFenKey(String parentFenKey, String uci) {
  final fields = parentFenKey.trim().split(RegExp(r'\s+'));
  if (fields.length < 2 || uci.length < 4) return null;
  final placement = fields[0];
  final turn = fields[1];
  var castling = fields.length > 2 ? fields[2] : '-';
  final enPassant = fields.length > 3 ? fields[3] : '-';
  final from = uci.substring(0, 2);
  final to = uci.substring(2, 4);
  final promotion = uci.length > 4 ? uci[4] : null;
  final fromIndex = _squareToIndex(from);
  final toIndex = _squareToIndex(to);
  if (fromIndex == null || toIndex == null) return null;

  final board = _expandPlacement(placement);
  if (board == null) return null;
  final piece = board[fromIndex];
  if (piece.isEmpty) return null;
  final isWhite = _pieceIsWhite(piece);
  var moveTo = to;
  var moveToIndex = toIndex;
  String? castlingRookFrom;
  String? castlingRookTo;
  String? castlingRook;
  if (piece == 'K' && from == 'e1' && (to == 'g1' || to == 'h1')) {
    moveTo = 'g1';
    moveToIndex = _squareToIndex(moveTo)!;
    castlingRookFrom = 'h1';
    castlingRookTo = 'f1';
    castlingRook = 'R';
  } else if (piece == 'K' && from == 'e1' && (to == 'c1' || to == 'a1')) {
    moveTo = 'c1';
    moveToIndex = _squareToIndex(moveTo)!;
    castlingRookFrom = 'a1';
    castlingRookTo = 'd1';
    castlingRook = 'R';
  } else if (piece == 'k' && from == 'e8' && (to == 'g8' || to == 'h8')) {
    moveTo = 'g8';
    moveToIndex = _squareToIndex(moveTo)!;
    castlingRookFrom = 'h8';
    castlingRookTo = 'f8';
    castlingRook = 'r';
  } else if (piece == 'k' && from == 'e8' && (to == 'c8' || to == 'a8')) {
    moveTo = 'c8';
    moveToIndex = _squareToIndex(moveTo)!;
    castlingRookFrom = 'a8';
    castlingRookTo = 'd8';
    castlingRook = 'r';
  }
  var capturedPiece = castlingRookFrom == null ? board[moveToIndex] : '';
  board[fromIndex] = '';

  if (piece.toLowerCase() == 'p' &&
      moveTo == enPassant &&
      capturedPiece.isEmpty &&
      from[0] != moveTo[0]) {
    final capturedPawnIndex = isWhite ? moveToIndex + 8 : moveToIndex - 8;
    if (capturedPawnIndex < 0 || capturedPawnIndex >= 64) return null;
    capturedPiece = board[capturedPawnIndex];
    board[capturedPawnIndex] = '';
  }

  if (castlingRookFrom != null) {
    board[_squareToIndex(castlingRookFrom)!] = '';
    board[_squareToIndex(castlingRookTo!)!] = castlingRook!;
  }

  board[moveToIndex] =
      piece.toLowerCase() == 'p' && promotion != null
          ? (isWhite ? promotion.toUpperCase() : promotion.toLowerCase())
          : piece;
  castling = _updateCastlingRights(
    castling,
    piece: piece,
    from: from,
    to: moveTo,
    capturedPiece: capturedPiece,
  );

  var nextEnPassant = '-';
  if (piece.toLowerCase() == 'p' && (moveToIndex - fromIndex).abs() == 16) {
    final targetIndex = (fromIndex + moveToIndex) ~/ 2;
    if (_hasLegalEnPassantCapture(
      board,
      targetIndex: targetIndex,
      movedPawnIndex: moveToIndex,
      movingWhite: isWhite,
    )) {
      nextEnPassant = _indexToSquare(targetIndex);
    }
  }

  final nextTurn = turn == 'w' ? 'b' : 'w';
  return '${_compressPlacement(board)} $nextTurn $castling $nextEnPassant';
}

int? _squareToIndex(String square) {
  if (square.length != 2) return null;
  final file = square.codeUnitAt(0) - 0x61;
  final rank = square.codeUnitAt(1) - 0x30;
  if (file < 0 || file > 7 || rank < 1 || rank > 8) return null;
  return (8 - rank) * 8 + file;
}

String _indexToSquare(int index) {
  final file = String.fromCharCode(0x61 + (index % 8));
  final rank = 8 - (index ~/ 8);
  return '$file$rank';
}

List<String>? _expandPlacement(String placement) {
  final board = <String>[];
  for (final codePoint in placement.runes) {
    final char = String.fromCharCode(codePoint);
    if (char == '/') continue;
    final empty = int.tryParse(char);
    if (empty != null && empty > 0) {
      board.addAll(List<String>.filled(empty, ''));
    } else {
      board.add(char);
    }
  }
  return board.length == 64 ? board : null;
}

String _compressPlacement(List<String> board) {
  final ranks = <String>[];
  for (var rank = 0; rank < 8; rank++) {
    final text = StringBuffer();
    var empty = 0;
    for (var file = 0; file < 8; file++) {
      final piece = board[(rank * 8) + file];
      if (piece.isEmpty) {
        empty++;
      } else {
        if (empty > 0) text.write(empty);
        empty = 0;
        text.write(piece);
      }
    }
    if (empty > 0) text.write(empty);
    ranks.add(text.toString());
  }
  return ranks.join('/');
}

bool _pieceIsWhite(String piece) => piece == piece.toUpperCase();

int? _boardIndex(int row, int file) {
  if (row < 0 || row > 7 || file < 0 || file > 7) return null;
  return (row * 8) + file;
}

int _findKingIndex(List<String> board, {required bool white}) =>
    board.indexOf(white ? 'K' : 'k');

bool _isSquareAttacked(
  List<String> board,
  int targetIndex, {
  required bool byWhite,
}) {
  final targetRow = targetIndex ~/ 8;
  final targetFile = targetIndex % 8;
  final pawn = byWhite ? 'P' : 'p';
  final knight = byWhite ? 'N' : 'n';
  final bishop = byWhite ? 'B' : 'b';
  final rook = byWhite ? 'R' : 'r';
  final queen = byWhite ? 'Q' : 'q';
  final king = byWhite ? 'K' : 'k';

  final pawnRow = byWhite ? targetRow + 1 : targetRow - 1;
  for (final fileOffset in const <int>[-1, 1]) {
    final index = _boardIndex(pawnRow, targetFile + fileOffset);
    if (index != null && board[index] == pawn) return true;
  }

  for (final offset in const <(int, int)>[
    (-2, -1),
    (-2, 1),
    (-1, -2),
    (-1, 2),
    (1, -2),
    (1, 2),
    (2, -1),
    (2, 1),
  ]) {
    final index = _boardIndex(targetRow + offset.$1, targetFile + offset.$2);
    if (index != null && board[index] == knight) return true;
  }

  for (final offset in const <(int, int)>[
    (-1, -1),
    (-1, 0),
    (-1, 1),
    (0, -1),
    (0, 1),
    (1, -1),
    (1, 0),
    (1, 1),
  ]) {
    final index = _boardIndex(targetRow + offset.$1, targetFile + offset.$2);
    if (index != null && board[index] == king) return true;
  }

  final rayAttacks = <(int, int, Set<String>)>[
    (-1, 0, <String>{rook, queen}),
    (1, 0, <String>{rook, queen}),
    (0, -1, <String>{rook, queen}),
    (0, 1, <String>{rook, queen}),
    (-1, -1, <String>{bishop, queen}),
    (-1, 1, <String>{bishop, queen}),
    (1, -1, <String>{bishop, queen}),
    (1, 1, <String>{bishop, queen}),
  ];
  for (final ray in rayAttacks) {
    var row = targetRow + ray.$1;
    var file = targetFile + ray.$2;
    while (row >= 0 && row <= 7 && file >= 0 && file <= 7) {
      final piece = board[(row * 8) + file];
      if (piece.isNotEmpty) {
        if (ray.$3.contains(piece)) return true;
        break;
      }
      row += ray.$1;
      file += ray.$2;
    }
  }
  return false;
}

String _removeCastlingRight(String castling, String right) {
  if (castling == '-') return castling;
  final next = castling.replaceAll(right, '');
  return next.isEmpty ? '-' : next;
}

String _updateCastlingRights(
  String castling, {
  required String piece,
  required String from,
  required String to,
  required String capturedPiece,
}) {
  var next = castling;
  if (piece == 'K') {
    next = _removeCastlingRight(_removeCastlingRight(next, 'K'), 'Q');
  } else if (piece == 'k') {
    next = _removeCastlingRight(_removeCastlingRight(next, 'k'), 'q');
  }
  if (piece == 'R') {
    if (from == 'h1') next = _removeCastlingRight(next, 'K');
    if (from == 'a1') next = _removeCastlingRight(next, 'Q');
  } else if (piece == 'r') {
    if (from == 'h8') next = _removeCastlingRight(next, 'k');
    if (from == 'a8') next = _removeCastlingRight(next, 'q');
  }
  if (capturedPiece == 'R') {
    if (to == 'h1') next = _removeCastlingRight(next, 'K');
    if (to == 'a1') next = _removeCastlingRight(next, 'Q');
  } else if (capturedPiece == 'r') {
    if (to == 'h8') next = _removeCastlingRight(next, 'k');
    if (to == 'a8') next = _removeCastlingRight(next, 'q');
  }
  return next.isEmpty ? '-' : next;
}

bool _hasLegalEnPassantCapture(
  List<String> board, {
  required int targetIndex,
  required int movedPawnIndex,
  required bool movingWhite,
}) {
  final targetFile = targetIndex % 8;
  final capturingWhite = !movingWhite;
  final opponentPawn = capturingWhite ? 'P' : 'p';
  final sourceRankOffset = movingWhite ? -8 : 8;
  for (final fileOffset in const <int>[-1, 1]) {
    final sourceFile = targetFile + fileOffset;
    if (sourceFile < 0 || sourceFile > 7) continue;
    final sourceIndex = targetIndex + sourceRankOffset + fileOffset;
    if (sourceIndex < 0 ||
        sourceIndex >= 64 ||
        board[sourceIndex] != opponentPawn) {
      continue;
    }
    final nextBoard = List<String>.of(board);
    nextBoard[sourceIndex] = '';
    nextBoard[movedPawnIndex] = '';
    nextBoard[targetIndex] = opponentPawn;
    final kingIndex = _findKingIndex(nextBoard, white: capturingWhite);
    if (kingIndex == -1 ||
        !_isSquareAttacked(nextBoard, kingIndex, byWhite: movingWhite)) {
      return true;
    }
  }
  return false;
}

_ParsedHeaders _parseHeaders(String rawPgn) {
  final headers = <String, String>{};
  var headerEnd = 0;
  for (final match in _pgnHeaderRegex.allMatches(rawPgn)) {
    headers[match.group(1)!] = _unescapePgnHeader(match.group(2)!);
    if (match.end > headerEnd) headerEnd = match.end;
  }
  return _ParsedHeaders(headers: headers, headerEnd: headerEnd);
}

Iterable<String> _mainlineSanTokens(String rawPgn, int headerEnd) sync* {
  final length = rawPgn.length;
  var i = headerEnd.clamp(0, length).toInt();
  var variationDepth = 0;

  while (i < length) {
    final code = rawPgn.codeUnitAt(i);
    if (_isWhitespace(code)) {
      i++;
      continue;
    }
    if (code == 0x3B) {
      i = _skipLineComment(rawPgn, i + 1);
      continue;
    }
    if (code == 0x7B) {
      i = _skipBraceComment(rawPgn, i + 1);
      continue;
    }
    if (code == 0x28) {
      variationDepth++;
      i++;
      continue;
    }
    if (code == 0x29) {
      if (variationDepth > 0) variationDepth--;
      i++;
      continue;
    }

    final start = i;
    while (i < length) {
      final tokenCode = rawPgn.codeUnitAt(i);
      if (_isWhitespace(tokenCode) ||
          tokenCode == 0x3B ||
          tokenCode == 0x7B ||
          tokenCode == 0x28 ||
          tokenCode == 0x29) {
        break;
      }
      i++;
    }

    if (variationDepth > 0) continue;
    final san = _cleanMainlineSanToken(rawPgn.substring(start, i));
    if (san != null) yield san;
  }
}

int _skipLineComment(String text, int start) {
  var i = start;
  while (i < text.length) {
    final code = text.codeUnitAt(i);
    if (code == 0x0A || code == 0x0D) return i + 1;
    i++;
  }
  return i;
}

int _skipBraceComment(String text, int start) {
  var i = start;
  while (i < text.length) {
    if (text.codeUnitAt(i) == 0x7D) return i + 1;
    i++;
  }
  return i;
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D ||
    codeUnit == 0x0B ||
    codeUnit == 0x0C;

String? _cleanMainlineSanToken(String raw) {
  var token = raw.trim();
  if (token.isEmpty) return null;
  if (_isPgnOutcome(token) || token.startsWith(r'$')) return null;
  if (_moveNumberOnlyRegex.hasMatch(token)) return null;

  while (true) {
    final match = _moveNumberPrefixRegex.firstMatch(token);
    if (match == null) break;
    token = token.substring(match.end);
    if (token.isEmpty) return null;
  }

  if (_isPgnOutcome(token) || token.startsWith(r'$')) return null;
  token = token.replaceFirst(_annotationSuffixRegex, '');
  return token.isEmpty ? null : token;
}

bool _isPgnOutcome(String token) {
  switch (token) {
    case '1-0':
    case '0-1':
    case '1/2-1/2':
    case '*':
      return true;
    default:
      return false;
  }
}

String _unescapePgnHeader(String value) {
  return value.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
}

class _ParsedHeaders {
  const _ParsedHeaders({required this.headers, required this.headerEnd});

  final Map<String, String> headers;
  final int headerEnd;
}

class _ParsedLocalGame {
  const _ParsedLocalGame({
    required this.metadata,
    required this.startingFen,
    required this.startingKey,
    required this.moves,
  });

  final Map<String, String> metadata;
  final String startingFen;
  final _PositionKey startingKey;
  final List<_ParsedLocalMove> moves;
}

class _ParsedLocalMove {
  const _ParsedLocalMove({required this.uci, required this.key});

  final String uci;
  final _PositionKey key;
}

@immutable
class _PositionKey {
  const _PositionKey(this.fenKey);

  factory _PositionKey.fromPosition(Position position) {
    return _PositionKey(playerOpeningTreeFenKey(position.fen));
  }

  final String fenKey;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _PositionKey && other.fenKey == fenKey;
  }

  @override
  int get hashCode => fenKey.hashCode;
}

class _NodeAccumulator {
  _NodeAccumulator({required this.id, required this.fenKey, required this.ply});

  final int id;
  final String fenKey;
  int ply;
  final Map<String, _MoveAccumulator> moves = <String, _MoveAccumulator>{};

  void recordMove({
    required String uci,
    required int childNodeId,
    required _ResultBucket result,
    required DateTime? date,
    required String gameId,
  }) {
    moves
        .putIfAbsent(
          uci,
          () => _MoveAccumulator(uci: uci, childNodeId: childNodeId),
        )
        .record(result: result, date: date, gameId: gameId);
  }

  void mergeMove(PlayerOpeningTreeMove move, {required int childNodeId}) {
    moves
        .putIfAbsent(
          move.uci,
          () => _MoveAccumulator(uci: move.uci, childNodeId: childNodeId),
        )
        .merge(move);
  }

  PlayerOpeningTreeNode toNode() {
    final frozenMoves =
        moves.values.map((move) => move.toMove()).toList()..sort((a, b) {
          final byTotal = b.total.compareTo(a.total);
          return byTotal != 0 ? byTotal : a.uci.compareTo(b.uci);
        });
    return PlayerOpeningTreeNode(
      id: id,
      fenKey: fenKey,
      ply: ply,
      moves: List<PlayerOpeningTreeMove>.unmodifiable(frozenMoves),
    );
  }
}

class _MoveAccumulator {
  _MoveAccumulator({required this.uci, required this.childNodeId});

  final String uci;
  final int childNodeId;
  int white = 0;
  int black = 0;
  int draws = 0;
  int total = 0;
  DateTime? lastPlayed;
  String? sampleGameId;

  void record({
    required _ResultBucket result,
    required DateTime? date,
    required String gameId,
  }) {
    switch (result) {
      case _ResultBucket.white:
        white++;
        break;
      case _ResultBucket.black:
        black++;
        break;
      case _ResultBucket.draw:
        draws++;
        break;
      case _ResultBucket.unknown:
        draws++;
        break;
    }
    total++;
    sampleGameId ??= gameId;
    if (date != null && (lastPlayed == null || date.isAfter(lastPlayed!))) {
      lastPlayed = date;
      sampleGameId = gameId;
    }
  }

  void merge(PlayerOpeningTreeMove move) {
    white += move.white;
    black += move.black;
    draws += move.draws;
    total += move.total;
    sampleGameId ??= move.sampleGameId;
    final moveLastPlayed = move.lastPlayed;
    if (moveLastPlayed != null &&
        (lastPlayed == null || moveLastPlayed.isAfter(lastPlayed!))) {
      lastPlayed = moveLastPlayed;
      sampleGameId = move.sampleGameId;
    }
  }

  PlayerOpeningTreeMove toMove() {
    return PlayerOpeningTreeMove(
      uci: uci,
      childNodeId: childNodeId,
      white: white,
      black: black,
      draws: draws,
      total: total,
      lastPlayed: lastPlayed,
      sampleGameId: sampleGameId,
    );
  }
}

enum _ResultBucket { white, black, draw, unknown }

_ResultBucket _resultBucket(Object? raw) {
  switch (raw?.toString().replaceAll('½', '1/2').trim()) {
    case '1-0':
    case 'W':
      return _ResultBucket.white;
    case '0-1':
    case 'B':
      return _ResultBucket.black;
    case '1/2-1/2':
    case 'D':
      return _ResultBucket.draw;
    default:
      return _ResultBucket.unknown;
  }
}

Map<String, dynamic> _rowForGame(
  LocalOpeningTreeGameInput input,
  Map<String, String> metadata,
  List<String> line,
  DateTime? parsedDate, {
  required String startingFen,
}) {
  String meta(String key) => metadata[key]?.trim() ?? '';
  int? rating(String key) {
    final value = int.tryParse(meta(key));
    return value == null || value <= 0 ? null : value;
  }

  final dateText = meta('Date');
  return <String, dynamic>{
    'id': input.id,
    'white': _fallback(meta('White'), 'White'),
    'black': _fallback(meta('Black'), 'Black'),
    'whiteTitle': meta('WhiteTitle'),
    'blackTitle': meta('BlackTitle'),
    'whiteFed': _firstMetadata(metadata, const <String>[
      'WhiteFed',
      'WhiteFederation',
      'WhiteCountry',
      'WhiteTeamCountry',
    ]),
    'blackFed': _firstMetadata(metadata, const <String>[
      'BlackFed',
      'BlackFederation',
      'BlackCountry',
      'BlackTeamCountry',
    ]),
    'whiteElo': rating('WhiteElo'),
    'blackElo': rating('BlackElo'),
    'whiteFideId': meta('WhiteFideId'),
    'blackFideId': meta('BlackFideId'),
    'result': _normalizeResult(meta('Result')),
    'date': parsedDate?.toIso8601String() ?? dateText,
    'timeControl': meta('TimeControl'),
    'eco': meta('ECO'),
    'opening': meta('Opening'),
    'variation': meta('Variation'),
    'event': _fallback(meta('Event'), 'Local PGN'),
    'site': meta('Site'),
    'sourcePath': input.sourcePath,
    'sourceRelativePath': input.sourceRelativePath,
    'fileName': input.fileName,
    'indexInFile': input.indexInFile,
    'fileGameCount': input.fileGameCount,
    'sourceByteStart': input.sourceByteStart,
    'sourceByteEnd': input.sourceByteEnd,
    'startingFen': startingFen,
    'pgnHash': localChessPgnFingerprint(input.rawPgn),
    'line': List<String>.unmodifiable(line),
  }..removeWhere((_, value) => value == null || value == '');
}

String _firstMetadata(Map<String, String> metadata, List<String> keys) {
  for (final key in keys) {
    final value = metadata[key]?.trim() ?? '';
    if (value.isNotEmpty && value != '?') return value;
  }
  return '';
}

String _fallback(String value, String fallback) {
  final trimmed = value.trim();
  return trimmed.isEmpty || trimmed == '?' ? fallback : trimmed;
}

String _normalizeResult(String raw) {
  final normalized = raw.replaceAll('½', '1/2').trim();
  switch (normalized) {
    case '1-0':
    case '0-1':
    case '1/2-1/2':
      return normalized;
    default:
      return '*';
  }
}

DateTime? _dateFromMetadata(Map<String, String> metadata) {
  final raw = metadata['Date']?.toString().trim();
  if (raw == null || raw.isEmpty || raw.contains('?')) return null;
  return DateTime.tryParse(raw.replaceAll('.', '-'));
}

String _fenKey(String fen) => playerOpeningTreeFenKey(fen);
