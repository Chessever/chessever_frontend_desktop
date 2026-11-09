import 'package:chessever/desktop/widgets/desktop_spinner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

RenderPaintDrivenSpinner _spinner(WidgetTester tester) =>
    tester.renderObject<RenderPaintDrivenSpinner>(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_PaintDrivenSpinner',
        skipOffstage: false,
      ),
    );

void main() {
  testWidgets('a painted spinner keeps the next frame booked', (tester) async {
    await tester.pumpWidget(
      _host(
        const Center(
          child: SizedBox.square(dimension: 16, child: DesktopSpinner()),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isTrue);
      expect(_spinner(tester).isAnimating, isTrue);
    }
    expect(tester.getSize(find.byType(DesktopSpinner)), const Size(16, 16));
  });

  testWidgets('an offstage spinner schedules no frames, and resumes on show', (
    tester,
  ) async {
    Widget build({required bool offstage}) => _host(
      Offstage(
        offstage: offstage,
        child: const Center(child: DesktopSpinner()),
      ),
    );

    await tester.pumpWidget(build(offstage: true));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(_spinner(tester).isAnimating, isFalse);

    await tester.pumpWidget(build(offstage: false));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_spinner(tester).isAnimating, isTrue);
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets(
    'a load-more spinner in the cache extent below the viewport stops',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          SizedBox(
            height: 300,
            child: ListView.builder(
              controller: controller,
              // The default cache extent (250 px) reaches the footer.
              itemCount: 11,
              itemBuilder:
                  (context, i) =>
                      i < 10
                          ? const SizedBox(height: 40)
                          : const SizedBox(
                            height: 40,
                            child: Center(child: DesktopSpinner()),
                          ),
            ),
          ),
        ),
      );
      // Built (it is in the cache extent), but outside the viewport.
      expect(
        find.byType(DesktopSpinner, skipOffstage: false),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isFalse);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_spinner(tester).isAnimating, isTrue);
      expect(tester.binding.hasScheduledFrame, isTrue);

      controller.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('a determinate spinner is a plain CircularProgressIndicator', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const DesktopSpinner(value: 0.4)));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
