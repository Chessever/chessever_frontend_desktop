import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';

/// One principal variation, normalized to white perspective.
@immutable
class BoardPv {
  const BoardPv({
    required this.evaluation,
    required this.mate,
    required this.moves,
  });

  /// Pawn-units, white-perspective. ±10 for mate scores so the bar pegs.
  final double evaluation;

  /// Moves to mate, white-perspective; null when not a mate line.
  final int? mate;

  /// Space-separated UCI moves of the principal variation.
  final String moves;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BoardPv &&
            other.evaluation == evaluation &&
            other.mate == mate &&
            other.moves == moves;
  }

  @override
  int get hashCode => Object.hash(evaluation, mate, moves);
}

/// White-perspective evaluation snapshot for the active board position.
///
/// Carries up to `multiPV` lines so the desktop chrome can render every
/// principal variation, not just the best one. The first-PV convenience
/// getters keep `EvaluationBarWidget` and the legacy single-line `EnginePanel`
/// working without changes.
@immutable
class BoardEvalState {
  const BoardEvalState({
    required this.pvs,
    required this.isEvaluating,
    required this.depth,
    this.evaluationOverride,
    this.mateOverride,
    this.statusText,
  });

  /// Initial state — no evaluation yet, search just started.
  const BoardEvalState.evaluating()
    : pvs = const <BoardPv>[],
      isEvaluating = true,
      depth = 0,
      evaluationOverride = null,
      mateOverride = null,
      statusText = null;

  const BoardEvalState.terminal({
    required double evaluation,
    required this.statusText,
    int? mate,
  }) : pvs = const <BoardPv>[],
       isEvaluating = false,
       depth = 0,
       evaluationOverride = evaluation,
       mateOverride = mate;

  final List<BoardPv> pvs;
  final bool isEvaluating;
  final int depth;
  final double? evaluationOverride;
  final int? mateOverride;
  final String? statusText;

  // Convenience getters used by the eval bar and the legacy engine panel.
  double? get evaluation =>
      evaluationOverride ?? (pvs.isEmpty ? null : pvs.first.evaluation);
  int? get mate => mateOverride ?? (pvs.isEmpty ? null : pvs.first.mate);
  String get pvMoves => pvs.isEmpty ? '' : pvs.first.moves;

  BoardEvalState copyWith({
    List<BoardPv>? pvs,
    bool? isEvaluating,
    int? depth,
    double? evaluationOverride,
    int? mateOverride,
    String? statusText,
    bool clearEvaluationOverride = false,
    bool clearMateOverride = false,
    bool clearStatusText = false,
  }) {
    return BoardEvalState(
      pvs: pvs ?? this.pvs,
      isEvaluating: isEvaluating ?? this.isEvaluating,
      depth: depth ?? this.depth,
      evaluationOverride:
          clearEvaluationOverride
              ? null
              : (evaluationOverride ?? this.evaluationOverride),
      mateOverride:
          clearMateOverride ? null : (mateOverride ?? this.mateOverride),
      statusText: clearStatusText ? null : (statusText ?? this.statusText),
    );
  }

  BoardEvalState applySearchUpdate({
    List<BoardPv>? pvs,
    required bool isEvaluating,
    required int depth,
    bool preserveExistingPvsOnDepthRegression = false,
  }) {
    final depthRegressed = depth < this.depth;
    return BoardEvalState(
      pvs:
          preserveExistingPvsOnDepthRegression &&
                  depthRegressed &&
                  this.pvs.isNotEmpty
              ? this.pvs
              : (pvs ?? this.pvs),
      isEvaluating: isEvaluating,
      depth: monotonicSearchDepth(current: this.depth, incoming: depth),
    );
  }
}

@visibleForTesting
int monotonicSearchDepth({required int current, required int incoming}) {
  return incoming > current ? incoming : current;
}

@visibleForTesting
BoardEvalState? terminalBoardEvalStateForFen(String fen) {
  if (fen.trim().isEmpty) return null;
  try {
    final position = Chess.fromSetup(Setup.parseFen(fen));
    if (!position.isGameOver) return null;

    if (position.isCheckmate) {
      final whiteWon = position.turn == Side.black;
      return BoardEvalState.terminal(
        evaluation: whiteWon ? 10.0 : -10.0,
        mate: 0,
        statusText: 'Checkmate',
      );
    }

    final statusText =
        position.isStalemate
            ? 'Draw by stalemate'
            : position.isInsufficientMaterial
            ? 'Draw by insufficient material'
            : position.halfmoves >= 100
            ? 'Draw by 50-move rule'
            : 'Game drawn';
    return BoardEvalState.terminal(evaluation: 0.0, statusText: statusText);
  } catch (_) {
    return null;
  }
}

