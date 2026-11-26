import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

/// Chessconnect (chessconnect.de) connects electronic chessboards to chess
/// sites through a small page-level JavaScript interface, the "Chessconnect
/// Adapter API" version 1. This file is the platform-neutral half: what the
/// boards report and what a board move may do. `lib/web/chessconnect_*`
/// exposes it as `window.chessconnectAdapter` in the browser build only.
///
/// Security contract, enforced here and pinned by
/// `test/desktop/chessconnect_bridge_test.dart`:
///
/// - Only what is already on screen leaves the app: the position, which
///   colour moves, the orientation, the Play clocks and the result. Never
///   names, accounts, ids, engine output or anything about the opponent.
/// - Game ids are opaque per-page tokens, never a database or broadcast id.
/// - A board move is a strict UCI string. It is rate limited and goes to the
///   one focused board, through the same legality and turn rules as a mouse
///   move. Anything else is refused with `ok: false`; nothing throws.
/// - No takeback, resign, draw, navigation or settings are reachable.

/// Kill switch for the browser build: build with
/// `--dart-define=CHESSCONNECT_ADAPTER_DISABLED=true` to ship without the
/// adapter. Chessconnect can also drop the site from its signed list.
const bool kChessconnectAdapterDisabled = bool.fromEnvironment(
  'CHESSCONNECT_ADAPTER_DISABLED',
);

enum ChessconnectGameState {
  notStarted('not_started'),
  ongoing('ongoing'),
  finished('finished');

  const ChessconnectGameState(this.wire);
  final String wire;
}

/// Who may move pieces from the physical board. `both` is the analysis and
/// replay board (adapter spec 4.8).
enum ChessconnectPlayerColor {
  white('white'),
  black('black'),
  both('both');

  const ChessconnectPlayerColor(this.wire);
  final String wire;

  static ChessconnectPlayerColor of(Side side) =>
      side == Side.white ? white : black;
}

@immutable
class ChessconnectClock {
  const ChessconnectClock({
    required this.whiteMs,
    required this.blackMs,
    required this.running,
    this.whiteInitialMs,
    this.blackInitialMs,
  });

  final int whiteMs;
  final int blackMs;
  final Side? running;
  final int? whiteInitialMs;
  final int? blackInitialMs;
}

/// One board's state, as Chessconnect may see it.
@immutable
class ChessconnectSnapshot {
  const ChessconnectSnapshot({
    required this.gameKey,
    required this.state,
    required this.playerColor,
    required this.fen,
    this.result,
    this.clock,
    this.orientation,
  });

  /// Internal identity of the game on this board. Never sent: the bridge
  /// maps it to an opaque token.
  final String gameKey;
  final ChessconnectGameState state;
  final ChessconnectPlayerColor playerColor;
  final String fen;

  /// `1-0`, `0-1`, `1/2-1/2`, `aborted`, or null.
  final String? result;
  final ChessconnectClock? clock;
  final Side? orientation;
}

/// A board surface that can take a move from the physical board.
abstract interface class ChessconnectSource {
  /// The board as it is now, or null when it cannot be played on.
  ChessconnectSnapshot? snapshot();

  /// Plays [move] exactly as the same mouse move would. Returns true only
  /// when the move is on the board afterwards, so the next [snapshot]
  /// already shows the position after it.
  bool playMove(NormalMove move);
}

typedef ChessconnectMoveResult = ({bool ok, String? message});

@immutable
class ChessconnectConnection {
  const ChessconnectConnection({required this.connected, this.board});
  final bool connected;

  /// Board family such as `DGT`; display only, never stored or sent.
  final String? board;
}

/// The single bridge between the focused board and Chessconnect.
class ChessconnectBridge {
  ChessconnectBridge({
    @visibleForTesting DateTime Function()? now,
    @visibleForTesting math.Random? random,
  }) : _now = now ?? DateTime.now,
       _sessionTag = _randomTag(random ?? _secureRandom());

