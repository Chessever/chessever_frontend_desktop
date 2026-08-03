import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:chessever/desktop/services/engine/lichess_judgment.dart';
import 'package:chessever/desktop/services/engine/move_position_facts.dart';

enum GameReportStatus { idle, running, completed, cancelled, failed }

/// The desktop app owns one Stockfish process, so visible whole-game reports
/// and the live board search cannot make progress at the same time. Hidden
/// automatic reports stay in the background; a report only borrows the engine
/// when the user is looking at its running progress UI.
bool shouldRunLiveBoardAnalysis({
  required bool isForeground,
  required bool reportVisible,
  required bool reportRunning,
}) => isForeground && !(reportVisible && reportRunning);

enum GameMoveClassification {
  brilliant('Brilliant'),
  goodMove('Great'),
  bestMove('Top move'),
  missedWin('Missed Win'),
  inaccuracy('Inaccuracy'),
  mistake('Mistake'),
  blunder('Blunder'),
  bookMove('Book');

  const GameMoveClassification(this.label);
  final String label;

  /// Labels that mean the move did measurable damage. Book never displaces
  /// these — a line being popular is no defence.
  bool get isNegative =>
      this == GameMoveClassification.inaccuracy ||
      this == GameMoveClassification.mistake ||
      this == GameMoveClassification.blunder ||
      this == GameMoveClassification.missedWin;
}

@immutable
class GameReportLine {
  const GameReportLine({
    required this.moves,
    required this.depth,
    this.centipawns,
    this.mate,
  });

  final List<String> moves;
  final int depth;
  final int? centipawns;
  final int? mate;
}

@immutable
class GameReportPosition {
  const GameReportPosition({required this.fen, required this.lines});

  final String fen;
  final List<GameReportLine> lines;

  GameReportLine get bestLine => lines.first;
}

@immutable
class GameReportMove {
  const GameReportMove({
    required this.ply,
    required this.san,
    required this.uci,
    required this.isWhite,
    required this.classification,
    required this.evaluation,
    this.bestAlternative,
  });

  final int ply;
  final String san;
  final String uci;
  final bool isWhite;

  /// Null when the move is neutral and does not warrant a named category.
  final GameMoveClassification? classification;
  final GameReportLine evaluation;
  final String? bestAlternative;
}

@immutable
class GameAnalysisReport {
  const GameAnalysisReport({
    required this.fingerprint,
    required this.positions,
    required this.moves,
    required this.whiteAccuracy,
    required this.blackAccuracy,
    required this.generatedAt,
    this.whiteEstimatedRating,
    this.blackEstimatedRating,
  });

  final String fingerprint;
  final List<GameReportPosition> positions;
  final List<GameReportMove> moves;
  final double whiteAccuracy;
  final double blackAccuracy;
  final int? whiteEstimatedRating;
  final int? blackEstimatedRating;
  final DateTime generatedAt;

  int count(GameMoveClassification classification, {required bool white}) =>
      moves
          .where(
            (move) =>
                move.isWhite == white && move.classification == classification,
          )
          .length;
}

@immutable
class GameReportState {
  const GameReportState({
    this.status = GameReportStatus.idle,
    this.progress = 0,
    this.completedPositions = 0,
    this.totalPositions = 0,
    this.report,
    this.message,
  });

  final GameReportStatus status;
  final double progress;
  final int completedPositions;
  final int totalPositions;
  final GameAnalysisReport? report;
  final String? message;

  bool get isRunning => status == GameReportStatus.running;
}

typedef GameReportEvaluator =
    Future<EnhancedCloudEval> Function(
      String fen, {
      required int depth,
      required int multiPv,
      required String ownerId,
      void Function(int reachedDepth, int knodes)? onProgress,
    });

/// How many database games reached [fen] and then played [uci], having arrived
/// through [path].
///
/// Identical to mobile's typedef of the same name: book detection has to agree
/// across the apps, so both drive it through the same shape and the same
/// gamebase query.
typedef GameReportBookLookup =
    Future<int?> Function(String fen, String uci, List<String> path);

/// Owns one board tab's session-only whole-game analysis.
class GameAnalysisReportController extends ChangeNotifier {
  GameAnalysisReportController({
    StockfishSingleton? stockfish,
    GameReportEvaluator? evaluator,
    GameReportBookLookup? bookLookup,
  }) : _stockfish = stockfish ?? StockfishSingleton(),
       _evaluator = evaluator,
       _bookLookup = bookLookup;

  /// Principal search depth. Slightly above mobile (12) — desktops are faster
  /// per node, but full MultiPV-3-at-18 on every ply was slower than mobile's
  /// multipass design. Depth alone is not the win; **when** we spend MultiPV is.
  static const int reportDepth = 14;
  static const int reportMultiPv = 3;
  /// High-precision !! verification only (same depth family as mobile 16).
  static const int brilliantDepth = 16;
  static const int brilliantMultiPv = 3;

  /// Node count (in thousands) at which one position's search is treated as
  /// ~63% complete. Stockfish reports cumulative `nodes` on nearly every info
  /// line, so a node-driven fraction advances the bar on every engine tick —
  /// far smoother than the discrete depth steps, which leave the bar flat
  /// through the long final-depth tail. The exact value only shapes the curve;
  /// the per-position completion always snaps to the full slice regardless.
  static const double reportKnodeReference = 500;

  final StockfishSingleton _stockfish;
  final GameReportEvaluator? _evaluator;
  final GameReportBookLookup? _bookLookup;
  late final String _ownerId = StockfishSingleton.generateOwnerId(
    'gameReport',
    identityHashCode(this),
  );
  GameReportState _state = const GameReportState();
  int _generation = 0;
  bool _disposed = false;

  GameReportState get state => _state;

  void invalidate() {
    _generation++;
    if (_state.isRunning) {
      unawaited(_stockfish.cancelEvaluationsForOwner(_ownerId));
    }
    _setState(const GameReportState());
  }

  Future<void> cancel() async {
    if (!_state.isRunning) return;
    _generation++;
    await _stockfish.cancelEvaluationsForOwner(_ownerId);
    _setState(
      const GameReportState(
        status: GameReportStatus.cancelled,
        message: 'Analysis cancelled. No partial report was saved.',
      ),
    );
  }

