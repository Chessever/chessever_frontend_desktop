import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/maia3_engine.dart';
import 'package:chessever/desktop/services/play/play_models.dart';

/// Terminal reason for a finished game. We keep our own enum because
/// dartchess [Outcome] alone doesn't tell us *why* (timeout vs resignation
/// vs natural ending), and we need that to render the result banner.
enum PlayEndReason {
  none,
  whiteCheckmated,
  blackCheckmated,
  whiteResigned,
  blackResigned,
  whiteFlagged,
  blackFlagged,
  drawByAgreement,
  stalemate,
  insufficientMaterial,
  fiftyMoveRule,
  threefoldRepetition,
  aborted,
}

extension PlayEndReasonText on PlayEndReason {
  String get banner {
    switch (this) {
      case PlayEndReason.none:
        return '';
      case PlayEndReason.whiteCheckmated:
        return 'Black wins by checkmate';
      case PlayEndReason.blackCheckmated:
        return 'White wins by checkmate';
      case PlayEndReason.whiteResigned:
        return 'Black wins by resignation';
      case PlayEndReason.blackResigned:
        return 'White wins by resignation';
      case PlayEndReason.whiteFlagged:
        return 'Black wins on time';
      case PlayEndReason.blackFlagged:
        return 'White wins on time';
      case PlayEndReason.drawByAgreement:
        return 'Draw by agreement';
      case PlayEndReason.stalemate:
        return 'Draw by stalemate';
      case PlayEndReason.insufficientMaterial:
        return 'Draw — insufficient material';
      case PlayEndReason.fiftyMoveRule:
        return 'Draw — 50-move rule';
      case PlayEndReason.threefoldRepetition:
        return 'Draw — threefold repetition';
      case PlayEndReason.aborted:
        return 'Game aborted';
    }
  }
}

@immutable
class PlaySessionState {
  const PlaySessionState({
    required this.config,
    required this.humanSide,
    required this.botIdentity,
    required this.position,
    required this.startingFen,
    required this.history,
    required this.whiteMillis,
    required this.blackMillis,
    required this.lastClockTick,
    required this.activeClock,
    required this.engineThinking,
    required this.premoves,
    required this.engineReady,
    required this.engineStatus,
    required this.endReason,
    required this.outcome,
    required this.lastMove,
  });

  final PlayConfig config;
  final Side humanSide;
  final BotIdentity botIdentity;

  final Position position;
  final String startingFen;

  /// UCI history of moves played, in order. The engine search is driven from
  /// [position] so a rejected or truncated seed cannot desync the bot from
  /// the board; history remains the visible notation and persistence source.
  final List<String> history;

  final int whiteMillis;
  final int blackMillis;
  final DateTime? lastClockTick;

  /// Which clock is counting down right now. `null` until the first human
  /// move (so the bot doesn't burn time before either side has touched a
  /// piece) and `null` again once the game ends.
  final Side? activeClock;

  final bool engineThinking;

  /// FIFO queue of premove UCI strings. The user can stack them while it's
  /// the bot's turn; the head is applied immediately after the bot's reply
  /// if still legal, and the rest cascade through subsequent turns. Empty
  /// most of the time.
  final List<String> premoves;

  final bool engineReady;
  final String engineStatus;

  final PlayEndReason endReason;
  final Outcome? outcome;

  final NormalMove? lastMove;

  bool get isHumanToMove =>
      position.turn == humanSide && !engineThinking && !isGameOver;
  bool get isBotToMove =>
      position.turn != humanSide && !engineThinking && !isGameOver;
  bool get isGameOver => endReason != PlayEndReason.none;