  static final ChessconnectBridge instance = ChessconnectBridge();

  final DateTime Function() _now;
  final String _sessionTag;

  Object? _owner;
  ChessconnectSource? _source;

  /// The surface that currently owns the bridge. The connect slot renders
  /// only for this owner, so the page never holds two `#chessconnect-root`.
  /// Published in a microtask: boards attach from build and lifecycle
  /// callbacks, where notifying other widgets is not allowed.
  ValueListenable<Object?> get activeOwner => _activeOwner;
  final ValueNotifier<Object?> _activeOwner = ValueNotifier<Object?>(null);
  bool _ownerPublishPending = false;

  void _publishOwner() {
    if (_ownerPublishPending) return;
    _ownerPublishPending = true;
    scheduleMicrotask(() {
      _ownerPublishPending = false;
      _activeOwner.value = _owner;
    });
  }

  /// Null until Chessconnect has called `onConnectionChange` on this page,
  /// i.e. until the user has turned Chessconnect on for the site.
  final ValueNotifier<ChessconnectConnection?> connection =
      ValueNotifier<ChessconnectConnection?>(null);

  final List<VoidCallback> _changeListeners = <VoidCallback>[];

  /// Attach [source] for [owner]; the last attached surface wins.
  void attach(Object owner, ChessconnectSource source) {
    if (identical(_owner, owner) && identical(_source, source)) return;
    _owner = owner;
    _source = source;
    _publishOwner();
    markChanged();
  }

