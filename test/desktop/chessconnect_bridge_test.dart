import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/chessconnect/chessconnect_bridge.dart';
import 'package:chessever/desktop/services/chessconnect/chessconnect_sources.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';

/// The Chessconnect adapter is the only part of the web app a third-party
/// browser extension talks to. These tests pin its security contract: only
/// what is on screen leaves, ids are opaque, and nothing but a legal board
/// move, at a human pace, on the focused board, gets in.
void main() {
  late DateTime now;
  late ChessconnectBridge bridge;

  setUp(() {
    now = DateTime.utc(2026, 11, 26, 12);
    bridge = ChessconnectBridge(now: () => now, random: math.Random(7));
  });

  BoardChessconnectSource boardAt(
    String fen, {
    String gameKey = 'board:tab-1:secret-db-id-123:start',
    bool acceptsMoves = true,
    List<NormalMove>? applied,
  }) {
    final source = BoardChessconnectSource(
      applyMove: (move) => applied?.add(move),
    );
    source.update(
      gameKey: gameKey,
      position: Chess.fromSetup(Setup.parseFen(fen)),
      orientation: Side.white,
      acceptsMoves: acceptsMoves,
    );
    return source;
  }

  group('getState', () {
    test('is null with no board attached', () {
      expect(bridge.state(), isNull);
    });

    test('a replay board reports only the shown position, as spec 4.8', () {
      final owner = Object();
      bridge.attach(owner, boardAt(Chess.initial.fen));
      final state = bridge.state()!;
      expect(state['state'], 'ongoing');
      expect(state['playerColor'], 'both');
      expect(state['fen'], Chess.initial.fen);
      expect(state['clock'], isNull);
      expect(state['result'], isNull);
      expect(state['variant'], 'standard');
      expect(state['orientation'], 'white');
      expect(state.keys.toSet(), {
        'gameId',
        'state',
        'playerColor',
        'fen',
        'result',
        'clock',
        'variant',
        'orientation',
      });
      bridge.detach(owner);
      expect(bridge.state(), isNull);
    });

    test('game ids are opaque tokens, stable per game, new per game', () {
      final owner = Object();
      bridge.attach(owner, boardAt(Chess.initial.fen));
      final first = bridge.state()!['gameId']! as String;
      expect(first, matches(RegExp(r'^ce-[a-z0-9]{8}-\d+$')));
      expect(first, isNot(contains('secret')));
      expect(first, isNot(contains('tab-1')));
      expect(bridge.state()!['gameId'], first);

      bridge.attach(owner, boardAt(Chess.initial.fen, gameKey: 'other'));
      expect(bridge.state()!['gameId'], isNot(first));
    });

    test('never throws, even when the board does', () {
      bridge.attach(Object(), _ThrowingSource());
      expect(bridge.state(), isNull);
      expect(bridge.move('e2e4').ok, isFalse);
    });

    test(
      'only the last attached board is reported; a stale detach is a no-op',
      () {
        final a = Object();
        final b = Object();
        bridge.attach(a, boardAt(Chess.initial.fen));
        bridge.attach(b, boardAt(_afterE4));
        bridge.detach(a);
        expect(bridge.state()!['fen'], _afterE4);
      },
    );
  });

  group('move', () {
    test('rejects anything that is not a strict UCI string', () {
      bridge.attach(Object(), boardAt(Chess.initial.fen));
      for (final raw in <Object?>[
        null,
        42,
        <String>['e2e4'],
        '',
        'e2e4 ',
        ' e2e4',
        'E2E4',
        'e2e9',
        'e2e4k',
        'e7e8p',
        'e2e2',
        'O-O',
        'e4',
        'e2e4\u0000',
        '<img src=x onerror=alert(1)>',
        'e2e4' * 1000,
      ]) {
        expect(bridge.move(raw).ok, isFalse, reason: '$raw');
      }
    });

    test('plays a legal move and reports the new position at once', () {
      final applied = <NormalMove>[];
      bridge.attach(Object(), boardAt(Chess.initial.fen, applied: applied));
      expect(bridge.move('e2e4').ok, isTrue);
      expect(applied.single.uci, 'e2e4');
      expect(bridge.state()!['fen'], _afterE4);
    });

    test('refuses illegal moves and boards that take no moves', () {
      final applied = <NormalMove>[];
      bridge.attach(Object(), boardAt(Chess.initial.fen, applied: applied));
      expect(bridge.move('e2e5').ok, isFalse);
      expect(bridge.move('e7e5').ok, isFalse, reason: 'not White to move');

      bridge.attach(
        Object(),
        boardAt(Chess.initial.fen, applied: applied, acceptsMoves: false),
      );
      expect(bridge.move('e2e4').ok, isFalse);
      expect(applied, isEmpty);
    });

    test('a promotion must name its piece, and only a promotion may', () {
      const fen = '8/4P3/8/8/8/8/k7/4K3 w - - 0 1';
      final applied = <NormalMove>[];
      bridge.attach(Object(), boardAt(fen, applied: applied));
      expect(bridge.move('e7e8').ok, isFalse);
      expect(bridge.move('e1d1q').ok, isFalse);
      expect(bridge.move('e7e8n').ok, isTrue);
      expect(applied.single.promotion, Role.knight);
    });

    test('castling is accepted as the king move', () {
      const fen = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';
      final applied = <NormalMove>[];
      bridge.attach(Object(), boardAt(fen, applied: applied));
      expect(bridge.move('e1g1').ok, isTrue);
      expect(applied, hasLength(1));
    });

    test('is rate limited to a human pace', () {
      final source = _CountingSource();
      bridge.attach(Object(), source);
      for (var i = 0; i < 8; i++) {
        expect(bridge.move('e2e4').ok, isTrue);
      }
      expect(bridge.move('e2e4').ok, isFalse);
      expect(source.moves, 8);
      now = now.add(const Duration(seconds: 1));
      expect(bridge.move('e2e4').ok, isTrue);
    });

    test('with no board attached, nothing is played', () {
      expect(bridge.move('e2e4').ok, isFalse);
    });
  });

  group('onConnectionChange', () {
    test('keeps only a short, plain board family name', () {
      bridge.connectionChanged(connected: true, board: 'CHESSNUT');
      expect(bridge.connection.value!.connected, isTrue);
      expect(bridge.connection.value!.board, 'CHESSNUT');

      bridge.connectionChanged(connected: true, board: '<script>x</script>');
      expect(bridge.connection.value!.board, isNull);

      bridge.connectionChanged(connected: true, board: 'X' * 33);
      expect(bridge.connection.value!.board, isNull);

      bridge.connectionChanged(connected: false, board: 'DGT');
      expect(bridge.connection.value!.connected, isFalse);
      expect(bridge.connection.value!.board, isNull);
    });

    test('ignores malformed calls', () {
      bridge.connectionChanged(connected: 'yes');
      expect(bridge.connection.value, isNull);
    });
  });

  group('Play against a bot', () {
    PlaySessionState playState({
      PlayColorChoice color = PlayColorChoice.white,
    }) => debugInitialPlayState(
      PlayConfig.defaults.copyWith(
        color: color,
        baseSeconds: 180,
        blackBaseSeconds: 120,
      ),
    );

    test('reports the user colour, clocks and lifecycle', () {
      final initial = playState();
      var snap = playChessconnectSnapshot(initial, gameKey: 'g', now: now);
      expect(snap.state, ChessconnectGameState.notStarted);
      expect(snap.playerColor, ChessconnectPlayerColor.white);
      expect(snap.clock!.whiteInitialMs, 180000);
      expect(snap.clock!.blackInitialMs, 120000);
      expect(snap.clock!.running, isNull);

      final running = initial.copyWith(
        activeClock: Side.white,
        lastClockTick: now.subtract(const Duration(milliseconds: 1500)),
      );
      snap = playChessconnectSnapshot(running, gameKey: 'g', now: now);
      expect(snap.state, ChessconnectGameState.ongoing);
      expect(snap.clock!.running, Side.white);
      expect(snap.clock!.whiteMs, 178500);
      expect(snap.clock!.blackMs, 120000);
    });

    test('a finished game carries the PGN result by colour', () {
      final base = playState(color: PlayColorChoice.black);
      final won = base.copyWith(
        endReason: PlayEndReason.whiteResigned,
        outcome: Outcome.blackWins,
      );
      var snap = playChessconnectSnapshot(won, gameKey: 'g', now: now);
      expect(snap.state, ChessconnectGameState.finished);
      expect(snap.result, '0-1');
      expect(snap.clock!.running, isNull);

      final aborted = base.copyWith(endReason: PlayEndReason.aborted);
      snap = playChessconnectSnapshot(aborted, gameKey: 'g', now: now);
      expect(snap.result, 'aborted');

      final drawn = base.copyWith(
        endReason: PlayEndReason.stalemate,
        outcome: Outcome.draw,
      );
      snap = playChessconnectSnapshot(drawn, gameKey: 'g', now: now);
      expect(snap.result, '1/2-1/2');
    });

    test('moves only on the user\'s turn, never as a premove', () {
      var state = playState();
      final played = <String>[];
      final source = PlayChessconnectSource(
        readState: () => state,
        playHumanMove: (uci) {
          played.add(uci);
          return true;
        },
        gameKey: 'g',
        now: () => now,
      );
      bridge.attach(Object(), source);

      expect(bridge.move('e7e5').ok, isFalse, reason: 'the bot is Black');
      expect(bridge.move('e2e4').ok, isTrue);
      expect(played, ['e2e4']);

      state = state.copyWith(engineThinking: true);
      expect(bridge.move('d2d4').ok, isFalse, reason: 'bot is thinking');

      state = state.copyWith(
        engineThinking: false,
        endReason: PlayEndReason.whiteResigned,
        outcome: Outcome.blackWins,
      );
      expect(bridge.move('d2d4').ok, isFalse, reason: 'game over');
      expect(played, ['e2e4']);
    });

    test('the clock counting down is not a change; a move is', () {
      final state = playState().copyWith(
        activeClock: Side.white,
        lastClockTick: now,
      );
      final ticked = state.copyWith(whiteMillis: state.whiteMillis - 100);
      expect(
        playChessconnectSignature(ticked),
        playChessconnectSignature(state),
      );
      final moved = state.copyWith(
        position: state.position.play(NormalMove.fromUci('e2e4')),
        history: const ['e2e4'],
      );
      expect(
        playChessconnectSignature(moved),
        isNot(playChessconnectSignature(state)),
      );
    });
  });
}

const String _afterE4 =
    'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

class _ThrowingSource implements ChessconnectSource {
  @override
  ChessconnectSnapshot? snapshot() => throw StateError('board gone');

  @override
  bool playMove(NormalMove move) => throw StateError('board gone');
}

class _CountingSource implements ChessconnectSource {
  int moves = 0;

  @override
  ChessconnectSnapshot? snapshot() => null;

  @override
  bool playMove(NormalMove move) {
    moves++;
    return true;
  }
}
