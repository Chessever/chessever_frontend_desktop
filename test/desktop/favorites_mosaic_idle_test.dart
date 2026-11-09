import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_player.dart';
import 'package:chessever/screens/group_event/widget/premium_collection_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Favorites extends FavoritePlayersNotifierNew {
  @override
  Future<List<FavoritePlayer>> build() async => [
    for (var i = 0; i < 3; i++)
      FavoritePlayer(
        id: '$i',
        userId: 'u',
        playerName: 'Player $i',
        metadata: const {},
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
  ];
}

Widget _host(bool animate) => ProviderScope(
  overrides: [favoritePlayersProviderNew.overrideWith(_Favorites.new)],
  child: MaterialApp(
    home: Center(
      child: SizedBox(
        width: 220,
        height: 120,
        child: FavoritePlayersGridBackground(animate: animate),
      ),
    ),
  ),
);

void main() {
  // The drift redraws the whole window each frame on web and Impeller; the
  // desktop For You strip must be able to hold it still.
  testWidgets('a paused mosaic schedules no frames', (tester) async {
    await tester.pumpWidget(_host(false));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the mosaic drifts while animate is true and stops after', (
    tester,
  ) async {
    await tester.pumpWidget(_host(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isTrue);

    await tester.pumpWidget(_host(false));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
