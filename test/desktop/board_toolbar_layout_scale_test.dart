import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

Widget _harness(double width) => ProviderScope(
  child: MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        key: const ValueKey('footer'),
        width: width,
        child: boardToolbarForTesting(
          canGoBack: true,
          canGoForward: true,
          onFirst: () {},
          onPrevious: () {},
          onNext: () {},
          onLast: () {},
          onPlayPause: () {},
          onPreviousGame: () {},
          onNextGame: () {},
          leadingActions: const SizedBox.square(
            dimension: 40,
            child: Icon(Icons.favorite_border_rounded),
          ),
          secondaryActions: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 40,
                child: Icon(Icons.flip_camera_android_rounded),
              ),
              SizedBox(width: 4),
              SizedBox.square(dimension: 40, child: Icon(Icons.share_rounded)),
            ],
          ),
          trailingActions: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 40,
                child: Icon(Icons.bookmark_outline),
              ),
              SizedBox(width: 4),
              SizedBox.square(
                dimension: 40,
                child: Icon(Icons.sports_esports_outlined),
              ),
              SizedBox(width: 4),
              SizedBox.square(
                dimension: 40,
                child: Icon(Icons.info_outline_rounded),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'Like anchors the far left and optional shortcuts share the second row',
    (tester) async {
      await tester.pumpWidget(_harness(700));
      final like = tester.getRect(find.byIcon(Icons.favorite_border_rounded));
      final explorer = tester.getRect(find.byIcon(Icons.menu_book_outlined));
      final report = tester.getRect(find.byIcon(Icons.analytics_outlined));
      final previousGame = tester.getRect(
        find.byIcon(Icons.keyboard_double_arrow_left_rounded),
      );
      final flip = tester.getRect(
        find.byIcon(Icons.flip_camera_android_rounded),
      );
      final share = tester.getRect(find.byIcon(Icons.share_rounded));
      final save = tester.getRect(find.byIcon(Icons.bookmark_outline));
      final info = tester.getRect(find.byIcon(Icons.info_outline_rounded));
      expect(like.left, lessThan(explorer.left));
      expect(explorer.left, lessThan(report.left));
      expect(report.right, lessThan(previousGame.left));
      expect(previousGame.right, lessThan(flip.left));
      expect(flip.left, lessThan(share.left));
      expect(share.left, lessThan(save.left));
      expect(save.left, lessThan(info.left));
      for (final rect in [
        explorer,
        report,
        previousGame,
        flip,
        share,
        save,
        info,
      ]) {
        expect(rect.center.dy, closeTo(like.center.dy, 0.1));
      }
      expect(tester.getSize(find.byKey(const ValueKey('footer'))).height, 107);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'narrow rails omit secondary shortcuts before adding unnecessary rows',
    (tester) async {
      for (final width in [700.0, 480.0, 400.0, 320.0, 240.0, 220.0, 700.0]) {
        await tester.pumpWidget(_harness(width));
        final roomy = width >= 520;
        expect(
          find.byIcon(Icons.share_rounded),
          roomy ? findsOneWidget : findsNothing,
        );
        expect(
          find.byIcon(Icons.flip_camera_android_rounded),
          roomy ? findsOneWidget : findsNothing,
        );
        for (final icon in [
          Icons.favorite_border_rounded,
          Icons.menu_book_outlined,
          Icons.analytics_outlined,
          Icons.keyboard_double_arrow_left_rounded,
          Icons.keyboard_double_arrow_right_rounded,
          Icons.bookmark_outline,
          Icons.sports_esports_outlined,
          Icons.info_outline_rounded,
        ]) {
          final rect = tester.getRect(find.byIcon(icon));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        if (width >= 400) {
          expect(
            tester.getSize(find.byKey(const ValueKey('footer'))).height,
            107,
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
