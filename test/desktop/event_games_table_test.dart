import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/gamebase_position_games_loader.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:dio/dio.dart';

void main() {
  test('gamebase result parsing accepts unicode dashes', () {
    expect(gamebaseStatusFromResult('0–1'), GameStatus.blackWins);
    expect(gamebaseStatusFromResult('1—0'), GameStatus.whiteWins);
    expect(gamebaseStatusFromResult('½–½'), GameStatus.draw);
  });

  test('event rail summaries prefer canonical round start from game rows', () {
    final game = Games.fromJson({
      'id': 'game-1',
      'round_id': 'round-7',
      'round_slug': 'round-7',
      'tour_id': 'tour-1',
      'tour_slug': 'naroditsky-2026',
      'players': [
        {'name': 'Aravindh,C', 'title': 'GM', 'fed': 'IND', 'rating': 2584},
        {'name': 'Sindarov,J', 'title': 'GM', 'fed': 'UZB', 'rating': 2718},
      ],
      'date_start': '2026-07-03',
      'rounds': {'starts_at': '2026-07-03T16:52:00Z'},
      'status': 'ONGOING',
      'pgn': '1. e4 e5 *',
      'last_move': 'e5',
      'last_move_time': '2026-07-03T16:55:00Z',
    });

    final summary = TournamentGameSummary.fromGame(game);

    expect(summary.startsAt, DateTime.parse('2026-07-03'));
    expect(summary.roundStartsAt, DateTime.parse('2026-07-03T16:52:00Z'));
  });

  test(
    'round start survives the GamesTourModel hop so headers avoid 00:00',
    () {
      // Regression: board-pane rails seed summaries via GamesTourModel, which
      // used to drop `roundStartsAt`. `_roundHeaderStartsAt` then fell back to
      // the date-only `date_start`, rendering every round header at midnight.
      final game = Games.fromJson({
        'id': 'game-1',
        'round_id': 'round-1',
        'round_slug': 'round-1',
        'tour_id': 'tour-1',
        'tour_slug': 'biel-2026',
        'players': [
          {'name': 'Aronian,L', 'title': 'GM', 'fed': 'USA', 'rating': 2735},
          {'name': 'Finek,V', 'title': 'IM', 'fed': 'CZE', 'rating': 2454},
        ],
        'date_start': '2026-07-11',
        'rounds': {'starts_at': '2026-07-11T12:00:00Z'},
        'status': 'ONGOING',
        'pgn': '1. e4 e5 *',
        'last_move': 'e5',
      });

      final model = GamesTourModel.fromGame(game);
      expect(model.roundStartsAt, DateTime.parse('2026-07-11T12:00:00Z'));

      // No explicit round map (the board-pane path) — the model's own value
      // must carry through instead of collapsing to midnight `date_start`.
      final summary = TournamentGameSummary.fromGamesTourModel(model);
      expect(summary.roundStartsAt, DateTime.parse('2026-07-11T12:00:00Z'));
      expect(summary.roundStartsAt!.toUtc().hour, 12);
    },
  );

  test(
    'event rail board opens keep newer live summaries over stale fetches',
    () {
      final liveTime = DateTime.utc(2026, 7, 7, 15, 2);
      final staleTime = DateTime.utc(2026, 7, 7, 15);
      final current = _summary(
        id: 'game-1',
        roundLabel: 'Round 1',
        fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
        pgn: '[Event "Test"]\n\n1. e4 e5 *',
        status: GameStatus.ongoing,
        lastMoveTime: liveTime,
      );
      final fetched = _summary(
        id: 'game-1',
        roundLabel: 'Round 1',
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        pgn: '[Event "Test"]\n\n1. e4 *',
        status: GameStatus.ongoing,
        lastMoveTime: staleTime,
      );

      final selected = selectFreshestEventSummaryForOpen(
        current: current,
        incoming: fetched,
      );

      expect(selected, same(current));
    },
  );

  test('event rail board opens accept richer PGN at the same position', () {
    final moveTime = DateTime.utc(2026, 7, 7, 15, 2);
    const fen = 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    final current = _summary(
      id: 'game-1',
      roundLabel: 'Round 1',
      fen: fen,
      pgn: '1. e4 e5 *',
      status: GameStatus.ongoing,
      lastMoveTime: moveTime,
    );
    final fetched = _summary(
      id: 'game-1',
      roundLabel: 'Round 1',
      fen: fen,
      pgn: '''
[Event "Test"]
[White "White"]
[Black "Black"]

1. e4 e5 *
''',
      status: GameStatus.ongoing,
      lastMoveTime: moveTime,
    );

    final selected = selectFreshestEventSummaryForOpen(
      current: current,
      incoming: fetched,
    );

    expect(selected.pgn, fetched.pgn);
    expect(selected.fen, fetched.fen);
  });

  test('richer stale PGN cannot regress a terminal result', () {
    final moveTime = DateTime.utc(2026, 7, 7, 15, 2);
    final current = _summary(
      id: 'game-1',
      roundLabel: 'Round 1',
      pgn: '1. e4 e5 1-0',
      status: GameStatus.whiteWins,
      lastMoveTime: moveTime,
    );
    final fetched = _summary(
      id: 'game-1',
      roundLabel: 'Round 1',
      pgn: '[Event "Test"]\n[White "White"]\n\n1. e4 e5 *',
      status: GameStatus.ongoing,
      lastMoveTime: moveTime,
    );

    final selected = selectFreshestEventSummaryForOpen(
      current: current,
      incoming: fetched,
    );

    expect(selected, same(current));
    expect(selected.status, GameStatus.whiteWins);
  });

  test('authoritative event-open row accepts a reopen and takeback', () {
    final current = _summary(
      id: 'game-1',
      roundLabel: 'Round 7',
      fen: 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2',
      pgn: '1. e4 e5 1-0',
      status: GameStatus.whiteWins,
      lastMoveTime: DateTime.utc(2026, 7, 7, 15, 2),
    );
    final exact = GamesTourModel.fromGame(
      Games.fromJson({
        'id': 'game-1',
        'round_id': 'round-7',
        'round_slug': 'round-7',
        'tour_id': 'tour-1',
        'tour_slug': 'tour-1',
        'players': [
          {'name': 'Corrected White', 'rating': 2512},
          {'name': 'Corrected Black', 'rating': 2498},
        ],
        'status': 'ONGOING',
        'pgn': '1. e4 *',
        'fen': 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        'last_move_time': '2026-07-07T15:01:00Z',
      }),
    );

    final selected = tournamentSummaryWithArbitratedLiveGame(
      structuralSummary: current,
      liveGame: exact,
    );

    expect(selected.status, GameStatus.ongoing);
    expect(selected.pgn, '1. e4 *');
    expect(selected.fen, exact.fen);
    expect(selected.whitePlayer, 'Corrected White');
    expect(selected.roundLabel, 'Round 7');
    expect(selected.hasStarted, isTrue);
  });

  test(
    'continuation rail window centers provider games on the selected row',
    () {
      final providerGames = [
        for (var i = 0; i < 100; i++)
          _summary(id: 'game-$i', roundLabel: 'Round 1'),
      ];

      final visible = eventRailWindowContinuationGamesForTesting(
        fallbackGames: const <TournamentGameSummary>[],
        providerGames: providerGames,
        selectedGameId: 'game-50',
        visibleLimit: 61,
      );

      expect(visible.length, 61);
      expect(visible.first.id, 'game-20');
      expect(visible.last.id, 'game-80');
    },
  );

  testWidgets('event rail omits ongoing status chip text', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Naroditsky Memorial',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'Round 7',
              // Started ~2h ago so the derived round status is deterministically
              // `ongoing` (within the rolling 24h window); a fixed past date
              // would age into `completed` and stop exercising the suppression.
              roundStartsAt: DateTime.now().subtract(const Duration(hours: 2)),
              status: GameStatus.unknown,
              hasStarted: false,
              pgn: '1. e4 e5 *',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Round 7'), findsOneWidget);
    expect(find.text('ONGOING'), findsNothing);
  });

  test('event rail range selection follows visible row order', () {
    final games = [
      _summary(id: 'game-1', roundLabel: 'R1'),
      _summary(id: 'game-2', roundLabel: 'R1'),
      _summary(id: 'game-3', roundLabel: 'R1'),
      _summary(id: 'game-4', roundLabel: 'R1'),
    ];

    expect(
      eventRailRangeSelectionIds(
        orderedGames: games,
        anchorGameId: 'game-2',
        targetGameId: 'game-4',
      ),
      ['game-2', 'game-3', 'game-4'],
    );
    expect(
      eventRailRangeSelectionIds(
        orderedGames: games,
        anchorGameId: 'game-3',
        targetGameId: 'game-1',
      ),
      ['game-1', 'game-2', 'game-3'],
    );
    expect(
      eventRailRangeSelectionIds(
        orderedGames: [games[0], games[3]],
        anchorGameId: 'game-1',
        targetGameId: 'game-4',
      ),
      ['game-1', 'game-4'],
    );

    final gamesAcrossRounds = [
      _summary(id: 'round-1-game-1', roundLabel: 'Round 1'),
      _summary(id: 'round-1-game-2', roundLabel: 'Round 1'),
      _summary(id: 'round-2-game-1', roundLabel: 'Round 2'),
      _summary(id: 'round-2-game-2', roundLabel: 'Round 2'),
    ];
    expect(
      eventRailRangeSelectionIds(
        orderedGames: gamesAcrossRounds,
        anchorGameId: 'round-1-game-2',
        targetGameId: 'round-2-game-2',
      ),
      ['round-1-game-2', 'round-2-game-1', 'round-2-game-2'],
    );
  });

  test('event rail copy selection preserves highlighted row order', () {
    final games = [
      _summary(id: 'game-1', roundLabel: 'R1'),
      _summary(id: 'game-2', roundLabel: 'R1'),
      _summary(id: 'game-3', roundLabel: 'R1'),
    ];

    expect(
      eventRailGamesForCopy(
        orderedGames: games,
        selectedIds: {'game-1', 'game-3'},
        highlightedGameId: 'game-3',
        selectedGameId: 'game-1',
      ).map((game) => game.id),
      ['game-1', 'game-3'],
    );

    expect(
      eventRailGamesForCopy(
        orderedGames: games,
        selectedIds: const <String>{},
        highlightedGameId: 'game-2',
        selectedGameId: 'game-1',
      ).map((game) => game.id),
      ['game-2'],
    );
  });

  test('player event card rail can preserve source game order', () {
    final sourceOrder = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    final timestampOrder = [8, 5, 3, 1, 10, 9, 7, 6, 4, 2];
    final rankByRound = <int, int>{
      for (var i = 0; i < timestampOrder.length; i++)
        timestampOrder[i]: timestampOrder.length - i,
    };
    final games = [
      for (final round in sourceOrder)
        _summary(
          id: 'round-$round',
          roundLabel: 'Round $round',
          roundStartsAt: DateTime.now().subtract(
            Duration(days: 30, hours: 24 - rankByRound[round]!),
          ),
        ),
    ];

    expect(eventRailOrderedIdsForTesting(games, preserveInputOrder: true), [
      for (final round in sourceOrder) 'round-$round',
    ]);
    // Mobile `sortRoundsForDisplay` parity: all rounds completed and named
    // "Round N", so the started rounds order by round number descending
    // (focus round = most recent by that same order).
    expect(eventRailOrderedIdsForTesting(games), [
      for (final round in sourceOrder.reversed) 'round-$round',
    ]);
  });

  test('event rail orders rounds like the mobile Games tab', () {
    final now = DateTime.now();
    final games = [
      // Round 5 — tomorrow, resolved pairings without moves → pairing-only,
      // pinned to the top with boards ascending.
      _summary(
        id: 'r5-g1',
        roundLabel: 'Round 5',
        roundStartsAt: now.add(const Duration(days: 1)),
        pgn: '',
        status: GameStatus.ongoing,
        hasStarted: true,
        lastMoveTime: now.add(const Duration(days: 1)),
        boardNumber: 2,
      ),
      _summary(
        id: 'r5-g2',
        roundLabel: 'Round 5',
        roundStartsAt: now.add(const Duration(days: 1)),
        pgn: '',
        status: GameStatus.ongoing,
        hasStarted: true,
        lastMoveTime: now.add(const Duration(days: 1)),
        boardNumber: 1,
      ),
      // Round 6 — later this week but all "?" placeholder pairings → hidden,
      // even though the pre-created rows claim to be ongoing.
      _summary(
        id: 'r6-g1',
        roundLabel: 'Round 6',
        roundStartsAt: now.add(const Duration(days: 2)),
        whitePlayer: '?',
        blackPlayer: '?',
        pgn: '',
        status: GameStatus.ongoing,
        hasStarted: true,
      ),
      // Round 4 — live right now → first started round beneath Round 5.
      _summary(
        id: 'r4-g1',
        roundLabel: 'Round 4',
        roundStartsAt: now.subtract(const Duration(hours: 1)),
        status: GameStatus.ongoing,
        hasStarted: true,
        lastMoveTime: now.subtract(const Duration(minutes: 5)),
      ),
      // Rounds 3, 2, and 1 — played, newest first below the focus round.
      _summary(
        id: 'r3-g1',
        roundLabel: 'Round 3',
        roundStartsAt: now.subtract(const Duration(days: 1)),
        status: GameStatus.whiteWins,
      ),
      _summary(
        id: 'r2-g1',
        roundLabel: 'Round 2',
        roundStartsAt: now.subtract(const Duration(days: 2)),
        status: GameStatus.draw,
      ),
      _summary(
        id: 'r1-g1',
        roundLabel: 'Round 1',
        roundStartsAt: now.subtract(const Duration(days: 3)),
        status: GameStatus.whiteWins,
      ),
    ];

    final groups = eventRailRoundGroupsForTesting(games);

    expect(groups.map((group) => group.title).toList(), [
      'Round 4',
      'Round 3',
      'Round 2',
      'Round 1',
      'Round 5',
    ]);
    expect(groups.first.status, 'live');
    expect(groups.last.status, 'upcoming');
    expect(groups.last.pairingOnly, isTrue);
    expect(groups.last.gameIds, ['r5-g2', 'r5-g1']);
    expect(
      groups.skip(1).take(3).map((group) => group.status),
      everyElement('completed'),
    );
  });

  test('event rail groups team rounds into matchups with running scores', () {
    final started = DateTime.now().subtract(const Duration(hours: 2));
    final games = [
      _summary(
        id: 'ab-b1',
        roundLabel: 'Round 1',
        roundStartsAt: started,
        whitePlayer: 'Player A1',
        blackPlayer: 'Player B1',
        whiteTeam: 'Alpha',
        blackTeam: 'Beta',
        status: GameStatus.whiteWins,
        boardNumber: 1,
      ),
      // Colors swap on board 2; the matchup still folds into Alpha vs Beta.
      _summary(
        id: 'ab-b2',
        roundLabel: 'Round 1',
        roundStartsAt: started,
        whitePlayer: 'Player B2',
        blackPlayer: 'Player A2',
        whiteTeam: 'Beta',
        blackTeam: 'Alpha',
        status: GameStatus.draw,
        boardNumber: 2,
      ),
      _summary(
        id: 'cd-b1',
        roundLabel: 'Round 1',
        roundStartsAt: started,
        whitePlayer: 'Player C1',
        blackPlayer: 'Player D1',
        whiteTeam: 'Gamma',
        blackTeam: 'Delta',
        status: GameStatus.blackWins,
        boardNumber: 1,
      ),
      _summary(
        id: 'cd-b2',
        roundLabel: 'Round 1',
        roundStartsAt: started,
        whitePlayer: 'Player C2',
        blackPlayer: 'Player D2',
        whiteTeam: 'Gamma',
        blackTeam: 'Delta',
        status: GameStatus.ongoing,
        hasStarted: true,
        boardNumber: 2,
      ),
    ];

    final segments = eventRailRoundSegmentsForTesting(games);

    expect(segments.map((segment) => segment.title).toList(), [
      'Alpha vs Beta',
      'Gamma vs Delta',
    ]);
    expect(segments[0].score, '1½–½');
    expect(segments[0].gameIds, ['ab-b1', 'ab-b2']);
    expect(segments[1].score, '0–1');
    expect(segments[1].gameIds, ['cd-b1', 'cd-b2']);
  });

  test('event rail groups knockout stages into per-matchup game lists', () {
    final started = DateTime.now().subtract(const Duration(days: 1));
    TournamentGameSummary stageGame({
      required String id,
      required String roundId,
      required String roundSlug,
      required String white,
      required String black,
      required GameStatus status,
    }) => _summary(
      id: id,
      roundId: roundId,
      roundSlug: roundSlug,
      roundLabel: roundSlug,
      roundName: 'Quarterfinals',
      roundStartsAt: started,
      whitePlayer: white,
      blackPlayer: black,
      status: status,
    );

    final games = [
      stageGame(
        id: 'ab-g2',
        roundId: 'round-qf-2',
        roundSlug: 'game-2',
        white: 'Beck',
        black: 'Adams',
        status: GameStatus.draw,
      ),
      stageGame(
        id: 'ab-g1',
        roundId: 'round-qf-1',
        roundSlug: 'game-1',
        white: 'Adams',
        black: 'Beck',
        status: GameStatus.whiteWins,
      ),
      stageGame(
        id: 'cd-g1',
        roundId: 'round-qf-1',
        roundSlug: 'game-1',
        white: 'Card',
        black: 'Dole',
        status: GameStatus.draw,
      ),
      stageGame(
        id: 'cd-g2',
        roundId: 'round-qf-2',
        roundSlug: 'game-2',
        white: 'Dole',
        black: 'Card',
        status: GameStatus.draw,
      ),
    ];

    final groups = eventRailRoundGroupsForTesting(games);
    expect(groups, hasLength(1));
    expect(groups.single.title, 'Quarterfinals');

    final segments = eventRailRoundSegmentsForTesting(games);
    expect(segments, hasLength(2));
    expect(segments[0].title, 'Adams vs Beck');
    expect(segments[0].score, '1½–½');
    expect(segments[0].gameIds, ['ab-g1', 'ab-g2']);
    expect(segments[1].title, 'Card vs Dole');
    expect(segments[1].score, '1–1');
    expect(segments[1].gameIds, ['cd-g1', 'cd-g2']);
  });

  test(
    'event rail merges fresh live tournament games into existing rounds',
    () {
      final cachedRoundStart = DateTime.utc(2026, 6, 20, 12);
      final cached = [
        _summary(
          id: 'round-3-game-1',
          roundLabel: 'R3',
          roundName: 'Round 3',
          roundStartsAt: cachedRoundStart,
        ),
        _summary(
          id: 'round-4-game-1',
          roundLabel: 'R4',
          roundName: 'Round 4',
          roundStartsAt: cachedRoundStart.add(const Duration(hours: 2)),
          status: GameStatus.unknown,
          hasStarted: false,
        ),
      ];
      final fresh = [
        _summary(
          id: 'round-4-game-1',
          roundLabel: 'R4',
          status: GameStatus.ongoing,
          hasStarted: true,
        ),
        _summary(
          id: 'round-4-game-2',
          roundLabel: 'R4',
          status: GameStatus.ongoing,
          hasStarted: true,
        ),
      ];

      final merged = eventRailMergeFreshEventGamesForTesting(cached, fresh);

      expect(merged.map((game) => game.id), [
        'round-3-game-1',
        'round-4-game-1',
        'round-4-game-2',
      ]);
      final updatedRound4 = merged.singleWhere(
        (game) => game.id == 'round-4-game-1',
      );
      expect(updatedRound4.status, GameStatus.ongoing);
      expect(updatedRound4.hasStarted, isTrue);
      expect(updatedRound4.roundName, 'Round 4');
      expect(
        updatedRound4.roundStartsAt,
        cachedRoundStart.add(const Duration(hours: 2)),
      );
    },
  );

  test(
    'event rail folds completed rounds from the tournament cache into context',
    () {
      final cached = [
        _summary(
          id: 'round-5-game-1',
          roundLabel: 'R5',
          roundName: 'Round 5',
          tourId: 'tour-1',
          status: GameStatus.ongoing,
        ),
      ];
      final fresh = [
        Games(
          id: 'round-5-game-1',
          roundId: 'round-5',
          roundSlug: 'round-5',
          tourId: 'tour-1',
          tourSlug: 'event-2026',
          status: 'D',
          pgn: '1. e4 e5 1/2-1/2',
        ),
        Games(
          id: 'round-6-game-1',
          roundId: 'round-6',
          roundSlug: 'round-6',
          tourId: 'tour-1',
          tourSlug: 'event-2026',
          status: '1-0',
          pgn: '1. d4 d5 2. c4 1-0',
        ),
      ];

      final merged = eventRailMergeTournamentProviderGamesForTesting(
        cached,
        fresh,
      );

      expect(merged.map((game) => game.id), [
        'round-5-game-1',
        'round-6-game-1',
      ]);
      expect(merged[0].status, GameStatus.draw);
      expect(merged[0].roundName, 'Round 5');
      expect(merged[1].status, GameStatus.whiteWins);
      expect(merged[1].roundLabel, 'R6');
    },
  );

  test('event rail uses shown game ids for realtime tournament rows', () {
    final games = [
      _summary(
        id: 'round-5-board-1',
        roundLabel: 'R5',
        tourId: 'tour-1',
        status: GameStatus.ongoing,
      ),
      _summary(
        id: 'round-5-board-2',
        roundLabel: 'R5',
        tourId: 'tour-1',
        status: GameStatus.ongoing,
      ),
    ];

    final keys = eventRailLiveBatchKeysForTesting(
      activeTabId: 'tournaments-default',
      games: games,
      isEventRail: true,
      isDatabaseRail: false,
    );

    expect(keys, hasLength(1));
    final key = keys.single;
    expect(key.tourId, isNull);
    expect(key.gameIds, ['round-5-board-1', 'round-5-board-2']);
    expect(key.contains('new-round-board-1'), isFalse);
  });

  test('database rail does not subscribe to live tournament updates', () {
    final keys = eventRailLiveBatchKeysForTesting(
      activeTabId: 'tournaments-default',
      games: [_summary(id: 'local-game-1', roundLabel: '2026')],
      isEventRail: false,
      isDatabaseRail: true,
    );

    expect(keys, isEmpty);
  });

  test('event rail chunks ids without shifting membership on finish', () {
    final games = [
      for (var i = 0; i < 26; i++)
        _summary(
          id: 'live-${i.toString().padLeft(2, '0')}',
          roundLabel: 'R5',
          status: GameStatus.ongoing,
        ),
      _summary(id: 'finished-1', roundLabel: 'R5', status: GameStatus.draw),
    ];

    final keys = eventRailLiveBatchKeysForTesting(
      activeTabId: 'tournaments-default',
      games: games,
      isEventRail: true,
      isDatabaseRail: false,
    );

    expect(keys, hasLength(2));
    expect(keys[0].gameIds.length, 25);
    expect(keys[1].gameIds, ['finished-1', 'live-25']);
    expect(keys.any((key) => key.contains('finished-1')), isTrue);
  });

  test('event rail copy selection can span rounds', () {
    final games = [
      _summary(id: 'round-1-game-1', roundLabel: 'Round 1'),
      _summary(id: 'round-1-game-2', roundLabel: 'Round 1'),
      _summary(id: 'round-2-game-1', roundLabel: 'Round 2'),
      _summary(id: 'round-2-game-2', roundLabel: 'Round 2'),
    ];

    expect(
      eventRailGamesForCopy(
        orderedGames: games,
        selectedIds: {'round-1-game-2', 'round-2-game-1', 'round-2-game-2'},
        highlightedGameId: 'round-2-game-2',
        selectedGameId: 'round-1-game-2',
      ).map((game) => game.id),
      ['round-1-game-2', 'round-2-game-1', 'round-2-game-2'],
    );
  });

  testWidgets('database games hide the board and round column', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          pgn: '1. d4 d5 *',
          label: 'Database game',
          whiteName: 'White',
          blackName: 'Black',
          databaseTitle: 'My Database',
          databaseGames: [_summary(id: 'db-game-1', roundLabel: 'R9')],
          gameListSelectedId: 'db-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('My Database'), findsOneWidget);
    expect(find.text('DATABASE GAMES'), findsNothing);
    expect(find.text('BD'), findsNothing);
    expect(find.text('R9'), findsNothing);
    expect(find.text('White Player'), findsOneWidget);
    expect(find.text('Black Player'), findsOneWidget);
  });

  testWidgets('database game rows show result instead of vs fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          pgn: '1. e4 e5 0-1',
          label: 'Database game',
          whiteName: 'White',
          blackName: 'Black',
          databaseTitle: 'Continuation after 1.e4 e5',
          databaseGames: [
            _summary(
              id: 'db-game-1',
              roundLabel: '2026',
              whitePlayer: 'Esipenko,A',
              blackPlayer: 'Radjabov,T',
              status: GameStatus.blackWins,
            ),
          ],
          gameListSelectedId: 'db-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('vs'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.textSpan?.toPlainText() == '0–1',
      ),
      findsOneWidget,
    );
  });

  testWidgets('database games rail virtualizes large local lists', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          pgn: '1. d4 d5 *',
          label: 'Local database game',
          whiteName: 'Local White 0',
          blackName: 'Local Black 0',
          databaseTitle: 'Huge Local Database',
          databaseGames: [
            for (var i = 0; i < 1000; i++)
              _summary(
                id: 'local-game-$i',
                roundLabel: 'Local',
                whitePlayer: 'Local White $i',
                blackPlayer: 'Local Black $i',
              ),
          ],
          gameListSelectedId: 'local-game-0',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Huge Local Database'), findsOneWidget);
    expect(find.text('Local White 0'), findsOneWidget);
    expect(find.text('Local White 999'), findsNothing);
  });

  testWidgets(
    'opening a database row with header-only PGN keeps hydration id',
    (tester) async {
      const headerOnlyPgn = '[White "Header"]\n[Black "Only"]\n\n*';

      await tester.pumpWidget(
        _wrap(
          BoardTabGameArgs(
            gameId: 'db-game-1',
            pgn: headerOnlyPgn,
            label: 'Database game',
            whiteName: 'White',
            blackName: 'Black',
            databaseTitle: 'TWIC Database',
            databaseGames: [
              _summary(
                id: 'db-game-1',
                roundLabel: '2026',
                whitePlayer: 'Header One',
                blackPlayer: 'Only One',
                pgn: headerOnlyPgn,
              ),
              _summary(
                id: 'db-game-2',
                roundLabel: '2026',
                whitePlayer: 'Header Two',
                blackPlayer: 'Only Two',
                pgn: headerOnlyPgn,
              ),
            ],
            gameListSelectedId: 'db-game-1',
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Only Two'));
      await tester.pump();

      var container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      var args = container.read(boardTabGameArgsByTabIdProvider).values.single;
      expect(args.gameId, 'db-game-1');
      expect(args.gameListSelectedId, 'db-game-1');

      await tester.tap(find.text('Only Two'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Only Two'));
      await tester.pump(const Duration(milliseconds: 100));

      container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      args = container.read(boardTabGameArgsByTabIdProvider).values.single;
      expect(args.gameId, 'db-game-2');
      expect(args.gameListSelectedId, 'db-game-2');
      expect(args.pgn, headerOnlyPgn);
    },
  );

  testWidgets('opening a local database row preserves its PGN update target', (
    tester,
  ) async {
    const firstSource = TournamentGameLocalPgnSource(
      sourcePath: '/tmp/local-library.pgn',
      sourceIndex: 2,
      sourceFileGameCount: 6,
      title: 'Local One vs Local Two',
    );
    const secondSource = TournamentGameLocalPgnSource(
      sourcePath: '/tmp/local-library.pgn',
      sourceIndex: 3,
      sourceFileGameCount: 6,
      title: 'Local Three vs Local Four',
    );
    final first = _summary(
      id: 'local-game-1',
      roundLabel: 'Local',
      whitePlayer: 'Local One',
      blackPlayer: 'Local Two',
      localPgnSource: firstSource,
    );
    final second = _summary(
      id: 'local-game-2',
      roundLabel: 'Local',
      whitePlayer: 'Local Three',
      blackPlayer: 'Local Four',
      localPgnSource: secondSource,
    );

    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          pgn: first.pgn!,
          label: first.name,
          whiteName: first.whitePlayer,
          blackName: first.blackPlayer,
          databaseTitle: 'Local Library',
          databaseGames: [first, second],
          gameListSelectedId: first.id,
          librarySaveOrigin: const BoardTabLibrarySaveOrigin.localPgnFile(
            sourcePath: '/tmp/local-library.pgn',
            sourceIndex: 2,
            sourceFileGameCount: 6,
            title: 'Local One vs Local Two',
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Local Three'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, isNull);
    expect(args.gameListSelectedId, second.id);
    expect(
      args.librarySaveOrigin?.kind,
      BoardTabLibrarySaveOriginKind.localPgnFile,
    );
    expect(args.librarySaveOrigin?.sourcePath, secondSource.sourcePath);
    expect(args.librarySaveOrigin?.sourceIndex, secondSource.sourceIndex);
    expect(
      args.librarySaveOrigin?.sourceFileGameCount,
      secondSource.sourceFileGameCount,
    );
    expect(args.librarySaveOrigin?.title, secondSource.title);
  });

  testWidgets('database games rail loads the next page only after scroll', (
    tester,
  ) async {
    final repository = _FakeGamebaseRepository();
    const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final seedGames = [
      for (var i = 0; i < 24; i++)
        _summary(
          id: 'seed-$i',
          roundLabel: '2025',
          whitePlayer: 'Seed White $i',
          blackPlayer: 'Seed Black $i',
        ),
    ];

    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          pgn: '',
          label: 'Database game',
          whiteName: 'White',
          blackName: 'Black',
          initialFen: fen,
          databaseTitle: 'Continuation after 1.e4',
          databaseGames: seedGames,
          databaseGamesPagination: const BoardTabDatabaseGamesPagination(
            query: GamebasePositionGamesQuery(
              fen: fen,
              pageNumber: 0,
              pageSize: 1,
              notationPlies: 12,
            ),
            nextPageNumber: 1,
            hasMore: true,
            exactFenSearch: false,
            totalCount: 2,
          ),
          gameListSelectedId: 'seed-0',
        ),
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(repository.requestedPages, isEmpty);

    await tester.drag(find.byType(ListView), const Offset(0, -1200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;

    expect(repository.requestedPages, [1]);
    expect(args.databaseGames.map((game) => game.id), [
      ...seedGames.map((game) => game.id),
      'gamebase-2',
    ]);
    expect(args.databaseGamesPagination!.nextPageNumber, 2);
    expect(args.databaseGamesPagination!.hasMore, isFalse);
  });

  testWidgets('Enter opens the highlighted source game from the rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'source-game-1',
          pgn: '1. e4 e5 *',
          label: 'Source game',
          whiteName: 'White One',
          blackName: 'Black One',
          routeTitle: 'Player games',
          routeGames: [
            _summary(
              id: 'source-game-1',
              roundLabel: '2026',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'source-game-2',
              roundLabel: '2026',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'source-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('White One'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'source-game-2');
    expect(args.gameListSelectedId, 'source-game-2');
    expect(args.routeGames.map((game) => game.id), [
      'source-game-1',
      'source-game-2',
    ]);
  });

  testWidgets(
    'source rail highlight follows an externally selected active game',
    (tester) async {
      final sourceGames = [
        _summary(
          id: 'source-game-1',
          roundLabel: '2026',
          whitePlayer: 'White One',
          blackPlayer: 'Black One',
        ),
        _summary(
          id: 'source-game-2',
          roundLabel: '2026',
          whitePlayer: 'White Two',
          blackPlayer: 'Black Two',
        ),
      ];
      final initialArgs = BoardTabGameArgs(
        gameId: 'source-game-1',
        pgn: '1. e4 e5 *',
        label: 'Source game',
        whiteName: 'White One',
        blackName: 'Black One',
        routeTitle: 'Player games',
        routeGames: sourceGames,
        gameListSelectedId: 'source-game-1',
      );

      await tester.pumpWidget(_wrap(initialArgs));
      await tester.pump();

      // Give the rail its own local highlight, then simulate Cmd/Ctrl+Down
      // changing the canonical board selection outside the rail.
      await tester.tap(find.text('White One'));
      await tester.pump(const Duration(milliseconds: 400));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EventGamesTable)),
      );
      container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
        'tournaments-default': initialArgs.copyWith(
          gameId: 'source-game-2',
          gameListSelectedId: 'source-game-2',
        ),
      };
      await tester.pump();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final args =
          container.read(boardTabGameArgsByTabIdProvider).values.single;
      expect(args.gameId, 'source-game-2');
      expect(args.gameListSelectedId, 'source-game-2');
    },
  );

  testWidgets('event games keep the board and round column', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Event'), findsOneWidget);
    expect(find.text('EVENT GAMES'), findsNothing);
    expect(find.text('BD'), findsNothing);
    expect(find.text('R5'), findsNothing);
  });

  testWidgets('event game title labels use the primary table color', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'R5',
              whiteTitle: 'GM',
              blackTitle: 'FM',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(tester.widget<Text>(find.text('GM')).style?.color, kPrimaryColor);
    expect(tester.widget<Text>(find.text('FM')).style?.color, kPrimaryColor);
  });

  testWidgets('event round header preserves Armageddon round name', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'armageddon-1',
          pgn: '1. e4 e5 *',
          label: 'Armageddon game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Norway Chess 2026',
          eventGames: [
            _summary(
              id: 'armageddon-1',
              roundLabel: 'R1',
              roundName: 'Round 1 / Armageddon',
            ),
          ],
          gameListSelectedId: 'armageddon-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Round 1 / Armageddon'), findsOneWidget);
    expect(find.text('Round 1'), findsNothing);
  });

  testWidgets('event rounds sort by descending start datetime', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-1-game',
              roundLabel: 'R1',
              startsAt: DateTime(2026, 1, 1, 10),
            ),
            _summary(
              id: 'round-3-game',
              roundLabel: 'R3',
              startsAt: DateTime(2026, 1, 3, 10),
            ),
            _summary(
              id: 'round-2-game',
              roundLabel: 'R2',
              startsAt: DateTime(2026, 1, 2, 10),
            ),
          ],
          gameListSelectedId: 'round-2-game',
        ),
      ),
    );
    await tester.pump();

    final round3Top = tester.getTopLeft(find.text('Round 3')).dy;
    final round2Top = tester.getTopLeft(find.text('Round 2')).dy;
    final round1Top = tester.getTopLeft(find.text('Round 1')).dy;

    expect(round3Top, lessThan(round2Top));
    expect(round2Top, lessThan(round1Top));
  });

  testWidgets('event round header prefers canonical round start time', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-1-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-1-game',
              roundLabel: 'R1',
              startsAt: DateTime(2026, 5, 22),
              roundStartsAt: DateTime(2026, 5, 25, 11),
            ),
          ],
          gameListSelectedId: 'round-1-game',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('25 May 2026 11:00'), findsOneWidget);
    expect(find.text('22 May 2026 00:00'), findsNothing);
  });

  testWidgets('selected top event round stays collapsed after header tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-1-game',
              roundLabel: 'R1',
              whitePlayer: 'Round One White',
              blackPlayer: 'Round One Black',
              startsAt: DateTime(2026, 1, 1, 10),
            ),
            _summary(
              id: 'round-2-game',
              roundLabel: 'R2',
              whitePlayer: 'Selected White',
              blackPlayer: 'Selected Black',
              startsAt: DateTime(2026, 1, 2, 10),
            ),
          ],
          gameListSelectedId: 'round-2-game',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('Selected White'), findsOneWidget);

    await tester.tap(find.text('Round 2'));
    await tester.pump();
    await tester.pump();

    // One round is open at a time, so collapsing the open round leaves the rail
    // fully collapsed rather than handing the expansion to a neighbour. Both
    // headings stay listed so nothing becomes unreachable.
    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('Round 1'), findsOneWidget);
    expect(find.text('Selected White'), findsNothing);
    expect(find.text('Round One White'), findsNothing);
  });

  testWidgets('event games within a round sort by board number ascending', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'board-1-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'board-10-game',
              roundLabel: 'R1',
              whitePlayer: 'Board Ten White',
              blackPlayer: 'Board Ten Black',
              boardNumber: 10,
              startsAt: DateTime(2026, 1, 1, 11),
            ),
            _summary(
              id: 'board-1-game',
              roundLabel: 'R1',
              whitePlayer: 'Board One White',
              blackPlayer: 'Board One Black',
              boardNumber: 1,
              startsAt: DateTime(2026, 1, 1, 9),
            ),
            _summary(
              id: 'board-2-game',
              roundLabel: 'R1',
              whitePlayer: 'Board Two White',
              blackPlayer: 'Board Two Black',
              boardNumber: 2,
              startsAt: DateTime(2026, 1, 1, 10),
            ),
          ],
          gameListSelectedId: 'board-1-game',
        ),
      ),
    );
    await tester.pump();

    final board1Top = tester.getTopLeft(find.text('Board One White')).dy;
    final board2Top = tester.getTopLeft(find.text('Board Two White')).dy;
    final board10Top = tester.getTopLeft(find.text('Board Ten White')).dy;

    expect(board1Top, lessThan(board2Top));
    expect(board2Top, lessThan(board10Top));
  });

  testWidgets('active event headers lead and future rounds stay collapsed', (
    tester,
  ) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-2-game',
              roundLabel: 'R2',
              whitePlayer: 'Live White',
              blackPlayer: 'Live Black',
              status: GameStatus.ongoing,
              hasStarted: true,
              roundStartsAt: now.subtract(const Duration(hours: 1)),
              lastMoveTime: now.subtract(const Duration(minutes: 1)),
            ),
            _summary(
              id: 'round-4-game',
              roundLabel: 'R4',
              whitePlayer: 'Future White',
              blackPlayer: 'Future Black',
              status: GameStatus.ongoing,
              hasStarted: false,
              roundStartsAt: now.add(const Duration(days: 1)),
            ),
          ],
          gameListSelectedId: 'round-2-game',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Round 2'), findsOneWidget);
    expect(find.text('Round 4'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Round 2')).dy,
      lessThan(tester.getTopLeft(find.text('Round 4')).dy),
    );
    expect(find.text('Live White'), findsOneWidget);
    expect(find.text('Future White'), findsNothing);

    await tester.tap(find.text('Round 4'));
    await tester.pump();

    expect(find.text('Future White'), findsOneWidget);
  });

  testWidgets('an upcoming round is listed and reveals pairings on expand', (
    tester,
  ) async {
    final now = DateTime.now();
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'Finished White',
          blackName: 'Finished Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-2-game',
              roundLabel: 'R2',
              whitePlayer: 'Finished White',
              blackPlayer: 'Finished Black',
              status: GameStatus.draw,
              roundStartsAt: now.subtract(const Duration(days: 1)),
            ),
            _summary(
              id: 'round-3-game',
              roundLabel: 'R3',
              whitePlayer: 'Next White',
              blackPlayer: 'Next Black',
              pgn: '',
              status: GameStatus.unknown,
              hasStarted: false,
              roundStartsAt: now.add(const Duration(days: 1)),
            ),
          ],
          gameListSelectedId: 'round-2-game',
        ),
      ),
    );
    await tester.pump();

    // Only the top-most round is open, so the upcoming round is listed but its
    // published pairings stay behind its heading until the user asks for them.
    expect(find.text('Round 3'), findsOneWidget);
    expect(find.text('Next White'), findsNothing);

    await tester.tap(find.text('Round 3'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Next White'), findsOneWidget);
    expect(find.text('Finished White'), findsNothing);
  });

  testWidgets('event game rows are tappable in the fixed table rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'R5',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'event-game-2',
              roundLabel: 'R5',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Black Two'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Black Two'));
    await tester.pump(const Duration(milliseconds: 100));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'event-game-2');
    expect(args.gameListSelectedId, 'event-game-2');
    expect(args.pgn, '1. e4 e5 *');
  });

  testWidgets('selected event game gets a full-row container treatment', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    final table = tester.widget<Table>(find.byType(Table));
    final selectedDecoration = table.children[0].decoration as BoxDecoration;
    expect(selectedDecoration.color, isNotNull);
    expect(selectedDecoration.border, isNotNull);
    expect(selectedDecoration.boxShadow, isNotEmpty);
  });

  testWidgets('single click moves the only highlighted game row', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White One',
          blackName: 'Black One',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'R5',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'event-game-2',
              roundLabel: 'R5',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    var table = tester.widget<Table>(find.byType(Table));
    var firstDecoration = table.children[0].decoration as BoxDecoration;
    var secondDecoration = table.children[1].decoration as BoxDecoration;
    expect(firstDecoration.color, isNot(Colors.transparent));
    expect(secondDecoration.color, Colors.transparent);

    await tester.tap(find.text('Black Two'));
    await tester.pump(const Duration(milliseconds: 350));

    table = tester.widget<Table>(find.byType(Table));
    firstDecoration = table.children[0].decoration as BoxDecoration;
    secondDecoration = table.children[1].decoration as BoxDecoration;
    expect(firstDecoration.color, Colors.transparent);
    expect(secondDecoration.color, isNot(Colors.transparent));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'event-game-1');
    expect(args.gameListSelectedId, 'event-game-1');
  });

  testWidgets('Shift click ranges from the active event game in the open round', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'round-2-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'Round Two White One',
          blackName: 'Round Two Black One',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'round-2-game-1',
              roundLabel: 'R2',
              roundName: 'Round 2',
              whitePlayer: 'Round Two White One',
              blackPlayer: 'Round Two Black One',
              boardNumber: 1,
              startsAt: DateTime(2026, 1, 2, 10),
            ),
            _summary(
              id: 'round-2-game-2',
              roundLabel: 'R2',
              roundName: 'Round 2',
              whitePlayer: 'Round Two White Two',
              blackPlayer: 'Round Two Black Two',
              boardNumber: 2,
              startsAt: DateTime(2026, 1, 2, 10),
            ),
            _summary(
              id: 'round-1-game-1',
              roundLabel: 'R1',
              roundName: 'Round 1',
              whitePlayer: 'Round One White One',
              blackPlayer: 'Round One Black One',
              boardNumber: 1,
              startsAt: DateTime(2026, 1, 1, 10),
            ),
          ],
          gameListSelectedId: 'round-2-game-1',
        ),
      ),
    );
    await tester.pump();

    // Round 2 is the open round; Round 1 is listed but collapsed, so a range can
    // only span the rows the user can actually see.
    expect(find.byType(Table), findsOneWidget);
    var openRoundTable = tester.widget<Table>(find.byType(Table).at(0));
    expect(
      (openRoundTable.children[0].decoration as BoxDecoration).color,
      isNot(Colors.transparent),
    );
    expect(
      (openRoundTable.children[1].decoration as BoxDecoration).color,
      Colors.transparent,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.ensureVisible(find.text('Round Two Black Two'));
    await tester.tap(find.text('Round Two Black Two'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    openRoundTable = tester.widget<Table>(
      find
          .ancestor(
            of: find.text('Round Two Black Two'),
            matching: find.byType(Table),
          )
          .first,
    );
    // Both boards of the open round are now in the range.
    expect(
      (openRoundTable.children[0].decoration as BoxDecoration).color,
      isNot(Colors.transparent),
    );
    expect(
      (openRoundTable.children[1].decoration as BoxDecoration).color,
      isNot(Colors.transparent),
    );
  });

  testWidgets('Ctrl click opens a game row in a new tab', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White One',
          blackName: 'Black One',
          tournamentTitle: 'Event',
          eventGames: [
            _summary(
              id: 'event-game-1',
              roundLabel: 'R5',
              whitePlayer: 'White One',
              blackPlayer: 'Black One',
            ),
            _summary(
              id: 'event-game-2',
              roundLabel: 'R5',
              whitePlayer: 'White Two',
              blackPlayer: 'Black Two',
            ),
          ],
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    final ctrlClick = await tester.startGesture(
      tester.getCenter(find.text('Black Two')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await ctrlClick.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump(const Duration(milliseconds: 350));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final gamesByTab = container.read(boardTabGameArgsByTabIdProvider);
    expect(
      gamesByTab.values.map((args) => args.gameId),
      contains('event-game-1'),
    );
    expect(
      gamesByTab.values.map((args) => args.gameId),
      contains('event-game-2'),
    );
    expect(gamesByTab.length, 2);
  });

  testWidgets('event games show loading shimmer while context hydrates', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'event-game-1',
          pgn: '1. e4 e5 *',
          label: 'Event game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Event',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          eventGamesLoading: true,
          gameListSelectedId: 'event-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Loading…'), findsOneWidget);
    expect(find.byType(AnimatedBuilder), findsWidgets);
  });

  testWidgets(
    'route context is the default rail when event context also exists',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          BoardTabGameArgs(
            gameId: 'route-game-1',
            pgn: '1. e4 e5 *',
            label: 'Profile game',
            whiteName: 'White',
            blackName: 'Black',
            tournamentTitle: 'Tournament context',
            eventGames: [
              _summary(
                id: 'event-game-1',
                roundLabel: 'R5',
                whitePlayer: 'Event White',
                blackPlayer: 'Event Black',
              ),
            ],
            routeTitle: 'Player games',
            routeGames: [
              _summary(
                id: 'route-game-1',
                roundLabel: 'R1',
                whitePlayer: 'Route White',
                blackPlayer: 'Route Black',
              ),
              _summary(
                id: 'route-game-2',
                roundLabel: 'R2',
                whitePlayer: 'Route Two',
                blackPlayer: 'Route Opponent',
              ),
            ],
            gameListSelectedId: 'route-game-1',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Player games'), findsOneWidget);
      expect(find.text('SOURCE GAMES'), findsNothing);
      expect(find.text('Player games'), findsOneWidget);
      expect(find.text('Source'), findsOneWidget);
      expect(find.text('Event'), findsOneWidget);
      expect(find.text('Route Two'), findsOneWidget);
      expect(find.text('Event White'), findsNothing);

      await tester.tap(find.text('Event'));
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.text('EVENT GAMES'), findsNothing);
      expect(find.text('Tournament context'), findsOneWidget);
      expect(find.text('Event White'), findsOneWidget);
      expect(find.text('Route Two'), findsNothing);
    },
  );

  testWidgets('opening a route row preserves the source game list', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BoardTabGameArgs(
          gameId: 'route-game-1',
          pgn: '1. e4 e5 *',
          label: 'Profile game',
          whiteName: 'White',
          blackName: 'Black',
          tournamentTitle: 'Tournament context',
          eventGames: [_summary(id: 'event-game-1', roundLabel: 'R5')],
          routeTitle: 'Player games',
          routeGames: [
            _summary(
              id: 'route-game-1',
              roundLabel: 'R1',
              whitePlayer: 'Route White',
              blackPlayer: 'Route Black',
            ),
            _summary(
              id: 'route-game-2',
              roundLabel: 'R2',
              whitePlayer: 'Route Two',
              blackPlayer: 'Route Opponent',
            ),
          ],
          gameListSelectedId: 'route-game-1',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Route Two'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Route Two'));
    await tester.pump(const Duration(milliseconds: 100));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(EventGamesTable)),
    );
    final args = container.read(boardTabGameArgsByTabIdProvider).values.single;
    expect(args.gameId, 'route-game-2');
    expect(args.gameListSelectedId, 'route-game-2');
    expect(args.routeTitle, 'Player games');
    expect(args.routeGames.map((game) => game.id), [
      'route-game-1',
      'route-game-2',
    ]);
  });

  testWidgets('tabs without local context ignore stale tournament state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const BoardTabGameArgs(
          pgn: '1. c4 e5 *',
          label: 'Scratch analysis',
          whiteName: 'White',
          blackName: 'Black',
        ),
        legacy: TournamentGamesState(
          tournamentTitle: 'Wrong Event',
          games: [_summary(id: 'stale-game-1', roundLabel: 'R1')],
          activeGameId: 'stale-game-1',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('EVENT GAMES'), findsNothing);
    expect(find.text('Wrong Event'), findsNothing);
    expect(find.text('White Player'), findsNothing);
  });
}

