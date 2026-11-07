import 'package:chessever/desktop/panes/board_pane.dart'
    show
        boardSecondaryToolbarActionsForTesting,
        boardGameToolbarActionsForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:forui/forui.dart';

void main() {
  testWidgets(
    'real Flip and Share actions retain forty-pixel targets and callbacks',
    (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Center(
              child: boardSecondaryToolbarActionsForTesting(
                onFlipBoard: () => calls.add('flip'),
                onShareGame: () => calls.add('share'),
              ),
            ),
          ),
        ),
      );
      for (final icon in [
        Icons.flip_camera_android_rounded,
        Icons.share_rounded,
      ]) {
        final target =
            find
                .ancestor(of: find.byIcon(icon), matching: find.byType(FButton))
                .first;
        expect(tester.getSize(target), const Size(40, 40));
        expect(tester.widget<Icon>(find.byIcon(icon)).size, 21);
        await tester.tapAt(tester.getTopLeft(target) + const Offset(2, 2));
        await tester.pump();
      }
      expect(calls, ['flip', 'share']);
      Focus.of(tester.element(find.byIcon(Icons.share_rounded))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, ['flip', 'share', 'share']);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'game utilities stay reachable at forty pixels including Play again',
    (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Center(
              child: boardGameToolbarActionsForTesting(
                onSaveGame: () => calls.add('save'),
                onPlayFromHere: () => calls.add('play-from-here'),
                onPlayAgain: () => calls.add('play-again'),
              ),
            ),
          ),
        ),
      );
      for (final icon in [
        FIcons.bookmarkPlus,
        Icons.sports_esports_outlined,
        Icons.replay_rounded,
      ]) {
        final target =
            find
                .ancestor(of: find.byIcon(icon), matching: find.byType(FButton))
                .first;
        expect(tester.getSize(target), const Size(40, 40));
        await tester.tap(target);
        await tester.pump();
      }
      expect(calls, ['save', 'play-from-here', 'play-again']);
      expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
      expect(find.byIcon(Icons.favorite_rounded), findsNothing);
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
