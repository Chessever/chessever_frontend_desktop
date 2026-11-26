/// Judges the moves of a game while it is being played, by the game report's
/// own rules: the same classes, the same thresholds, the same book lookup.
///
/// The report needs the whole game before it starts. Here each move is judged
/// as soon as the position after it has been searched, so a player sees the
/// report's mark on the board a moment after the move lands.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// Searches one position for the report: [multiPv] lines, every one from the
/// same completed [depth], scores from White's point of view.
typedef PlayLivePositionEvaluator =
    Future<GameReportPosition> Function(
      String fen, {
      required int depth,
      required int multiPv,
    });

/// Every judged move of a game in play, by its zero-based mainline index.
@immutable
class PlayLiveMoveJudgements {
  const PlayLiveMoveJudgements({
    this.classes = const <int, GameMoveClassification>{},
    this.judgedMoves = 0,
    this.engineAvailable = true,
  });

  /// The report's class for each judged move that earns one. A judged move
  /// missing here is ordinary play, exactly as in the report.
  final Map<int, GameMoveClassification> classes;

  /// How many moves from the start have a verdict.
  final int judgedMoves;

  /// False once the engine could not be started. Book moves are still
  /// marked; nothing else is.
  final bool engineAvailable;

  bool isJudged(int moveIndex) => moveIndex < judgedMoves;
}

/// A game in play as the classifier reads it: the moves from the start
/// position, each with the position after it.
///
/// Moves that do not apply end the line, the way the play board replays them.
/// The FEN after [uci] from [fen], written as the judged game writes it, or
/// null when the move is not legal there.
@visibleForTesting
String? playLiveFenAfter(String fen, String uci) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final parsed = Move.parse(uci);
    if (parsed == null) return null;
    final move =
        position.isLegal(parsed) || parsed is! NormalMove
            ? parsed
            : position.normalizeMove(parsed);
    if (!position.isLegal(move)) return null;
    return position.play(move).fen;
  } catch (_) {
    return null;
  }
}

ChessGame playLiveClassifierGame(String startingFen, List<String> history) {
  Position position;
  try {
    position = Chess.fromSetup(
      Setup.parseFen(startingFen),
      ignoreImpossibleCheck: true,
    );
  } catch (_) {
    position = Chess.initial;
  }
  final start = position.fen;
  final mainline = <ChessMove>[];
  for (final uci in history) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final (next, san) = position.makeSan(move);
    mainline.add(
      ChessMove(
        num: position.fullmoves,
        fen: next.fen,
        san: san,
        uci: move.uci,
        turn: position.turn == Side.white ? ChessColor.white : ChessColor.black,
      ),
    );
    position = next;
  }
  return ChessGame(
    gameId: 'play-live',
    startingFen: start,
    metadata: const <String, dynamic>{},
    mainline: List<ChessMove>.unmodifiable(mainline),
  );
}

/// Judges each move of one game in play, in order, as the game grows.
///
/// Feed it the game after every move with [sync]. It searches each new
/// position once at the report's depth and breadth, asks the opening database
/// about the move while the engine works, and publishes the move's class.
/// A brilliant candidate is searched again at the report's deeper depth
/// before it is judged, as the report does.
class PlayLiveMoveClassifier extends StateNotifier<PlayLiveMoveJudgements> {
  PlayLiveMoveClassifier({
    required Future<PlayLivePositionEvaluator?> Function() openEvaluator,
    GameReportBookLookup? bookLookup,
    Future<void> Function()? closeEvaluator,
  }) : _openEvaluator = openEvaluator,
       _closeEvaluator = closeEvaluator,
       _bookLookup = bookLookup,
       super(const PlayLiveMoveJudgements());

  final Future<PlayLivePositionEvaluator?> Function() _openEvaluator;
  final Future<void> Function()? _closeEvaluator;
  final GameReportBookLookup? _bookLookup;

  Future<PlayLivePositionEvaluator?>? _evaluator;
  ChessGame? _game;
  int _generation = 0;
  bool _running = false;
  bool _disposed = false;

  /// Searches already made, by FEN, at the report depth and the deeper
  /// brilliant depth.
  final Map<String, GameReportPosition> _searched = {};
  final Map<String, GameReportPosition> _searchedDeep = {};

  /// The opening database's game count for each move, once asked.
  final Map<int, int?> _bookCounts = {};
  int _bookDryStreak = 0;

  /// Book lookups asked ahead, by ply and move, so a move that was
  /// expected finds its count waiting.
  final Map<String, Future<int?>> _bookAhead = {};

  GameMoveClassification? _previousClass;

