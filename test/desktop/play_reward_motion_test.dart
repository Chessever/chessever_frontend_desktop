import 'dart:io';

import 'package:fastlottie/fastlottie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/play_reward_motion.dart';

void main() {
  // FastLottie rejects anything outside its 2D subset with an exception
  // instead of drawing it wrong: every reward animation must compile, and
  // the file must be one tool/play_rewards_lottie.dart writes.
  for (final motion in PlayRewardMotion.values) {
    test('${motion.name} compiles and plays under two seconds', () {
      final file = File(motion.asset);
      expect(file.existsSync(), isTrue, reason: motion.asset);
      final composition = FastLottieComposition.fromBytes(
        file.readAsBytesSync(),
      );
      expect(composition.duration, greaterThan(Duration.zero));
      expect(
        composition.duration,
        lessThanOrEqualTo(const Duration(seconds: 2)),
      );
    });
  }

  testWidgets('a badge without a burst lays out at its own size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: PlayBadgeWithBurst(
            badgeSize: 40,
            color: Colors.white,
            child: ColoredBox(color: Colors.red),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(PlayBadgeWithBurst)), const Size(40, 40));
    expect(find.byType(PlayRewardBurst), findsNothing);
  });

  testWidgets('a burst spills into the overlay, not the layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: PlayBadgeWithBurst(
            badgeSize: 40,
            color: Colors.white,
            playKey: 1,
            child: ColoredBox(color: Colors.red),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(PlayBadgeWithBurst)), const Size(40, 40));
    final burst = find.byType(PlayRewardBurst);
    expect(burst, findsOneWidget);
    expect(tester.getSize(burst), const Size(80, 80));
    expect(
      tester.getCenter(burst),
      tester.getCenter(find.byType(PlayBadgeWithBurst)),
    );
  });

  testWidgets('a burst asked for after the first frame plays without '
      'touching the overlay during build', (tester) async {
    Widget badge(Object? key) => MaterialApp(
      home: Center(
        child: PlayBadgeWithBurst(
          badgeSize: 40,
          color: Colors.white,
          playKey: key,
          child: const ColoredBox(color: Colors.red),
        ),
      ),
    );
    await tester.pumpWidget(badge(null));
    expect(find.byType(PlayRewardBurst), findsNothing);
    await tester.pumpWidget(badge(1));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(PlayRewardBurst), findsOneWidget);
  });
}
