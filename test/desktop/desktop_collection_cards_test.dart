import 'package:chessever/desktop/widgets/desktop_collection_cards.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('desktop collection cards expose GM smart games from home', (
    tester,
  ) async {
    PremiumGamesType? selectedType;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          favoritePlayersProviderNew.overrideWith(
            _TestFavoritePlayersNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              ResponsiveHelper.init(context);
              return Material(
                child: SizedBox(
                  width: 900,
                  height: 180,
                  child: DesktopCollectionCards(
                    onFavoritesTap: () {},
                    onCountrymenTap: () {},
                    onSmartCollectionTap: (type) => selectedType = type,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('GM'), findsOneWidget);

    await tester.tap(find.text('GM'));
    await tester.pumpAndSettle();

    expect(selectedType, PremiumGamesType.gm);
  });
}

class _TestFavoritePlayersNotifier extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => const [];
}