  /// Takes the game as it stands now. A game that is not a continuation of
  /// the one already judged starts over.
  void sync(ChessGame game) {
    if (_disposed) return;
    final previous = _game;
    _game = game;
    if (previous != null && !_continues(previous, game)) {
      _generation++;
      _bookCounts.clear();
      _bookAhead.clear();
      _bookDryStreak = 0;
      _previousClass = null;
      state = PlayLiveMoveJudgements(engineAvailable: state.engineAvailable);
    }
    if (!_running) unawaited(_pump());
  }

  static bool _continues(ChessGame previous, ChessGame next) {
    if (previous.startingFen != next.startingFen) return false;
    final judged = math.min(previous.mainline.length, next.mainline.length);
    for (var i = 0; i < judged; i++) {
      if (previous.mainline[i].uci != next.mainline[i].uci) return false;
    }
    return next.mainline.length >= previous.mainline.length;
  }

  Future<void> _pump() async {
    _running = true;
    try {
      while (!_disposed) {
        final game = _game;
        final generation = _generation;
        if (game == null) return;
        final index = state.judgedMoves;
        if (index >= game.mainline.length) {
          // Caught up: while the side to move thinks, search the replies
          // the engine likes best, one at a time, so the move actually
          // played is usually judged the moment it lands. Each step is
          // one search, then the loop looks for a real move again.
          if (await _searchAhead(game, generation)) continue;
          return;
        }
        final judged = await _judge(game, index, generation);
        if (_disposed) return;
        if (generation != _generation) continue;
        _previousClass = judged;
        state = PlayLiveMoveJudgements(
          classes: <int, GameMoveClassification>{
            ...state.classes,
            if (judged != null) index: judged,
          },
          judgedMoves: index + 1,
          engineAvailable: state.engineAvailable,
        );
      }
    } finally {
      _running = false;
    }
  }

  /// The report's class for move [index] of [game], or null for ordinary
  /// play (or when the engine is unavailable and the move is not theory).
  Future<GameMoveClassification?> _judge(
    ChessGame game,
    int index,
    int generation,
  ) async {
    final fens = gameReportFens(game);
    final bookFuture = _bookCount(game, index, fens);
    final evaluator = await (_evaluator ??= _open());
    if (evaluator == null) {
      return applyBookMoveOverride(null, await bookFuture);
    }

    final positions = <GameReportPosition>[];
    try {
      for (var i = 0; i <= index + 1; i++) {
        positions.add(await _search(evaluator, fens[i], deep: false));
        if (_disposed || generation != _generation) return null;
      }
      final line = game.copyWith(mainline: game.mainline.sublist(0, index + 1));
      var winPercentages = _winPercentages(positions);
      if (isBrilliantCandidate(
        index: index,
        game: line,
        positions: positions,
        winPercentages: winPercentages,
      )) {
        positions[index] = await _search(evaluator, fens[index], deep: true);
        positions[index + 1] = await _search(
          evaluator,
          fens[index + 1],
          deep: true,
        );
        if (_disposed || generation != _generation) return null;
        winPercentages = _winPercentages(positions);
      }
      return classifyGameReportMove(
        index: index,
        game: line,
        positions: positions,
        winPercentages: winPercentages,
        previousMoveClassification: _previousClass,
        bookGameCount: await bookFuture,
      );
    } catch (error) {
      // One position the engine could not read costs that move its mark,
      // never the rest of the game.
      debugPrint('[PlayLiveMoveClassifier] move ${index + 1}: $error');
      return applyBookMoveOverride(null, await bookFuture);
    }
  }

  /// How many replies are searched ahead: the report's own MultiPV, so the
  /// engine's whole shortlist is covered.
  static const int _aheadCandidates =
      GameAnalysisReportController.reportMultiPv;

  /// Searches one not-yet-searched position a likely next move would reach.
  /// False when there is nothing left to search ahead (or no engine).
  Future<bool> _searchAhead(ChessGame game, int generation) async {
    final evaluator = await (_evaluator ??= _open());
    if (evaluator == null || _disposed || generation != _generation) {
      return false;
    }
    final fens = gameReportFens(game);
    final index = game.mainline.length;
    final fen = fens.last;
    try {
      final here = await _search(evaluator, fen, deep: false);
      final candidates = <String>[
        for (final line in here.lines.take(_aheadCandidates))
          if (line.moves.isNotEmpty) line.moves.first,
      ];
      for (final uci in candidates) {
        _bookAheadFor(game, index, uci, fens);
      }
      for (final uci in candidates) {
        final after = playLiveFenAfter(fen, uci);
        if (after == null) continue;
        if (_searched.containsKey(after) ||
            terminalGameReportPosition(after) != null) {
          continue;
        }
        await _search(evaluator, after, deep: false);
        return !_disposed && generation == _generation;
      }
    } catch (error) {
      debugPrint('[PlayLiveMoveClassifier] search ahead: $error');
    }
    return false;
  }

