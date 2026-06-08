import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/player_score_card_view.dart';
import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/providers/player_ratings_provider.dart';
import 'package:chessever/screens/standings/score_card_screen.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';

void main() {
  testWidgets(
    'player game rows place circular result beside row number',
    (tester) async {
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
          return;
        }
        originalOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalOnError);

      addTearDown(() => tester.view.resetPhysicalSize());
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;

      const player = PlayerStandingModel(
        countryCode: 'GER',
        title: 'FM',
        name: 'Guttkin, Ilya',
        score: 2280,
        scoreChange: 0,
        matchScore: '1 / 1',
      );
      final game = _game(
        white: _player(
          name: 'Guttkin, Ilya',
          federation: 'GER',
          title: 'FM',
          rating: 2280,
          fideId: 1001,
        ),
        black: _player(
          name: 'Schueler, Tobias',
          federation: 'GER',
          rating: 2038,
          fideId: 2002,
        ),
        status: GameStatus.whiteWins,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backfilledStandingPlayerProvider.overrideWith(
              (ref, player) async => player,
            ),
            allRatingsProvider.overrideWith(
              (ref, request) async =>
                  const AllRatingsResult(standard: 2280, standardK: 20),
            ),
            scoreCardGamesContextProvider.overrideWith((ref) => [game]),
            scoreCardHasEventContextProvider.overrideWith((ref) => true),
            scoreCardPlayerProfileDataSourceProvider.overrideWith(
              (ref) => PlayerProfileDataSource.twic,
            ),
            selectedBroadcastModelProvider.overrideWith((ref) => null),
            favoritePlayersProviderNew.overrideWith(
              _TestFavoritePlayersNotifier.new,
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                ResponsiveHelper.init(context);
                return const Scaffold(
                  body: SizedBox(
                    width: 1600,
                    height: 900,
                    child: PlayerScoreCardView(player: player),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final nameFinder = find.text('Schueler, Tobias');
      final ratingFinder = find.text('2038');
      final changeFinder = find.text('+4').last;
      final roundFinder = find.text('1').first;
      final resultFinder = find.text('1').last;

      expect(nameFinder, findsOneWidget);
      expect(ratingFinder, findsOneWidget);
      expect(changeFinder, findsOneWidget);

      final roundRight = tester.getTopRight(roundFinder).dx;
      final resultLeft = tester.getTopLeft(resultFinder).dx;
      final resultRight = tester.getTopRight(resultFinder).dx;
      final nameLeft = tester.getTopLeft(nameFinder).dx;
      final nameRight = tester.getTopRight(nameFinder).dx;
      final ratingLeft = tester.getTopLeft(ratingFinder).dx;
      final ratingRight = tester.getTopRight(ratingFinder).dx;
      final changeLeft = tester.getTopLeft(changeFinder).dx;

      expect(resultLeft - roundRight, lessThan(40));
      expect(resultRight, lessThan(nameLeft));
      expect(ratingLeft - nameRight, lessThan(18));
      expect(changeLeft - ratingRight, lessThan(16));

      final badgeFinder = find.ancestor(
        of: resultFinder,
        matching: find.byWidgetPredicate((widget) {
          final decoration = widget is Container ? widget.decoration : null;
          return decoration is BoxDecoration &&
              decoration.shape == BoxShape.circle &&
              decoration.color == Colors.white;
        }),
      );
      expect(badgeFinder, findsOneWidget);

      final resultText = tester.widget<Text>(resultFinder);
      expect(resultText.style?.color, Colors.black);
    },
  );
}

PlayerCard _player({
  required String name,
  required String federation,
  String title = '',
  required int rating,
  required int fideId,
}) {
  return PlayerCard(
    name: name,
    federation: federation,
    title: title,
    rating: rating,
    countryCode: federation,
    team: null,
    fideId: fideId,
  );
}

GamesTourModel _game({
  required PlayerCard white,
  required PlayerCard black,
  required GameStatus status,
}) {
  return GamesTourModel(
    gameId: 'game-1',
    whitePlayer: white,
    blackPlayer: black,
    whiteTimeDisplay: '',
    blackTimeDisplay: '',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    roundSlug: 'round-1',
    tourId: 'event-1',
    tourSlug: 'Krefelder Pfingstopen 2026',
    timeControl: 'standard',
  );
}

class _TestFavoritePlayersNotifier extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => const [];
}
