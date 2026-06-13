import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/chessboard/widgets/evaluation_bar_widget.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/responsive_helper.dart';

const _kFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class _FakeGameStreamRepository extends GameStreamRepository {
  @override
  Stream<Map<String, dynamic>?> subscribeToGameUpdates(String gameId) {
    return const Stream.empty();
  }
}

void main() {
  testWidgets('finished live game cards can be saved from right-click menu', (
    tester,
  ) async {
    await _pumpCard(tester, _game(status: GameStatus.whiteWins));

    await _openContextMenu(tester);

    expect(find.text('Save to library'), findsOneWidget);
  });

  testWidgets('ongoing live game cards omit save-to-library action', (
    tester,
  ) async {
    await _pumpCard(tester, _game(status: GameStatus.ongoing));

    await _openContextMenu(tester);

    expect(find.text('Save to library'), findsNothing);
    expect(find.text('Share Game'), findsOneWidget);
  });

  testWidgets('grid cards hide eval rail when board setting is disabled', (
    tester,
  ) async {
    await _pumpDesktopGameCard(
      tester,
      _cardData(),
      _EvaluationBarOffNotifier.new,
    );

    expect(find.byType(EvaluationBarWidgetForGames), findsNothing);
  });

  testWidgets('grid cards show eval rail when board setting is enabled', (
    tester,
  ) async {
    await _pumpDesktopGameCard(
      tester,
      _cardData(),
      _EvaluationBarOnNotifier.new,
    );

    expect(find.byType(EvaluationBarWidgetForGames), findsOneWidget);
  });
}

Future<void> _pumpCard(WidgetTester tester, GamesTourModel game) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardSettingsProviderNew.overrideWith(_EvaluationBarOnNotifier.new),
        gameStreamRepositoryProvider.overrideWithValue(
          _FakeGameStreamRepository(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              child: LiveDesktopGameCard(
                game: game,
                tournamentTitle: 'Test Event',
                layout: DesktopCardLayout.compact,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpDesktopGameCard(
  WidgetTester tester,
  GameCardData data,
  BoardSettingsNotifierNew Function() createNotifier,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardSettingsProviderNew.overrideWith(createNotifier),
        gameCardEvalWithStockfishFallbackProvider.overrideWith(
          (ref, fen) async => _cloudEval(),
        ),
        gameCardEvalCacheOnlyProvider.overrideWith(
          (ref, fen) async => _cloudEval(),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return Scaffold(
              body: Center(
                child: SizedBox(
                  width: 260,
                  height: 320,
                  child: DesktopGameCard(
                    data: data,
                    layout: DesktopCardLayout.grid,
                    allowStockfishFallback: false,
                    onTap: () {},
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openContextMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byType(DesktopGameCard)),
    buttons: kSecondaryMouseButton,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

GamesTourModel _game({required GameStatus status}) {
  return GamesTourModel(
    gameId: 'game-${status.name}',
    whitePlayer: _player('White'),
    blackPlayer: _player('Black'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'tour-1',
    tourSlug: 'test-event',
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: null,
  );
}

CloudEval _cloudEval() {
  return CloudEval(
    fen: _kFen,
    knodes: 0,
    depth: 12,
    pvs: [Pv(moves: 'e2e4', cp: 32)],
    requestedMultiPv: 1,
  );
}

GameCardData _cardData() {
  return const GameCardData(
    id: 'live-grid-card',
    title: 'White vs Black',
    whiteName: 'White',
    blackName: 'Black',
    whiteFederation: 'USA',
    blackFederation: 'USA',
    whiteTitle: 'GM',
    blackTitle: 'GM',
    whiteRating: 2700,
    blackRating: 2700,
    fen: _kFen,
    status: GameStatus.ongoing,
    hasStarted: true,
  );
}

class _EvaluationBarOffNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: false);
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _EvaluationBarOnNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew(showEvaluationBar: true);
    state = const AsyncValue.data(settings);
    return settings;
  }
}
