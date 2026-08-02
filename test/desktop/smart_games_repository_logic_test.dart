import 'package:chessever/desktop/panes/desktop_smart_games_pane.dart'
    show
        kSmartGamesLoadMoreThreshold,
        kSmartGamesMaxViewportFillLoads,
        shouldAutoFillSmartGamesViewport,
        shouldLoadMoreForCollapsedMiniatures,
        visibleDesktopSmartGames;
import 'package:chessever/desktop/utils/desktop_smart_game_sections.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';

Games _buildGame({
  required String id,
  required int whiteRating,
  required int blackRating,
  String? pgn,
}) {
  return Games(
    id: id,
    roundId: 'round1',
    roundSlug: 'round1',
    tourId: 'tour1',
    tourSlug: 'tour1',
    status: '*',
    players: [
      Player(
        name: 'White',
        fideId: 1,
        title: 'GM',
        fed: 'USA',
        rating: whiteRating,
        clock: 0,
        team: '',
      ),
      Player(
        name: 'Black',
        fideId: 2,
        title: 'GM',
        fed: 'IND',
        rating: blackRating,
        clock: 0,
        team: '',
      ),
    ],
    pgn: pgn,
  );
}

void main() {
  group('desktop smart games GM average rating', () {
    test('uses structured player ratings when PGN rating tags are missing', () {
      final game = _buildGame(
        id: 'g1',
        whiteRating: 2520,
        blackRating: 2510,
        pgn: '[Event "Live"]\n\n1. e4 e5',
      );

      expect(gameStructuredAverageRating(game), 2515);
      expect(gameStructuredAverageRating(game) >= 2500, isTrue);
    });

    test('requires both player ratings for GM qualification', () {
      final game = _buildGame(
        id: 'g2',
        whiteRating: 2600,
        blackRating: 0,
        pgn: '[WhiteElo "2600"]\n\n1. d4 d5',
      );

      expect(gameStructuredAverageRating(game), 0);
      expect(gameStructuredAverageRating(game) >= 2500, isFalse);
    });
  });

  group('desktop smart games live filtering', () {
    test('recognizes backend ongoing status literals as live', () {
      expect(GameStatus.fromString('*'), GameStatus.ongoing);
      expect(GameStatus.fromString('ongoing'), GameStatus.ongoing);
      expect(GameStatus.fromString('live'), GameStatus.ongoing);
      expect(GameStatus.fromString('LIVE'), GameStatus.ongoing);
    });

    test('keeps only effectively ongoing games in the Live collection', () {
      final live = _tourGame(
        id: 'live',
        status: GameStatus.ongoing,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        lastMove: 'e2e4',
        whiteClockSeconds: 170,
        blackClockSeconds: 180,
      );
      final staleFinished = _tourGame(
        id: 'stale',
        status: GameStatus.ongoing,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        lastMove: 'e2e4',
        whiteClockSeconds: 0,
        blackClockSeconds: 180,
      );
      final missingClock = _tourGame(
        id: 'missing-clock',
        status: GameStatus.ongoing,
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
        lastMove: 'e2e4',
        whiteClockSeconds: 170,
        blackClockSeconds: null,
      );
      final finished = _tourGame(id: 'finished', status: GameStatus.whiteWins);
      final unstarted = _tourGame(
        id: 'unstarted',
        status: GameStatus.ongoing,
        fen: null,
        lastMove: null,
        whiteClockSeconds: 1800,
        blackClockSeconds: 1800,
      );

      expect(isPremiumLiveGame(live), isTrue);
      expect(isPremiumLiveGame(staleFinished), isFalse);
      expect(isPremiumLiveGame(missingClock), isFalse);
      expect(isPremiumLiveGame(finished), isFalse);
      expect(isPremiumLiveGame(unstarted), isFalse);
    });
  });

  group('desktop smart event sections', () {
    test('groups GM smart games by date cards instead of event cards', () {
      final now = DateTime(2026, 6, 22, 12);
      final sections = buildDesktopSmartGameSections(
        [
          _tourGame(
            id: 'beta-1',
            status: GameStatus.whiteWins,
            tourId: 'beta',
            tourSlug: 'stronger-event',
            gameDay: DateTime(2026, 6, 22),
            avgElo: 2820,
            boardNr: 1,
          ),
          _tourGame(
            id: 'alpha-2',
            status: GameStatus.ongoing,
            tourId: 'alpha',
            tourSlug: 'alpha-event',
            gameDay: DateTime(2026, 6, 22),
            avgElo: 2700,
            boardNr: 2,
          ),
          _tourGame(
            id: 'alpha-1',
            status: GameStatus.ongoing,
            tourId: 'alpha',
            tourSlug: 'alpha-event',
            gameDay: DateTime(2026, 6, 22),
            avgElo: 2700,
            boardNr: 1,
          ),
          _tourGame(
            id: 'yesterday',
            status: GameStatus.draw,
            tourId: 'gamma',
            tourSlug: 'previous-event',
            gameDay: DateTime(2026, 6, 21),
            avgElo: 2750,
          ),
          _tourGame(
            id: 'future',
            status: GameStatus.ongoing,
            tourId: 'future',
            tourSlug: 'future-event',
            gameDay: DateTime(2026, 6, 23),
            avgElo: 2900,
          ),
        ],
        type: PremiumGamesType.gm,
        now: now,
      );

      expect(sections.map((section) => section.title), ['Today', 'Yesterday']);
      expect(sections.first.liveCount, 2);
      expect(sections.first.dateLabel, '2500+ average rating');
      expect(sections.first.games.map((game) => game.gameId), [
        'alpha-1',
        'alpha-2',
        'beta-1',
      ]);
    });

    test('keeps separate expandable sections per classical event day', () {
      final now = DateTime(2026, 6, 22, 12);
      final sections = buildDesktopSmartGameSections(
        [
          _tourGame(
            id: 'today',
            status: GameStatus.draw,
            tourId: 'classic',
            tourSlug: 'norway-chess',
            gameDay: DateTime(2026, 6, 22),
            timeControl: 'standard',
          ),
          _tourGame(
            id: 'yesterday',
            status: GameStatus.draw,
            tourId: 'classic',
            tourSlug: 'norway-chess',
            gameDay: DateTime(2026, 6, 21),
            timeControl: 'standard',
          ),
        ],
        type: PremiumGamesType.classical,
        now: now,
      );

      expect(sections.length, 2);
      expect(sections.map((section) => section.dateLabel), [
        'Today',
        'Yesterday',
      ]);
      expect(sections.map((section) => section.title).toSet(), {
        'Norway Chess',
      });
      expect(sections.first.timeControlLabel, 'Classical');
    });

    test('prefers Supabase broadcast event names over tour slugs', () {
      final sections = buildDesktopSmartGameSections(
        [
          _tourGame(
            id: 'pool-a',
            status: GameStatus.ongoing,
            tourId: 'pool-a',
            eventName: 'FIDE World Team Rapid & Blitz Chess Championships 2026',
            tourName:
                'FIDE World Team Rapid & Blitz Chess Championships 2026 | Pool A',
            tourSlug:
                'fide-world-team-rapid-blitz-chess-championships-2026-pool-a',
            gameDay: DateTime(2026, 6, 22),
          ),
          _tourGame(
            id: 'pool-b',
            status: GameStatus.ongoing,
            tourId: 'pool-b',
            eventName: 'FIDE World Team Rapid & Blitz Chess Championships 2026',
            tourName:
                'FIDE World Team Rapid & Blitz Chess Championships 2026 | Pool B',
            tourSlug:
                'fide-world-team-rapid-blitz-chess-championships-2026-pool-b',
            gameDay: DateTime(2026, 6, 22),
          ),
        ],
        type: PremiumGamesType.live,
        now: DateTime(2026, 6, 22, 12),
      );

      expect(sections, hasLength(1));
      expect(
        sections.single.title,
        'FIDE World Team Rapid & Blitz Chess Championships 2026',
      );
      expect(sections.single.gameCount, 2);
    });
  });

  group('Gamebase miniatures parsing', () {
    test('maps the backend pagination envelope and miniature fields', () {
      final page = GamebaseMiniaturesPage.fromJson({
        'status': 'success',
        'data': {
          'items': [
            {
              'gameId': '04a5af9b-0a7f-58c6-837f-ed3a49162b54',
              'avgRating': 1629,
              'plyCount': 50,
              'finalMoveNumber': 25,
              'result': 'W',
              'timeControl': 'RAPID',
              'isOnline': false,
              'date': '2026-06-25T00:00:00.000Z',
              'event': 'Fountain Open',
              'eco': 'B03',
              'opening': 'Alekhine Defense',
              'variation': 'Four Pawns Attack',
              'whiteName': 'Ashwin Jayaram',
              'blackName': 'Mathilde Sage Housion',
              'whiteElo': null,
              'blackElo': 1629,
              'whitePlayerId': 'white-id',
              'blackPlayerId': 'black-id',
              'whiteFed': 'USA',
              'blackFed': 'ITA',
            },
          ],
          'total': 2632661,
          'limit': 1,
          'offset': 0,
        },
      });

      expect(page.total, 2632661);
      expect(page.limit, 1);
      expect(page.offset, 0);
      expect(page.items, hasLength(1));

      final miniature = page.items.single;
      expect(miniature.gameId, '04a5af9b-0a7f-58c6-837f-ed3a49162b54');
      expect(miniature.avgRating, 1629);
      expect(miniature.finalMoveNumber, 25);
      expect(miniature.result, 'W');
      expect(miniature.isOnline, isFalse);
      expect(miniature.date, DateTime.utc(2026, 6, 25));
      expect(miniature.opening, 'Alekhine Defense');
      expect(miniature.variation, 'Four Pawns Attack');
      expect(miniature.blackElo, 1629);
      expect(miniature.whiteElo, isNull);
    });

    test('serializes endpoint filter options into miniatures query params', () {
      final filter = MiniatureGamesFilter(
        window: MiniatureGamesWindow.week,
        sort: MiniatureGamesSort.moves,
        order: MiniatureGamesSortOrder.asc,
        search: 'Carlsen',
        results: {MiniatureGameResult.whiteWins},
        eco: 'B12,C44',
        opening: 'Sicilian Defense',
        variation: 'Najdorf',
        ecoCategories: {'B', 'C'},
        timeControls: {
          MiniatureGameTimeControl.rapid,
          MiniatureGameTimeControl.blitz,
        },
        isOnline: true,
        minRating: 2200,
        maxRating: 2800,
        minMoves: 8,
        maxMoves: 25,
        dateFrom: '2026-01-01',
        dateTo: '2026-12-31',
        player: 'Kasparov',
      );

      expect(filter.queryParameters(limit: 30, offset: 60), {
        'window': 'week',
        'sort': 'moves',
        'order': 'asc',
        'limit': 30,
        'offset': 60,
        'q': 'Carlsen',
        'result': 'W',
        'eco': 'B12,C44',
        'opening': 'Sicilian Defense',
        'variation': 'Najdorf',
        'ecoCategory': 'B,C',
        'timeControl': 'RAPID,BLITZ',
        'isOnline': true,
        'minRating': 2200,
        'maxRating': 2800,
        'minMoves': 8,
        'maxMoves': 25,
        'dateFrom': '2026-01-01',
        'dateTo': '2026-12-31',
        'player': 'Kasparov',
      });
    });

    test('normalizes inverted date range before API serialization', () {
      final filter = MiniatureGamesFilter(
        dateFrom: '2026-12-31',
        dateTo: '2026-01-01',
      );

      expect(filter.queryParameters(limit: 30, offset: 0), {
        'window': 'all',
        'sort': 'recent',
        'order': 'desc',
        'limit': 30,
        'offset': 0,
        'dateFrom': '2026-01-01',
        'dateTo': '2026-12-31',
      });
    });

    test('miniature search does not filter only the loaded client page', () {
      final loadedPage = [
        _tourGame(
          id: 'loaded-row',
          status: GameStatus.whiteWins,
          whiteName: 'Already Loaded',
          blackName: 'Visible Opponent',
        ),
      ];

      expect(
        visibleDesktopSmartGames(
          type: PremiumGamesType.miniatures,
          games: loadedPage,
          query: 'Carlsen',
        ),
        loadedPage,
      );
      expect(
        visibleDesktopSmartGames(
          type: PremiumGamesType.live,
          games: loadedPage,
          query: 'Carlsen',
        ),
        isEmpty,
      );
    });

    test(
      'collapsed miniatures request another page when nothing is expanded',
      () {
        expect(
          shouldLoadMoreForCollapsedMiniatures(
            type: PremiumGamesType.miniatures,
            sectionCount: 2,
            expandedGameCount: 0,
            hasMore: true,
            isLoading: false,
          ),
          isTrue,
        );
      },
    );

    test(
      'collapsed miniature pagination waits when already loading or exhausted',
      () {
        expect(
          shouldLoadMoreForCollapsedMiniatures(
            type: PremiumGamesType.miniatures,
            sectionCount: 2,
            expandedGameCount: 0,
            hasMore: true,
            isLoading: true,
          ),
          isFalse,
        );
        expect(
          shouldLoadMoreForCollapsedMiniatures(
            type: PremiumGamesType.miniatures,
            sectionCount: 2,
            expandedGameCount: 0,
            hasMore: false,
            isLoading: false,
          ),
          isFalse,
        );
      },
    );

    test(
      'collapsed miniature pagination keeps visible expanded games stable',
      () {
        expect(
          shouldLoadMoreForCollapsedMiniatures(
            type: PremiumGamesType.miniatures,
            sectionCount: 2,
            expandedGameCount: 3,
            hasMore: true,
            isLoading: false,
          ),
          isFalse,
        );
        expect(
          shouldLoadMoreForCollapsedMiniatures(
            type: PremiumGamesType.live,
            sectionCount: 2,
            expandedGameCount: 0,
            hasMore: true,
            isLoading: false,
          ),
          isFalse,
        );
      },
    );

    test('a smart feed too short to scroll keeps requesting older days', () {
      // A single "Today" section that does not overflow the viewport leaves
      // maxScrollExtent at 0, so the scroll listener can never fire.
      expect(
        shouldAutoFillSmartGamesViewport(
          hasMore: true,
          isLoading: false,
          remainingScrollExtent: 0,
          autoFillLoads: 0,
        ),
        isTrue,
      );
    });

    test('viewport auto-fill stops once the feed is scrollable', () {
      expect(
        shouldAutoFillSmartGamesViewport(
          hasMore: true,
          isLoading: false,
          remainingScrollExtent: kSmartGamesLoadMoreThreshold + 1,
          autoFillLoads: 0,
        ),
        isFalse,
      );
    });

    test('viewport auto-fill never stacks requests or outruns its budget', () {
      expect(
        shouldAutoFillSmartGamesViewport(
          hasMore: true,
          isLoading: true,
          remainingScrollExtent: 0,
          autoFillLoads: 0,
        ),
        isFalse,
      );
      expect(
        shouldAutoFillSmartGamesViewport(
          hasMore: false,
          isLoading: false,
          remainingScrollExtent: 0,
          autoFillLoads: 0,
        ),
        isFalse,
      );
      expect(
        shouldAutoFillSmartGamesViewport(
          hasMore: true,
          isLoading: false,
          remainingScrollExtent: 0,
          autoFillLoads: kSmartGamesMaxViewportFillLoads,
        ),
        isFalse,
      );
    });
  });
}

GamesTourModel _tourGame({
  required String id,
  required GameStatus status,
  String tourId = 'tour1',
  String? tourSlug,
  String? tourName,
  String? eventName,
  String? fen,
  String? lastMove,
  int? whiteClockSeconds,
  int? blackClockSeconds,
  DateTime? gameDay,
  DateTime? lastMoveTime,
  int? avgElo,
  int? boardNr,
  String? timeControl,
  String whiteName = 'White',
  String blackName = 'Black',
}) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: PlayerCard(
      name: whiteName,
      federation: 'USA',
      title: 'GM',
      rating: 2700,
      countryCode: 'USA',
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: blackName,
      federation: 'IND',
      title: 'GM',
      rating: 2700,
      countryCode: 'IND',
      team: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    whiteClockSeconds: whiteClockSeconds,
    blackClockSeconds: blackClockSeconds,
    gameStatus: status,
    roundId: 'round1',
    tourId: tourId,
    tourSlug: tourSlug,
    tourName: tourName,
    eventName: eventName,
    fen: fen,
    lastMove: lastMove,
    gameDay: gameDay,
    lastMoveTime: lastMoveTime,
    avgElo: avgElo,
    boardNr: boardNr,
    timeControl: timeControl,
  );
}
