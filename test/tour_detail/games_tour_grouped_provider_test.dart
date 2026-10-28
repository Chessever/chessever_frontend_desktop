import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';

void main() {
  test(
    'empty Live result is ready when the tournament has completed games',
    () {
      const providerGameIds = <String>['completed-game'];
      const modeledGameIds = <String>[];
      expect(
        isGamesModelReadyForDisplay(
          displayMode: GameDisplayMode.hideFinishedGames,
          isSearchMode: false,
          providerGameCount: providerGameIds.length,
          modelGameCount: modeledGameIds.length,
          providerGamesFingerprint: Object.hashAll(providerGameIds),
          modelGamesFingerprint: Object.hashAll(modeledGameIds),
        ),
        isTrue,
      );
    },
  );

  test('empty All snapshot waits for raw games to be modeled', () {
    const providerGameIds = <String>['current-game'];
    const modeledGameIds = <String>[];
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: providerGameIds.length,
        modelGameCount: modeledGameIds.length,
        providerGamesFingerprint: Object.hashAll(providerGameIds),
        modelGamesFingerprint: Object.hashAll(modeledGameIds),
      ),
      isFalse,
    );
  });

  test('partial All snapshot waits for the complete provider model', () {
    const providerGameIds = <String>['board-a', 'board-b', 'board-c'];
    const modeledGameIds = <String>['board-b'];
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: providerGameIds.length,
        modelGameCount: modeledGameIds.length,
        providerGamesFingerprint: Object.hashAll(providerGameIds),
        modelGamesFingerprint: Object.hashAll(modeledGameIds),
      ),
      isFalse,
    );
  });

  test(
    'complete source coverage is ready when malformed models are skipped',
    () {
      const sourceGameIds = <String>['renderable-game', 'malformed-game'];
      final sourceFingerprint = Object.hashAll(sourceGameIds);
      final model = GamesScreenModel(
        gamesTourModels: const [],
        pinnedGamedIs: const [],
        sourceGameCount: sourceGameIds.length,
        sourceGamesFingerprint: sourceFingerprint,
      );

      expect(
        isGamesModelReadyForDisplay(
          displayMode: GameDisplayMode.all,
          isSearchMode: false,
          providerGameCount: sourceGameIds.length,
          modelGameCount: model.sourceGameCount,
          providerGamesFingerprint: sourceFingerprint,
          modelGamesFingerprint: model.sourceGamesFingerprint,
        ),
        isTrue,
      );
    },
  );

  test('same-size All snapshot waits for the current live-round identity', () {
    const previousRoundGameIds = <String>['previous-round-board'];
    const currentRoundGameIds = <String>['current-round-board'];
    expect(
      isGamesModelReadyForDisplay(
        displayMode: GameDisplayMode.all,
        isSearchMode: false,
        providerGameCount: currentRoundGameIds.length,
        modelGameCount: previousRoundGameIds.length,
        providerGamesFingerprint: Object.hashAll(currentRoundGameIds),
        modelGamesFingerprint: Object.hashAll(previousRoundGameIds),
      ),
      isFalse,
    );
  });

  test('Live mode includes only games explicitly marked ongoing', () {
    expect(
      isGameStatusVisible(
        displayMode: GameDisplayMode.hideFinishedGames,
        gameStatus: GameStatus.ongoing,
      ),
      isTrue,
    );

    for (final status in <GameStatus>[
      GameStatus.whiteWins,
      GameStatus.blackWins,
      GameStatus.draw,
      GameStatus.unknown,
    ]) {
      expect(
        isGameStatusVisible(
          displayMode: GameDisplayMode.hideFinishedGames,
          gameStatus: status,
        ),
        isFalse,
        reason: '$status is not a live game',
      );
    }
  });

  test('hides unresolved starting-position placeholders', () {
    expect(
      isEventBoardGameVisible(
        _board(
          id: 'future-placeholder',
          whiteName: '?',
          blackName: '?',
          fen: _initialFen,
        ),
      ),
      isFalse,
    );
  });

  test('hides named unstarted pairings as standalone event boards', () {
    expect(
      isEventBoardGameVisible(
        _board(
          id: 'future-pairing',
          whiteName: 'Nepal, H',
          blackName: 'Flores Quillas, D',
          fen: _initialFen,
        ),
      ),
      isFalse,
    );
  });

  test('keeps finished named no-move games as real boards', () {
    expect(
      isEventBoardGameVisible(
        _board(
          id: 'forfeit-no-moves',
          whiteName: 'Player A',
          blackName: 'Player B',
          fen: _initialFen,
          gameStatus: GameStatus.whiteWins,
        ),
      ),
      isTrue,
    );
  });

  test(
    'merges unstarted named pairings onto a live round that already has a move',
    () {
      const roundId = 'olympiad-round-1';
      final started = _board(
        id: 'started-board',
        whiteName: 'Nepal, H',
        blackName: 'Flores Quillas, D',
        lastMove: 'e2e4',
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        boardNr: 1,
      );
      final waiting = [
        _board(
          id: 'waiting-2',
          whiteName: 'White 2',
          blackName: 'Black 2',
          fen: _initialFen,
          boardNr: 2,
        ),
        _board(
          id: 'waiting-3',
          whiteName: 'White 3',
          blackName: 'Black 3',
          fen: _initialFen,
          boardNr: 3,
        ),
      ];

      final merge = resolveNamedPairingsForRound(
        roundStatus: RoundStatus.live,
        allGames: [started, ...waiting],
        roundId: roundId,
        knownRoundIds: {roundId},
        defaultRoundId: roundId,
        alreadyVisibleGameIds: {started.gameId},
        includeGame: (_) => true,
      );

      expect(merge.markAsPairingOnly, isFalse);
      expect(
        merge.gamesToAdd.map((game) => game.gameId),
        ['waiting-2', 'waiting-3'],
      );
    },
  );

  test('still treats an empty upcoming round as pairing-only', () {
    const roundId = 'round-2';
    final pairing = _board(
      id: 'future-board',
      whiteName: 'White 1',
      blackName: 'Black 1',
      fen: _initialFen,
      roundId: roundId,
    );

    final merge = resolveNamedPairingsForRound(
      roundStatus: RoundStatus.upcoming,
      allGames: [pairing],
      roundId: roundId,
      knownRoundIds: {roundId},
      defaultRoundId: roundId,
      alreadyVisibleGameIds: <String>{},
      includeGame: (_) => true,
    );

    expect(merge.markAsPairingOnly, isTrue);
    expect(merge.gamesToAdd.single.gameId, 'future-board');
  });

  test('does not merge pairings onto a completed round', () {
    const roundId = 'round-done';
    final pairing = _board(
      id: 'late-pairing',
      whiteName: 'White 1',
      blackName: 'Black 1',
      fen: _initialFen,
      roundId: roundId,
    );

    final merge = resolveNamedPairingsForRound(
      roundStatus: RoundStatus.completed,
      allGames: [pairing],
      roundId: roundId,
      knownRoundIds: {roundId},
      defaultRoundId: roundId,
      alreadyVisibleGameIds: <String>{},
      includeGame: (_) => true,
    );

    expect(merge.gamesToAdd, isEmpty);
    expect(merge.markAsPairingOnly, isFalse);
  });

  test('keeps placeholder names off a live pairing merge', () {
    const roundId = 'round-1';
    final started = _board(
      id: 'started-board',
      whiteName: 'White 1',
      blackName: 'Black 1',
      lastMove: 'e2e4',
      roundId: roundId,
    );
    final placeholder = _board(
      id: 'placeholder',
      whiteName: '?',
      blackName: '?',
      fen: _initialFen,
      roundId: roundId,
    );

    final merge = resolveNamedPairingsForRound(
      roundStatus: RoundStatus.ongoing,
      allGames: [started, placeholder],
      roundId: roundId,
      knownRoundIds: {roundId},
      defaultRoundId: roundId,
      alreadyVisibleGameIds: {started.gameId},
      includeGame: (_) => true,
    );

    expect(merge.gamesToAdd, isEmpty);
  });
}

const _initialFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

GamesTourModel _board({
  required String id,
  required String whiteName,
  required String blackName,
  String roundId = 'olympiad-round-1',
  String? lastMove,
  String? fen,
  int? boardNr,
  GameStatus gameStatus = GameStatus.ongoing,
}) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: _player(whiteName),
    blackPlayer: _player(blackName),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: gameStatus,
    roundId: roundId,
    tourId: 'tour-1',
    lastMove: lastMove,
    fen: fen,
    boardNr: boardNr,
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'PER',
    title: '',
    rating: 2500,
    countryCode: 'PER',
    team: 'PER',
  );
}