Widget _wrap(
  BoardTabGameArgs args, {
  TournamentGamesState? legacy,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      ...overrides,
      boardTabGameArgsByTabIdProvider.overrideWith(
        (ref) => {'tournaments-default': args},
      ),
      if (legacy != null)
        tournamentGamesProvider.overrideWith((ref) {
          final notifier = TournamentGamesNotifier();
          notifier.setLoaded(
            tournamentTitle: legacy.tournamentTitle,
            games: legacy.games,
          );
          if (legacy.activeGameId != null) {
            notifier.markActive(legacy.activeGameId!);
          }
          return notifier;
        }),
      gameUpdatesStreamProvider.overrideWith(
        (ref, gameId) => const Stream<Map<String, dynamic>?>.empty(),
      ),
      gameUpdatesBatchStreamProvider.overrideWith(
        (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: EventGamesTable.width,
          child: EventGamesTable(tabId: 'tournaments-default'),
        ),
      ),
    ),
  );
}

class _FakeGamebaseRepository extends GamebaseRepository {
  _FakeGamebaseRepository() : super(Dio(), baseUrl: 'http://localhost');

  final List<int> requestedPages = <int>[];

  @override
  Future<GamebaseSearchQueryResponse> getPositionGames({
    required String fen,
    List<String> moves = const [],
    String? uci,
    TimeControl? timeControl,
    String? playerId,
    String? color,
    String? result,
    int? minRating,
    int? maxRating,
    int? yearFrom,
    int? yearTo,
    GamebaseSortField? sortBy,
    GamebaseSortDirection? sortDirection,
    bool? isOnline,
    int pageNumber = 0,
    int pageSize = 20,
    int notationPlies = 0,
  }) async {
    requestedPages.add(pageNumber);
    return GamebaseSearchQueryResponse(
      status: 'success',
      data: const [
        {
          'id': 'gamebase-2',
          'white': 'Caruana',
          'black': 'Giri',
          'whiteFed': 'USA',
          'blackFed': 'NED',
          'whiteTitle': 'GM',
          'blackTitle': 'GM',
          'whiteElo': 2800,
          'blackElo': 2760,
          'result': '1/2-1/2',
          'date': '2024-01-01',
          'event': 'Wijk aan Zee',
          'opening': 'Open Game',
          'eco': 'C20',
        },
      ],
      metadata: GamebasePaginationMetadata(
        pageNumber: pageNumber,
        pageSize: pageSize,
        totalCount: 2,
        hasMoreValue: false,
      ),
    );
  }
}

