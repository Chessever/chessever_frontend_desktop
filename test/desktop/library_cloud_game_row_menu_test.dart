import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/library/library_game_context_menu.dart';

/// Regression coverage for the cloud database game-row menu.
///
/// A local database table already exposed Game info / Copy PGN / Paste games /
/// Save To Cloud / Delete game. A cloud database table (`_DatabaseSavedGameRow`,
/// used by the database workspace and the Library-Home preview) had no row menu
/// at all, which is what the user reported. The cloud subset must keep the same
/// actions where they are semantically valid, and stay read-only for a followed
/// (subscribed) book.
void main() {
  testWidgets('writable cloud rows expose the full cloud action subset', (
    tester,
  ) async {
    LibraryGameAction? dispatched;
    var openingCount = 0;
    await _pumpRowMenu(
      tester,
      writable: true,
      onAction: (action) => dispatched = action,
      onContextMenuOpening: () => openingCount++,
    );

    await _openMenu(tester);

    expect(openingCount, 1);
    expect(find.text('Game info'), findsOneWidget);
    expect(find.text('Copy PGN'), findsOneWidget);
    expect(find.text('Paste games'), findsOneWidget);
    expect(find.text('Save To Cloud'), findsOneWidget);
    expect(find.text('Delete game'), findsOneWidget);

    await tester.tap(find.text('Game info'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(dispatched, LibraryGameAction.gameInfo);
  });

  testWidgets('read-only cloud rows keep paste and delete disabled', (
    tester,
  ) async {
    LibraryGameAction? dispatched;
    await _pumpRowMenu(
      tester,
      writable: false,
      onAction: (action) => dispatched = action,
    );

    await _openMenu(tester);

    expect(find.text('Game info'), findsOneWidget);
    expect(find.text('Copy PGN'), findsOneWidget);
    // Still listed so the constraint is visible, but inert.
    expect(find.text('Paste games'), findsOneWidget);
    expect(find.text('Save To Cloud'), findsOneWidget);
    expect(find.text('Delete game'), findsOneWidget);

    await tester.tap(find.text('Paste games'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(dispatched, isNull);

    await tester.tap(find.text('Delete game'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(dispatched, isNull);
  });

  testWidgets('copy PGN dispatches from a cloud row', (tester) async {
    LibraryGameAction? dispatched;
    await _pumpRowMenu(
      tester,
      writable: true,
      onAction: (action) => dispatched = action,
    );

    await _openMenu(tester);
    await tester.tap(find.text('Copy PGN'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(dispatched, LibraryGameAction.copyPgn);
  });

  test('menu entries mirror the local database row menu order', () {
    final writable = cloudDatabaseGameMenuEntries(writable: true);
    final labels = <String>[
      for (final entry in writable)
        if (entry is DesktopContextMenuItem<LibraryGameAction>) entry.label,
    ];
    expect(labels, <String>[
      'Game info',
      'Copy PGN',
      'Paste games',
      'Save To Cloud',
      'Delete game',
    ]);
    expect(
      writable.whereType<DesktopContextMenuDivider<LibraryGameAction>>(),
      hasLength(1),
    );

    final readOnly = cloudDatabaseGameMenuEntries(writable: false);
    for (final entry in readOnly) {
      if (entry is DesktopContextMenuItem<LibraryGameAction>) {
        final enabled = entry.enabled;
        switch (entry.value) {
          case LibraryGameAction.pasteGames:
          case LibraryGameAction.delete:
            expect(enabled, isFalse);
          default:
            expect(enabled, isTrue);
        }
      }
    }
  });
}

Future<void> _pumpRowMenu(
  WidgetTester tester, {
  required bool writable,
  required ValueChanged<LibraryGameAction> onAction,
  VoidCallback? onContextMenuOpening,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            height: 44,
            child: LibraryCloudGameRowMenu(
              writable: writable,
              onAction: onAction,
              onContextMenuOpening: onContextMenuOpening,
              child: const Center(child: Text('Cloud game row')),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.text('Cloud game row')),
    buttons: kSecondaryMouseButton,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}