  Future<void> analyze(
    ChessGame game, {
    int? whiteRating,
    int? blackRating,
  }) async {
    if (_state.isRunning || game.mainline.isEmpty) return;
    final generation = ++_generation;
    final fingerprint = gameReportFingerprint(game);
    final fens = gameReportFens(game);
    final totalMoves = game.mainline.length;
    // Primary (one line each FEN) + refinement (one unit per mainline move,
    // whether or not MultiPV actually runs). Brilliant is a small tail on top.
    final primaryAndRefineUnits = fens.length + totalMoves;
    _setState(
      GameReportState(
        status: GameReportStatus.running,
        totalPositions: primaryAndRefineUnits,
        message: 'Preparing Stockfish…',
      ),
    );

    // Network-bound and independent of the engine, so it runs alongside the
    // Stockfish passes and is collected just before the report is assembled —
    // the opening lookups cost no extra wall-clock. [_probeBookMoves] swallows
    // its own failures, so this future never needs a catch of its own.
    final bookGameCountsFuture = _probeBookMoves(
      game,
      fens,
      generation: generation,
    );

    final positions = <GameReportPosition>[];
    final evaluatedPositions = <String, GameReportPosition>{};
    try {
      // Pass 1: single PV for every position. Graph, accuracy, and loss labels
      // only need PV1. MultiPV-3-everywhere was the main desktop slowdown vs
      // mobile (mobile does MultiPV 1 first, then MultiPV only where praise
      // labels need an alternative).
      for (var i = 0; i < fens.length; i++) {
        if (_disposed || generation != _generation) return;
        final fen = fens[i];
        final terminal = terminalGameReportPosition(fen);
        late final GameReportPosition position;
        if (terminal != null) {
          position = terminal;
        } else {
          final reused = evaluatedPositions[fen];
          if (reused != null) {
            position = reused;
          } else {
            position = await _evaluateWithPreemptRetry(
              fen,
              generation: generation,
              depth: reportDepth,
              multiPv: 1,
              completedPositions: i,
              totalPositions: primaryAndRefineUnits,
              progress: (i + 0.5) / primaryAndRefineUnits,
              message: 'Analyzing position ${i + 1} of ${fens.length}',
            );
            evaluatedPositions[fen] = position;
          }
        }
        if (_disposed || generation != _generation) return;
        positions.add(position);
        final done = i + 1;
        _reportProgress(
          generation: generation,
          progress: done / primaryAndRefineUnits,
          completedPositions: done,
          totalPositions: primaryAndRefineUnits,
          message: 'Analyzing position $done of ${fens.length}',
        );
      }

      // Pass 2: MultiPV only where Best / Great / Brilliant need an alternative
      // line. Bad moves keep their cheap PV1 eval.
      final winPercentages = positions
          .map((position) => gameReportWinPercentage(position.bestLine))
          .toList(growable: false);
      final refinedPositions = <String, GameReportPosition>{};
      for (var moveIndex = 0; moveIndex < totalMoves; moveIndex++) {
        if (_disposed || generation != _generation) return;
        final completedBefore = fens.length + moveIndex;
        final needsRefinement = gameReportMoveNeedsMultiPv(
          index: moveIndex,
          game: game,
          positions: positions,
          winPercentages: winPercentages,
        );
        if (needsRefinement) {
          final fen = fens[moveIndex];
          final reused = refinedPositions[fen];
          late final GameReportPosition refined;
          if (reused != null) {
            refined = reused;
          } else {
            refined = await _evaluateWithPreemptRetry(
              fen,
              generation: generation,
              depth: reportDepth,
              multiPv: reportMultiPv,
              completedPositions: completedBefore,
              totalPositions: primaryAndRefineUnits,
              progress: (completedBefore + 0.5) / primaryAndRefineUnits,
              message:
                  'Refining move ${moveIndex + 1} of $totalMoves',
            );
            refinedPositions[fen] = refined;
          }
          positions[moveIndex] = refined;
        }
        final done = completedBefore + 1;
        _reportProgress(
          generation: generation,
          progress: done / primaryAndRefineUnits,
          completedPositions: done,
          totalPositions: primaryAndRefineUnits,
          message: 'Refining move ${moveIndex + 1} of $totalMoves',
        );
      }

      // Pass 3: deeper !! verify only for candidates (usually few or none).
      final refinedWinPct = positions
          .map((position) => gameReportWinPercentage(position.bestLine))
          .toList(growable: false);
      final brilliantCandidates = <int>[];
      for (var moveIndex = 0; moveIndex < totalMoves; moveIndex++) {
        if (isBrilliantCandidate(
          index: moveIndex,
          game: game,
          positions: positions,
          winPercentages: refinedWinPct,
        )) {
          brilliantCandidates.add(moveIndex);
        }
      }
      for (var c = 0; c < brilliantCandidates.length; c++) {
        if (_disposed || generation != _generation) return;
        final moveIndex = brilliantCandidates[c];
        final fen = fens[moveIndex];
        final deep = await _evaluateWithPreemptRetry(
          fen,
          generation: generation,
          depth: brilliantDepth,
          multiPv: brilliantMultiPv,
          completedPositions: primaryAndRefineUnits,
          totalPositions: primaryAndRefineUnits,
          progress:
              0.92 +
              0.08 * (c + 0.5) / math.max(1, brilliantCandidates.length),
          message:
              'Verifying brilliant candidate ${c + 1} of ${brilliantCandidates.length}',
        );
        if (_disposed || generation != _generation) return;
        positions[moveIndex] = deep;
        // Keep MultiPV on the after-position so the next move's alternatives
        // are not clobbered by a multiPv:1 overwrite.
        final afterFen = fens[moveIndex + 1];
        if (terminalGameReportPosition(afterFen) == null) {
          final deepAfter = await _evaluateWithPreemptRetry(
            afterFen,
            generation: generation,
            depth: brilliantDepth,
            multiPv: brilliantMultiPv,
            completedPositions: primaryAndRefineUnits,
            totalPositions: primaryAndRefineUnits,
            progress:
                0.92 +
                0.08 * (c + 1) / math.max(1, brilliantCandidates.length),
            message:
                'Verifying brilliant candidate ${c + 1} of ${brilliantCandidates.length}',
          );
          if (_disposed || generation != _generation) return;
          positions[moveIndex + 1] = deepAfter;
        }
      }

      final report = buildGameAnalysisReport(
        game: game,
        fingerprint: fingerprint,
        positions: positions,
        whiteRating: whiteRating,
        blackRating: blackRating,
        bookGameCounts: await bookGameCountsFuture,
      );
      if (_disposed || generation != _generation) return;
      _setState(
        GameReportState(
          status: GameReportStatus.completed,
          progress: 1,
          completedPositions: primaryAndRefineUnits,
          totalPositions: primaryAndRefineUnits,
          report: report,
        ),
      );
    } on StockfishUnavailableException catch (error) {
      if (generation != _generation) return;
      _fail('Stockfish is unavailable: $error');
    } catch (error) {
      if (generation != _generation) return;
      _fail('Game analysis failed: $error');
    }
  }

  /// Walks the game from move one asking how many database games played each
  /// move, and keeps every answer it gets.
  ///
  /// Copied from mobile so both apps call the same moves theory. Each ply is
  /// judged on its own count — a move with [kBookMoveMinGames] or more games is
  /// theory, whatever the ply before it did. Move orders dip out of the
  /// database and transpose straight back into a main line, and the board's own
  /// opening explorer counts those transpositions, so a single quiet ply must
  /// not close the book on everything after it. The walk stops only once theory
  /// is properly gone: [kBookProbeDryStreak] plies in a row below the
  /// threshold, or the [kBookProbeMaxPlies] runaway guard.
  ///
  /// Lookups go out [kBookProbeConcurrency] at a time. The walk is collected
  /// after the Stockfish passes, which take minutes, so this is about not
  /// opening a burst of connections rather than about latency.
  ///
  /// The tree is an enhancement, never a dependency: a failed lookup leaves
  /// that ply unknown rather than failing the report.
  Future<List<int?>> _probeBookMoves(
    ChessGame game,
    List<String> fens, {
    required int generation,
  }) async {
    final counts = List<int?>.filled(game.mainline.length, null);
    final lookup = _bookLookup;
    if (lookup == null) return counts;

    // The gamebase infers a position's ply from the FEN's side-to-move and
    // fullmove number. A game set up from a custom position carries counters
    // that describe that position, not a real opening, so every lookup would be
    // answering a question about the wrong ply. Such a game has no book by
    // definition — skip the walk rather than spend requests misaddressing it.
    if (game.startingFen != kInitialFEN) return counts;

    final limit = math.min(game.mainline.length, kBookProbeMaxPlies);
    final line = game.mainline
        .map((move) => move.uci)
        .toList(growable: false);
    // The engine passes normally outlast this walk, but a stalled database must
    // not be what holds a finished report open. Whatever theory was resolved
    // before the budget ran out is kept.
    final elapsed = Stopwatch()..start();
    var dryStreak = 0;

    for (var start = 0; start < limit; start += kBookProbeConcurrency) {
      if (_disposed || generation != _generation) return counts;
      if (elapsed.elapsed > kBookProbeBudget) return counts;
      final end = math.min(start + kBookProbeConcurrency, limit);
      final wave = await Future.wait<int?>([
        for (var i = start; i < end; i++)
          _bookGameCount(lookup, fens[i], line[i], line.sublist(0, i)),
      ]);
      if (_disposed || generation != _generation) return counts;
      for (var offset = 0; offset < wave.length; offset++) {
        final total = wave[offset];
        counts[start + offset] = total;
        // An unknown answer counts as dry: it is not evidence of theory, and a
        // database that has stopped answering should end the walk, not spend
        // the whole budget timing out ply after ply.
        if (total == null || total < kBookMoveMinGames) {
          dryStreak++;
        } else {
          dryStreak = 0;
        }
      }
      if (dryStreak >= kBookProbeDryStreak) return counts;
    }
    return counts;
  }