  PlaySessionState copyWith({
    Position? position,
    List<String>? history,
    int? whiteMillis,
    int? blackMillis,
    DateTime? lastClockTick,
    Side? activeClock,
    bool? engineThinking,
    List<String>? premoves,
    bool? engineReady,
    String? engineStatus,
    PlayEndReason? endReason,
    Outcome? outcome,
    NormalMove? lastMove,
    bool clearActiveClock = false,
    bool clearLastMove = false,
    bool clearOutcome = false,
    bool clearLastTick = false,
  }) {
    return PlaySessionState(
      config: config,
      humanSide: humanSide,
      botIdentity: botIdentity,
      position: position ?? this.position,
      startingFen: startingFen,
      history: history ?? this.history,
      whiteMillis: whiteMillis ?? this.whiteMillis,
      blackMillis: blackMillis ?? this.blackMillis,
      lastClockTick:
          clearLastTick ? null : (lastClockTick ?? this.lastClockTick),
      activeClock: clearActiveClock ? null : (activeClock ?? this.activeClock),
      engineThinking: engineThinking ?? this.engineThinking,
      premoves: premoves ?? this.premoves,
      engineReady: engineReady ?? this.engineReady,
      engineStatus: engineStatus ?? this.engineStatus,
      endReason: endReason ?? this.endReason,
      outcome: clearOutcome ? null : (outcome ?? this.outcome),
      lastMove: clearLastMove ? null : (lastMove ?? this.lastMove),
    );
  }
}

@immutable
class _StartingReplay {
  const _StartingReplay({
    required this.position,
    required this.history,
    required this.lastMove,
  });

  final Position position;
  final List<String> history;
  final NormalMove? lastMove;
}

_StartingReplay _replayStartingMoves(
  String startingFen,
  List<String> movesUci,
) {
  Position position;
  try {
    position = Position.setupPosition(Rule.chess, Setup.parseFen(startingFen));
  } catch (_) {
    position = Chess.initial;
  }

  if (movesUci.isEmpty) {
    return _StartingReplay(
      position: position,
      history: const <String>[],
      lastMove: null,
    );
  }

  final replayed = <String>[];
  NormalMove? lastMove;
  for (final uci in movesUci) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    position = position.playUnchecked(move);
    replayed.add(move.uci);
    lastMove = move is NormalMove ? move : null;
  }

  return _StartingReplay(
    position: position,
    history: List<String>.unmodifiable(replayed),
    lastMove: lastMove,
  );
}

/// Live single-game Play state machine.
///
/// Owns the dartchess [Position], a Fischer-increment clock per side, and a
/// dedicated [UciEngine] subprocess. The engine is created on `start()` and
/// torn down on dispose / on `restart()`, so analysis (running on the shared
/// `StockfishSingleton`) doesn't fight the opponent.
class PlaySessionNotifier extends StateNotifier<PlaySessionState> {
  PlaySessionNotifier({
    required this.config,
    required this.engineBinaryPath,
    required this.botIdentity,
    @visibleForTesting this.bootEngine = true,
  }) : super(_initialState(config, botIdentity)) {
    if (state.activeClock != null) _ensureTicker();
    if (bootEngine) unawaited(_bootEngine());
  }

  final PlayConfig config;
  final String engineBinaryPath;
  final BotIdentity botIdentity;
  final bool bootEngine;

  UciEngine? _engine;
  Maia3LocalEngine? _maia3Engine;
  StreamSubscription<String>? _engineSub;
  Timer? _ticker;
  final Random _coinflip = Random();

  static PlaySessionState _initialState(PlayConfig config, BotIdentity id) {
    final humanSide = switch (config.color) {
      PlayColorChoice.white => Side.white,
      PlayColorChoice.black => Side.black,
      PlayColorChoice.random => Random().nextBool() ? Side.white : Side.black,
    };
    final startingFen = config.startingFen ?? Chess.initial.fen;
    final replay = _replayStartingMoves(startingFen, config.startingMovesUci);
    final clockStartsNow = config.startClockImmediately;
    return PlaySessionState(
      config: config,
      humanSide: humanSide,
      botIdentity: id,
      position: replay.position,
      startingFen: startingFen,
      history: replay.history,
      whiteMillis: config.whiteBaseSeconds * 1000,
      blackMillis: config.effectiveBlackBaseSeconds * 1000,
      lastClockTick: clockStartsNow ? DateTime.now() : null,
      activeClock: clockStartsNow ? replay.position.turn : null,
      engineThinking: false,
      premoves: const [],
      engineReady: false,
      engineStatus: 'Starting engine…',
      endReason: PlayEndReason.none,
      outcome: null,
      lastMove: replay.lastMove,
    );
  }

