import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/library/library_game_context_menu.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  testWidgets(
    'writable cloud-game menus expose selection and clipboard import actions',
    (tester) async {
      LibraryGameAction? dispatched;
      var openingCount = 0;
      await _pumpMenu(
        tester,
        canDelete: true,
        canPaste: true,
        onAction: (action) => dispatched = action,
        onContextMenuOpening: () => openingCount++,
      );

      await _openMenu(tester);

      expect(openingCount, 1);
      expect(find.text('Copy PGN'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
      expect(find.text('Paste games'), findsOneWidget);
      expect(find.text('Delete game'), findsOneWidget);

      await tester.tap(find.text('Select all'));
      await tester.pump(const Duration(milliseconds: 120));

      expect(dispatched, LibraryGameAction.selectAll);
    },
  );

  testWidgets('read-only cloud-game menus cannot paste or delete', (
    tester,
  ) async {
    LibraryGameAction? dispatched;
    await _pumpMenu(
      tester,
      canDelete: false,
      canPaste: false,
      onAction: (action) => dispatched = action,
    );

    await _openMenu(tester);

    expect(find.text('Copy PGN'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('Paste games'), findsNothing);
    expect(find.text('Delete game'), findsOneWidget);

    await tester.tap(find.text('Delete game'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(dispatched, isNull);
  });
}

Future<void> _pumpMenu(
  WidgetTester tester, {
  required bool canDelete,
  required bool canPaste,
  required ValueChanged<LibraryGameAction> onAction,
  VoidCallback? onContextMenuOpening,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            height: 48,
            child: LibraryGameContextMenu(
              analysis: _analysis(),
              canDelete: canDelete,
              canPaste: canPaste,
              onAction: onAction,
              onContextMenuOpening: onContextMenuOpening,
              child: const Center(child: Text('Game row')),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.text('Game row')),
    buttons: kSecondaryMouseButton,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

SavedAnalysis _analysis() {
  return SavedAnalysis(
    id: 'game',
    userId: 'user',
    title: 'White vs Black',
    chessGame: ChessGame(
      gameId: 'game',
      startingFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      metadata: const <String, dynamic>{'White': 'White', 'Black': 'Black'},
      mainline: const <ChessMove>[],
    ),
    analysisState: const <String, dynamic>{},
    variationComments: const <String, String>{},
    lastViewedPosition: -1,
    tags: const <String>[],
    isFavorite: false,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}
