import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/utils/pgn_clock_utils.dart';

/// Play clocks must reach the Board pane's player headers (right side, next to
/// the WON/LOST capsule) exactly like a watched broadcast game: the session
/// snapshots the mover's remaining time on every move, and both PGN export
/// paths (`_finishedPlayBoardArgs` + saved-game analysis) write `[%clk]` tags.
void main() {
  setUp(() async {
    await UciEngine.disposeAll();
    UciEngine.resumeSpawns();
  });

  tearDown(() async {
    await UciEngine.disposeAll();
    UciEngine.resumeSpawns();
  });

  group('play clock recording and export', () {
    test('formatPgnClockFromMillis emits broadcast-shaped clocks', () {
      expect(formatPgnClockFromMillis(600000), '0:10:00');
      expect(formatPgnClockFromMillis(61000), '0:01:01');
      expect(formatPgnClockFromMillis(3723000), '1:02:03');
      expect(formatPgnClockFromMillis(0), '0:00:00');
      expect(formatPgnClockFromMillis(-5), '0:00:00');
      // Floors sub-second remainders like a real clock face.
      expect(formatPgnClockFromMillis(59999), '0:00:59');

      // Round-trips through the PGN clock parser + display formatter.
      expect(parsePgnClockToSeconds('0:10:00'), 600);
      expect(formatPgnClockForDisplay('0:10:00'), '10:00');
      expect(formatPgnClockForDisplay('1:02:03'), '1:02:03');
    });

    test('human moves append mover snapshots aligned with history', () {
      final notifier = _notifier();
      addTearDown(notifier.dispose);

      expect(notifier.playHumanMove('e2e4'), isTrue);

      expect(notifier.state.history, ['e2e4']);
      expect(notifier.state.clockAfterMoveMillis, hasLength(1));
      // 180s base untouched (the ticker starts with this move) + 2s increment.
      expect(notifier.state.clockAfterMoveMillis.single, 182000);
    });

    test('engine replies append snapshots too', () async {
      final notifier = _notifierWithScriptedEngine(['e7e5', 'b8c6']);
      addTearDown(notifier.dispose);
      await _waitFor(() => notifier.state.engineReady, what: 'engine ready');

      expect(notifier.playHumanMove('e2e4'), isTrue);
      await _waitFor(
        () => notifier.state.history.length == 2,
        what: 'engine reply e7e5',
      );
      expect(notifier.playHumanMove('g1f3'), isTrue);
      await _waitFor(
        () => notifier.state.history.length == 4,
        what: 'engine reply b8c6',
      );

      expect(notifier.state.history, ['e2e4', 'e7e5', 'g1f3', 'b8c6']);
      final clocks = notifier.state.clockAfterMoveMillis;
      expect(clocks, hasLength(4));
      expect(clocks.every((c) => c != null), isTrue);
      // White's first snapshot is exact (no time had burned yet). Later
      // snapshots burned only the in-memory fake-engine round-trip — and with
      // a 2s increment, instant moves bank time, so each side's second
      // snapshot can exceed its first.
      expect(clocks[0], 182000);
      expect(clocks[1]!, lessThanOrEqualTo(182000));
      expect(clocks[1]!, greaterThan(170000));
      expect(clocks[2]!, lessThanOrEqualTo(184000));
      expect(clocks[2]!, greaterThan(170000));
      expect(clocks[3]!, lessThanOrEqualTo(184000));
      expect(clocks[3]!, greaterThan(170000));
    });

    test('seeded prefix moves carry null clocks and stay aligned', () {
      final seeded = debugInitialPlayState(
        _config(startingMovesUci: const ['e2e4', 'e7e5']),
      );
      expect(seeded.history, ['e2e4', 'e7e5']);
      expect(seeded.clockAfterMoveMillis, [null, null]);

      final notifier = _notifier(
        startingMovesUci: const ['e2e4', 'e7e5'],
      );
      addTearDown(notifier.dispose);
      expect(notifier.playHumanMove('g1f3'), isTrue);
      expect(notifier.state.history, ['e2e4', 'e7e5', 'g1f3']);
      expect(notifier.state.clockAfterMoveMillis.take(2), [null, null]);
      expect(notifier.state.clockAfterMoveMillis[2], 182000);
    });

    test('notation game attaches per-move clocks', () {
      final state = debugInitialPlayState(_config()).copyWith(
        history: const ['e2e4', 'e7e5', 'g1f3'],
        clockAfterMoveMillis: const [178000, 179000, 176500],
      );

      final game = debugPlayNotationGame(state);

      expect(game.mainline.map((m) => m.san), ['e4', 'e5', 'Nf3']);
      expect(
        game.mainline.map((m) => m.clockTime).toList(),
        ['0:02:58', '0:02:59', '0:02:56'],
      );
    });

    test('finished-play board PGN round-trips both clocks', () async {
      final notifier = _notifierWithScriptedEngine(['e7e5', 'b8c6']);
      addTearDown(notifier.dispose);
      await _waitFor(() => notifier.state.engineReady, what: 'engine ready');
      expect(notifier.playHumanMove('e2e4'), isTrue);
      await _waitFor(
        () => notifier.state.history.length == 2,
        what: 'engine reply e7e5',
      );
      expect(notifier.playHumanMove('g1f3'), isTrue);
      await _waitFor(
        () => notifier.state.history.length == 4,
        what: 'engine reply b8c6',
      );
      final finished = notifier.state.copyWith(
        endReason: PlayEndReason.blackCheckmated,
        outcome: Outcome.whiteWins,
        clearActiveClock: true,
        clearLastTick: true,
      );

      final args = debugFinishedPlayBoardArgs(
        finished,
        null,
        userDisplayName: 'Berkay Can',
      );

      final pgn = args.pgn;
      expect('[%clk '.allMatches(pgn).length, 4);
      // Same walk-back the Board pane runs from the active pointer: latest
      // [%clk] per side is what lands in the player headers.
      final parsed = ChessGame.fromPgn('test', pgn);
      final clocks = _latestClocksPerSide(parsed.mainline);
      expect(
        clocks.$1,
        formatPgnClockFromMillis(finished.clockAfterMoveMillis[2]!),
      );
      expect(
        clocks.$2,
        formatPgnClockFromMillis(finished.clockAfterMoveMillis[3]!),
      );
    });

    test('saved-game analysis PGN carries clocks', () async {
      final notifier = _notifierWithScriptedEngine(['e7e5']);
      addTearDown(notifier.dispose);
      await _waitFor(() => notifier.state.engineReady, what: 'engine ready');
      expect(notifier.playHumanMove('e2e4'), isTrue);
      await _waitFor(
        () => notifier.state.history.length == 2,
        what: 'engine reply e7e5',
      );
      final finished = notifier.state.copyWith(
        endReason: PlayEndReason.blackCheckmated,
        outcome: Outcome.whiteWins,
        clearActiveClock: true,
        clearLastTick: true,
      );

      final record = await const PlayGameAnalyzer().analyzeSession(finished);

      expect('[%clk '.allMatches(record.pgn).length, 2);
      final parsed = ChessGame.fromPgn('test', record.pgn);
      final clocks = _latestClocksPerSide(parsed.mainline);
      expect(
        clocks.$1,
        formatPgnClockFromMillis(finished.clockAfterMoveMillis[0]!),
      );
      expect(
        clocks.$2,
        formatPgnClockFromMillis(finished.clockAfterMoveMillis[1]!),
      );
    });
  });
}