  static List<double> _winPercentages(List<GameReportPosition> positions) =>
      positions
          .map((position) => gameReportWinPercentage(position.bestLine))
          .toList(growable: false);

  Future<GameReportPosition> _search(
    PlayLivePositionEvaluator evaluator,
    String fen, {
    required bool deep,
  }) async {
    final terminal = terminalGameReportPosition(fen);
    if (terminal != null) return terminal;
    final cache = deep ? _searchedDeep : _searched;
    final known = cache[fen];
    if (known != null) return known;
    final position = await evaluator(
      fen,
      depth:
          deep
              ? GameAnalysisReportController.brilliantDepth
              : GameAnalysisReportController.reportDepth,
      multiPv:
          deep
              ? GameAnalysisReportController.brilliantMultiPv
              : GameAnalysisReportController.reportMultiPv,
    );
    cache[fen] = position;
    return position;
  }

  Future<PlayLivePositionEvaluator?> _open() async {
    try {
      final evaluator = await _openEvaluator();
      if (evaluator == null && !_disposed) {
        state = PlayLiveMoveJudgements(
          classes: state.classes,
          judgedMoves: state.judgedMoves,
          engineAvailable: false,
        );
      }
      return evaluator;
    } catch (error) {
      debugPrint('[PlayLiveMoveClassifier] engine unavailable: $error');
      if (!_disposed) {
        state = PlayLiveMoveJudgements(
          classes: state.classes,
          judgedMoves: state.judgedMoves,
          engineAvailable: false,
        );
      }
      return null;
    }
  }

  /// How many database games played move [index], asked the way the report
  /// asks: only from the standard start, at most [kBookProbeMaxPlies] deep,
  /// and no longer once [kBookProbeDryStreak] moves in a row were not theory.
  Future<int?> _bookCount(ChessGame game, int index, List<String> fens) async {
    if (_bookCounts.containsKey(index)) return _bookCounts[index];
    final lookup = _bookLookup;
    if (lookup == null ||
        game.startingFen != kInitialFEN ||
        index >= kBookProbeMaxPlies ||
        _bookDryStreak >= kBookProbeDryStreak) {
      return null;
    }
    final count =
        await (_bookAhead.remove(_bookKey(index, game.mainline[index].uci)) ??
            _askBook(lookup, game, index, game.mainline[index].uci, fens));
    _bookCounts[index] = count;
    if (count == null || count < kBookMoveMinGames) {
      _bookDryStreak++;
    } else {
      _bookDryStreak = 0;
    }
    return count;
  }

  static String _bookKey(int index, String uci) => '$index $uci';

  static Future<int?> _askBook(
    GameReportBookLookup lookup,
    ChessGame game,
    int index,
    String uci,
    List<String> fens,
  ) async {
    try {
      return await lookup(fens[index], uci, [
        for (final move in game.mainline.take(index)) move.uci,
      ]).timeout(kBookLookupTimeout);
    } catch (_) {
      return null;
    }
  }

  /// Asks the book about [uci] as move [index] before it is played, under
  /// the same rules as [_bookCount].
  void _bookAheadFor(ChessGame game, int index, String uci, List<String> fens) {
    final lookup = _bookLookup;
    if (lookup == null ||
        game.startingFen != kInitialFEN ||
        index >= kBookProbeMaxPlies ||
        _bookDryStreak >= kBookProbeDryStreak) {
      return;
    }
    _bookAhead.putIfAbsent(
      _bookKey(index, uci),
      () => _askBook(lookup, game, index, uci, fens),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    final close = _closeEvaluator;
    if (close != null) unawaited(close());
    super.dispose();
  }
}

/// A report evaluator on a UCI engine of its own, so judging moves never
/// waits behind (or interrupts) the analysis the player is watching.
class PlayLiveUciEvaluator {
  PlayLiveUciEvaluator._(this._engine);

  final UciEngine _engine;
  int _multiPv = 0;
  int _searches = 0;
  Future<void> _queue = Future<void>.value();

  /// Starts the engine at [binaryPath]. Null when it does not speak UCI.
  static Future<PlayLiveUciEvaluator?> open(
    String binaryPath, {
    List<String> arguments = const <String>[],
    String? workingDirectory,
  }) async {
    final engine = await UciEngine.spawn(
      binaryPath,
      arguments: arguments,
      workingDirectory: workingDirectory,
    );
    final ready = await engine.initialize(threads: 1, hashMb: 32, multiPv: 1);
    if (!ready) {
      await engine.dispose();
      return null;
    }
    engine.send('ucinewgame');
    final evaluator = PlayLiveUciEvaluator._(engine).._multiPv = 1;
    return evaluator;
  }

