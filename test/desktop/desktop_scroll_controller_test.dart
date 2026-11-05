import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _wheel(WidgetTester tester, Offset at, double delta) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
}

Widget _list({ScrollController? controller, Key? key}) => ListView.builder(
  key: key,
  controller: controller,
  physics: const ClampingScrollPhysics(),
  itemExtent: 40,
  itemCount: 100,
  itemBuilder: (_, index) => Text('Row $index'),
);

void main() {
  testWidgets('wheel steps interpolate, accumulate, and reverse immediately', (
    tester,
  ) async {
    final controller = DesktopScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: _list(controller: controller)));
    await _wheel(tester, const Offset(300, 200), 100);
    expect(controller.offset, 0);
    expect(controller.position.isScrollingNotifier.value, isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 8));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(100));
    await _wheel(tester, const Offset(300, 200), 100);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(200, 0.1));

    await _wheel(tester, const Offset(300, 200), 100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 24));
    final beforeReversal = controller.offset;
    await _wheel(tester, const Offset(300, 200), -100);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(beforeReversal - 100, 0.1));
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('fine pixel input and reduced motion stay direct', (
    tester,
  ) async {
    final controller = DesktopScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: _list(controller: controller)));
    await _wheel(tester, const Offset(300, 200), 3.5);
    expect(controller.offset, 3.5);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _list(controller: controller),
        ),
      ),
    );
    final before = controller.offset;
    await _wheel(tester, const Offset(300, 200), 100);
    expect(controller.offset, before + 100);
  });

  testWidgets('a jump cancels pending wheel motion and never resumes it', (
    tester,
  ) async {
    final controller = DesktopScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: _list(controller: controller)));
    await _wheel(tester, const Offset(300, 200), 100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    controller.jumpTo(500);
    await tester.pumpAndSettle();
    expect(controller.offset, 500);
    controller.position.pointerScroll(100);
    controller.position.pointerScroll(0);
    await tester.pumpAndSettle();
    expect(controller.offset, 500);
  });

  testWidgets(
    'controller-free nested views scroll independently and chain at the edge',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopScrollHost(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  SizedBox(
                    height: 250,
                    child: DesktopScrollHost(
                      child: _list(key: const ValueKey('inner')),
                    ),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        ),
      );
      final scrollables =
          tester.stateList<ScrollableState>(find.byType(Scrollable)).toList();
      expect(scrollables, hasLength(2));
      final outer = scrollables[0].position;
      final inner = scrollables[1].position;
      await _wheel(tester, const Offset(300, 120), 100);
      await tester.pumpAndSettle();
      expect(inner.pixels, closeTo(100, 0.1));
      expect(outer.pixels, 0);
      inner.jumpTo(inner.maxScrollExtent);
      await tester.pumpAndSettle();
      await _wheel(tester, const Offset(300, 120), 100);
      await tester.pumpAndSettle();
      expect(outer.pixels, closeTo(100, 0.1));
      expect(inner.pixels, inner.maxScrollExtent);
    },
  );
}
