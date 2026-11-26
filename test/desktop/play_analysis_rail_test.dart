import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/widgets/board_move_badge.dart';
import 'package:chessever/desktop/widgets/board_like_button.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';

const _tabId = 'play-rail-test';

Widget _harness({required bool liveHelp}) => ProviderScope(
  overrides: [
    boardSettingsProviderNew.overrideWith(
      () => _FixedBoardSettings(BoardSettingsNew(showPlayLiveHelp: liveHelp)),
    ),
    playSessionBootEngineProvider.overrideWithValue(false),
    playSessionArgsByTabIdProvider.overrideWith(
      (ref) => const <String, PlaySessionArgs>{
        _tabId: PlaySessionArgs(
          config: PlayConfig(
            engine: BotEngineKind.stockfish,
            elo: 1500,
            category: TimeControlCategory.blitz,
            baseSeconds: 180,
            incrementSeconds: 2,
            color: PlayColorChoice.white,
            startClockImmediately: false,
            startingFen: null,
            startingMovesUci: <String>[],
          ),
          engineBinaryPath: '',
          botIdentity: BotIdentity(
            firstName: 'Test',
            lastName: 'Bot',
            countryCode: 'US',
            elo: 1500,
          ),
        ),
      },
    ),
  ],
  child: FTheme(
    data: FThemes.zinc.dark,
    child: const MaterialApp(
      home: Scaffold(body: PlayActiveGameView(tabId: _tabId)),
    ),
  ),
);

class _FixedBoardSettings extends BoardSettingsNotifierNew {
  _FixedBoardSettings(this.settings);

  final BoardSettingsNew settings;

  @override
  Future<BoardSettingsNew> build() async => settings;
}

Position _after(String fen, String uci) =>
    Chess.fromSetup(Setup.parseFen(fen)).play(Move.parse(uci)!);

void main() {
  group('play analysis rail', () {
    testWidgets('live help carries the watching rail, without Like', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_harness(liveHelp: true));
      // Drain the board-size preference read's timeout timer.
      await tester.pump(const Duration(seconds: 5));

      // The watching board's rail: the Stockfish and Toby pane, explorer,
      // notation and the move controls.
      expect(find.byType(NotationOpeningPanel), findsOneWidget);
      expect(find.byType(EnginePanel), findsOneWidget);
      // Liked games are listed publicly; a game against a bot is private.
      expect(find.byType(DesktopBoardLikeButton), findsNothing);
      // The switch stays, so the player can go back to competition.
      expect(find.bySemanticsLabel('Live help'), findsOneWidget);
      expect(find.text('Resign'), findsOneWidget);
      expect(find.text('Abort'), findsOneWidget);
    });

    testWidgets('without live help the game is played as in competition', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_harness(liveHelp: false));
      await tester.pump(const Duration(seconds: 5));

      // Moves and game controls only: no engine, Toby or explorer.
      expect(find.byType(NotationOpeningPanel), findsNothing);
      expect(find.byType(EnginePanel), findsNothing);
      expect(find.byType(NotationLadderView), findsOneWidget);
      expect(find.byType(FSwitch), findsOneWidget);
      expect(find.text('Live help'), findsOneWidget);
      expect(find.text('Resign'), findsOneWidget);
      expect(find.text('Abort'), findsOneWidget);
    });
  });

  group('board move badge square', () {
    test('sits on the square the piece landed on', () {
      final after = _after(Chess.initial.fen, 'g1f3');
      expect(boardMoveBadgeSquare(after, Move.parse('g1f3')), Square.f3);
    });

    test('a king-to-rook castle anchors to the king, not the rook', () {
      const castleFen = 'r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1';
      final kingSide = _after(castleFen, 'e1h1');
      expect(boardMoveBadgeSquare(kingSide, Move.parse('e1h1')), Square.g1);
      final queenSide = _after(castleFen, 'e1a1');
      expect(boardMoveBadgeSquare(queenSide, Move.parse('e1a1')), Square.c1);
    });

    test('a rook move to a corner stays on the rook', () {
      const fen = '4k3/8/8/8/8/8/8/R3K3 w Q - 0 1';
      final after = _after(fen, 'a1a8');
      expect(boardMoveBadgeSquare(after, Move.parse('a1a8')), Square.a8);
    });
  });
}
