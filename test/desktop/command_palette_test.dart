import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/command_palette.dart';

void main() {
  testWidgets('command palette scrollbar thumb is attached to its list', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CommandPalette(
              onSelectPane: (_) {},
              onAction: (_) {},
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar).first);
    final listView = tester.widget<ListView>(find.byType(ListView).first);

    expect(scrollbar.controller, isNotNull);
    expect(scrollbar.controller, same(listView.controller));
    expect(listView.primary, isFalse);
    expect(scrollbar.interactive, isTrue);
  });

  test('command palette routes local intake through PGN import only', () {
    expect(
      debugCommandPaletteEntryTitles(),
      containsAll(<String>['Open PGN on Board…', 'Import PGN in Library…']),
    );

    expect(
      debugCommandPaletteEntryTitles(),
      isNot(contains('Browse Local Chess Folder…')),
    );
    expect(
      debugCommandPaletteEntryTitles(),
      isNot(contains('Open Local Chess Files…')),
    );
    expect(
      debugCommandPaletteActionForTitle('Import PGN in Library…'),
      CommandAction.openLocalChessFiles,
    );
    expect(
      debugCommandPaletteEntryTitles(),
      isNot(contains('Open Opening Explorer')),
    );
  });
  test('command palette arrow navigation wraps one row at a time', () {
    expect(
      nextCommandPaletteHighlight(current: null, itemCount: 5, direction: 1),
      0,
    );
    expect(
      nextCommandPaletteHighlight(current: null, itemCount: 5, direction: -1),
      4,
    );
    expect(
      nextCommandPaletteHighlight(current: 0, itemCount: 5, direction: -1),
      4,
    );
    expect(
      nextCommandPaletteHighlight(current: 4, itemCount: 5, direction: 1),
      0,
    );
    expect(
      nextCommandPaletteHighlight(current: null, itemCount: 0, direction: 1),
      isNull,
    );
  });

  test('command palette page navigation jumps by a larger clamped step', () {
    expect(
      pageCommandPaletteHighlight(current: null, itemCount: 20, direction: 1),
      3,
    );
    expect(
      pageCommandPaletteHighlight(current: null, itemCount: 20, direction: -1),
      16,
    );
    expect(
      pageCommandPaletteHighlight(current: 3, itemCount: 20, direction: 1),
      7,
    );
    expect(
      pageCommandPaletteHighlight(current: 3, itemCount: 20, direction: -1),
      0,
    );
    expect(
      pageCommandPaletteHighlight(current: 18, itemCount: 20, direction: 1),
      19,
    );
    expect(
      pageCommandPaletteHighlight(current: null, itemCount: 0, direction: 1),
      isNull,
    );
  });
}