class BoardEvalNotifier extends StateNotifier<BoardEvalState> {
  BoardEvalNotifier(this.ref, this.fen, this.config)
    : super(const BoardEvalState.evaluating()) {
    // _start mutates the shared depth tracker; keep provider creation side-effect free.
    Timer.run(() {
      if (!mounted) return;
      unawaited(_start());
    });
  }

  final Ref ref;
  final String fen;
  final BoardEvalConfig config;
  static const Duration _minUiUpdateInterval = Duration(milliseconds: 80);
  late final String _ownerId = StockfishSingleton.generateOwnerId(
    'boardEval',
    identityHashCode(this),
  );
  Timer? _uiUpdateTimer;
  DateTime? _lastUiUpdateAt;
  List<BoardPv>? _pendingPvs;
  int? _pendingDepth;
  int _pendingKnodes = 0;
  bool _pendingIsEvaluating = true;
  bool _pendingHasDepthProgress = false;

  Future<void> _start() async {
    if (!mounted) return;
    if (fen.isEmpty || !config.enabled) {
      _clearDepth();
      state = const BoardEvalState(
        pvs: <BoardPv>[],
        isEvaluating: false,
        depth: 0,
      );
      return;
    }
    final terminalState = terminalBoardEvalStateForFen(fen);
    if (terminalState != null) {
      _clearDepth();
      state = terminalState;
      return;
    }
    _clearDepth();
    final settings = config.toEngineSettings();
    final multiPV = settings.multiPvForStockfish();
    final searchDuration = settings.searchDurationFor(
      EngineComponent.principalVariation,
    );
    final maxDepth = settings.maxDepthFor(EngineComponent.principalVariation);

    try {
      final result = await StockfishSingleton().evaluatePosition(
        fen,
        depth: maxDepth,
        maxDepth: maxDepth,
        multiPV: multiPV,
        searchDuration: searchDuration,
        isCurrentPosition: true,
        allowCache: false,
        ownerId: _ownerId,
        onDepthUpdate: _onDepthUpdate,
        onPvUpdate: _onPvUpdate,
      );
      if (!mounted) return;
      _flushPendingSearchUpdate();
      final resultPvs = _toBoardPvs(result.pvs, alreadyWhite: true);
      final nextDepth = monotonicSearchDepth(
        current: state.depth,
        incoming: result.depth,
      );
      _publishDepth(nextDepth, result.knodes);
      // Final result PVs are already white-perspective per the singleton.
      state = state.applySearchUpdate(
        pvs: resultPvs,
        isEvaluating: false,
        depth: result.depth,
        preserveExistingPvsOnDepthRegression: true,
      );
    } catch (_) {
      if (!mounted) return;
      _cancelPendingSearchUpdate();
      state = state.copyWith(isEvaluating: false);
    }
  }

  void _onDepthUpdate(int depth, int knodes) {
    if (!mounted) return;
    _scheduleSearchUpdate(
      depth: depth,
      knodes: knodes,
      isEvaluating: true,
      publishDepth: true,
    );
  }

  void _onPvUpdate(List<Pv> snapshot, int depth) {
    if (!mounted) return;
    _scheduleSearchUpdate(
      pvs: _toBoardPvs(snapshot, alreadyWhite: false),
      depth: depth,
      knodes: 0,
      isEvaluating: true,
      publishDepth: false,
    );
  }

  void _scheduleSearchUpdate({
    List<BoardPv>? pvs,
    required int depth,
    required int knodes,
    required bool isEvaluating,
    required bool publishDepth,
  }) {
    if (!mounted) return;
    if (pvs != null) _pendingPvs = pvs;
    _pendingDepth =
        _pendingDepth == null
            ? depth
            : monotonicSearchDepth(current: _pendingDepth!, incoming: depth);
    if (knodes > 0) _pendingKnodes = knodes;
    _pendingIsEvaluating = isEvaluating;
    _pendingHasDepthProgress = _pendingHasDepthProgress || publishDepth;

    final now = DateTime.now();
    final last = _lastUiUpdateAt;
    if (last == null || now.difference(last) >= _minUiUpdateInterval) {
      _flushPendingSearchUpdate(now: now);
      return;
    }

    _uiUpdateTimer ??= Timer(_minUiUpdateInterval - now.difference(last), () {
      _uiUpdateTimer = null;
      _flushPendingSearchUpdate();
    });
  }

