import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_adaptive_toolbar.dart';

void main() {
  Widget harness(
    double width, {
    ValueChanged<double>? onWidth,
    VoidCallback? onTap,
  }) => MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: DesktopAdaptiveToolbar(
          key: const ValueKey('toolbar'),
          onFullWidthChanged: onWidth,
          leading: const SizedBox(
            key: ValueKey('leading'),
            width: 78,
            height: 36,
          ),
          navigation: Wrap(
            spacing: 4,
            runSpacing: 8,
            children: List.generate(
              6,
              (i) => GestureDetector(
                key: ValueKey('nav-$i'),
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: const SizedBox(width: 36, height: 36),
              ),
            ),
          ),
          trailing: const SizedBox(
            key: ValueKey('trailing'),
            width: 156,
            height: 36,
          ),
        ),
      ),
    ),
  );

  testWidgets('all controls fit and remain clickable across wrapping widths', (
    tester,
  ) async {
    var taps = 0;
    double? fullWidth;
    for (final width in [760.0, 486.0, 485.5, 320.0, 280.0, 220.0, 760.0]) {
      await tester.pumpWidget(
        harness(
          width,
          onWidth: (value) => fullWidth = value,
          onTap: () => taps++,
        ),
      );
      final bounds = tester.getRect(find.byKey(const ValueKey('toolbar')));
      expect(fullWidth, 486);
      expect(
        bounds.height,
        width >= 486
            ? 36
            : width >= 244
            ? 80
            : 168,
      );
      for (final key in [
        'leading',
        'trailing',
        for (var i = 0; i < 6; i++) 'nav-$i',
      ]) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.left, greaterThanOrEqualTo(bounds.left));
        expect(rect.right, lessThanOrEqualTo(bounds.right));
        expect(rect.top, greaterThanOrEqualTo(bounds.top));
        expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
      }
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(ValueKey('nav-$i')));
      }
      expect(tester.takeException(), isNull);
    }
    expect(taps, 42);
  });

  testWidgets('reports changed action widths and ignores a disposed toolbar', (
    tester,
  ) async {
    final widths = <double>[];
    Widget toolbar(double trailingWidth) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 280,
          child: DesktopAdaptiveToolbar(
            onFullWidthChanged: widths.add,
            leading: const SizedBox(width: 78, height: 36),
            trailing: SizedBox(width: trailingWidth, height: 36),
          ),
        ),
      ),
    );
    await tester.pumpWidget(toolbar(156));
    await tester.pumpWidget(toolbar(196));
    expect(widths, [242, 282]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
