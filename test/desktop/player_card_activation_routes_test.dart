import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/player_hover_preview.dart';

void main() {
  for (final target in <String>[
    'player-hover-header-name',
    'player-hover-header-avatar',
    'game-result-event-game',
  ]) {
    testWidgets('compact card $target keeps report/profile/game routes distinct',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      await tester.pumpWidget(ProviderScope(child: MaterialApp(
        home: Scaffold(body: Center(child: PlayerHoverPreview(
          player: const PlayerHoverPreviewIdentity(name: 'Player', fideId: 101),
          games: [TournamentGameSummary(
            id: 'event-game', name: 'Game', whitePlayer: 'Player',
            blackPlayer: 'Opponent', whiteFideId: 101, hasPgn: true,
          )],
          onOpenScoreCard: () => calls.add('report'),
          onOpenPlayerInNewTab: (_) => calls.add('profile'),
          onOpenOpponentInNewTab: (_) => calls.add('opponent'),
          onOpenGameInNewTab: (game) => calls.add(game.id),
        ))),
      )));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(tester.getCenter(
        find.byKey(const ValueKey('player-hover-preview-trigger')),
      )));
      await tester.pump(playerHoverIntentDelay);
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('Open event games'), findsNothing);
      expect(find.text('Open player profile'), findsNothing);
      expect(find.byKey(const ValueKey('player-hover-open-profile')), findsNothing);
      await tester.tap(find.text('Games'));
      await tester.pump();
      expect(calls, isEmpty);
      await tester.tap(find.byKey(ValueKey(target)));
      await tester.pump();
      expect(calls, [switch (target) {
        'player-hover-header-name' || 'player-hover-header-avatar' => 'report',
        'game-result-event-game' => 'event-game',
        _ => throw StateError('Unexpected activation target'),
      }]);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
