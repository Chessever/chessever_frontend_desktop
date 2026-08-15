import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/knockout_match_detector.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('confirmed knockout presentation', () {
    test('groups complete player pairings without game-N round slugs', () {
      final games = [
        _game('g1', 'Alpha', 'Beta'),
        _game('g2', 'Beta', 'Alpha'),
        _game('g3', 'Gamma', 'Delta'),
        _game('g4', 'Delta', 'Gamma'),
      ];

      expect(KnockoutMatchDetector.isKnockoutMatchFormat(games), isFalse);
      expect(KnockoutMatchDetector.canGroupConfirmedKnockout(games), isTrue);
      expect(KnockoutMatchDetector.groupByMatches(games), hasLength(2));
    });

    test('supports a one-game match once knockout state is confirmed', () {
      final games = [_game('g1', 'Alpha', 'Beta')];

      expect(KnockoutMatchDetector.canGroupConfirmedKnockout(games), isTrue);
    });

    test('falls back when any game has unresolved placeholder entrants', () {
      final games = [
        _game('g1', 'Alpha', 'Beta'),
        _game('g2', 'Winner of Match 1', 'TBD'),
      ];

      expect(KnockoutMatchDetector.canGroupConfirmedKnockout(games), isFalse);
    });
  });

  group('Desktop knockout games presentation mode', () {
    test('shows match sections only in Match series mode', () {
      expect(
        shouldShowKnockoutMatchSections(
          isKnockout: true,
          canGroup: true,
          presentation: DesktopKnockoutGamesPresentation.matchSeries,
        ),
        isTrue,
      );
      expect(
        shouldShowKnockoutMatchSections(
          isKnockout: true,
          canGroup: true,
          presentation: DesktopKnockoutGamesPresentation.allBoards,
        ),
        isFalse,
      );
    });

    test('does not manufacture match sections for unsupported rounds', () {
      expect(
        shouldShowKnockoutMatchSections(
          isKnockout: false,
          canGroup: true,
          presentation: DesktopKnockoutGamesPresentation.matchSeries,
        ),
        isFalse,
      );
      expect(
        shouldShowKnockoutMatchSections(
          isKnockout: true,
          canGroup: false,
          presentation: DesktopKnockoutGamesPresentation.matchSeries,
        ),
        isFalse,
      );
    });

    test('orders later knockout stages before earlier-stage matches', () {
      final games = [
        _game(
          'qf-board-1',
          'Quarterfinal A',
          'Quarterfinal B',
          roundSlug: 'quarterfinals-match-3-4',
          boardNr: 1,
        ),
        _game(
          'sf-board-1',
          'Semifinal A',
          'Semifinal B',
          roundSlug: 'semifinals-match-2',
          boardNr: 1,
        ),
        _game(
          'qf-board-2',
          'Quarterfinal C',
          'Quarterfinal D',
          roundSlug: 'quarterfinals-match-3-4',
          boardNr: 2,
        ),
      ];

      final matches = orderedKnockoutMatchEntriesForDisplay(games);

      expect(matches, hasLength(3));
      expect(matches.first.value.single.gameId, 'sf-board-1');
      expect(
        matches.skip(1).map((entry) => entry.value.single.gameId),
        <String>['qf-board-1', 'qf-board-2'],
      );
    });

    test('orders latest pairing first within the same knockout stage', () {
      final games = [
        _game(
          'earlier-pairing',
          'Nakamura, Hikaru',
          'Lazavik, Denis',
          roundSlug: 'quarterfinals-match-3-4',
          boardNr: 1,
          roundStartsAt: DateTime.utc(2026, 8, 14, 9, 40),
        ),
        _game(
          'later-pairing',
          'Carlsen, Magnus',
          'Firouzja, Alireza',
          roundSlug: 'quarterfinals-match-3-4',
          boardNr: 2,
          roundStartsAt: DateTime.utc(2026, 8, 14, 11, 40),
        ),
      ];

      expect(
        orderedKnockoutMatchEntriesForDisplay(
          games,
        ).map((entry) => entry.value.single.gameId),
        <String>['later-pairing', 'earlier-pairing'],
      );
    });

    test('derives compact identity, result, and start-time presentation', () {
      final later = DateTime(2026, 8, 15, 8, 30);
      final earlier = DateTime(2026, 8, 15, 6);
      final nakamura = _player(
        'Nakamura, Hikaru',
        federation: 'USA',
        title: 'GM',
        rating: 2792,
      );
      final lazavik = _player(
        'Lazavik, Denis',
        federation: 'BLR',
        title: 'GM',
        rating: 2621,
      );
      final header = KnockoutMatchDetector.createMatchHeader('pairing', [
        _game(
          'g1',
          nakamura.name,
          lazavik.name,
          whitePlayer: nakamura,
          blackPlayer: lazavik,
          gameStatus: GameStatus.whiteWins,
          roundStartsAt: later,
        ),
        _game(
          'g2',
          lazavik.name,
          nakamura.name,
          whitePlayer: lazavik,
          blackPlayer: nakamura,
          gameStatus: GameStatus.ongoing,
          roundStartsAt: earlier,
        ),
      ]);

      expect(header.player1Card, nakamura);
      expect(header.player2Card, lazavik);
      expect(header.startsAt, earlier);
      expect(header.hasReportedScore, isTrue);
      expect(header.player1ScoreLabel, '1');
      expect(header.player2ScoreLabel, '0');
      expect(header.player1ResultTone, MatchPlayerResultTone.leading);
      expect(header.player2ResultTone, MatchPlayerResultTone.trailing);
    });

    test('keeps vs state neutral before any game result is reported', () {
      final header = KnockoutMatchDetector.createMatchHeader('pairing', [
        _game(
          'g1',
          'Nakamura, Hikaru',
          'Lazavik, Denis',
          gameStatus: GameStatus.ongoing,
        ),
      ]);

      expect(header.hasReportedScore, isFalse);
      expect(header.player1ResultTone, MatchPlayerResultTone.neutral);
      expect(header.player2ResultTone, MatchPlayerResultTone.neutral);
    });

    test('prefers per-game time_start over a shared round start', () {
      final source = Games.fromJson({
        'id': 'scheduled-pairing',
        'round_id': 'shared-quarterfinal-round',
        'round_slug': 'quarterfinals-match-3-4',
        'tour_id': 'playoffs',
        'tour_slug': 'playoffs',
        'players': [
          {'name': 'Nakamura, Hikaru', 'rating': 2792},
          {'name': 'Lazavik, Denis', 'rating': 2621},
        ],
        'status': 'ONGOING',
        'date_start': '2026-08-15',
        'time_start': '11:40:00',
        'round_schedule': {
          'name': 'Quarterfinals | Match 3 & 4',
          'starts_at': '2026-08-15T10:00:00Z',
        },
      });
      final game = GamesTourModel.fromGame(source);
      final header = KnockoutMatchDetector.createMatchHeader('pairing', [game]);

      expect(source.timeStart, '11:40:00');
      expect(source.toJson()['time_start'], '11:40:00');
      expect(game.timeStart, '11:40:00');
      expect(header.startsAt, DateTime.utc(2026, 8, 15, 11, 40));
    });

    testWidgets('keeps filters and knockout presentation on one toolbar row', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              child: TournamentGamesToolbarLayout(
                quickFilter: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('All'), Text('Live')],
                ),
                knockoutPresentation: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Text('Match series'), Text('All boards')],
                ),
                viewMode: Icon(Icons.grid_view_rounded),
              ),
            ),
          ),
        ),
      );

      expect(find.text('VIEW'), findsNothing);
      final all = tester.getRect(find.text('All'));
      final matchSeries = tester.getRect(find.text('Match series'));
      final viewMode = tester.getRect(find.byIcon(Icons.grid_view_rounded));
      expect(all.left, lessThan(matchSeries.left));
      expect(matchSeries.right, lessThan(viewMode.left));
      expect(all.center.dy, closeTo(matchSeries.center.dy, 0.5));
      expect(matchSeries.center.dy, closeTo(viewMode.center.dy, 0.5));
    });

    testWidgets(
      'keeps identity colors and places decisive scores toward the center',
      (tester) async {
        final startsAt = DateTime(2026, 8, 15, 6);
        final nakamura = _player(
          'Nakamura, Hikaru',
          federation: 'USA',
          title: 'GM',
          rating: 2792,
        );
        final lazavik = _player(
          'Lazavik, Denis',
          federation: 'BLR',
          title: 'GM',
          rating: 2621,
        );

        MatchHeaderModel headerFor(GameStatus status) =>
            KnockoutMatchDetector.createMatchHeader('pairing', [
              _game(
                'g1',
                nakamura.name,
                lazavik.name,
                whitePlayer: nakamura,
                blackPlayer: lazavik,
                gameStatus: status,
                roundStartsAt: startsAt,
              ),
            ]);

        Future<void> pumpHeader(MatchHeaderModel header) => tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.darkTheme,
            home: Scaffold(
              body: SizedBox(
                width: 1400,
                child: buildKnockoutMatchSectionHeaderForTesting(header),
              ),
            ),
          ),
        );

        await pumpHeader(headerFor(GameStatus.ongoing));

        expect(find.text('MATCH'), findsNothing);
        expect(find.text('Nakamura, Hikaru'), findsOneWidget);
        expect(find.text('(2792)'), findsOneWidget);
        expect(find.text('Lazavik, Denis'), findsOneWidget);
        expect(find.text('(2621)'), findsOneWidget);
        expect(find.text('vs'), findsOneWidget);
        expect(find.text('Aug 15 · 06:00'), findsOneWidget);

        await pumpHeader(headerFor(GameStatus.whiteWins));
        await tester.pumpAndSettle();

        expect(find.text('vs'), findsNothing);
        expect(find.text('1'), findsOneWidget);
        expect(find.text('0'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('Nakamura, Hikaru')).style?.color,
          kWhiteColor,
        );
        expect(
          tester.widget<Text>(find.text('Lazavik, Denis')).style?.color,
          kWhiteColor,
        );
        expect(tester.widget<Text>(find.text('1')).style?.color, kPrimaryColor);
        expect(tester.widget<Text>(find.text('0')).style?.color, kRedColor);
        final player1Name = tester.getRect(find.text('Nakamura, Hikaru'));
        final player1Score = tester.getRect(find.text('1'));
        final separator = tester.getRect(find.text('–'));
        final player2Score = tester.getRect(find.text('0'));
        final player2Name = tester.getRect(find.text('Lazavik, Denis'));
        expect(player1Name.right, lessThan(player1Score.left));
        expect(player1Score.right, lessThan(separator.left));
        expect(separator.right, lessThan(player2Score.left));
        expect(player2Score.right, lessThan(player2Name.left));
      },
    );
  });
}

GamesTourModel _game(
  String id,
  String white,
  String black, {
  String roundSlug = 'playoffs',
  int? boardNr,
  PlayerCard? whitePlayer,
  PlayerCard? blackPlayer,
  GameStatus gameStatus = GameStatus.draw,
  DateTime? roundStartsAt,
}) => GamesTourModel(
  gameId: id,
  whitePlayer: whitePlayer ?? _player(white),
  blackPlayer: blackPlayer ?? _player(black),
  whiteTimeDisplay: '',
  blackTimeDisplay: '',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: gameStatus,
  roundId: 'playoffs',
  roundSlug: roundSlug,
  boardNr: boardNr,
  tourId: 'tour',
  roundStartsAt: roundStartsAt,
);

PlayerCard _player(
  String name, {
  String federation = 'FIDE',
  String title = '',
  int rating = 2500,
}) => PlayerCard(
  name: name,
  federation: federation,
  title: title,
  rating: rating,
  countryCode: federation,
  team: null,
);
