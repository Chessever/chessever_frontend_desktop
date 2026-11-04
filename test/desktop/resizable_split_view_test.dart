import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/resizable_split_view.dart';

void main() {
  testWidgets('collapsed rail restore invokes child restore hook', (
    tester,
  ) async {
    final controller = ResizableSplitViewController();
    var restoreCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 104,
            height: 240,
            child: ResizableSplitView(
              axis: Axis.horizontal,
              controller: controller,
              children: [
                const SplitChild(
                  label: 'Notation',
                  child: SizedBox(key: Key('notation')),
                ),
                SplitChild(
                  label: 'Engine',
                  collapsedIcon: Icons.memory_rounded,
                  onRestore: () => restoreCount++,
                  child: const SizedBox(key: Key('engine')),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    controller.collapse(1);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('engine')), findsNothing);

    await tester.tap(find.byIcon(Icons.memory_rounded));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(restoreCount, 1);
    expect(find.byKey(const Key('engine')), findsOneWidget);
  });

  testWidgets('collapsed sibling lets remaining pane exceed max size', (
    tester,
  ) async {
    final controller = ResizableSplitViewController();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 500,
              height: 400,
              child: ResizableSplitView(
                axis: Axis.vertical,
                controller: controller,
                collapsedRailThickness: 32,
                children: const [
                  SplitChild(
                    minSize: 120,
                    maxSize: 180,
                    label: 'Databases',
                    child: SizedBox(key: ValueKey<String>('databases')),
                  ),
                  SplitChild(
                    minSize: 120,
                    label: 'Preview',
                    child: SizedBox(key: ValueKey<String>('preview')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const ValueKey('databases'))).height, 180);

    controller.collapse(1, persist: false);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('preview')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('databases'))).height,
      closeTo(360, 1),
    );
  });

  testWidgets('controller setSize expands one pane and compacts siblings', (
    tester,
  ) async {
    final controller = ResizableSplitViewController();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 600,
              height: 100,
              child: ResizableSplitView(
                axis: Axis.horizontal,
                controller: controller,
                children: const [
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('left')),
                  ),
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('center')),
                  ),
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('right')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final initialCenter = tester.getSize(find.byKey(const ValueKey('center')));
    final initialRight = tester.getSize(find.byKey(const ValueKey('right')));

    final applied = controller.setSize(1, 320, persist: false);
    await tester.pump();

    final center = tester.getSize(find.byKey(const ValueKey('center')));
    final right = tester.getSize(find.byKey(const ValueKey('right')));

    expect(center.width, greaterThan(initialCenter.width));
    expect(applied, closeTo(320, 1));
    expect(center.width, closeTo(320, 1));
    expect(right.width, lessThan(initialRight.width));
  });

  testWidgets('controller setSize reports capped size when siblings block', (
    tester,
  ) async {
    final controller = ResizableSplitViewController();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 600,
              height: 100,
              child: ResizableSplitView(
                axis: Axis.horizontal,
                controller: controller,
                children: const [
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('left')),
                  ),
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('center')),
                  ),
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('right')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final applied = controller.setSize(1, 500, persist: false);
    await tester.pump();

    final center = tester.getSize(find.byKey(const ValueKey('center')));

    expect(applied, closeTo(384, 1));
    expect(center.width, closeTo(384, 1));
  });

  testWidgets('controller setFraction sizes pane by available split area', (
    tester,
  ) async {
    final controller = ResizableSplitViewController();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 600,
              height: 100,
              child: ResizableSplitView(
                axis: Axis.horizontal,
                controller: controller,
                children: const [
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('board')),
                  ),
                  SplitChild(
                    minSize: 100,
                    child: SizedBox(key: ValueKey<String>('right-pane')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    controller.setFraction(0, 0.60, persist: false);
    await tester.pump();

    final board = tester.getSize(find.byKey(const ValueKey('board')));
    final rightPane = tester.getSize(find.byKey(const ValueKey('right-pane')));

    expect(board.width, closeTo(355.2, 1));
    expect(rightPane.width, closeTo(236.8, 1));
  });

  testWidgets(
    'removing a leading child does not carry over collapse to siblings',
    (tester) async {
      final controller = ResizableSplitViewController();
      var showLeader = true;
      StateSetter? setHarnessState;

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 800,
              height: 200,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setHarnessState = setState;
                  return ResizableSplitView(
                    axis: Axis.horizontal,
                    controller: controller,
                    children: [
                      if (showLeader)
                        const SplitChild(
                          minSize: 120,
                          label: 'Games',
                          collapsedIcon: Icons.view_list_rounded,
                          dismissible: true,
                          child: SizedBox(key: ValueKey<String>('games')),
                        ),
                      const SplitChild(
                        minSize: 240,
                        label: 'Board',
                        dismissible: false,
                        child: SizedBox(key: ValueKey<String>('board')),
                      ),
                      const SplitChild(
                        minSize: 200,
                        label: 'Analysis',
                        child: SizedBox(key: ValueKey<String>('analysis')),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      controller.collapse(0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('games')), findsNothing);

      setHarnessState!(() => showLeader = false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('board')), findsOneWidget);
      expect(find.byKey(const ValueKey('analysis')), findsOneWidget);
      expect(controller.isCollapsed(0), isFalse);
      expect(
        tester.getSize(find.byKey(const ValueKey('board'))).width,
        greaterThan(0),
      );
    },
  );

  group('comfortable size', () {
    // Two 8 px gutters leave exactly 1000 px for the panes. Weights alone
    // give Games 300, Board 400, Analysis 300.
    Widget harness({
      required double width,
      double analysisComfortable = 400,
      ResizableSplitViewController? controller,
      bool reduceMotion = false,
    }) {
      return MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 200,
                child: ResizableSplitView(
                  axis: Axis.horizontal,
                  controller: controller,
                  children: [
                    const SplitChild(
                      minSize: 200,
                      initialWeight: 0.3,
                      label: 'Games',
                      child: SizedBox(key: ValueKey<String>('games')),
                    ),
                    const SplitChild(
                      minSize: 300,
                      initialWeight: 0.4,
                      label: 'Board',
                      dismissible: false,
                      spareAbove: 350,
                      child: SizedBox(key: ValueKey<String>('board')),
                    ),
                    SplitChild(
                      minSize: 150,
                      initialWeight: 0.3,
                      label: 'Analysis',
                      comfortableSize: analysisComfortable,
                      child: const SizedBox(key: ValueKey<String>('analysis')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    double widthOf(WidgetTester tester, String key) =>
        tester.getSize(find.byKey(ValueKey<String>(key))).width;

    // The default 800 px test surface would clamp the harness.
    void useWideSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('borrows dead space first, then room above minimums', (
      tester,
    ) async {
      useWideSurface(tester);
      await tester.pumpWidget(harness(width: 1016));

      // Board lends only its 50 px past spareAbove; Games covers the rest.
      expect(widthOf(tester, 'analysis'), closeTo(400, 0.01));
      expect(widthOf(tester, 'board'), closeTo(350, 0.01));
      expect(widthOf(tester, 'games'), closeTo(250, 0.01));
    });

    testWidgets('grows only as far as siblings can spare', (tester) async {
      useWideSurface(tester);
      await tester.pumpWidget(harness(width: 1016, analysisComfortable: 600));

      expect(widthOf(tester, 'board'), closeTo(350, 0.01));
      expect(widthOf(tester, 'games'), closeTo(200, 0.01));
      expect(widthOf(tester, 'analysis'), closeTo(450, 0.01));
    });

    testWidgets('a gutter drag holds until the window changes size', (
      tester,
    ) async {
      useWideSurface(tester);
      await tester.pumpWidget(harness(width: 1016));
      expect(widthOf(tester, 'analysis'), closeTo(400, 0.01));

      // Gutter between Board and Analysis: Games 250 + gutter 8 + Board 350.
      final gutter = tester.getTopLeft(find.byKey(const ValueKey('board')));
      await tester.timedDragFrom(
        Offset(gutter.dx + 350 + 4, 100),
        const Offset(60, 0),
        const Duration(milliseconds: 200),
      );
      await tester.pumpAndSettle();

      // The user's narrower Analysis stays, and Games is left alone instead
      // of being drained to refill it.
      expect(widthOf(tester, 'analysis'), lessThan(400));
      expect(widthOf(tester, 'games'), closeTo(250, 0.01));

      await tester.pumpWidget(harness(width: 1116));
      await tester.pumpAndSettle();

      expect(widthOf(tester, 'analysis'), greaterThanOrEqualTo(399.5));
    });

    testWidgets('setSize keeps the size it was asked for', (tester) async {
      useWideSurface(tester);
      final controller = ResizableSplitViewController();
      await tester.pumpWidget(harness(width: 1016, controller: controller));

      controller.setSize(1, 420, persist: false);
      await tester.pump();

      expect(widthOf(tester, 'board'), closeTo(420, 0.01));
      expect(widthOf(tester, 'analysis'), closeTo(330, 0.01));
    });

    testWidgets('new toolbar space applies immediately with reduced motion', (
      tester,
    ) async {
      useWideSurface(tester);
      await tester.pumpWidget(harness(width: 1016, reduceMotion: true));
      await tester.pumpWidget(
        harness(width: 1016, analysisComfortable: 450, reduceMotion: true),
      );
      expect(widthOf(tester, 'analysis'), closeTo(450, 0.01));
      await tester.pumpAndSettle();
    });
  });
}
