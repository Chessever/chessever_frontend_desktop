import 'dart:async';

import 'package:chessever/desktop/widgets/desktop_endgame_board_overlay.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/utils/date_time_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
final _moveTime = DateTime.utc(2026, 10, 16, 17);

// Played positions captured from the public U.S. Championship round-7 rows.
// Tournament preview payloads intentionally omit PGN; FEN must stand alone.
final _women = <GamesTourModel>[
  _game(
    'women-1',
    '8/8/2nk4/8/R2p1PP1/3BbK2/8/8 b - - 0 60',
    'g3g4',
    GameStatus.whiteWins,
    'women',
  ),
  _game(
    'women-2',
    '1r6/6k1/p2R1B2/2K2bP1/2P5/1P6/P7/8 b - - 9 53',
    'd8f6',
    GameStatus.whiteWins,
    'women',
  ),
  _game(
    'women-3',
    '6k1/p5p1/8/7R/Pq5P/2p5/2P1R3/1K6 w - - 1 48',
    'd4b4',
    GameStatus.blackWins,
    'women',
  ),
  _game(
    'women-4',
    '7k/6pp/4b3/p3P3/Pp3P1q/2p1nQ2/3rB2P/B5RK w - - 0 47',
    'f5e3',
    GameStatus.blackWins,
    'women',
  ),
  _game(
    'women-5',
    '8/1q3pk1/5p1p/8/p5P1/P3QK1P/5P2/8 w - - 28 49',
    'b3b7',
    GameStatus.draw,
    'women',
  ),
  _game(
    'women-6',
    '8/8/p4p1p/Pp5P/1P3Pk1/R1n5/1Nrr4/K6R w - - 8 51',
    'g2d2',
    GameStatus.blackWins,
    'women',
  ),
];
final _open = <GamesTourModel>[
  _game(
    'open-1',
    '8/2p2k2/4pn1r/1p1b1p1P/2pP1P1K/P1P5/8/3BB1R1 w - - 8 48',
    'h8h6',
    GameStatus.draw,
    'open',
  ),
  _game(
    'open-2',
    'r2b1rk1/1p1bn1pB/1P1p3p/p1pPp3/P1P4q/5R1P/1B1N1PP1/1Q2R1K1 b - - 2 27',
    'd3h7',
    GameStatus.whiteWins,
    'open',
  ),
];

GamesTourModel _game(
  String id,
  String fen,
  String lastMove,
  GameStatus status,
  String tour,
) {
  PlayerCard player(String side) => PlayerCard(
    name: '$side $id',
    federation: 'USA',
    title: '',
    rating: 2400,
    countryCode: 'USA',
    team: null,
  );
  return GamesTourModel(
    gameId: id,
    whitePlayer: player('White'),
    blackPlayer: player('Black'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: '$tour-round-7',
    tourId: tour,
    fen: fen,
    lastMove: lastMove,
    lastMoveTime: _moveTime,
  );
}

class _Rows extends GameStreamRepository {
  int subscriptions = 0;
  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> ids,
  ) {
    subscriptions++;
    return const Stream.empty();
  }
}

class _BoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(showEvaluationBar: false);
}

class _EngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineGauge: false);
}

void _expectPositions(WidgetTester tester, List<GamesTourModel> seeds) {
  expect(find.byType(LiveDesktopGameCard), findsNWidgets(seeds.length));
  for (final seed in seeds) {
    final card = find.byWidgetPredicate(
      (widget) =>
          widget is LiveDesktopGameCard && widget.game.gameId == seed.gameId,
    );
    final decorated = tester.widget<DesktopEndgameBoard>(
      find.descendant(of: card, matching: find.byType(DesktopEndgameBoard)),
    );
    expect(decorated.fen, seed.fen, reason: seed.gameId);
    expect(decorated.status, seed.gameStatus, reason: seed.gameId);
    final painted = tester.widget<cg.StaticChessboard>(
      find.descendant(of: card, matching: find.byType(cg.StaticChessboard)),
    );
    final expected = <Square, Piece>{
      for (final (square, piece) in Setup.parseFen(seed.fen!).board.pieces)
        if (!(piece.role == Role.king &&
            ((seed.gameStatus == GameStatus.whiteWins &&
                    piece.color == Side.black) ||
                (seed.gameStatus == GameStatus.blackWins &&
                    piece.color == Side.white))))
          square: piece,
    };
    final actual = <Square, Piece>{
      for (final (square, piece) in Setup.parseFen(painted.fen).board.pieces)
        square: piece,
    };
    expect(
      actual,
      expected,
      reason: 'actual painted pieces for ${seed.gameId}',
    );
  }
  expect(tester.takeException(), isNull);
}