  /// Searches [fen]; searches run one at a time, in the order asked.
  Future<GameReportPosition> evaluate(
    String fen, {
    required int depth,
    required int multiPv,
  }) {
    final run = _queue.then((_) => _evaluate(fen, depth, multiPv));
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<GameReportPosition> _evaluate(
    String fen,
    int depth,
    int multiPv,
  ) async {
    final batches = PlayLiveUciBatches(multiPv: multiPv);
    final done = Completer<void>();
    final subscription = _engine.lines.listen((line) {
      if (line.startsWith('bestmove')) {
        if (!done.isCompleted) done.complete();
        return;
      }
      batches.add(line);
    });
    try {
      if (_multiPv != multiPv) {
        _engine.send('setoption name MultiPV value $multiPv');
        _multiPv = multiPv;
      }
      _engine.send('position fen $fen');
      _engine.send('go depth $depth');
      await done.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          _engine.send('stop');
          throw TimeoutException('No bestmove for $fen');
        },
      );
    } finally {
      await subscription.cancel();
    }
    final lines = batches.deepestBatch(whiteToMove: _whiteToMove(fen));
    if (lines.isEmpty) {
      throw StateError('The engine returned no line for $fen');
    }
    return GameReportPosition(
      fen: fen,
      lines: lines,
      search: GameReportSearchEvidence(
        engineId: 'play-live-uci:${identityHashCode(this)}',
        searchId: 'play-live-${_searches++}',
        complete: true,
      ),
    );
  }

  static bool _whiteToMove(String fen) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    return parts.length < 2 || parts[1] != 'b';
  }

  Future<void> close() => _engine.dispose();
}

/// Collects a search's `info` lines into complete MultiPV batches.
///
/// The report trusts a snapshot only when every line in it comes from the
/// same completed depth ([gameReportSnapshotIsCoherent]), so the deepest depth
/// whose lines run unbroken from the first is the one returned.
@visibleForTesting
class PlayLiveUciBatches {
  PlayLiveUciBatches({required this.multiPv});

  final int multiPv;
  final Map<int, Map<int, ({int? cp, int? mate, List<String> moves})>>
  _byDepth = {};

  void add(String line) {
    if (!line.startsWith('info ') ||
        line.contains(' lowerbound') ||
        line.contains(' upperbound') ||
        line.contains(' currmove ')) {
      return;
    }
    final tokens = line.trim().split(RegExp(r'\s+'));
    int? depth;
    var rank = 1;
    int? cp;
    int? mate;
    List<String>? moves;
    for (var i = 1; i < tokens.length; i++) {
      switch (tokens[i]) {
        case 'depth':
          depth = int.tryParse(tokens.elementAtOrNull(i + 1) ?? '');
          i++;
        case 'multipv':
          rank = int.tryParse(tokens.elementAtOrNull(i + 1) ?? '') ?? 1;
          i++;
        case 'score':
          final kind = tokens.elementAtOrNull(i + 1);
          final value = int.tryParse(tokens.elementAtOrNull(i + 2) ?? '');
          if (kind == 'cp') cp = value;
          if (kind == 'mate') mate = value;
          i += 2;
        case 'pv':
          moves = tokens.sublist(i + 1);
          i = tokens.length;
      }
    }
    if (depth == null ||
        moves == null ||
        moves.isEmpty ||
        (cp == null && mate == null) ||
        mate == 0) {
      return;
    }
    (_byDepth[depth] ??= {})[rank] = (cp: cp, mate: mate, moves: moves);
  }

  /// The deepest batch holding as many lines as any depth produced (fewer
  /// legal moves than [multiPv] give a shorter batch), scores turned to
  /// White's point of view.
  List<GameReportLine> deepestBatch({required bool whiteToMove}) {
    final batches = {
      for (final depth in _byDepth.keys)
        depth: _batchAt(depth, whiteToMove: whiteToMove),
    };
    final widest = batches.values.fold<int>(
      0,
      (most, lines) => math.max(most, lines.length),
    );
    if (widest == 0) return const <GameReportLine>[];
    final depths = batches.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final depth in depths) {
      final lines = batches[depth]!;
      if (lines.length == widest) return lines;
    }
    return const <GameReportLine>[];
  }

  List<GameReportLine> _batchAt(int depth, {required bool whiteToMove}) {
    final batch = _byDepth[depth]!;
    final sign = whiteToMove ? 1 : -1;
    final lines = <GameReportLine>[];
    final roots = <String>{};
    for (var rank = 1; rank <= multiPv; rank++) {
      final line = batch[rank];
      if (line == null || !roots.add(line.moves.first)) break;
      lines.add(
        GameReportLine(
          moves: List<String>.unmodifiable(line.moves),
          depth: depth,
          centipawns: line.mate == null ? line.cp! * sign : null,
          mate: line.mate == null ? null : line.mate! * sign,
        ),
      );
    }
    return List<GameReportLine>.unmodifiable(lines);
  }
}
