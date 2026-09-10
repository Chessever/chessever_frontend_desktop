import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_game_points.dart';
import 'package:chessever/desktop/widgets/desktop_team_match_grouping.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

List<Games> fixtureGames() {
  final fixture =
      jsonDecode(
            File('test/fixtures/alpine_pbg_Au6yU4b1.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  return (fixture['games'] as List).map((value) {
    final row = value as Map<String, dynamic>;
    // Adapt the public broadcast envelope to the existing Supabase model.
    // Awards remain exactly as fetched; only foreign-key/FIDE id typing is
    // normalized because the broadcast envelope serializes ids as strings.
    return Games.fromJson({
      ...row,
      'round_id': 'Au6yU4b1',
      'round_slug': 'alpine-apl-pipers-pbg-alaskan-knights',
      'tour_id': 'lPIyMgCi',
      'tour_slug': 'global-chess-league-season-4-preliminary-stage',
      'board_nr': row['boardNr'],
      'last_move': row['lastMove'],
      'players': [
        for (final player in row['players'] as List? ?? const [])
          {
            ...(player as Map<String, dynamic>),
            'fideId': int.tryParse('${player['fideId'] ?? ''}') ?? 0,
          },
      ],
    });
  }).toList();
}

GamesTourModel model(Games row) =>
    gamesTourModelFromTournamentSummary(TournamentGameSummary.fromGame(row));

class _AwardRepository implements GameRepository {
  _AwardRepository(this.rows);
  final List<Games> rows;
  @override
  Future<Games> getGameWithPGN(String id) async =>
      rows.firstWhere((row) => row.id == id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'actual rail next-game navigation hands authoritative awards to Board args',
    (tester) async {
      final rows = fixtureGames();
      final summaries = rows.map(TournamentGameSummary.fromGame).toList();
      final selected = summaries[1];
      final args = BoardTabGameArgs(
        gameId: selected.id,
        pgn: '',
        label: selected.name,
        whiteName: selected.whitePlayer,
        blackName: selected.blackPlayer,
        routeTitle: 'Match',
        routeGames: summaries,
        gameListSelectedId: selected.id,
      );
      WidgetRef? widgetRef;
      BuildContext? widgetContext;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gameRepositoryProvider.overrideWithValue(_AwardRepository(rows)),
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => {'tournaments-default': args},
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                widgetRef = ref;
                widgetContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await navigateActiveEventGame(
        widgetRef!,
        context: widgetContext!,
        delta: 1,
      );
      await tester.pump();
      final opened =
          widgetRef!.read(
            boardTabGameArgsByTabIdProvider,
          )['tournaments-default']!;
      expect(opened.gameId, summaries[2].id);
      expect(boardPlayerAwardedPoints(isWhite: true, args: opened), 0);
      expect(boardPlayerAwardedPoints(isWhite: false, args: opened), 4);
      // Flipping only changes placement; switching back uses that row's own award.
      expect(
        boardPlayerAwardedPoints(
          isWhite: false,
          args: opened.copyWith(initialBoardFlipped: true),
        ),
        4,
      );
      await navigateActiveEventGame(
        widgetRef!,
        context: widgetContext!,
        delta: -1,
      );
      await tester.pump();
      final returned =
          widgetRef!.read(
            boardTabGameArgsByTabIdProvider,
          )['tournaments-default']!;
      expect(returned.gameId, selected.id);
      expect(boardPlayerAwardedPoints(isWhite: true, args: returned), 1);
      expect(boardPlayerAwardedPoints(isWhite: false, args: returned), 1);
    },
  );
  test('actual six boards retain source awards and sum to Alpine 11 PBG 6', () {
    final rows = fixtureGames();
    expect(rows, hasLength(6));
    final games = rows.map(model).toList();
    final group = buildDesktopTeamMatchGroups(games).single;
    expect(group.leftTeam, 'Alpine APL Pipers');
    expect(group.rightTeam, 'PBG Alaskan Knights');
    expect([group.score.left, group.score.right], [11, 6]);
    expect(
      games.map(
        (g) => [g.whitePlayer.customPoints, g.blackPlayer.customPoints],
      ),
      [
        [3, 0],
        [1, 1],
        [0, 4],
        [1, 1],
        [3, 0],
        [3, 0],
      ],
    );
    final standard =
        games
            .map(
              (g) => g.copyWith(
                whitePlayer: g.whitePlayer.copyWith(clearCustomPoints: true),
                blackPlayer: g.blackPlayer.copyWith(clearCustomPoints: true),
              ),
            )
            .toList();
    final fallback = buildDesktopTeamMatchGroups(standard).single.score;
    expect([fallback.left, fallback.right], [4, 2]);
    final reversed = games[2].copyWith(
      whitePlayer: games[2].blackPlayer,
      blackPlayer: games[2].whitePlayer,
      gameStatus: GameStatus.whiteWins,
    );
    final mixed = [...games]..[2] = reversed;
    final swapped = buildDesktopTeamMatchGroups(mixed).single;
    expect(swapped.games[2].order, DesktopTeamGameOrder.oppositeOrder);
    expect([swapped.score.left, swapped.score.right], [11, 6]);
  });

