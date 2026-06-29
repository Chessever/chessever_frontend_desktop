import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the production `selected` expression used by the library database
/// tables beside the board (`_DatabaseSavedGamesTable` /
/// `_TwicGamesTable` itemBuilders in library_pane.dart):
///
///   (selectedIds?.contains(id) ?? false) || id == selectedId
///
/// The previous form `selectedIds?.contains(id) ?? id == selectedId` was bugged:
/// `selectedIds` is always a non-null (often empty) set, so `{}.contains(id)`
/// returned `false` and the `??` never fell through to the single `selectedId`
/// — meaning a single-clicked row was never marked selected.
bool rowSelected({
  required String id,
  required Set<String> selectedIds,
  required String? selectedId,
}) {
  return (selectedIds.contains(id)) || id == selectedId;
}

void main() {
  test('single-select (empty selectedIds + selectedId) marks exactly one row', () {
    const ids = ['r1', 'r2', 'r3'];
    const selectedId = 'r2';
    final selectedIds = <String>{}; // single-select clears the multi-set

    final selected = [
      for (final id in ids)
        rowSelected(id: id, selectedIds: selectedIds, selectedId: selectedId),
    ];
    expect(selected, [false, true, false]);

    // Faithful replay of the OLD bugged precedence: a non-null empty set makes
    // `?? selectedId` unreachable, so every row resolves false (no highlight).
    List<bool> oldPrecedence(Set<String>? ids2) =>
        [for (final id in ids) ids2?.contains(id) ?? (id == selectedId)];
    expect(oldPrecedence(selectedIds), [false, false, false]);
  });

  testWidgets('selected library row renders the kPrimaryColor accent + tint', (
    tester,
  ) async {
    const ids = ['r1', 'r2', 'r3'];
    const labels = {
      'r1': ('Xu, X.', 'Carlsen, M.'),
      'r2': ('Le, Q.', 'Caruana, F.'),
      'r3': ('Zhao, Y.', 'Caruana, F.'),
    };
    const selectedId = 'r2';
    final selectedIds = <String>{};

    Widget row(String id) {
      final selected =
          rowSelected(id: id, selectedIds: selectedIds, selectedId: selectedId);
      final (white, black) = labels[id]!;
      return Container(
        // The real production decoration.
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
                '${ids.indexOf(id) + 1}',
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
                  children: [for (final id in ids) row(id)],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Exactly one row paints the kPrimaryColor left accent bar.
    final accentRows = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) {
          final decoration = c.decoration;
          if (decoration is! BoxDecoration) return false;
          final border = decoration.border;
          if (border is! Border) return false;
          return border.left.color == kPrimaryColor && border.left.width == 3;
        });
    expect(accentRows.length, 1);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/library_selected_row_indicator.png'),
    );
  });
}