  Future<void> _bootEngine() async {
    try {
      if (config.engine == BotEngineKind.maia &&
          isMaia3ModelPath(engineBinaryPath)) {
        _maia3Engine = await Maia3LocalEngine.load(engineBinaryPath);
        state = state.copyWith(
          engineReady: true,
          engineStatus: '${config.engine.displayName} ready',
        );
        if (state.isBotToMove) {
          _scheduleEngineThink();
        }
        return;
      }

      final engine = await UciEngine.spawn(
        engineBinaryPath,
        arguments: engineLaunchArguments(
          config.engine,
          engineBinaryPath,
          config.elo,
        ),
        workingDirectory: engineWorkingDirectory(engineBinaryPath),
      );
      _engine = engine;
      _engineSub = engine.lines.listen(_onEngineLine);
      final ok = await engine.initialize(
        threads: _hostThreadHint(),
        hashMb: config.engine == BotEngineKind.stockfish ? 64 : null,
        multiPv: 1,
      );
      if (!ok) {
        state = state.copyWith(
          engineStatus: 'Engine handshake failed',
          engineReady: false,
        );
        return;
      }
      _applyStrengthOptions();
      engine.send('ucinewgame');
      engine.send('isready');
      state = state.copyWith(
        engineReady: true,
        engineStatus: '${config.engine.displayName} ready',
      );
      // If the bot owns the seeded side-to-move, start its first search now.
      // The clock still waits for the first landed move before ticking.
      if (state.isBotToMove) {
        _scheduleEngineThink();
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('Engine boot failed: $e\n$st');
      state = state.copyWith(
        engineStatus: 'Failed to start engine',
        engineReady: false,
      );
    }
  }

  void _applyStrengthOptions() {
    final engine = _engine;
    if (engine == null) return;
    for (final command in engineStrengthOptionCommands(
      config.engine,
      config.elo,
    )) {
      engine.send(command);
    }
  }

  int _hostThreadHint() {
    // Reasonable conservative default that won't pin every core; the real
    // analysis singleton handles that. Bots don't need many threads.
    final cores = Platform.numberOfProcessors;
    return cores >= 4 ? 2 : 1;
  }

  /// Handle one line of engine stdout. We only care about `bestmove` here —
  /// info lines are noise for play (no eval bar in the opponent's pane).
  void _onEngineLine(String line) {
    if (!mounted) return;
    if (!line.startsWith('bestmove')) return;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) return;
    final uci = parts[1];
    if (uci == '(none)' || uci == '0000') {
      // Engine has no legal move — checkmate or stalemate. Position update
      // below will end the game by outcome.
      return;
    }
    _applyEngineMove(uci);
  }

  void _applyEngineMove(String uci) {
    if (!mounted) return;
    if (state.isGameOver) return;
    final move = _parseMove(uci, state.position);
    if (move == null) return;
    final next = state.position.play(move);
    final now = DateTime.now();
    final whiteMs = state.whiteMillis;
    final blackMs = state.blackMillis;
    // Apply Fischer increment to the side that just moved.
    final mover = state.position.turn;
    final wMs =
        mover == Side.white
            ? whiteMs + config.whiteIncrementSeconds * 1000
            : whiteMs;
    final bMs =
        mover == Side.black
            ? blackMs + config.effectiveBlackIncrementSeconds * 1000
            : blackMs;
    state = state.copyWith(
      position: next,
      history: [...state.history, move.uci],
      lastMove: move is NormalMove ? move : null,
      whiteMillis: wMs,
      blackMillis: bMs,
      engineThinking: false,
      activeClock:
          state.activeClock == null && state.history.isEmpty
              ? next.turn
              : next.turn,
      lastClockTick: now,
    );
    _ensureTicker();
    _checkTerminal();
    if (state.isGameOver) return;
    // After the bot's reply, drain any premove the human had queued.
    _drainPremovesAfterOpponent();
  }

  Move? _parseMove(String uci, Position position) {
    try {
      final raw = NormalMove.fromUci(uci);
      final move = _standardizeCastlingMove(
        raw,
        (square) => position.board.pieceAt(square),
      );
      if (!position.isLegal(move)) return null;
      return move;
    } catch (_) {
      return null;
    }
  }

  // --- public commands ---