  void _flushPendingSearchUpdate({DateTime? now}) {
    if (!mounted || _pendingDepth == null) return;
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
    final pvs = _pendingPvs;
    final depth = _pendingDepth!;
    final knodes = _pendingKnodes;
    final isEvaluating = _pendingIsEvaluating;
    final hasDepthProgress = _pendingHasDepthProgress;
    _pendingPvs = null;
    _pendingDepth = null;
    _pendingKnodes = 0;
    _pendingIsEvaluating = true;
    _pendingHasDepthProgress = false;
    _lastUiUpdateAt = now ?? DateTime.now();

    final nextDepth = monotonicSearchDepth(
      current: state.depth,
      incoming: depth,
    );
    final nextState = state.applySearchUpdate(
      pvs: pvs,
      isEvaluating: isEvaluating,
      depth: nextDepth,
      preserveExistingPvsOnDepthRegression: true,
    );

    if (nextState.depth == state.depth &&
        nextState.isEvaluating == state.isEvaluating &&
        _boardPvsEqual(nextState.pvs, state.pvs)) {
      return;
    }

    if (hasDepthProgress) {
      _publishDepth(nextDepth, knodes);
    }
    state = nextState;
  }

  void _cancelPendingSearchUpdate() {
    _uiUpdateTimer?.cancel();
    _uiUpdateTimer = null;
    _pendingPvs = null;
    _pendingDepth = null;
    _pendingKnodes = 0;
    _pendingIsEvaluating = true;
    _pendingHasDepthProgress = false;
  }

  void _publishDepth(int depth, int knodes) {
    ref
        .read(engineDepthTrackerProvider.notifier)
        .update(
          component: EngineComponent.principalVariation,
          progress: EngineSearchProgress(
            depth: depth,
            kiloNodes: knodes,
            fenFragment: fen,
          ),
          context: 'desktop board D:$depth',
          allowDecrease: false,
        );
  }

  void _clearDepth() {
    ref
        .read(engineDepthTrackerProvider.notifier)
        .clear(EngineComponent.principalVariation, reason: 'desktop board');
  }

  List<BoardPv> _toBoardPvs(List<Pv> pvs, {required bool alreadyWhite}) {
    final out = <BoardPv>[];
    for (final pv in pvs) {
      if (pv.moves.isEmpty) continue;
      final normalized =
          alreadyWhite
              ? (cp: pv.cp, isMate: pv.isMate, mate: pv.mate)
              : _normalizeToWhite(pv, fen);
      out.add(
        BoardPv(
          evaluation: _toPawns(normalized.cp),
          mate: normalized.isMate ? normalized.mate : null,
          moves: pv.moves,
        ),
      );
    }
    return List<BoardPv>.unmodifiable(out);
  }

  @override
  void dispose() {
    _cancelPendingSearchUpdate();
    // Tear down the in-flight Stockfish job tied to this widget so the engine
    // can move on to the next position immediately rather than burning cycles.
    unawaited(StockfishSingleton().cancelEvaluationsForOwner(_ownerId));
    super.dispose();
  }
}

bool _boardPvsEqual(List<BoardPv> a, List<BoardPv> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

double _toPawns(int cp) {
  // Mate scores are encoded as ±100000 in centipawns by the singleton; pin the
  // bar to ±10 pawns so the visual fills the meter without being absurd.
  if (cp.abs() >= 100000) {
    return cp.isNegative ? -10.0 : 10.0;
  }
  return cp / 100.0;
}

({int cp, bool isMate, int? mate}) _normalizeToWhite(Pv pv, String fen) {
  if (pv.whitePerspective) {
    return (cp: pv.cp, isMate: pv.isMate, mate: pv.mate);
  }
  final parts = fen.split(' ');
  final isWhite = parts.length > 1 ? parts[1] == 'w' : true;
  final sign = isWhite ? 1 : -1;
  return (
    cp: pv.cp * sign,
    isMate: pv.isMate,
    mate: pv.mate == null ? null : pv.mate! * sign,
  );
}

final boardEvalProvider = StateNotifierProvider.autoDispose
    .family<BoardEvalNotifier, BoardEvalState, String>((ref, fen) {
      final config = ref.watch(
        engineSettingsProviderNew.select((async) {
          final settings = async.valueOrNull ?? const EngineSettings();
          return BoardEvalConfig(
            enabled: settings.showEngineAnalysis,
            searchTimeIndex: settings.searchTimeIndex,
            principalVariationIndex: settings.principalVariationIndex,
          );
        }),
      );
      return BoardEvalNotifier(ref, fen, config);
    });

@immutable
class BoardEvalConfig {
  const BoardEvalConfig({
    required this.enabled,
    required this.searchTimeIndex,
    required this.principalVariationIndex,
  });

  final bool enabled;
  final int searchTimeIndex;
  final int principalVariationIndex;

  EngineSettings toEngineSettings() {
    return EngineSettings(
      showEngineAnalysis: enabled,
      searchTimeIndex: searchTimeIndex,
      principalVariationIndex: principalVariationIndex,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is BoardEvalConfig &&
            other.enabled == enabled &&
            other.searchTimeIndex == searchTimeIndex &&
            other.principalVariationIndex == principalVariationIndex;
  }

  @override
  int get hashCode =>
      Object.hash(enabled, searchTimeIndex, principalVariationIndex);
}