  /// One opening lookup, resolving to null on timeout or failure so a flaky
  /// database costs one unknown ply instead of the whole report.
  Future<int?> _bookGameCount(
    GameReportBookLookup lookup,
    String fen,
    String uci,
    List<String> path,
  ) async {
    try {
      return await lookup(fen, uci, path).timeout(kBookLookupTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<GameReportPosition> _evaluateWithPreemptRetry(
    String fen, {
    required int generation,
    required int depth,
    required int multiPv,
    required int completedPositions,
    required int totalPositions,
    required double progress,
    required String message,
  }) async {
    while (true) {
      if (_disposed || generation != _generation) {
        throw const _ReportPositionPreempted();
      }
      try {
        return await _evaluate(
          fen,
          depth: depth,
          multiPv: multiPv,
          ownerId: _ownerId,
          onProgress: (reached, knodes) {
            if (knodes <= 0) return;
            final within = 1 - 1 / (1 + knodes / reportKnodeReference);
            _reportProgress(
              generation: generation,
              progress: (progress + 0.02 * within).clamp(0.0, 0.99),
              completedPositions: completedPositions,
              totalPositions: totalPositions,
              message: message,
            );
          },
        );
      } on _ReportPositionPreempted {
        if (_disposed || generation != _generation) {
          throw const _ReportPositionPreempted();
        }
        _reportProgress(
          generation: generation,
          progress: _state.progress,
          completedPositions: completedPositions,
          totalPositions: totalPositions,
          message: 'Waiting for live position analysis…',
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<GameReportPosition> _evaluate(
    String fen, {
    required int depth,
    required int multiPv,
    required String ownerId,
    void Function(int reachedDepth, int knodes)? onProgress,
  }) async {
    final customEvaluator = _evaluator;
    final result =
        customEvaluator != null
            ? await customEvaluator(
              fen,
              depth: depth,
              multiPv: multiPv,
              ownerId: ownerId,
              onProgress: onProgress,
            )
            : await _stockfish.evaluatePosition(
              fen,
              depth: depth,
              maxDepth: depth,
              multiPV: multiPv,
              // Report searches are background work. Live board analysis must
              // remain responsive and may preempt this job; the caller retries
              // the same report position when that happens.
              isCurrentPosition: false,
              allowCache: true,
              ownerId: ownerId,
              onDepthUpdate: onProgress,
            );
    if (result.isCancelled) {
      throw const _ReportPositionPreempted();
    }
    final lines = <GameReportLine>[
      for (final pv in result.pvs)
        if (pv.moves.trim().isNotEmpty)
          GameReportLine(
            moves: List<String>.unmodifiable(
              pv.moves
                  .trim()
                  .split(RegExp(r'\s+'))
                  .where((move) => move.isNotEmpty),
            ),
            depth: result.depth,
            centipawns: pv.isMate ? null : pv.cp,
            mate: pv.isMate ? pv.mate : null,
          ),
    ];
    if (lines.isEmpty) {
      throw StateError('Stockfish returned no principal variation');
    }
    return GameReportPosition(fen: fen, lines: List.unmodifiable(lines));
  }

  void _fail(String message) {
    _setState(
      GameReportState(status: GameReportStatus.failed, message: message),
    );
  }

  /// Pushes a running-progress update. Refuses to move the bar backwards and
  /// drops only exact-duplicate writes, so the bar streams forward as fast as
  /// the engine reports while ignoring node callbacks that arrive after a
  /// cancel/supersede.
  void _reportProgress({
    required int generation,
    required double progress,
    required int completedPositions,
    required int totalPositions,
    required String message,
  }) {
    if (_disposed || generation != _generation) return;
    final nextProgress = math.max(progress, _state.progress);
    final advanced = nextProgress > _state.progress;
    if (!advanced && message == _state.message) return;
    _setState(
      GameReportState(
        status: GameReportStatus.running,
        progress: nextProgress,
        completedPositions: completedPositions,
        totalPositions: totalPositions,
        message: message,
      ),
    );
  }

  void _setState(GameReportState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_stockfish.cancelEvaluationsForOwner(_ownerId));
    super.dispose();
  }
}

class _ReportPositionPreempted implements Exception {
  const _ReportPositionPreempted();
}

String gameReportFingerprint(ChessGame game) =>
    '${game.startingFen}|${game.mainline.map((move) => move.uci).join(' ')}';

List<String> gameReportFens(ChessGame game) => List<String>.unmodifiable([
  game.startingFen,
  ...game.mainline.map((move) => move.fen),
]);

GameReportPosition? terminalGameReportPosition(String fen) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    if (!position.isGameOver) return null;
    if (position.isCheckmate) {
      final whiteWon = position.turn == Side.black;
      return GameReportPosition(
        fen: fen,
        lines: [
          GameReportLine(moves: const [], depth: 0, mate: whiteWon ? 1 : -1),
        ],
      );
    }
    return GameReportPosition(
      fen: fen,
      lines: const [GameReportLine(moves: [], depth: 0, centipawns: 0)],
    );
  } catch (_) {
    return null;
  }
}

double gameReportWinPercentage(GameReportLine line) {
  final mate = line.mate;
  if (mate != null) return mate > 0 ? 100 : 0;
  final cp = (line.centipawns ?? 0).clamp(-1000, 1000);
  final winChances = 2 / (1 + math.exp(-0.00368208 * cp)) - 1;
  return 50 + 50 * winChances;
}

GameAnalysisReport buildGameAnalysisReport({
  required ChessGame game,
  required String fingerprint,
  required List<GameReportPosition> positions,
  int? whiteRating,
  int? blackRating,
  /// Database game count per move index, or null where it was not looked up.
  List<int?>? bookGameCounts,
}) {
  if (positions.length != game.mainline.length + 1) {
    throw ArgumentError('A report needs one evaluation per game position');
  }
  final winPercentages = positions
      .map((position) => gameReportWinPercentage(position.bestLine))
      .toList(growable: false);
  final moves = <GameReportMove>[];
  // Sequential: some tags depend on the previous half-move's classification.
  GameMoveClassification? previousClassification;
  for (var i = 0; i < game.mainline.length; i++) {
    final move = game.mainline[i];
    final before = positions[i];
    final after = positions[i + 1];
    final classification = classifyGameReportMove(
      index: i,
      game: game,
      positions: positions,
      winPercentages: winPercentages,
      previousMoveClassification: previousClassification,
      bookGameCount:
          bookGameCounts != null && i < bookGameCounts.length
              ? bookGameCounts[i]
              : null,
    );
    previousClassification = classification;
    moves.add(
      GameReportMove(
        ply: i + 1,
        san: move.san,
        uci: move.uci,
        isWhite: move.turn == ChessColor.white,
        classification: classification,
        evaluation: after.bestLine,
        bestAlternative: _bestAlternative(before, move.uci),
      ),
    );
  }
  final accuracy = computeGameReportAccuracy(winPercentages);
  final ratings = computeGameReportEstimatedRatings(
    positions,
    whiteRating: whiteRating,
    blackRating: blackRating,
  );
  return GameAnalysisReport(
    fingerprint: fingerprint,
    positions: List.unmodifiable(positions),
    moves: List.unmodifiable(moves),
    whiteAccuracy: accuracy.white,
    blackAccuracy: accuracy.black,
    whiteEstimatedRating: ratings?.white,
    blackEstimatedRating: ratings?.black,
    generatedAt: DateTime.now(),
  );
}

String? _bestAlternative(GameReportPosition position, String playedMove) {
  for (final line in position.lines) {
    if (line.moves.isNotEmpty && line.moves.first != playedMove) {
      return line.moves.first;
    }
  }
  return null;
}

/// Whether a move needs MultiPV refinement (PV1 vs PV2 for specials / Best).
bool gameReportMoveNeedsMultiPv({
  required int index,
  required ChessGame game,
  required List<GameReportPosition> positions,
  required List<double> winPercentages,
}) {
  final move = game.mainline[index];
  final before = positions[index];
  final isWhite = move.turn == ChessColor.white;
  final moverChange =
      (winPercentages[index + 1] - winPercentages[index]) * (isWhite ? 1 : -1);
  final playedIsBest =
      before.bestLine.moves.isNotEmpty &&
      before.bestLine.moves.first == move.uci;
  return playedIsBest || moverChange >= -2;
}

/// Classifies a mainline move into our [GameMoveClassification] set.
///
/// Two halves, deliberately kept apart. The praise — Brilliant, Great, Best and
/// Book — is ours, and it reasons in win-percentage points from
/// [gameReportWinPercentage] plus board facts. The damage — `?!`, `?`, `??` — is
/// lichess's, judged in winning chances by [lichessJudgementForReportMove], with
/// Missed Win as the one label layered over it. Ordinary accurate play returns
/// null.
GameMoveClassification? classifyGameReportMove({
  required int index,
  required ChessGame game,
  required List<GameReportPosition> positions,
  required List<double> winPercentages,
  GameMoveClassification? previousMoveClassification,
  int? bookGameCount,
}) => applyBookMoveOverride(
  _classifyGameReportMoveCore(
    index: index,
    game: game,
    positions: positions,
    winPercentages: winPercentages,
    previousMoveClassification: previousMoveClassification,
  ),
  bookGameCount,
);

/// Replaces a non-damaging label with Book when the database has seen the move
/// often enough for it to be theory.
///
/// Theory is not a decision the player found at the board, so it earns no
/// praise — Brilliant, Great and Best all give way. Errors do not: a popular
/// move can still be a trap a hundred players have fallen into, so Inaccuracy,
/// Mistake, Blunder and Missed Win always outrank Book.
GameMoveClassification? applyBookMoveOverride(
  GameMoveClassification? classification,
  int? bookGameCount,
) {
  if (bookGameCount == null || bookGameCount < kBookMoveMinGames) {
    return classification;
  }
  if (classification != null && classification.isNegative) return classification;
  return GameMoveClassification.bookMove;
}

GameMoveClassification? _classifyGameReportMoveCore({
  required int index,
  required ChessGame game,
  required List<GameReportPosition> positions,
  required List<double> winPercentages,
  GameMoveClassification? previousMoveClassification,
}) {
  final move = game.mainline[index];
  final before = positions[index];
  final isWhite = move.turn == ChessColor.white;
  final beforeWin = winPercentages[index];
  final afterWin = winPercentages[index + 1];

  // Mover ΔWin% (pp). Negative = lost winning chances.
  var moverChange = (afterWin - beforeWin) * (isWhite ? 1 : -1);

  // Prefer MultiPV estimate of the played candidate when present (stable under
  // shallow mobile search).
  for (final line in before.lines) {
    if (line.moves.isEmpty || line.moves.first != move.uci) continue;
    final lineWin = gameReportWinPercentage(line);
    final lineChange = (lineWin - beforeWin) * (isWhite ? 1 : -1);
    moverChange = math.max(moverChange, lineChange);
    break;
  }

  final playedIsBest =
      before.bestLine.moves.isNotEmpty &&
      before.bestLine.moves.first == move.uci;

  final moverBefore = isWhite ? beforeWin : (100 - beforeWin);
  final moverAfter = isWhite ? afterWin : (100 - afterWin);

  // A single engine line can never support a positive label — they all have to
  // beat an alternative — so the judgment is the whole verdict here.
  if (before.lines.length <= 1) {
    return _missedOrLoss(
      index: index,
      game: game,
      positions: positions,
      moverChange: moverChange,
      moverBefore: moverBefore,
      moverAfter: moverAfter,
      previousMoveClassification: previousMoveClassification,
    );
  }

  final alternatives = before.lines
      .where((line) => line.moves.isNotEmpty && line.moves.first != move.uci)
      .toList(growable: false);
  final alternativeWin = alternatives.isEmpty
      ? null
      : gameReportWinPercentage(alternatives.first);
  final alternativeMoverWin = alternativeWin == null
      ? null
      : (isWhite ? alternativeWin : (100 - alternativeWin));

  // Gap: played result vs next-best path (pp, mover's favour).
  final alternativeGap =
      alternativeWin == null
          ? 0.0
          : (afterWin - alternativeWin) * (isWhite ? 1 : -1);

  final simpleRecapture =
      index > 0 &&
      isSimpleReportRecapture(
        positions[index - 1].fen,
        game.mainline[index - 1].uci,
        move.uci,
      );

  // ── Steps 2–3: board facts and outcome-band context ────────────────────
  // Derived from the FENs alone, so re-tuning the rules below never needs a
  // fresh engine run.
  final facts = describeMove(
    beforeFen: before.fen,
    playedUci: move.uci,
    previousUci: index > 0 ? game.mainline[index - 1].uci : null,
  );

  // Routine and forced moves veto *positive* labels only. They must still fall
  // through to the judgment — an obvious-looking move can be an inaccuracy or
  // worse, and returning "no symbol" here would hide it.
  var positiveLabelsEligible = !facts.isForcedOrRoutine && !simpleRecapture;

  // Routine material recovery: taking a loose or already-committed unit while
  // conceding nothing, in a position the capture does not actually change.
  // Material balance alone is never the test — a deficit can be real
  // compensation — so board evidence is combined with band and win% movement.
  final routineMaterialRecovery =
      facts.isBoardLevelMaterialRecovery &&
      !escapesClearlyLosingBand(
        moverBefore: moverBefore,
        moverAfter: moverAfter,
      ) &&
      outcomeBandFor(moverAfter).index <= outcomeBandFor(moverBefore).index &&
      moverChange < kRoutinePraiseMinWinGainPp;
  if (routineMaterialRecovery) positiveLabelsEligible = false;

  // Praise floor: below it, an ordinary capture, recapture or retreat has to
  // earn its symbol with a real winning-chance gain or by escaping the
  // clearly-losing band.
  //
  // Scoped to Great and Best only, matching the rule as written. It does not
  // currently change Brilliant either way: [verifyBrilliantMove] independently
  // requires the mover to sit near or above equality after the move, so a !!
  // can never reach this band. That also means a genuine *defensive* brilliancy
  // in a losing position is unreachable today — a known gap, tracked separately
  // rather than papered over here.
  var greatAndBestEligible = positiveLabelsEligible;

  // Once the played move and the first real alternative both keep a clearly
  // won position clearly won, their gap is conversion noise rather than a
  // prestigious decision. Brilliant remains separate: an independently
  // verified exceptional idea may still qualify on its own evidence.
  final saturatedWinningConversion =
      moverBefore >= kBandBetterMax &&
      moverAfter >= kBandBetterMax &&
      alternativeMoverWin != null &&
      alternativeMoverWin >= kBandBetterMax;
  if (saturatedWinningConversion) greatAndBestEligible = false;

  // Do not let routine captures inherit the prestige of the tactic that made
  // them possible. A capture can still earn praise in a competitive position,
  // by crossing an outcome band, or by producing a substantial win% gain.
  final beforeBand = outcomeBandFor(moverBefore);
  final afterBand = outcomeBandFor(moverAfter);
  final routineConversionCapture =
      facts.isCapture &&
      beforeBand == afterBand &&
      beforeBand != OutcomeBand.competitive &&
      moverChange < kRoutinePraiseMinWinGainPp;
  if (routineConversionCapture) greatAndBestEligible = false;

  if (moverAfter <= kPositivePraiseWinFloorPp &&
      (facts.isCapture || facts.isRoutineRetreat || facts.isForcedRecapture)) {
    final earnsException =
        moverChange >= kRoutinePraiseMinWinGainPp ||
        escapesClearlyLosingBand(
          moverBefore: moverBefore,
          moverAfter: moverAfter,
        );
    if (!earnsException) greatAndBestEligible = false;
  }

  // ── Steps 4–7: positive labels ─────────────────────────────────────────
  if (positiveLabelsEligible) {
    // Brilliant (!!): engine-best/tied + genuine material investment +
    // multi-ply persistence + exclusions. An immediate one-reply sacrifice
    // alone is not enough — ordinary gambits and accepted pawn offers stay
    // untagged.
    if (verifyBrilliantMove(
      index: index,
      game: game,
      positions: positions,
      winPercentages: winPercentages,
      moverChange: moverChange,
      playedIsBest: playedIsBest,
      alternativeWin: alternativeWin,
      alternativeGap: alternativeGap,
      simpleRecapture: simpleRecapture,
      facts: facts,
    )) {
      return GameMoveClassification.brilliant;
    }

    // Great: near-best — the only reliable move (meaningful MultiPV gap), a
    // decisive outcome swing, engine-top punishment of the opponent's error,
    // a defensive save, or a clean advantage conversion where natural
    // alternatives slip. Defensive saves may still sit under 50% after the
    // move (partial recovery); other paths keep the losing/alt-crushing veto.
    if (greatAndBestEligible &&
        moverChange >= -2 &&
        alternativeWin != null) {
      final defensiveSave = _isDefensiveSave(
        playedIsBest: playedIsBest,
        moverBefore: moverBefore,
        moverAfter: moverAfter,
        alternativeGap: alternativeGap,
      );
      final notLosingOrCrushing = !_isLosingOrAlternateCrushing(
        afterWin: afterWin,
        alternativeWin: alternativeWin,
        isWhite: isWhite,
      );
      if (defensiveSave || notLosingOrCrushing) {
        final onlyGoodMove = alternativeGap >= kGreatOnlyGoodMoveGapPp;
        final outcomeSwing = _hasChangedGameOutcome(
          beforeWin: beforeWin,
          afterWin: afterWin,
          isWhite: isWhite,
          moverChange: moverChange,
        );
        final punishError =
            playedIsBest &&
            (previousMoveClassification == GameMoveClassification.blunder ||
                previousMoveClassification == GameMoveClassification.mistake);
        final advantageConversion = _isAdvantageConversion(
          playedIsBest: playedIsBest,
          moverBefore: moverBefore,
          moverAfter: moverAfter,
          alternativeMoverWin: alternativeMoverWin!,
          alternativeGap: alternativeGap,
        );
        if (defensiveSave ||
            (notLosingOrCrushing &&
                (onlyGoodMove ||
                    outcomeSwing ||
                    punishError ||
                    advantageConversion))) {
          return GameMoveClassification.bestMove;
        }
      }
    }

    // Best: being PV1 is not sufficient on its own. The next playable
    // alternative has to be meaningfully worse, and the position has to still
    // be contested — unless the move is itself a substantial defensive
    // recovery.
    if (greatAndBestEligible && playedIsBest && moverChange >= -2) {
      final band = outcomeBandFor(moverBefore);
      final contested =
          band == OutcomeBand.competitive ||
          band == OutcomeBand.worse ||
          band == OutcomeBand.better;
      final recovers = escapesClearlyLosingBand(
        moverBefore: moverBefore,
        moverAfter: moverAfter,
      );
      final hasMoat =
          alternativeWin == null || alternativeGap >= kBestRequiredPvMoatPp;
      if ((contested || recovers) && hasMoat) {
        return GameMoveClassification.goodMove;
      }
    }
  }

  // ── Steps 8–11 ─────────────────────────────────────────────────────────
  return _missedOrLoss(
    index: index,
    game: game,
    positions: positions,
    moverChange: moverChange,
    moverBefore: moverBefore,
    moverAfter: moverAfter,
    previousMoveClassification: previousMoveClassification,
  );
}

/// Lichess's verdict for mainline move [index] — the sole source of `?!`, `?`
/// and `??`. Null means lichess would leave the move unmarked.
///
/// Both scores come from the engine's first line, White-relative, exactly as
/// `AnalysisBuilder.makeInfos` feeds `Advice`. See [lichessAdvice] for the rules
/// and for the one deviation (lichess measures move one against a fixed +0.15
/// because fishnet never evaluates the starting position; we have that
/// evaluation, so we use it).
LichessJudgement? lichessJudgementForReportMove({
  required int index,
  required ChessGame game,
  required List<GameReportPosition> positions,
}) {
  if (index < 0 || index >= game.mainline.length) return null;
  if (index + 1 >= positions.length) return null;
  final move = game.mainline[index];
  final before = positions[index].bestLine;
  final after = positions[index + 1].bestLine;
  return lichessAdvice(
    previous: EngineScore.fromLine(
      centipawns: before.centipawns,
      mate: before.mate,
    ),
    current: EngineScore.fromLine(
      centipawns: after.centipawns,
      mate: after.mate,
    ),
    moverIsWhite: move.turn == ChessColor.white,
    engineBestUci: before.moves.isEmpty ? null : before.moves.first,
    playedUci: move.uci,
  );
}

/// The negative half of the verdict: lichess's judgment, with ChessEver's
/// decided-outcome amnesty and Missed Win layered on top of it.
///
/// The port remains the source of thresholds and severity. The one deliberate
/// product overlay is that a mover who remains at 77 or higher, or at 23 or
/// lower, on the report's winning-chance scale receives no negative symbol.
/// Those bounds map roughly to ±3.3 and keep conversion noise silent on either
/// side without weakening judgments that change the outcome.
GameMoveClassification? _missedOrLoss({
  required int index,
  required ChessGame game,
  required List<GameReportPosition> positions,
  required double moverChange,
  required double moverBefore,
  required double moverAfter,
  required GameMoveClassification? previousMoveClassification,
}) {
  final retainedDecisiveWin =
      moverBefore >= kDecisiveWinNoErrorFloorPp &&
      moverAfter >= kDecisiveWinNoErrorFloorPp;
  final retainedDecisiveLoss =
      moverBefore <= kDecisiveLossNoErrorCeilingPp &&
      moverAfter <= kDecisiveLossNoErrorCeilingPp;
  if (retainedDecisiveWin || retainedDecisiveLoss) {
    return null;
  }

  final judgement = lichessJudgementForReportMove(
    index: index,
    game: game,
    positions: positions,
  );
  if (judgement == null) return null;

  // ── Missed Win ─────────────────────────────────────────────────────────
  // Ours, not lichess's, and deliberately gated behind a judgment: it only ever
  // *renames* an error lichess already found, so the set of moves carrying a
  // negative symbol stays exactly lichess's set. A missed conversion after the
  // opponent's blunder, then throwing a clear win outright.
  if (previousMoveClassification == GameMoveClassification.blunder &&
      moverChange < -5 &&
      moverBefore >= 60) {
    return GameMoveClassification.missedWin;
  }
  if (moverBefore >= 75 && moverAfter <= 55 && moverChange <= -15) {
    return GameMoveClassification.missedWin;
  }

  return switch (judgement) {
    LichessJudgement.inaccuracy => GameMoveClassification.inaccuracy,
    LichessJudgement.mistake => GameMoveClassification.mistake,
    LichessJudgement.blunder => GameMoveClassification.blunder,
  };
}

/// Losing after the move, or the unplayed line was already a forced win.
bool _isLosingOrAlternateCrushing({
  required double afterWin,
  required double alternativeWin,
  required bool isWhite,
}) {
  final losing = isWhite ? afterWin < 50 : afterWin > 50;
  final altCrushing = isWhite ? alternativeWin > 97 : alternativeWin < 3;
  return losing || altCrushing;
}

/// Crossed the 50% line with a ≥10pp gain for the mover.
bool _hasChangedGameOutcome({
  required double beforeWin,
  required double afterWin,
  required bool isWhite,
  required double moverChange,
}) {
  if (moverChange <= 10) return false;
  return (beforeWin < 50 && afterWin > 50) ||
      (beforeWin > 50 && afterWin < 50);
}

/// Near-best resource that lifts the mover out of a lost or clearly-worse
/// position while alternatives remain meaningfully inferior.
///
/// Stronger than Best's "recovers" path: requires engine-top play plus a
/// gap under the Great only-reliable bar so ordinary defensive Best moves
/// stay ★ rather than !.
bool _isDefensiveSave({
  required bool playedIsBest,
  required double moverBefore,
  required double moverAfter,
  required double alternativeGap,
}) {
  if (!playedIsBest) return false;
  if (alternativeGap < kGreatSupportingPathMinGapPp) return false;
  final beforeBand = outcomeBandFor(moverBefore);
  final afterBand = outcomeBandFor(moverAfter);
  final savedFromLosing = escapesClearlyLosingBand(
    moverBefore: moverBefore,
    moverAfter: moverAfter,
  );
  final climbedFromWorse =
      beforeBand == OutcomeBand.worse &&
      afterBand.index >= OutcomeBand.competitive.index &&
      (moverAfter - moverBefore) > kBandHysteresisPp;
  return savedFromLosing || climbedFromWorse;
}

/// Engine-top conversion that keeps a real advantage when the natural
/// alternative would surrender it (band drop with a supporting MultiPV gap).
bool _isAdvantageConversion({
  required bool playedIsBest,
  required double moverBefore,
  required double moverAfter,
  required double alternativeMoverWin,
  required double alternativeGap,
}) {
  if (!playedIsBest) return false;
  if (alternativeGap < kGreatSupportingPathMinGapPp) return false;
  final beforeBand = outcomeBandFor(moverBefore);
  final afterBand = outcomeBandFor(moverAfter);
  if (beforeBand.index < OutcomeBand.better.index) return false;
  if (afterBand.index < OutcomeBand.better.index) return false;
  return outcomeBandFor(alternativeMoverWin).index < OutcomeBand.better.index;
}

// ── Brilliant (!!) high-precision path ─────────────────────────────────────

/// Max mover win% loss (pp) for a !! candidate / verified brilliant.
///
/// A Brilliant has to be the engine's move: within one percentage point of PV1.
const double kBrilliantMaxLossPp = 1;

/// Database games a move needs before it counts as theory rather than a choice
/// the player made over the board.
const int kBookMoveMinGames = 10;

/// How far into a game the opening tree is consulted at all — a runaway guard,
/// not the real stopping rule (that is [kBookProbeDryStreak]), so a pathological
/// line cannot spend a lookup per move across a 150-move game.
///
/// The old ceiling was twenty plies, tied to the gamebase materialised view.
/// That view is only the *fast* path: handed the move line, the backend keeps
/// answering far deeper — a Marshall main line still returns 22 games at ply 36
/// — and real theory routinely runs past move fifteen, so the view's depth was
/// cutting off book long before book actually ended. Sixty plies clears any
/// real book line while still bounding the work.
const int kBookProbeMaxPlies = 60;

/// Plies in a row below [kBookMoveMinGames] that end the walk.
///
/// Deliberately not a contiguity rule. A move order can leave the database for
/// a ply and transpose straight back into a main line, and that move is still
/// theory, so one quiet ply must not close the book. Six is long enough for any
/// real transposition and short enough that a middlegame costs six spare
/// lookups before the walk gives up.
const int kBookProbeDryStreak = 6;

/// Lookups in flight at once.
const int kBookProbeConcurrency = 4;

/// Ceiling on one opening lookup, and on the walk as a whole.
///
/// A cold position at the edge of the cached view is served by a table scan —
/// measured between four and six and a half seconds — so the old four-second
/// ceiling timed out exactly where theory gets interesting. The counts are
/// collected after the engine passes, which take minutes, so neither number is
/// on the report's critical path.
const Duration kBookLookupTimeout = Duration(seconds: 12);
const Duration kBookProbeBudget = Duration(seconds: 90);

/// PV moat (pp) the played move needs over the first unplayed alternative
/// before being called Best. Being PV1 is not on its own a distinction.
///
/// Tuned so accurate, contested PV1 choices earn ★ without requiring the
/// near-only-move gap reserved for Great.
const double kBestRequiredPvMoatPp = 2.5;

/// MultiPV gap (pp, mover favour) for Great via the only-reliable-move path.
/// Alternatives this far worse mean the played move is the only practical choice.
const double kGreatOnlyGoodMoveGapPp = 7.5;

/// Supporting-path floor for Great defensive-save and advantage-conversion.
/// Below the only-reliable bar so those paths need their band evidence as well.
const double kGreatSupportingPathMinGapPp = 5;

/// Mover winning chance (pp) below which ordinary captures, recaptures and
/// retreats no longer earn a positive symbol by default.
const double kPositivePraiseWinFloorPp = 25;

/// The winning-chance gain (pp) that buys a routine-looking move its symbol
/// back, at any point on the scale.
const double kRoutinePraiseMinWinGainPp = 10;

/// Human-facing Game Report floor for a retained decisive win. The report's
/// Stockfish-to-win curve maps +3.3 to about 77.1%, so 77% intentionally treats
/// +7, +4 and +3.3 as the same won outcome for negative-symbol purposes.
const double kDecisiveWinNoErrorFloorPp = 77;

/// Mover-relative mirror of [kDecisiveWinNoErrorFloorPp]. A move that remains
/// below this ceiling stays decisively lost and receives no evaluation-based
/// negative symbol merely for shortening the conversion to mate.
const double kDecisiveLossNoErrorCeilingPp =
    100 - kDecisiveWinNoErrorFloorPp;

/// Minimum MultiPV gap (played vs next-best, mover pp) for non-unique best.
const double kBrilliantMinAlternativeGapPp = 8;

/// Early plies treated as opening/book for !! exclusion (half-moves).
const int kBrilliantOpeningPlyLimit = 10;

/// Minimum engine continuation length for multi-ply persistence.
const int kBrilliantMinContinuationPlies = 3;

/// Cheap prefilter: worth spending a deeper MultiPV pass on this move.
bool isBrilliantCandidate({
  required int index,
  required ChessGame game,
  required List<GameReportPosition> positions,
  required List<double> winPercentages,
}) {
  if (index < 0 || index >= game.mainline.length) return false;
  if (index + 1 >= positions.length || index + 1 >= winPercentages.length) {
    return false;
  }
  final move = game.mainline[index];
  if (move.san.contains('=')) return false;
  if (isReportLikelyOpeningBookForBrilliant(index, game)) return false;

  final before = positions[index];
  final after = positions[index + 1];
  final isWhite = move.turn == ChessColor.white;
  final beforeWin = winPercentages[index];
  final afterWin = winPercentages[index + 1];
  if (isReportCompletelyDecidedForBrilliant(
    beforeWin: beforeWin,
    afterWin: afterWin,
    isWhite: isWhite,
  )) {
    return false;
  }

  final moverChange = (afterWin - beforeWin) * (isWhite ? 1 : -1);
  if (moverChange < -2) return false;

  final playedIsBest =
      before.bestLine.moves.isNotEmpty &&
      before.bestLine.moves.first == move.uci;
  if (!playedIsBest && moverChange < -kBrilliantMaxLossPp) return false;

  if (index > 0 &&
      isSimpleReportRecapture(
        positions[index - 1].fen,
        game.mainline[index - 1].uci,
        move.uci,
      )) {
    return false;
  }

  return isMeaningfulBrilliantInvestment(
    before.fen,
    move.uci,
    after.bestLine.moves,
  );
}

/// Full high-confidence !! gate used by [classifyGameReportMove].
///
/// Prefer fail-closed (false) over awarding !! on ordinary gambits.
bool verifyBrilliantMove({
  required int index,
  required ChessGame game,
  required List<GameReportPosition> positions,
  required List<double> winPercentages,
  required double moverChange,
  required bool playedIsBest,
  required double? alternativeWin,
  required double alternativeGap,
  required bool simpleRecapture,
  MovePositionFacts? facts,
}) {
  if (index < 0 || index >= game.mainline.length) return false;
  if (index + 1 >= positions.length || index + 1 >= winPercentages.length) {
    return false;
  }
  final move = game.mainline[index];
  final before = positions[index];
  final after = positions[index + 1];
  final isWhite = move.turn == ChessColor.white;
  final beforeWin = winPercentages[index];
  final afterWin = winPercentages[index + 1];

  // ── Hard exclusions ────────────────────────────────────────────────────
  if (move.san.contains('=')) return false;
  if (simpleRecapture) return false;
  // A forced reply, a recapture or an attacked piece stepping aside is never
  // Brilliant, however well the engine scores it.
  final moveFacts =
      facts ??
      describeMove(
        beforeFen: before.fen,
        playedUci: move.uci,
        previousUci: index > 0 ? game.mainline[index - 1].uci : null,
      );
  if (moveFacts.isForcedOrRoutine) return false;
  if (isReportLikelyOpeningBookForBrilliant(index, game)) return false;
  if (isReportCompletelyDecidedForBrilliant(
    beforeWin: beforeWin,
    afterWin: afterWin,
    isWhite: isWhite,
  )) {
    return false;
  }
  if (alternativeWin != null &&
      _isLosingOrAlternateCrushing(
        afterWin: afterWin,
        alternativeWin: alternativeWin,
        isWhite: isWhite,
      )) {
    return false;
  }
  final losing = isWhite ? afterWin < 48 : afterWin > 52;
  if (losing) return false;

  // ── Engine-best or effectively tied ────────────────────────────────────
  final tiedForBest = moverChange >= -kBrilliantMaxLossPp;
  if (!playedIsBest && !tiedForBest) return false;
  if (moverChange < -kBrilliantMaxLossPp) return false;

  // Need MultiPV alternatives for prestige; single-line "only move" is not !!.
  if (before.lines.length < 2 || alternativeWin == null) return false;

  // Clear edge over ordinary alternatives, or a uniquely strong only-move.
  final onlyMoveResource = alternativeGap >= 12;
  final meaningfulGap = alternativeGap >= kBrilliantMinAlternativeGapPp;
  if (!onlyMoveResource && !meaningfulGap) return false;

  // ── Material / tactical investment ─────────────────────────────────────
  if (!isMeaningfulBrilliantInvestment(
    before.fen,
    move.uci,
    after.bestLine.moves,
  )) {
    return false;
  }

  // ── Multi-ply persistence (not only the immediate reply) ───────────────
  if (!brilliantContinuationPersists(
    beforeFen: before.fen,
    playedUci: move.uci,
    continuationAfterMove: after.bestLine.moves,
    afterWin: afterWin,
    isWhite: isWhite,
  )) {
    return false;
  }

  return true;
}

/// Opening / book exclusion for !!: early quiet development and gambit territory.
///
/// Sparse FENs (endgame studies / crafted boards) are not treated as opening
/// just because the half-move index is low.
bool isReportLikelyOpeningBookForBrilliant(int index, ChessGame game) {
  if (index >= kBrilliantOpeningPlyLimit) return false;
  if (_sidePieceCount(game.startingFen) <= 12) return false;
  final move = game.mainline[index];
  final san = move.san;
  // Quiet early moves in a full opening are book-like.
  final tactical = san.contains('x') || san.contains('+') || san.contains('#');
  if (!tactical) return true;
  // Early pawn gambits (even with captures) are not prestigious !! material.
  try {
    final beforeFen =
        index == 0 ? game.startingFen : game.mainline[index - 1].fen;
    final pos = Chess.fromSetup(Setup.parseFen(beforeFen));
    final played = NormalMove.fromUci(move.uci);
    if (!pos.isLegal(played)) return true;
    final piece = pos.board.pieceAt(played.from);
    if (piece?.role == Role.pawn) return true;
  } catch (_) {
    return true;
  }
  return false;
}

int _sidePieceCount(String fen) {
  try {
    final pos = Chess.fromSetup(Setup.parseFen(fen));
    var n = 0;
    for (final sq in Square.values) {
      if (pos.board.pieceAt(sq) != null) n++;
    }
    return n;
  } catch (_) {
    return 32;
  }
}

/// Completely decided positions: !! has no prestige value.
bool isReportCompletelyDecidedForBrilliant({
  required double beforeWin,
  required double afterWin,
  required bool isWhite,
}) {
  final moverBefore = isWhite ? beforeWin : (100 - beforeWin);
  final moverAfter = isWhite ? afterWin : (100 - afterWin);
  return moverBefore >= 92 ||
      moverBefore <= 8 ||
      moverAfter >= 95 ||
      moverAfter <= 5;
}

/// Meaningful material investment for !! (not routine development / exchanges).
///
/// Accepts only real sacs:
/// - classic immediate piece sacrifice (opponent takes on destination),
///   with invested piece value ≥ 3 (no pawn-only offers);
/// - declined/delayed sac: after the move, the opponent can capture our
///   just-moved piece and a one-exchange SEE is net-negative for us
///   (truly hanging / underprotected — not a protected piece on an attacked
///   square where the trade is equal or better for us).
///
/// Quiet piece moves (e.g. Nc3) are never investments — fail closed.
bool isMeaningfulBrilliantInvestment(
  String fen,
  String playedUci,
  List<String> bestContinuation,
) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final move = NormalMove.fromUci(playedUci);
    if (!position.isLegal(move)) return false;
    final moving = position.board.pieceAt(move.from);
    if (moving == null || moving.role == Role.king) return false;
    final captured = position.board.pieceAt(move.to);
    final invested = _pieceValue(moving.role);
    final immediateGain = captured == null ? 0 : _pieceValue(captured.role);
    // Equal or winning capture is not a sacrifice.
    if (immediateGain >= invested) return false;
    // Pawn-only offers are not !! investment (opening gambits, etc.).
    if (invested < 3) return false;

    final after = position.play(move);
    // Accepted in PV *or* declined: require one-exchange SEE net-negative for
    // us on the destination (true hang / underprotection). Protected pieces
    // taken into a fair recapture (e.g. N on c3 hit by pawn, defended by pawn)
    // do not count as !! material investment.
    //
    // This SEE gate is what enforces "acceptance creates a real material
    // deficit": it requires the mover to end at least a full minor down. That
    // is one step stricter than counting a bare exchange sacrifice, chosen
    // deliberately to favour precision — a missed !! costs less than a wrong
    // one.
    return _isNetHangingPiece(
      after,
      square: move.to,
      owner: moving.color,
    );
  } catch (_) {
    return false;
  }
}

/// One-exchange SEE: opponent takes our piece on [square]; we recapture with
/// the cheapest defender if any. Net < 0 for [owner] ⇒ truly hanging /
/// underprotected (protected equal trades return false).
bool _isNetHangingPiece(
  Position position, {
  required Square square,
  required Side owner,
}) => isNetHangingPiece(position, square: square, owner: owner);

/// Multi-ply persistence: the idea survives several continuation plies.
///
/// Immediate-reply capture alone is not enough — require either:
/// - a long enough PV (≥ [kBrilliantMinContinuationPlies]),
/// - material recovery / continued pressure along that PV, or
/// - a short mate sequence.
bool brilliantContinuationPersists({
  required String beforeFen,
  required String playedUci,
  required List<String> continuationAfterMove,
  required double afterWin,
  required bool isWhite,
  int minPlies = kBrilliantMinContinuationPlies,
}) {
  final moverAfter = isWhite ? afterWin : (100 - afterWin);
  // Position must not collapse for the sacrificer after the move.
  if (moverAfter < 48) return false;

  try {
    Position position = Chess.fromSetup(Setup.parseFen(beforeFen));
    final move = NormalMove.fromUci(playedUci);
    if (!position.isLegal(move)) return false;
    position = position.play(move);

    // Immediate mate after the sac is rare but valid multi-ply "persistence".
    if (position.isCheckmate) return true;

    if (continuationAfterMove.length < minPlies) {
      // Short PV only acceptable if it ends in mate for the sacrificer.
      return _continuationEndsInMateFor(
        position,
        continuationAfterMove,
        side: isWhite ? Side.white : Side.black,
      );
    }

    final materialAfterMove = _materialBalanceWhite(position);
    final sacrificer = isWhite ? Side.white : Side.black;
    // Do NOT count the check from the played move itself as multi-ply
    // persistence — that would mark any checking best-move with a long PV.
    var sawContinuationCheck = false;
    var sacAcceptedInPv = false;
    var materialAfterAcceptance = materialAfterMove;
    var pos = position;
    final dest = move.to;
    final plies = math.min(minPlies, continuationAfterMove.length);
    for (var i = 0; i < plies; i++) {
      final step = NormalMove.fromUci(continuationAfterMove[i]);
      if (!pos.isLegal(step)) return false;
      // First reply captures our sacrificed unit on its destination.
      if (i == 0 && step.to == dest) {
        final victim = pos.board.pieceAt(dest);
        if (victim != null && victim.color == sacrificer) {
          sacAcceptedInPv = true;
        }
      }
      pos = pos.play(step);
      if (i == 0 && sacAcceptedInPv) {
        materialAfterAcceptance = _materialBalanceWhite(pos);
      }
      // Checks only count after the opponent has answered (ply index >= 1).
      if (i >= 1 && pos.isCheck) sawContinuationCheck = true;
      if (pos.isCheckmate) {
        final matingSide = pos.turn == Side.white ? Side.black : Side.white;
        return matingSide == sacrificer;
      }
    }

    final materialLater = _materialBalanceWhite(pos);
    final recoveryDelta =
        isWhite
            ? (materialLater - materialAfterAcceptance)
            : (materialAfterAcceptance - materialLater);
    // Persistence: continued attack after the reply, or material recovery
    // *after the sac was accepted in the PV* — not a quiet PV that never
    // touches the offered piece (materialDelta == 0 for free).
    if (sawContinuationCheck) return true;
    if (sacAcceptedInPv && recoveryDelta >= 0) return true;
    return false;
  } catch (_) {
    return false;
  }
}

bool _continuationEndsInMateFor(
  Position start,
  List<String> ucis, {
  required Side side,
}) {
  try {
    var pos = start;
    for (final uci in ucis) {
      final step = NormalMove.fromUci(uci);
      if (!pos.isLegal(step)) return false;
      pos = pos.play(step);
    }
    if (!pos.isCheckmate) return false;
    final matingSide = pos.turn == Side.white ? Side.black : Side.white;
    return matingSide == side;
  } catch (_) {
    return false;
  }
}

int _materialBalanceWhite(Position position) =>
    reportMaterialBalanceWhite(position);

bool isReportPieceSacrifice(
  String fen,
  String playedUci,
  List<String> bestContinuation,
) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final move = NormalMove.fromUci(playedUci);
    if (!position.isLegal(move)) return false;
    final moving = position.board.pieceAt(move.from);
    if (moving == null || moving.role == Role.king) return false;
    final captured = position.board.pieceAt(move.to);
    final invested = _pieceValue(moving.role);
    final immediateGain = captured == null ? 0 : _pieceValue(captured.role);
    if (immediateGain >= invested || bestContinuation.isEmpty) return false;
    final reply = NormalMove.fromUci(bestContinuation.first);
    final after = position.play(move);
    if (!after.isLegal(reply)) return false;
    final replyCapture = after.board.pieceAt(reply.to);
    return reply.to == move.to &&
        replyCapture != null &&
        _pieceValue(replyCapture.role) >= invested;
  } catch (_) {
    return false;
  }
}