TournamentGameSummary _summary({
  required String id,
  required String roundLabel,
  String whitePlayer = 'White Player',
  String blackPlayer = 'Black Player',
  String pgn = '1. e4 e5 *',
  String? fen,
  GameStatus status = GameStatus.draw,
  bool hasStarted = true,
  DateTime? startsAt,
  DateTime? roundStartsAt,
  DateTime? lastMoveTime,
  String roundId = '',
  String roundSlug = '',
  String roundName = '',
  int? boardNumber,
  String whiteTitle = '',
  String blackTitle = '',
  String whiteTeam = '',
  String blackTeam = '',
  String tourId = '',
  TournamentGameLocalPgnSource? localPgnSource,
}) {
  return TournamentGameSummary(
    id: id,
    name: '$whitePlayer vs $blackPlayer',
    whitePlayer: whitePlayer,
    blackPlayer: blackPlayer,
    tourId: tourId,
    whiteTitle: whiteTitle,
    blackTitle: blackTitle,
    hasPgn: true,
    pgn: pgn,
    fen: fen,
    roundId: roundId,
    roundSlug: roundSlug,
    roundLabel: roundLabel,
    roundName: roundName,
    boardNumber: boardNumber,
    status: status,
    lastMoveTime: lastMoveTime,
    startsAt: startsAt,
    roundStartsAt: roundStartsAt,
    hasStarted: hasStarted,
    whiteTeam: whiteTeam,
    blackTeam: blackTeam,
    localPgnSource: localPgnSource,
  );
}
