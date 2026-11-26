import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/chessconnect/chessconnect_bridge.dart';
import 'package:chessever/desktop/state/play_session.dart';

/// What Chessconnect sees of a Play game against Stockfish, Leela or Maia:
/// the user's colour, the live position (not a reviewed earlier ply), the
/// clocks as shown and the result. Never the bot's name, strength or eval.
ChessconnectSnapshot playChessconnectSnapshot(
  PlaySessionState state, {
  required String gameKey,
  required DateTime now,
  Side? orientation,
}) {
  var whiteMs = state.whiteMillis;
  var blackMs = state.blackMillis;
  final last = state.lastClockTick;
  final running = state.isGameOver ? null : state.activeClock;
  if (last != null && running != null) {
    final elapsed = now.difference(last).inMilliseconds;
    if (elapsed > 0) {
      if (running == Side.white) {
        whiteMs -= elapsed;
      } else {
        blackMs -= elapsed;
      }
    }
  }
  final seeded = state.config.startingMovesUci.length;
  final ChessconnectGameState gameState;
  if (state.isGameOver) {
    gameState = ChessconnectGameState.finished;
  } else if (state.activeClock != null || state.history.length > seeded) {
    gameState = ChessconnectGameState.ongoing;
  } else {
    gameState = ChessconnectGameState.notStarted;
  }
  return ChessconnectSnapshot(
    gameKey: gameKey,
    state: gameState,
    playerColor: ChessconnectPlayerColor.of(state.humanSide),
    fen: state.position.fen,
    result:
        state.isGameOver
            ? chessconnectResult(
              state.outcome,
              aborted: state.endReason == PlayEndReason.aborted,
            )
            : null,
    clock: ChessconnectClock(
      whiteMs: whiteMs < 0 ? 0 : whiteMs,
      blackMs: blackMs < 0 ? 0 : blackMs,
      running: running,
      whiteInitialMs: state.config.whiteBaseSeconds * 1000,
      blackInitialMs: state.config.effectiveBlackBaseSeconds * 1000,
    ),
    orientation: orientation ?? state.humanSide,
  );
}

/// The parts of a Play state whose change Chessconnect must hear about at
/// once. The clock merely counting down is not one of them (spec 7.1).
Object playChessconnectSignature(PlaySessionState state) => (
  state.position.fen,
  state.activeClock,
  state.endReason,
  state.history.length,
);

/// A Play game as a Chessconnect source.
class PlayChessconnectSource implements ChessconnectSource {
  PlayChessconnectSource({
    required this.readState,
    required this.playHumanMove,
    required this.gameKey,
    this.readOrientation,
    @visibleForTesting DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The live session, or null when the game view is gone.
  final PlaySessionState? Function() readState;

  /// `PlaySessionNotifier.playHumanMove`: refuses a move out of turn, while
  /// the bot thinks or after the end. Board moves never become premoves.
  final bool Function(String uci) playHumanMove;
  final String gameKey;

  /// The side at the bottom of the board as drawn; the user may flip it.
  final Side? Function()? readOrientation;
  final DateTime Function() _now;

  @override
  ChessconnectSnapshot? snapshot() {
    final state = readState();
    if (state == null) return null;
    return playChessconnectSnapshot(
      state,
      gameKey: gameKey,
      now: _now(),
      orientation: readOrientation?.call(),
    );
  }

  @override
  bool playMove(NormalMove move) {
    final state = readState();
    if (state == null || !state.isHumanToMove) return false;
    final legal = chessconnectLegalMove(state.position, move);
    if (legal == null) return false;
    return playHumanMove(legal.uci);
  }
}

/// The analysis and replay board (adapter spec 4.8): either colour may move,
/// the position is the one shown, and there is never a clock or result, even
/// for a finished game. A board move is added like a mouse move: it follows
/// an existing line or starts a variation.
class BoardChessconnectSource implements ChessconnectSource {
  BoardChessconnectSource({required this.applyMove});

  /// Plays a legal move on the board, without stealing keyboard focus.
  final void Function(NormalMove move) applyMove;

  String _gameKey = '';
  Position? _position;
  Side _orientation = Side.white;
  bool _acceptsMoves = false;

  /// Called on every board build. Returns true when Chessconnect should be
  /// told (a different position, game or orientation).
  bool update({
    required String gameKey,
    required Position position,
    required Side orientation,
    required bool acceptsMoves,
  }) {
    final changed =
        gameKey != _gameKey ||
        position.fen != _position?.fen ||
        orientation != _orientation;
    _gameKey = gameKey;
    _position = position;
    _orientation = orientation;
    _acceptsMoves = acceptsMoves;
    return changed;
  }

  @override
  ChessconnectSnapshot? snapshot() {
    final position = _position;
    if (position == null) return null;
    return ChessconnectSnapshot(
      gameKey: _gameKey,
      state: ChessconnectGameState.ongoing,
      playerColor: ChessconnectPlayerColor.both,
      fen: position.fen,
      orientation: _orientation,
    );
  }

  @override
  bool playMove(NormalMove move) {
    final position = _position;
    if (!_acceptsMoves || position == null) return false;
    final legal = chessconnectLegalMove(position, move);
    if (legal == null) return false;
    applyMove(legal);
    // The board's state updates synchronously, but its next build is still
    // pending; report the position after the move right away (spec 5.1).
    _position = position.play(legal);
    return true;
  }
}