bool isSimpleReportRecapture(
  String fen,
  String previousUci,
  String currentUci,
) {
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final previous = NormalMove.fromUci(previousUci);
    final current = NormalMove.fromUci(currentUci);
    if (!position.isLegal(previous)) return false;
    if (position.board.pieceAt(previous.to) == null) return false;
    final after = position.play(previous);
    return after.isLegal(current) &&
        current.to == previous.to &&
        after.board.pieceAt(current.to) != null;
  } catch (_) {
    return false;
  }
}

int _pieceValue(Role role) => reportPieceValue(role);

({double white, double black}) computeGameReportAccuracy(
  List<double> winPercentages,
) {
  if (winPercentages.length < 2) return (white: 0, black: 0);
  final moveAccuracies = <double>[];
  for (var i = 1; i < winPercentages.length; i++) {
    final loss =
        i.isOdd
            ? math.max(0.0, winPercentages[i - 1] - winPercentages[i])
            : math.max(0.0, winPercentages[i] - winPercentages[i - 1]);
    final raw =
        103.1668100711649 * math.exp(-0.04354415386753951 * loss) -
        3.166924740191411;
    moveAccuracies.add((raw + 1).clamp(0, 100).toDouble());
  }
  final weights = _accuracyWeights(winPercentages);
  return (
    white: _playerAccuracy(moveAccuracies, weights, even: true),
    black: _playerAccuracy(moveAccuracies, weights, even: false),
  );
}