  test(
    'absent malformed and nonfinite awards fall back; explicit zero survives',
    () {
      for (final value in [
        null,
        '3',
        'bad',
        true,
        {},
        [],
        double.nan,
        double.infinity,
      ]) {
        final player = Player.fromJson({
          'name': 'Player',
          'customPoints': value,
        });
        expect(player.customPoints, isNull);
        expect(
          desktopGamePointsLabel(
            GameStatus.draw,
            isWhite: true,
            customPoints: player.customPoints,
          ),
          '½',
        );
      }
      expect(Player.fromJson({'name': 'Player'}).customPoints, isNull);
      expect(
        Player.fromJson({'name': 'Player', 'customPoints': 0}).customPoints,
        0,
      );
      expect(
        desktopGamePointsLabel(
          GameStatus.whiteWins,
          isWhite: true,
          customPoints: 0,
        ),
        '0',
      );
      expect(
        desktopGamePointsLabel(GameStatus.draw, isWhite: true, customPoints: 1),
        '1',
      );
      expect(
        desktopGamePointsLabel(
          GameStatus.draw,
          isWhite: true,
          customPoints: 1.25,
        ),
        '1.25',
      );
      expect(
        desktopGamePointsLabel(
          GameStatus.ongoing,
          isWhite: true,
          customPoints: 3,
        ),
        '',
      );
      expect(
        desktopGamePointsLabel(
          GameStatus.unknown,
          isWhite: false,
          customPoints: 0,
        ),
        '',
      );
    },
  );

  test(
    'copy navigation and window payload preserve awards without changing PGN',
    () {
      const pgn = '[White "A"]\n[Black "B"]\n[Result "0-1"]\n\n1. e4 e5 0-1';
      final row = fixtureGames()[2].copyWith(pgn: pgn);
      final summary = TournamentGameSummary.fromGame(
        row,
      ).copyWith(name: 'Renamed');
      final source = gamesTourModelFromTournamentSummary(summary);
      final card = GameCardData.fromGamesTourModel(
        source,
      ).copyWith(whiteFederation: 'IND');
      expect([card.whiteCustomPoints, card.blackCustomPoints], [0, 4]);
      expect(source.whitePlayer.copyWith(name: 'Updated').customPoints, 0);
      expect(
        source.blackPlayer.copyWith(clearCustomPoints: true).customPoints,
        isNull,
      );
      expect(
        summary.copyWith(clearBlackCustomPoints: true).blackCustomPoints,
        isNull,
      );
      final args = BoardTabGameArgs(
        gameId: source.gameId,
        pgn: pgn,
        label: 'Game',
        whiteName: 'A',
        blackName: 'B',
        sourceGame: source,
        eventGames: [summary],
        initialBoardFlipped: true,
      );
      final decoded =
          DesktopBoardWindowPayload.decode(
            DesktopBoardWindowPayload.fromArgs(args).encode(),
          ).args!;
      final navigated = gamesTourModelFromTournamentSummary(
        decoded.eventGames.single,
      );
      expect(decoded.initialBoardFlipped, isTrue);
      expect(boardPlayerAwardedPoints(isWhite: false, args: decoded), 4);
      expect(
        boardPlayerAwardedPoints(
          isWhite: false,
          args: decoded,
          sourceGame: source.copyWith(
            blackPlayer: source.blackPlayer.copyWith(clearCustomPoints: true),
          ),
        ),
        isNull,
      );
      expect(
        [
          navigated.whitePlayer.customPoints,
          navigated.blackPlayer.customPoints,
        ],
        [0, 4],
      );
      expect(decoded.pgn, pgn);
      expect(navigated.pgn, pgn);
      expect(navigated.gameStatus, GameStatus.blackWins);
      expect(row.toJson()['status'], '0-1');
    },
  );