  /// Detach [owner] if it still owns the bridge.
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _source = null;
    _publishOwner();
    markChanged();
  }

  bool isOwner(Object owner) => identical(_owner, owner);

  /// Called by the browser binding to dispatch `chessconnectadapter:change`.
  void addChangeListener(VoidCallback listener) =>
      _changeListeners.add(listener);

  void removeChangeListener(VoidCallback listener) =>
      _changeListeners.remove(listener);

  /// Tell Chessconnect that something in the snapshot changed.
  void markChanged() {
    for (final listener in List<VoidCallback>.of(_changeListeners)) {
      try {
        listener();
      } catch (_) {
        // A listener failure must never reach a board surface.
      }
    }
  }

  // ---- getState() --------------------------------------------------------

  /// The adapter's `getState()` payload, or null when no board can be
  /// played. Plain values only; never throws.
  Map<String, Object?>? state() {
    try {
      final snapshot = _source?.snapshot();
      if (snapshot == null) return null;
      if (!_isPlausibleFen(snapshot.fen)) return null;
      final clock = snapshot.clock;
      return <String, Object?>{
        'gameId': _opaqueGameId(snapshot.gameKey),
        'state': snapshot.state.wire,
        'playerColor': snapshot.playerColor.wire,
        'fen': snapshot.fen,
        'result': snapshot.result,
        'clock':
            clock == null
                ? null
                : <String, Object?>{
                  'whiteMs': math.max(0, clock.whiteMs),
                  'blackMs': math.max(0, clock.blackMs),
                  'running': _color(clock.running),
                  'whiteInitialMs': clock.whiteInitialMs,
                  'blackInitialMs': clock.blackInitialMs,
                },
        'variant': 'standard',
        'orientation': _color(snapshot.orientation),
      };
    } catch (_) {
      return null;
    }
  }

  // ---- move(uci) ---------------------------------------------------------

  static final RegExp _uciPattern = RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$');

  /// At most this many board moves are accepted per [_rateWindow]. A person
  /// at a physical board never comes close; a script hammering `move()` does.
  static const int _rateLimit = 8;
  static const Duration _rateWindow = Duration(seconds: 1);
  final List<DateTime> _recentMoves = <DateTime>[];

  /// The adapter's `move(uci)`. [raw] is whatever the page passed in.
  ChessconnectMoveResult move(Object? raw) {
    try {
      if (raw is! String || raw.length > 5) {
        return (ok: false, message: 'invalid move');
      }
      if (!_uciPattern.hasMatch(raw)) {
        return (ok: false, message: 'invalid move');
      }
      final source = _source;
      if (source == null) return (ok: false, message: 'no board');
      if (!_takeRateToken()) return (ok: false, message: 'too many moves');
      final NormalMove move;
      try {
        move = NormalMove.fromUci(raw);
      } catch (_) {
        return (ok: false, message: 'invalid move');
      }
      if (move.from == move.to) return (ok: false, message: 'invalid move');
      if (!source.playMove(move)) return (ok: false, message: 'refused');
      markChanged();
      return (ok: true, message: null);
    } catch (_) {
      return (ok: false, message: 'refused');
    }
  }

  bool _takeRateToken() {
    final now = _now();
    _recentMoves.removeWhere((t) => now.difference(t) >= _rateWindow);
    if (_recentMoves.length >= _rateLimit) return false;
    _recentMoves.add(now);
    return true;
  }

  // ---- onConnectionChange(info) -----------------------------------------

  static final RegExp _boardNamePattern = RegExp(r'^[A-Za-z0-9 _.-]{1,32}$');

  /// Chessconnect reporting whether a physical board is connected.
  void connectionChanged({required Object? connected, Object? board}) {
    if (connected is! bool) return;
    final name =
        connected && board is String && _boardNamePattern.hasMatch(board)
            ? board
            : null;
    connection.value = ChessconnectConnection(
      connected: connected,
      board: name,
    );
  }

  // ---- helpers -----------------------------------------------------------

  /// Opaque, page-local game ids. The same game key keeps its token; a new
  /// game gets the next one. Bounded so a long session cannot grow it.
  final Map<String, String> _gameIds = <String, String>{};
  int _nextGameId = 0;
  static const int _maxGameIds = 64;

  String _opaqueGameId(String key) {
    final existing = _gameIds.remove(key);
    if (existing != null) {
      _gameIds[key] = existing;
      return existing;
    }
    if (_gameIds.length >= _maxGameIds) {
      _gameIds.remove(_gameIds.keys.first);
    }
    final id = 'ce-$_sessionTag-${++_nextGameId}';
    _gameIds[key] = id;
    return id;
  }

  static String? _color(Side? side) =>
      side == null ? null : (side == Side.white ? 'white' : 'black');

  static bool _isPlausibleFen(String fen) =>
      fen.length <= 100 && fen.split(' ').length == 6;

  static math.Random _secureRandom() {
    try {
      return math.Random.secure();
    } catch (_) {
      return math.Random();
    }
  }

  static String _randomTag(math.Random random) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
      List<int>.generate(
        8,
        (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ),
    );
  }
}

/// [move] if it is legal in [position] as a board move: a pawn reaching the
/// last rank must name its piece (no promotion dialog is ever opened for a
/// physical board), and only a pawn reaching the last rank may name one.
NormalMove? chessconnectLegalMove(Position position, NormalMove move) {
  try {
    if (position.isGameOver) return null;
    final piece = position.board.pieceAt(move.from);
    if (piece == null || piece.color != position.turn) return null;
    final reachesLastRank =
        piece.role == Role.pawn &&
        (move.to.rank == Rank.first || move.to.rank == Rank.eighth);
    if (reachesLastRank != (move.promotion != null)) return null;
    if (!position.isLegal(move)) return null;
    return move;
  } catch (_) {
    return null;
  }
}

/// `1-0` / `0-1` / `1/2-1/2` for a finished game, `aborted` without one.
String? chessconnectResult(Outcome? outcome, {required bool aborted}) {
  if (aborted) return 'aborted';
  if (outcome == null) return null;
  final winner = outcome.winner;
  if (winner == null) return '1/2-1/2';
  return winner == Side.white ? '1-0' : '0-1';
}