List<double> _accuracyWeights(List<double> values) {
  final windowSize = (values.length / 10).ceil().clamp(2, 8);
  final half = (windowSize / 2).round();
  return [
    for (var i = 1; i < values.length; i++)
      _standardDeviation(
        i - half < 0
            ? values.take(windowSize).toList()
            : i + half > values.length
            ? values.skip(math.max(0, values.length - windowSize)).toList()
            : values.sublist(i - half, i + half),
      ).clamp(0.5, 12).toDouble(),
  ];
}

double _standardDeviation(List<double> values) {
  if (values.isEmpty) return 0.5;
  final mean = values.reduce((a, b) => a + b) / values.length;
  final variance =
      values.map((value) => math.pow(value - mean, 2)).reduce((a, b) => a + b) /
      values.length;
  return math.sqrt(variance);
}

double _playerAccuracy(
  List<double> accuracies,
  List<double> weights, {
  required bool even,
}) {
  final selected = <double>[];
  final selectedWeights = <double>[];
  for (var i = 0; i < accuracies.length; i++) {
    if (i.isEven == even) {
      selected.add(accuracies[i]);
      selectedWeights.add(weights[i]);
    }
  }
  if (selected.isEmpty) return 0;
  final weightSum = selectedWeights.reduce((a, b) => a + b);
  final weighted =
      [
        for (var i = 0; i < selected.length; i++)
          selected[i] * selectedWeights[i],
      ].reduce((a, b) => a + b) /
      weightSum;
  final harmonic =
      selected.length /
      selected.map((value) => 1 / math.max(value, 10)).reduce((a, b) => a + b);
  return (weighted + harmonic) / 2;
}

