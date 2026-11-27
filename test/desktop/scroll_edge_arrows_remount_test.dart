import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/play_help_modules_panel.dart';
import 'package:chessever/desktop/widgets/play_setup_layout.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';

/// Counts how often its State is created.
class _Probe extends StatefulWidget {
  const _Probe({required this.height, required this.inits});

  final double height;
  final List<int> inits;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.inits.add(1);
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: widget.height, child: const Text('probe'));
}

Finder get _down => find.byIcon(Icons.keyboard_arrow_down_rounded);

void main() {
  testWidgets('the fade mask turning on keeps the scrolled state', (
    tester,
  ) async {
    final inits = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 400,
            child: ScrollEdgeArrows(
              child: SingleChildScrollView(
                child: _Probe(height: 2000, inits: inits),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_down, findsOneWidget);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(inits, hasLength(1));
  });

  testWidgets('content crossing the viewport height keeps child state', (
    tester,
  ) async {
    final inits = <int>[];
    final height = ValueNotifier<double>(100);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: ScrollEdgeArrows(
              child: SingleChildScrollView(
                child: ValueListenableBuilder<double>(
                  valueListenable: height,
                  builder: (_, h, _) => _Probe(height: h, inits: inits),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_down, findsNothing);

    height.value = 900;
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(_down, findsOneWidget);

    height.value = 100;
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(_down, findsNothing);
    expect(inits, hasLength(1));
  });

  testWidgets('a growing setup column refits in the same frame', (
    tester,
  ) async {
    final inits = <int>[];
    final height = ValueNotifier<double>(100);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 600,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: PlaySetupColumnScroll(
                    child: ValueListenableBuilder<double>(
                      valueListenable: height,
                      builder: (_, h, _) => _Probe(height: h, inits: inits),
                    ),
                  ),
                ),
                const SizedBox(key: ValueKey('bar'), height: 60),
              ],
            ),
          ),
        ),
      ),
    );
    double barTop() =>
        tester.getTopLeft(find.byKey(const ValueKey('bar'))).dy -
        tester.getTopLeft(find.byType(PlaySetupColumnScroll)).dy;

    expect(barTop(), 100);
    expect(tester.getSize(find.byType(PlaySetupColumnScroll)).width, 400);

    height.value = 300;
    await tester.pump();
    expect(barTop(), 300);
    await tester.pump();
    expect(_down, findsNothing);

    height.value = 50;
    await tester.pump();
    expect(barTop(), 50);
    await tester.pump();
    expect(inits, hasLength(1));
  });

  testWidgets('a shrinking scroller is its content height on frame one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: Container()),
                const PlayShrinkingScroller(
                  maxHeight: 360,
                  child: SizedBox(height: 100),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // No overflow on the first frame, already at the content height.
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(PlayShrinkingScroller)).height, 100);
    expect(tester.getSize(find.byType(PlayShrinkingScroller)).width, 300);
  });

  testWidgets('a shrinking scroller caps at maxHeight and scrolls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 800,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PlayShrinkingScroller(
                  maxHeight: 360,
                  child: SizedBox(height: 1000),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(PlayShrinkingScroller)).height, 360);
    await tester.pump();
    expect(_down, findsOneWidget);
  });
}
