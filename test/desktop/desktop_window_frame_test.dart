import 'package:chessever/desktop/widgets/desktop_window_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'caption controls use filled font glyphs for Windows DPI safety',
    (tester) async {
      const expected = <DesktopCaptionGlyphType, IconData>{
        DesktopCaptionGlyphType.minimize: Icons.remove_rounded,
        DesktopCaptionGlyphType.maximize: Icons.crop_square_rounded,
        DesktopCaptionGlyphType.restore: Icons.filter_none_rounded,
        DesktopCaptionGlyphType.close: Icons.close_rounded,
      };

      for (final entry in expected.entries) {
        await tester.pumpWidget(
          MaterialApp(home: DesktopCaptionGlyph(entry.key)),
        );

        expect(find.byIcon(entry.value), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(DesktopCaptionGlyph),
            matching: find.byType(CustomPaint),
          ),
          findsNothing,
        );
      }
    },
  );
}