({int white, int black})? computeGameReportEstimatedRatings(
  List<GameReportPosition> positions, {
  int? whiteRating,
  int? blackRating,
}) {
  if (positions.length < 3) return null;
  var whiteLoss = 0.0;
  var blackLoss = 0.0;
  var whiteMoves = 0;
  var blackMoves = 0;
  var previous = _boundedCp(positions.first.bestLine);
  for (var i = 1; i < positions.length; i++) {
    final cp = _boundedCp(positions[i].bestLine);
    if (i.isOdd) {
      whiteLoss += math.max(0, previous - cp);
      whiteMoves++;
    } else {
      blackLoss += math.max(0, cp - previous);
      blackMoves++;
    }
    previous = cp;
  }
  if (whiteMoves == 0 || blackMoves == 0) return null;
  return (
    white: _ratingFromCpl(whiteLoss / whiteMoves, whiteRating ?? blackRating),
    black: _ratingFromCpl(blackLoss / blackMoves, blackRating ?? whiteRating),
  );
}

double _boundedCp(GameReportLine line) {
  final mate = line.mate;
  if (mate != null) return mate > 0 ? 1000 : -1000;
  return (line.centipawns ?? 0).clamp(-1000, 1000).toDouble();
}

int _ratingFromCpl(double cpl, int? knownRating) {
  final fromCpl = 3100 * math.exp(-0.01 * cpl);
  if (knownRating == null || knownRating <= 0) return fromCpl.round();
  final expected = -100 * math.log(math.min(knownRating, 3100) / 3100);
  final difference = cpl - expected;
  final adjusted =
      difference > 0
          ? knownRating * math.exp(-0.005 * difference)
          : knownRating / math.exp(0.005 * difference);
  return adjusted.clamp(100, 3500).round();
}
