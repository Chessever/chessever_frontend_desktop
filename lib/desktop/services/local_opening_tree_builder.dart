import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/player_opening_tree_builder.dart';

@immutable
class LocalOpeningTreeGameInput {
  LocalOpeningTreeGameInput({
    required this.id,
    required this.rawPgn,
    required this.sourcePath,
    required this.sourceRelativePath,
    required this.fileName,
    required this.indexInFile,
    required this.fileGameCount,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    if (rawPgn.trim().isEmpty) {
      throw ArgumentError.value(rawPgn, 'rawPgn', 'must not be empty');
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
  final String sourcePath;
  final String sourceRelativePath;
  final String fileName;
  final int indexInFile;
  final int fileGameCount;
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
}) {
  return buildLocalOpeningTreeIndexWithDiagnostics(
    treeId: treeId,
    databaseId: databaseId,
    games: games,
    maxPly: maxPly,
    includePositionGameRefs: includePositionGameRefs,
  ).index;
}

LocalOpeningTreeBuildResult buildLocalOpeningTreeIndexWithDiagnostics({
  required String treeId,
  required String databaseId,
  required List<LocalOpeningTreeGameInput> games,
  int maxPly = 0,
  bool includePositionGameRefs = true,
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
  ).build(List<LocalOpeningTreeGameInput>.unmodifiable(games));
}

void _validateBuildInputs({
  required String treeId,
  required String databaseId,
  required List<LocalOpeningTreeGameInput> games,
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
  final ids = <String>{};
  for (final game in games) {
    if (!ids.add(game.id)) {
      throw ArgumentError.value(game.id, 'games', 'duplicate game id');
    }
  }
}

class _LocalOpeningTreeAccumulator {
  _LocalOpeningTreeAccumulator({
    required this.treeId,
    required this.databaseId,
    required this.maxPly,
    required this.includePositionGameRefs,
  });

  final String treeId;
  final String databaseId;
  final int maxPly;
  final bool includePositionGameRefs;
  final Map<String, _NodeAccumulator> _nodesByFenKey =
      <String, _NodeAccumulator>{};
  final Map<String, Map<String, PlayerOpeningTreeGameRef>> _gamesByFen =
      <String, Map<String, PlayerOpeningTreeGameRef>>{};
  final Map<String, Map<String, dynamic>> _gameRowsById =
      <String, Map<String, dynamic>>{};
  final List<LocalOpeningTreeSkippedGame> _skippedGames =
      <LocalOpeningTreeSkippedGame>[];
  int _nextNodeId = 0;

  LocalOpeningTreeBuildResult build(List<LocalOpeningTreeGameInput> games) {
    final root = _nodeForFen(Chess.initial.fen, 0);

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

    final index = PlayerOpeningTreeIndex(
      treeId: treeId,
      playerId: databaseId,
      maxPly: maxPly <= 0 ? _maxSeenPly : maxPly,
      rootNodeId: root.id,
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
    );

    return LocalOpeningTreeBuildResult(
      index: index,
      skippedGames: List<LocalOpeningTreeSkippedGame>.unmodifiable(
        _skippedGames,
      ),
    );
  }

  int get _maxSeenPly {
    var out = 0;
    for (final node in _nodesByFenKey.values) {
      if (node.ply > out) out = node.ply;
    }
    return out;
  }

  void _addGame(LocalOpeningTreeGameInput input) {
    final parsed = _parseGame(input);
    if (parsed.moves.isEmpty) {
      throw LocalOpeningTreeGameException(input, 'No legal mainline moves');
    }

    final result = _resultBucket(parsed.metadata['Result']);
    final date = _dateFromMetadata(parsed.metadata);
    final line = <String>[for (final move in parsed.moves) move.uci];

    _gameRowsById[input.id] = Map<String, dynamic>.unmodifiable(
      _rowForGame(
        input,
        parsed.metadata,
        line,
        date,
        startingFen: parsed.startingFen,
      ),
    );

    var previousFen = parsed.startingFen;
    final pliesToIndex =
        maxPly <= 0
            ? parsed.moves.length
            : parsed.moves.length.clamp(0, maxPly).toInt();

    for (var ply = 0; ply < pliesToIndex; ply++) {
      final move = parsed.moves[ply];

      final parent = _nodeForFen(previousFen, ply);
      final child = _nodeForFen(move.fen, ply + 1);
      parent.recordMove(
        uci: move.uci,
        childNodeId: child.id,
        result: result,
        date: date,
        gameId: input.id,
      );
      _recordGameRef(fen: previousFen, gameId: input.id, ply: ply);
      previousFen = move.fen;
    }

    _recordGameRef(fen: previousFen, gameId: input.id, ply: pliesToIndex);
  }

  _NodeAccumulator _nodeForFen(String fen, int ply) {
    final key = _fenKey(fen);
    final existing = _nodesByFenKey[key];
    if (existing != null) {
      if (ply < existing.ply) existing.ply = ply;
      return existing;
    }
    final node = _NodeAccumulator(id: _nextNodeId++, fenKey: key, ply: ply);
    _nodesByFenKey[key] = node;
    return node;
  }

  void _recordGameRef({
    required String fen,
    required String gameId,
    required int ply,
  }) {
    if (!includePositionGameRefs) return;
    final key = _fenKey(fen);
    _gamesByFen.putIfAbsent(
      key,
      () => <String, PlayerOpeningTreeGameRef>{},
    )[gameId] = PlayerOpeningTreeGameRef(gameId: gameId, fen: fen, ply: ply);
  }
}

_ParsedLocalGame _parseGame(LocalOpeningTreeGameInput input) {
  final PgnGame<PgnNodeData> game;
  try {
    game = PgnGame.parsePgn(input.rawPgn);
  } on FormatException catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid PGN syntax: $e');
  } on ArgumentError catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid PGN data: $e');
  }

  final Position start;
  try {
    start = PgnGame.startingPosition(game.headers);
  } on PositionSetupException catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid starting position: $e');
  } on FormatException catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid starting FEN: $e');
  } on ArgumentError catch (e) {
    throw LocalOpeningTreeGameException(input, 'Invalid starting FEN: $e');
  }

  var position = start;
  final moves = <_ParsedLocalMove>[];

  for (final node in game.moves.mainline()) {
    final move = position.parseSan(node.san);
    if (move == null) {
      throw LocalOpeningTreeGameException(
        input,
        'Could not parse move "${node.san}" at ply ${moves.length + 1}',
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
      nextPosition = position.play(move);
    } on PlayException catch (e) {
      throw LocalOpeningTreeGameException(
        input,
        'Could not play move "${node.san}" at ply ${moves.length + 1}: $e',
      );
    }
    moves.add(_ParsedLocalMove(uci: uci, fen: nextPosition.fen));
    position = nextPosition;
  }

  return _ParsedLocalGame(
    metadata: Map<String, String>.unmodifiable(game.headers),
    startingFen: start.fen,
    moves: moves,
  );
}

class _ParsedLocalGame {
  const _ParsedLocalGame({
    required this.metadata,
    required this.startingFen,
    required this.moves,
  });

  final Map<String, String> metadata;
  final String startingFen;
  final List<_ParsedLocalMove> moves;
}

class _ParsedLocalMove {
  const _ParsedLocalMove({required this.uci, required this.fen});

  final String uci;
  final String fen;
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
    'whiteElo': rating('WhiteElo'),
    'blackElo': rating('BlackElo'),
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
    'startingFen': startingFen,
    'line': List<String>.unmodifiable(line),
  }..removeWhere((_, value) => value == null || value == '');
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
