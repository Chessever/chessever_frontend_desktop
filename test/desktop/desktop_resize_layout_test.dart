import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/desktop/shell/desktop_sidebar_layout.dart';
import 'package:chessever/desktop/widgets/desktop_width_breakpoint.dart';

class _CountingBox extends StatelessWidget {
  const _CountingBox({required this.onBuild});

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox.expand();
  }
}

class _CountingLayout extends SingleChildRenderObjectWidget {
  const _CountingLayout({required this.onLayout, super.child});

  final ValueChanged<double> onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCountingLayout(onLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCountingLayout renderObject,
  ) => renderObject.onLayout = onLayout;
}

class _RenderCountingLayout extends RenderProxyBox {
  _RenderCountingLayout(this.onLayout);

  ValueChanged<double> onLayout;

  @override
  void performLayout() {
    onLayout(constraints.maxWidth);
    super.performLayout();
  }
}

void main() {
  testWidgets('breakpoint scope skips rebuilds until the side flips', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(2000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var childBuilds = 0;
    var readerBuilds = 0;
    bool? below;
    final width = ValueNotifier<double>(1600);
    final child = Column(
      children: [
        Expanded(child: _CountingBox(onBuild: () => childBuilds++)),
        Builder(
          builder: (context) {
            readerBuilds++;
            below = DesktopWidthBreakpoint.isBelow(context);
            return const SizedBox(height: 1);
          },
        ),
      ],
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder<double>(
          valueListenable: width,
          builder:
              (_, value, built) => Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: value, height: 400, child: built),
              ),
          child: DesktopWidthBreakpoint(breakpoint: 1500, child: child),
        ),
      ),
    );
    expect(below, isFalse);
    final initialChildBuilds = childBuilds;
    final initialReaderBuilds = readerBuilds;

    for (final next in [1580.0, 1560.0, 1520.0, 1501.0]) {
      width.value = next;
      await tester.pump();
    }
    expect(childBuilds, initialChildBuilds);
    expect(readerBuilds, initialReaderBuilds);

    width.value = 1499;
    await tester.pump();
    expect(below, isTrue);
    expect(readerBuilds, initialReaderBuilds + 1);
    expect(childBuilds, initialChildBuilds);
  });

  testWidgets('sidebar toggles re-lay out the content once', (tester) async {
    final layoutWidths = <double>[];
    final expanded = ValueNotifier(true);
    final focus = ValueNotifier(false);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: focus,
          builder:
              (_, focused, _) => ValueListenableBuilder<bool>(
                valueListenable: expanded,
                builder:
                    (_, isExpanded, _) => DesktopSidebarLayout(
                      showSidebar: !focused,
                      expanded: isExpanded,
                      sidebar: AnimatedContainer(
                        duration: DesktopSidebar.animationDuration,
                        width:
                            isExpanded
                                ? DesktopSidebar.expandedWidth
                                : DesktopSidebar.collapsedWidth,
                        color: Colors.black,
                      ),
                      content: _CountingLayout(
                        onLayout: layoutWidths.add,
                        child: const SizedBox.expand(),
                      ),
                    ),
              ),
        ),
      ),
    );
    final window =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(layoutWidths.last, window - DesktopSidebar.expandedWidth);

    // Collapse: the content takes its final width at once, then stays put
    // while the sidebar shrinks over it.
    layoutWidths.clear();
    expanded.value = false;
    await tester.pumpAndSettle();
    expect(layoutWidths, [window - DesktopSidebar.collapsedWidth]);

    // Expand: the sidebar grows over the content, which narrows once at the
    // end of the animation.
    layoutWidths.clear();
    expanded.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(layoutWidths, isEmpty);
    await tester.pumpAndSettle();
    expect(layoutWidths, [window - DesktopSidebar.expandedWidth]);

    // Expanding then collapsing again before the animation ends never narrows
    // the content.
    expanded.value = false;
    await tester.pumpAndSettle();
    layoutWidths.clear();
    expanded.value = true;
    await tester.pump(const Duration(milliseconds: 60));
    expanded.value = false;
    await tester.pumpAndSettle();
    expect(layoutWidths, isEmpty);

    // Focus mode hides the sidebar and gives the content the full width.
    focus.value = true;
    await tester.pumpAndSettle();
    expect(layoutWidths.last, window);
    focus.value = false;
    await tester.pumpAndSettle();
    expect(layoutWidths.last, window - DesktopSidebar.collapsedWidth);
  });
}