  /// Submit a human move (UCI). Returns true if the move was accepted;
  /// returns false if it's not the human's turn (caller should queue it as
  /// a premove via [queuePremove] instead) or if the move is illegal.
  bool playHumanMove(String uci) {
    if (state.isGameOver) return false;
    if (!state.isHumanToMove) return false;
    final move = _parseMove(uci, state.position);
    if (move == null) return false;
    final next = state.position.play(move);
    final now = DateTime.now();
    // Apply Fischer increment to white/black.
    final mover = state.position.turn;
    final wMs =
        mover == Side.white
            ? state.whiteMillis + config.whiteIncrementSeconds * 1000
            : state.whiteMillis;
    final bMs =
        mover == Side.black
            ? state.blackMillis + config.effectiveBlackIncrementSeconds * 1000
            : state.blackMillis;
    state = state.copyWith(
      position: next,
      history: [...state.history, move.uci],
      lastMove: move is NormalMove ? move : null,
      whiteMillis: wMs,
      blackMillis: bMs,
      activeClock: next.turn,
      lastClockTick: now,
    );
    _ensureTicker();
    _checkTerminal();
    if (state.isGameOver) return true;
    _scheduleEngineThink();
    return true;
  }

  /// Stack a premove. Multiple calls during the bot's turn append to the
  /// queue (multi-premove). Returns false if the premove is structurally
  /// impossible (wrong source square, no piece, etc.) so the UI can flash
  /// an error border without actually queuing it.
  bool queuePremove(String uci) {
    if (state.isGameOver) return false;
    // Premove only meaningful while it's the bot's turn or the human's
    // own turn but they're stacking ahead. Keep the full queue so fast
    // users can enter a long intended sequence.
    final parsed = _tryParsePremove(uci);
    if (parsed == null) return false;
    if (parsed.from == parsed.to) return false;
    final piece = _virtualPieceAt(parsed.from);
    if (piece == null || piece.color != state.humanSide) return false;
    // Allow premoves whose destination currently holds an own piece. The
    // user is anticipating that piece to be captured (or to move) on the
    // opponent's reply — matches lichess / chess.com behavior. The drain
    // path validates legality against the real post-opponent position; if
    // the own piece is still sitting there when it's the user's turn the
    // premove will be rejected by playHumanMove and the queue flushed.
    final nm = _standardizeCastlingMove(parsed, _virtualPieceAt);
    state = state.copyWith(premoves: [...state.premoves, nm.uci]);
    return true;
  }

  void clearPremoves() {
    if (state.premoves.isEmpty) return;
    state = state.copyWith(premoves: const []);
  }

  void resign() {
    if (state.isGameOver) return;
    final reason =
        state.humanSide == Side.white
            ? PlayEndReason.whiteResigned
            : PlayEndReason.blackResigned;
    final outcome =
        state.humanSide == Side.white ? Outcome.blackWins : Outcome.whiteWins;
    _endGame(reason, outcome);
  }

  void offerDrawAccepted() {
    if (state.isGameOver) return;
    _endGame(PlayEndReason.drawByAgreement, Outcome.draw);
  }

  void abort() {
    _endGame(PlayEndReason.aborted, null);
  }

  // --- internals ---

  void _drainPremovesAfterOpponent() {
    if (state.premoves.isEmpty || !state.isHumanToMove) return;
    final head = state.premoves.first;
    final remaining = state.premoves.skip(1).toList(growable: false);
    state = state.copyWith(premoves: remaining);
    final accepted = playHumanMove(head);
    if (!accepted && state.premoves.isNotEmpty) {
      // First queued premove became illegal — flush the rest too. We *don't*
      // try later ones because they depend on a chain that's broken.
      state = state.copyWith(premoves: const []);
    }
  }

  NormalMove? _tryParsePremove(String uci) {
    try {
      return NormalMove.fromUci(uci);
    } catch (_) {
      return null;
    }
  }

  Piece? _virtualPieceAt(Square square) =>
      buildVirtualPlayBoard(state.position.board, state.premoves).pieceAt(square);

  void _scheduleEngineThink() {
    final maia3 = _maia3Engine;
    if (maia3 != null) {
      unawaited(_scheduleMaia3Think(maia3));
      return;
    }

    final engine = _engine;
    if (engine == null || !state.engineReady) return;
    state = state.copyWith(engineThinking: true);
    final positionCmd = _enginePositionCommand(state);
    engine.send(positionCmd);
    engine.send(
      engineGoCommand(
        config.engine,
        elo: config.elo,
        whiteMillis: state.whiteMillis,
        blackMillis: state.blackMillis,
        incrementMillis: config.incrementSeconds * 1000,
        sideToMove: state.position.turn,
        baseMillis: _engineBaseMillisFor(state.position.turn),
        ply: state.history.length,
        random: _coinflip,
      ),
    );
  }