Future<void> _exercise(
  WidgetTester tester, {
  required bool switchSections,
}) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final rows = _Rows();
  final selected = ValueNotifier<List<GamesTourModel>>(
    switchSections ? _open : _women,
  );
  final scroll = ScrollController();
  final container = ProviderContainer(
    overrides: [
      gameStreamRepositoryProvider.overrideWithValue(rows),
      boardSettingsProviderNew.overrideWith(_BoardSettings.new),
      engineSettingsProviderNew.overrideWith(_EngineSettings.new),
      dateTimeProvider.overrideWith((ref) => Stream.value(_moveTime)),
    ],
  );
  // A retained card from another surface can own an incomplete seed. Its
  // metadata timestamp is newer, but it has no played position or PGN.
  final retained = [
    for (final game in _women)
      container.listen(baseGameProvider(game.gameId), (_, __) {}),
  ];
  for (final game in _women) {
    container.read(baseGameProvider(game.gameId).notifier).state = game
        .copyWith(
          fen: _startFen,
          clearLastMove: true,
          lastMoveTime: _moveTime.add(const Duration(minutes: 1)),
        );
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return Scaffold(
              body: ValueListenableBuilder<List<GamesTourModel>>(
                valueListenable: selected,
                builder:
                    (context, games, _) =>
                        buildLazyTournamentGamesViewportForTesting(
                          games: games,
                          scrollController: scroll,
                          scopeId: 'section:${games.first.tourId}',
                          layout: DesktopCardLayout.grid,
                          cacheExtent: 2000,
                        ),
              ),
            );
          },
        ),
      ),
    ),
  );
  _expectPositions(tester, selected.value);
  await tester.pump(const Duration(milliseconds: 100));
  _expectPositions(tester, selected.value);
  if (switchSections) {
    selected.value = _women;
    await tester.pump();
    _expectPositions(tester, _women);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    _expectPositions(tester, _women);
  }
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 40));
    _expectPositions(tester, _women);
  }
  if (switchSections) {
    selected.value = _open;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    _expectPositions(tester, _open);

    selected.value = _women;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    _expectPositions(tester, _women);
    // Observe the newly mounted result-overlay entrance frames as well as
    // the first paint before disposing this section.
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 40));
      _expectPositions(tester, _women);
    }
  }
  expect(
    rows.subscriptions,
    0,
    reason:
        'Finished grid cards cannot rely on a live stream to repair a retained seed.',
  );
  await tester.pumpWidget(const SizedBox.shrink());
  for (final subscription in retained) {
    subscription.close();
  }
  container.dispose();
  await tester.pump();
  selected.dispose();
  scroll.dispose();
}

void main() {
  test(
    'finished-position recovery is restricted to incomplete same-game seeds',
    () {
      final finished = _women.first;
      final placeholder = finished.copyWith(
        fen: _startFen,
        clearLastMove: true,
        lastMoveTime: _moveTime.add(const Duration(minutes: 1)),
      );
      for (final seed in [
        placeholder,
        placeholder.copyWith(clearFen: true),
        placeholder.copyWith(pgn: '[Event "Header only"]\n\n*'),
      ]) {
        expect(shouldReplaceBaseGame(seed, finished), isTrue);
        expect(
          shouldReplaceBaseGame(
            seed,
            finished.copyWith(clearLastMoveTime: true),
          ),
          isTrue,
        );
      }
      expect(
        shouldReplaceBaseGame(
          placeholder.copyWith(pgn: '[SetUp "1"]\n[FEN "$_startFen"]\n\n*'),
          finished,
        ),
        isFalse,
        reason: 'An explicit zero-move reset is not a placeholder.',
      );
      expect(
        shouldReplaceBaseGame(
          finished.copyWith(
            lastMoveTime: _moveTime.add(const Duration(minutes: 1)),
          ),
          finished,
        ),
        isFalse,
        reason: 'A played position retains ordinary freshness arbitration.',
      );
      expect(
        shouldReplaceBaseGame(
          placeholder,
          finished.copyWith(gameStatus: GameStatus.ongoing),
        ),
        isFalse,
      );
      expect(
        shouldReplaceBaseGame(
          placeholder,
          finished.copyWith(gameId: 'other-game'),
        ),
        isFalse,
      );
      expect(
        shouldReplaceBaseGame(
          placeholder,
          finished.copyWith(source: GameSource.gamebase),
        ),
        isFalse,
      );
      expect(
        shouldReplaceBaseGame(
          placeholder,
          finished.copyWith(fen: _startFen.replaceAll('0 1', '0 99')),
        ),
        isFalse,
        reason: 'A move counter alone does not prove played-position recovery.',
      );
      expect(
        shouldReplaceBaseGame(
          placeholder,
          finished.copyWith(fen: _startFen, clearLastMove: true),
        ),
        isFalse,
        reason: 'A genuine unplayed result must not invent a played position.',
      );
      expect(
        shouldReplaceBaseGame(
          placeholder,
          finished.copyWith(
            fen: _startFen,
            pgn: '1. Nf3 Nf6 2. Ng1 Ng8 1/2-1/2',
            lastMove: 'f6g8',
            gameStatus: GameStatus.draw,
          ),
        ),
        isTrue,
        reason: 'A real PGN can finish with the initial piece arrangement.',
      );
    },
  );
  testWidgets(
    'Open to Women to Open repairs newer retained placeholders from six finished FEN-only rows',
    (tester) => _exercise(tester, switchSections: true),
  );
  testWidgets(
    'direct Women section repairs every retained placeholder without a summary PGN',
    (tester) => _exercise(tester, switchSections: false),
  );
}