  test(
    'score-only refresh changes stamps and full/partial clears are distinct',
    () {
      final row = fixtureGames().first;
      final source = model(row);
      final changed = mergeLiveGameUpdateWithBase(
        baseGame: source,
        update: LiveGameUpdate(
          gameId: source.gameId,
          players: [
            {'customPoints': 5},
            {'customPoints': 0},
          ],
        ),
      );
      expect(changed.whitePlayer.customPoints, 5);
      expect(changed.lastMoveTime, source.lastMoveTime);
      expect(changed.gameStatus, source.gameStatus);
      expect(
        tournamentGameModelsSourceFingerprint([changed]),
        isNot(tournamentGameModelsSourceFingerprint([source])),
      );
      final changedRow = row.copyWith(
        players: [
          Player.fromJson({...row.players!.first.toJson(), 'customPoints': 5}),
          row.players![1],
        ],
      );
      expect(
        tournamentGamesSourceFingerprint([changedRow]),
        tournamentGameModelsSourceFingerprint([changed]),
      );
      final omitted = mergeLiveGameUpdateWithBase(
        baseGame: changed,
        update: LiveGameUpdate(gameId: source.gameId, players: [{}, {}]),
      );
      expect(omitted.whitePlayer.customPoints, 5);
      final cleared = mergeLiveGameUpdateWithBase(
        baseGame: changed,
        update: LiveGameUpdate(
          gameId: source.gameId,
          players: [
            {'customPoints': null},
            {'customPoints': 'bad'},
          ],
        ),
      );
      expect(cleared.whitePlayer.customPoints, isNull);
      expect(cleared.blackPlayer.customPoints, isNull);
      final full = mergeLiveGameUpdateWithBase(
        baseGame: changed,
        update: LiveGameUpdate(
          gameId: source.gameId,
          isFullRow: true,
          players: [{}, {}],
        ),
      );
      expect(full.whitePlayer.customPoints, isNull);
      expect(full.blackPlayer.customPoints, isNull);
    },
  );

  testWidgets(
    'board awards follow color on flip, refresh and navigation; colors remain results',
    (tester) async {
      final games = fixtureGames().map(model).toList();
      Future<void> show(GamesTourModel game, bool flipped) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    for (final isWhite in [flipped, !flipped])
                      SizedBox(
                        width: 760,
                        height: 48,
                        child: DesktopBoardPlayerHeader(
                          name: isWhite ? 'White' : 'Black',
                          federation: '',
                          title: '',
                          rating: 0,
                          fideId: null,
                          result: boardPlayerResultForSide(
                            game.gameStatus,
                            isWhite: isWhite,
                          ),
                          isWhite: isWhite,
                          isToMove: false,
                          sourceGame: game,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await show(games[2], false);
      final status = find.byKey(const Key('desktop-board-result-status'));
      expect(tester.widgetList<Container>(status).map((c) => c.color), [
        kPrimaryColor.withValues(alpha: 0.78),
        kRedColor.withValues(alpha: 0.82),
      ]);
      expect(
        find.descendant(of: status.first, matching: find.text('4')),
        findsOneWidget,
      );
      await show(games[2], true);
      expect(
        find.descendant(of: status.first, matching: find.text('0')),
        findsOneWidget,
      );
      await show(games[1], true);
      expect(
        find.descendant(of: status, matching: find.text('1')),
        findsNWidgets(2),
      );
      expect(
        tester
            .widgetList<Container>(status)
            .every((c) => c.color == kMoveStatDrawColor),
        isTrue,
      );
      await show(
        games[1].copyWith(
          whitePlayer: games[1].whitePlayer.copyWith(customPoints: 2),
        ),
        true,
      );
      expect(
        find.descendant(of: status.first, matching: find.text('2')),
        findsOneWidget,
      );
      await show(games[1].copyWith(gameStatus: GameStatus.ongoing), true);
      expect(status, findsNothing);
    },
  );

  testWidgets('list card custom draw is neutral rather than winner cyan', (
    tester,
  ) async {
    final game = model(fixtureGames()[1]);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 150,
              child: DesktopGameCard(
                data: GameCardData.fromGamesTourModel(game),
                onTap: null,
                allowStockfishFallback: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final labels = tester.widgetList<Text>(find.text('1'));
    expect(labels, hasLength(2));
    expect(
      labels.every((text) => text.style?.color == kLightGreyColor),
      isTrue,
    );
    // Card eval caches keep providers alive on 3s/4s timers.
    await tester.pump(const Duration(seconds: 4));
  });
}