  Future<void> _scheduleMaia3Think(Maia3LocalEngine engine) async {
    if (!state.engineReady || state.engineThinking || !state.isBotToMove) {
      return;
    }
    final fen = state.position.fen;
    final sideToMove = state.position.turn;
    final ownMillis =
        sideToMove == Side.white ? state.whiteMillis : state.blackMillis;
    final thinkMillis = clockAwareMoveTimeMillis(
      elo: config.elo,
      ownMillis: ownMillis,
      incrementMillis: config.incrementSeconds * 1000,
      baseMillis: _engineBaseMillisFor(sideToMove),
      ply: state.history.length,
      random: _coinflip,
    );
    state = state.copyWith(engineThinking: true);
    try {
      await Future<void>.delayed(Duration(milliseconds: thinkMillis));
      if (!mounted) return;
      if (state.isGameOver || state.position.fen != fen) {
        state = state.copyWith(engineThinking: false);
        return;
      }
      final bestMove = await engine.pickMove(
        fen: fen,
        eloSelf: config.elo,
        eloOpponent: config.elo,
      );
      if (!mounted) return;
      if (state.isGameOver || state.position.fen != fen) return;
      if (bestMove == null) {
        state = state.copyWith(engineThinking: false);
        _checkTerminal();
        return;
      }
      _applyEngineMove(bestMove);
    } catch (e, st) {
      if (kDebugMode) debugPrint('Maia 3 inference failed: $e\n$st');
      if (!mounted) return;
      state = state.copyWith(
        engineThinking: false,
        engineReady: false,
        engineStatus: 'Maia 3 inference failed',
      );
    }
  }

  void _ensureTicker() {
    _ticker ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _onTick(),
    );
  }

  int _engineBaseMillisFor(Side side) {
    final seconds =
        side == Side.white
            ? config.whiteBaseSeconds
            : config.effectiveBlackBaseSeconds;
    return seconds * 1000;
  }

  void _onTick() {
    if (!mounted) return;
    if (state.isGameOver) return;
    final last = state.lastClockTick;
    if (last == null || state.activeClock == null) return;
    final now = DateTime.now();
    final elapsed = now.difference(last).inMilliseconds;
    if (elapsed <= 0) return;
    final side = state.activeClock!;
    final newWhite =
        side == Side.white ? state.whiteMillis - elapsed : state.whiteMillis;
    final newBlack =
        side == Side.black ? state.blackMillis - elapsed : state.blackMillis;
    state = state.copyWith(
      whiteMillis: newWhite < 0 ? 0 : newWhite,
      blackMillis: newBlack < 0 ? 0 : newBlack,
      lastClockTick: now,
    );
    if (newWhite <= 0) {
      _endGame(PlayEndReason.whiteFlagged, Outcome.blackWins);
    } else if (newBlack <= 0) {
      _endGame(PlayEndReason.blackFlagged, Outcome.whiteWins);
    }
  }

  void _checkTerminal() {
    final pos = state.position;
    if (!pos.isGameOver) return;
    final out = pos.outcome;
    if (out == Outcome.draw) {
      final reason =
          pos.isStalemate
              ? PlayEndReason.stalemate
              : pos.isInsufficientMaterial
              ? PlayEndReason.insufficientMaterial
              : (pos.halfmoves >= 100
                  ? PlayEndReason.fiftyMoveRule
                  : PlayEndReason.threefoldRepetition);
      _endGame(reason, out);
    } else if (out == Outcome.whiteWins) {
      _endGame(PlayEndReason.blackCheckmated, out);
    } else if (out == Outcome.blackWins) {
      _endGame(PlayEndReason.whiteCheckmated, out);
    }
  }

  void _endGame(PlayEndReason reason, Outcome? outcome) {
    state = state.copyWith(
      endReason: reason,
      outcome: outcome,
      clearActiveClock: true,
      clearLastTick: true,
      engineThinking: false,
    );
    _ticker?.cancel();
    _ticker = null;
    final engine = _engine;
    if (engine != null) {
      engine.send('stop');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    final sub = _engineSub;
    _engineSub = null;
    if (sub != null) {
      // Pause synchronously so no further `_onEngineLine` callback fires
      // against this disposed notifier; cancel runs async.
      sub.pause();
      unawaited(sub.cancel());
    }
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      try {
        engine.send('stop');
        engine.send('quit');
      } catch (_) {}
      unawaited(engine.dispose());
    }
    final maia3 = _maia3Engine;
    _maia3Engine = null;
    if (maia3 != null) {
      unawaited(maia3.dispose());
    }
    // Coinflip kept around in case sub-classes want to re-seed; clear it
    // explicitly to satisfy strict lint when not otherwise referenced.
    _coinflip.nextBool();
    super.dispose();
  }
}

