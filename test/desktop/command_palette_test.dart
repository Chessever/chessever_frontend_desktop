import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/command_palette.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';

void main() {
  testWidgets(
    'hidden Rankings route still activates from the command palette',
    (tester) async {
      DesktopPane? opened;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: CommandPalette(
                onSelectPane: (pane) => opened = pane,
                onAction: (_) {},
                onDismiss: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final rankings = find.text('Open Rankings');
      await tester.ensureVisible(rankings);
      await tester.pump();
      await tester.tap(rankings);
      await tester.pump();
      expect(opened, DesktopPane.rankings);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

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

  test(
    'command palette retains hidden destinations without number shortcuts',
    () {
      for (final title in [
        'Open Countrymen',
        'Open Favorites',
        'Open Collections',
        'Open Rankings',
      ]) {
        expect(debugCommandPaletteEntryTitles(), contains(title));
        expect(
          debugCommandPaletteShortcutForTitle(title, isMacOS: false),
          isNull,
        );
        expect(
          debugCommandPaletteShortcutForTitle(title, isMacOS: true),
          isNull,
        );
      }
      const expected = {
        'Open Home': 1,
        'Open Library': 2,
        'Open Prepare': 3,

        'Open Board': 4,
        'Open Play': 5,
      };
      for (final entry in expected.entries) {
        expect(
          debugCommandPaletteShortcutForTitle(entry.key, isMacOS: false),
          'Ctrl+${entry.value}',
        );
        expect(
          debugCommandPaletteShortcutForTitle(entry.key, isMacOS: true),
          '⌘${entry.value}',
        );
      }
      expect(
        debugCommandPaletteShortcutForTitle(
          'Open Board Editor',
          isMacOS: false,
        ),
        isNull,
      );
    },
  );

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
