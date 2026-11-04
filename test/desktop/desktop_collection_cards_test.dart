import 'package:chessever/desktop/widgets/desktop_collection_cards.dart';
import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('collection cards share sizing and actions', (tester) async {
    PremiumGamesType? selectedType;
    var favoritesTaps = 0;
    var countrymenTaps = 0;
    var likesTaps = 0;

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
                    onFavoritesTap: () => favoritesTaps++,
                    onCountrymenTap: () => countrymenTaps++,
                    onSmartCollectionTap: (type) => selectedType = type,
                    onLikesTap: () => likesTaps++,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));

    final miniatureSize = tester.getSize(
      find.ancestor(
        of: find.text('Miniatures'),
        matching: find.byType(DesktopTappable),
      ),
    );
    for (final title in ['Live', 'GM', 'Likes']) {
      expect(
        tester.getSize(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(DesktopTappable),
          ),
        ),
        miniatureSize,
        reason: '$title should match Miniatures',
      );
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selectedType, PremiumGamesType.live);

    await tester.tap(find.text('Favorites'));
    await tester.pump();
    expect(favoritesTaps, 1);

    await tester.tap(find.text('Countrymen'));
    await tester.pump();
    expect(countrymenTaps, 1);

    for (final entry
        in {
          'Live': PremiumGamesType.live,
          'GM': PremiumGamesType.gm,
          'Miniatures': PremiumGamesType.miniatures,
        }.entries) {
      await tester.ensureVisible(find.text(entry.key));
      await tester.pump();
      await tester.tap(find.text(entry.key));
      await tester.pump(const Duration(milliseconds: 250));
      expect(selectedType, entry.value);
    }

    // Likes sits at the end of the shelf; bring it into view first.
    await tester.ensureVisible(find.text('Likes'));
    await tester.pump();
    await tester.tap(find.text('Likes'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(likesTaps, 1);
  });
}

class _TestFavoritePlayersNotifier extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => const [];
}