String _enginePositionCommand(PlaySessionState state) =>
    'position fen ${state.position.fen}';

/// Applies queued [premoves] on top of [base] and returns the resulting
/// virtual board. Used by the play pane so chessground renders the
/// post-premove pieces — without this, the user could not stack a second
/// premove on the same piece (e.g. e2-e4 then e4-e5) because chessground
/// would still see the pawn at e2 in the raw FEN.
///
/// Illegality is ignored on purpose: premoves are speculative and may
/// reference squares that won't actually be empty when their turn comes.
/// The drain path validates each premove against the real position.
Board buildVirtualPlayBoard(Board base, List<String> premoves) {
  if (premoves.isEmpty) return base;
  var board = base;
  for (final uci in premoves) {
    final NormalMove move;
    try {
      move = NormalMove.fromUci(uci);
    } catch (_) {
      continue;
    }
    final moving = board.pieceAt(move.from);
    if (moving == null) continue;
    final rookMove = _castlingRookMove(move, moving);
    final rook = rookMove == null ? null : board.pieceAt(rookMove.from);
    board = board.removePieceAt(move.from);
    if (rookMove != null && rook != null) {
      board = board
          .removePieceAt(rookMove.from)
          .setPieceAt(rookMove.to, rook);
    }
    final placed =
        move.promotion == null
            ? moving
            : Piece(color: moving.color, role: move.promotion!, promoted: true);
    board = board.removePieceAt(move.to).setPieceAt(move.to, placed);
  }
  return board;
}

NormalMove _standardizeCastlingMove(
  NormalMove move,
  Piece? Function(Square square) pieceAt,
) {
  final moving = pieceAt(move.from);
  if (moving == null || !_isCastlingIntent(move, moving, pieceAt(move.to))) {
    return move;
  }
  return NormalMove(
    from: move.from,
    to: _standardKingCastlingDestination(move, moving.color),
  );
}

bool _isCastlingIntent(NormalMove move, Piece moving, Piece? target) {
  if (moving.role != Role.king || move.promotion != null) return false;
  if (move.from.rank != move.to.rank) return false;
  final backrank = moving.color == Side.white ? Rank.first : Rank.eighth;
  if (move.from.rank != backrank) return false;
  final fileDistance = (move.to.file - move.from.file).abs();
  final targetOwnRook =
      target?.color == moving.color && target?.role == Role.rook;
  return fileDistance == 2 || targetOwnRook;
}

Square _standardKingCastlingDestination(NormalMove move, Side side) {
  final rank = side == Side.white ? Rank.first : Rank.eighth;
  final file = move.to.file > move.from.file ? File.g : File.c;
  return Square.fromCoords(file, rank);
}

({Square from, Square to})? _castlingRookMove(NormalMove move, Piece moving) {
  if (moving.role != Role.king || move.promotion != null) return null;
  final backrank = moving.color == Side.white ? Rank.first : Rank.eighth;
  if (move.from.rank != backrank || move.to.rank != backrank) return null;
  final kingSide = move.to.file == File.g;
  final queenSide = move.to.file == File.c;
  if (!kingSide && !queenSide) return null;
  return (
    from: Square.fromCoords(kingSide ? File.h : File.a, backrank),
    to: Square.fromCoords(kingSide ? File.f : File.d, backrank),
  );
}