/// Mirrors the Board pane's per-side clock walk-back: scan the active line
/// backwards and keep the most recent `[%clk]` per colour.
(String? white, String? black) _latestClocksPerSide(List<ChessMove> mainline) {
  String? white;
  String? black;
  for (var i = mainline.length - 1; i >= 0; i--) {
    final m = mainline[i];
    if (m.clockTime == null) continue;
    if (m.turn == ChessColor.white && white == null) {
      white = m.clockTime;
    } else if (m.turn == ChessColor.black && black == null) {
      black = m.clockTime;
    }
    if (white != null && black != null) break;
  }
  return (white, black);
}

Future<void> _waitFor(bool Function() done, {required String what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

PlayConfig _config({List<String> startingMovesUci = const <String>[]}) {
  return PlayConfig(
    engine: BotEngineKind.stockfish,
    elo: 1500,
    category: TimeControlCategory.blitz,
    baseSeconds: 180,
    incrementSeconds: 2,
    color: PlayColorChoice.white,
    startingFen: Chess.initial.fen,
    startingMovesUci: startingMovesUci,
  );
}

PlaySessionNotifier _notifier({
  List<String> startingMovesUci = const <String>[],
}) {
  return PlaySessionNotifier(
    config: _config(startingMovesUci: startingMovesUci),
    engineBinaryPath: '/no-engine-needed',
    botIdentity: _testBot,
    bootEngine: false,
  );
}

PlaySessionNotifier _notifierWithScriptedEngine(List<String> bestmoves) {
  return PlaySessionNotifier(
    config: _config(),
    engineBinaryPath: 'test-engine',
    botIdentity: _testBot,
    spawnEngine: () async {
      return UciEngine.fromProcessForTesting(
        _ScriptedProcess(List<String>.of(bestmoves)),
        gracefulExitTimeout: const Duration(milliseconds: 20),
      );
    },
  );
}

const _testBot = BotIdentity(
  firstName: 'Test',
  lastName: 'Bot',
  countryCode: 'US',
  elo: 1500,
);

/// Fake UCI process: answers the handshake and replays one scripted bestmove
/// per `go` command.
class _ScriptedProcess implements Process {
  _ScriptedProcess(this._bestmoves) {
    _stdout = StreamController<List<int>>();
    _stderr = StreamController<List<int>>();
    _stdin = IOSink(
      _LineConsumer(
        onLine: (line) {
          if (line == 'uci') _emit('uciok');
          if (line == 'isready') _emit('readyok');
          if (line.startsWith('go') && _bestmoves.isNotEmpty) {
            _emit('bestmove ${_bestmoves.removeAt(0)}');
          }
          if (line == 'quit' && !_exit.isCompleted) _exit.complete(0);
        },
      ),
    );
  }

  final List<String> _bestmoves;
  final Completer<int> _exit = Completer<int>();
  late final IOSink _stdin;
  late final StreamController<List<int>> _stdout;
  late final StreamController<List<int>> _stderr;

  void _emit(String line) {
    if (!_stdout.isClosed) _stdout.add(utf8.encode('$line\n'));
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 42;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }
}

class _LineConsumer implements StreamConsumer<List<int>> {
  _LineConsumer({required this.onLine});

  final void Function(String line) onLine;
  String _pending = '';

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      _pending += utf8.decode(bytes);
      while (_pending.contains('\n')) {
        final newline = _pending.indexOf('\n');
        final line = _pending.substring(0, newline).replaceAll('\r', '');
        _pending = _pending.substring(newline + 1);
        onLine(line);
      }
    }
  }

  @override
  Future<void> close() async {}
}
