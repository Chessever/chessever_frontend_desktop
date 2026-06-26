import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the real production row decoration used by every desktop library
/// database table (`librarySelectedRowDecoration`) so the selected-row
/// indicator can be verified visually via a golden image — without launching
/// the app. Row 2 is selected: it must show the 3px kPrimaryColor left bar
/// plus tint; rows 1/3 must not.
void main() {
  testWidgets('library table selected row shows left accent indicator', (
    tester,
  ) async {
    Widget row(String white, String black, {required bool selected}) {
      return Container(
        decoration: librarySelectedRowDecoration(
          selected: selected,
          hovered: false,
        ),
        padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                white == 'Xu, X.'
                    ? '1'
                    : white == 'Le, Q.'
                    ? '2'
                    : '3',
                style: const TextStyle(color: kLightGreyColor, fontSize: 11),
              ),
            ),
            Expanded(
              child: Text(
                white,
                style: const TextStyle(color: kWhiteColor, fontSize: 12),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                black,
                style: const TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: kBlack2Color,
          body: Center(
            child: SizedBox(
              width: 360,
              child: Container(
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDividerColor),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    row('Xu, X.', 'Carlsen, M.', selected: false),
                    row('Le, Q.', 'Caruana, F.', selected: true),
                    row('Zhao, Y.', 'Caruana, F.', selected: false),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // The selected row paints the kPrimaryColor accent bar; assert a
    // BoxDecoration in the tree carries a left BorderSide in that color.
    final hasAccent = tester
        .widgetList<Container>(find.byType(Container))
        .any((c) {
          final decoration = c.decoration;
          if (decoration is! BoxDecoration) return false;
          final border = decoration.border;
          if (border is! Border) return false;
          return border.left.color == kPrimaryColor && border.left.width == 3;
        });
    expect(hasAccent, isTrue);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/library_selected_row_indicator.png'),
    );
  });
}