@visibleForTesting
String debugStandardizePlayMoveUci(String uci, Position position) {
  final move = NormalMove.fromUci(uci);
  return _standardizeCastlingMove(
    move,
    (square) => position.board.pieceAt(square),
  ).uci;
}

/// Parameters for spinning up a session. Held in its own provider so the
/// active-game widget can read them without rebuilding when the session
/// notifier replaces itself.
@immutable
class PlayTournamentContext {
  const PlayTournamentContext({
    required this.tournamentId,
    required this.tournamentTitle,
    required this.gameId,
    required this.round,
  });

  final String tournamentId;
  final String tournamentTitle;
  final String gameId;
  final int round;
}

@immutable
class PlaySessionArgs {
  const PlaySessionArgs({
    required this.config,
    required this.engineBinaryPath,
    required this.botIdentity,
    this.tournamentContext,
  });
  final PlayConfig config;
  final String engineBinaryPath;
  final BotIdentity botIdentity;
  final PlayTournamentContext? tournamentContext;
}

/// Per-tab Play session arguments, keyed by [DesktopTab.id]. A tab with no
/// entry here is in the setup phase; presence of an entry means the tab is
/// running a live game. Multiple Play tabs may carry independent sessions —
/// each tab spawns its own [PlaySessionNotifier] (and its own engine
/// subprocess) via [playSessionProviderFor].
final playSessionArgsByTabIdProvider =
    StateProvider<Map<String, PlaySessionArgs>>(
      (_) => const <String, PlaySessionArgs>{},
    );

@visibleForTesting
final playSessionBootEngineProvider = Provider<bool>((_) => true);

/// Per-tab live session. The family key is the owning tab id. Args are read
/// from the tab's current args entry so a cached fallback from a just-ended
/// game is replaced when the user starts the next game. The notifier persists
/// across tab switches because the args entry is stable while a game is live
/// (the desktop shell unmounts inactive tabs, and we want the bot's clock +
/// engine subprocess to survive that). Tear-down is explicit — call
/// `ref.invalidate(playSessionProviderFor(tabId))` after removing the tab's
/// entry from [playSessionArgsByTabIdProvider]. During that removal frame the
/// old active-game widget can still be watching, so a missing args entry
/// produces an inert fallback notifier rather than a fatal provider error.
final playSessionProviderFor =
    StateNotifierProvider.family<PlaySessionNotifier, PlaySessionState, String>(
      (ref, tabId) {
        final args = ref.watch(
          playSessionArgsByTabIdProvider.select((m) => m[tabId]),
        );
        final bootEngine = ref.watch(playSessionBootEngineProvider);
        if (args == null) {
          return PlaySessionNotifier(
            config: PlayConfig.defaults,
            engineBinaryPath: '',
            botIdentity: _testIdentity,
            bootEngine: false,
          );
        }
        return PlaySessionNotifier(
          config: args.config,
          engineBinaryPath: args.engineBinaryPath,
          botIdentity: args.botIdentity,
          bootEngine: bootEngine,
        );
      },
    );

/// Helper: resolve the engine binary path the user picked, by reading the
/// install state from [engineInstallProvider]. Returns null if the engine
/// isn't installed (caller should keep the Start button disabled).
String? engineBinaryPathFor(WidgetRef ref, BotEngineKind kind) {
  final s = ref.read(engineInstallProvider(kind));
  return engineReady(s) ? s.binaryPath : null;
}

String formatClock(int millis) {
  final ms = millis < 0 ? 0 : millis;
  final totalSec = ms ~/ 1000;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  final hh = h.toString().padLeft(2, '0');
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  if (ms < 10000) {
    // Last 10 seconds show tenths so the user feels the clock pressure.
    final tenths = (ms % 1000) ~/ 100;
    return '$hh:$mm:$ss.$tenths';
  }
  return '$hh:$mm:$ss';
}

@visibleForTesting
PlaySessionState debugInitialPlayState(PlayConfig config) =>
    PlaySessionNotifier._initialState(config, _testIdentity);

@visibleForTesting
String debugPlayEnginePositionCommand(PlaySessionState state) =>
    _enginePositionCommand(state);

const _testIdentity = BotIdentity(
  firstName: 'Test',
  lastName: 'Bot',
  countryCode: 'US',
  elo: 1500,
);
