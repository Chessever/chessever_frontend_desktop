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
      _cardsHost(
        width: 900,
        height: 260,
        onSmartCollectionTap: (type) => selectedType = type,
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('GM'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Countrymen'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Miniatures'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final favoritesTop = tester.getTopLeft(find.text('Favorites')).dy;
    final countrymenTop = tester.getTopLeft(find.text('Countrymen')).dy;
    final liveTop = tester.getTopLeft(find.text('Live')).dy;
    expect(countrymenTop, favoritesTop);
    expect(liveTop, greaterThan(favoritesTop));

    await tester.tap(find.text('GM'));
    await tester.pump();

    expect(selectedType, PremiumGamesType.gm);
  });

  testWidgets('wide desktop keeps all five shortcuts in one row', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _cardsHost(width: 1400, height: 180, onSmartCollectionTap: (_) {}),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final top = tester.getTopLeft(find.text('Favorites')).dy;
    expect(tester.getTopLeft(find.text('Countrymen')).dy, closeTo(top, 3));
    expect(tester.getTopLeft(find.text('Live')).dy, closeTo(top, 3));
    expect(tester.getTopLeft(find.text('GM')).dy, closeTo(top, 3));
    expect(tester.getTopLeft(find.text('Miniatures')).dy, closeTo(top, 3));
    expect(tester.takeException(), isNull);
  });
}

Widget _cardsHost({
  required double width,
  required double height,
  required ValueChanged<PremiumGamesType> onSmartCollectionTap,
}) {
  return ProviderScope(
    overrides: [
      favoritePlayersProviderNew.overrideWith(_TestFavoritePlayersNotifier.new),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) {
          ResponsiveHelper.init(context);
          return Material(
            child: SizedBox(
              width: width,
              height: height,
              child: DesktopCollectionCards(
                onFavoritesTap: () {},
                onCountrymenTap: () {},
                onSmartCollectionTap: onSmartCollectionTap,
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _TestFavoritePlayersNotifier extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => const [];
}
