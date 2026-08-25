import 'dart:async';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/board_context_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('annotated Event games save a detached user copy', () {
    expect(
      shouldUsePristineEventSourceForLibrarySave(
        canSaveSource: true,
        dirtySinceLoad: false,
        hasUserNags: false,
        hasCompletedReport: false,
      ),
      isTrue,
    );
    expect(
      shouldUsePristineEventSourceForLibrarySave(
        canSaveSource: true,
        dirtySinceLoad: true,
        hasUserNags: false,
        hasCompletedReport: false,
      ),
      isFalse,
    );
    expect(
      shouldUsePristineEventSourceForLibrarySave(
        canSaveSource: true,
        dirtySinceLoad: false,
        hasUserNags: true,
        hasCompletedReport: false,
      ),
      isFalse,
    );
    expect(
      shouldUsePristineEventSourceForLibrarySave(
        canSaveSource: true,
        dirtySinceLoad: false,
        hasUserNags: false,
        hasCompletedReport: true,
      ),
      isFalse,
    );
  });

  testWidgets('board menu exposes the board focus toggle', (tester) async {
    var toggled = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyboardShortcutsProvider.overrideWith(
            _TestKeyboardShortcutsNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder:
                (context, ref, _) => TextButton(
                  onPressed: () {
                    unawaited(
                      showBoardContextMenu(
                        ref,
                        context,
                        position: const Offset(16, 16),
                        onShareGame: () {},
                        onFlipBoard: () {},
                        onToggleBoardFocus: () => toggled = true,
                        onCopyPgn: () {},
                        onCopyFen: () {},
                        onSavePgn: () {},
                        onSaveGameToLibrary: () {},
                        onOpenBoardSettings: () {},
                        onOpenPositionSetup: () {},
                        canCopyOrSavePgn: true,
                        boardFocusMode: false,
                      ),
                    );
                  },
                  child: const Text('Open menu'),
                ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open menu'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Board focus'), findsOneWidget);
    await tester.tap(find.text('Board focus'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(toggled, isTrue);
  });

  testWidgets('board menu opens picture in picture when a game is available', (
    tester,
  ) async {
    var opened = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyboardShortcutsProvider.overrideWith(
            _TestKeyboardShortcutsNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder:
                (context, ref, _) => TextButton(
                  onPressed: () {
                    unawaited(
                      showBoardContextMenu(
                        ref,
                        context,
                        position: const Offset(16, 16),
                        onShareGame: () {},
                        onFlipBoard: () {},
                        onToggleBoardFocus: () {},
                        onOpenPictureInPicture: () => opened = true,
                        showPictureInPictureAction: true,
                        onCopyPgn: () {},
                        onCopyFen: () {},
                        onSavePgn: () {},
                        onSaveGameToLibrary: () {},
                        onOpenBoardSettings: () {},
                        onOpenPositionSetup: () {},
                        canCopyOrSavePgn: true,
                        boardFocusMode: false,
                      ),
                    );
                  },
                  child: const Text('Open menu'),
                ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open menu'));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Open picture in picture'));
    await tester.pump(const Duration(milliseconds: 120));

    expect(opened, isTrue);
  });

  testWidgets('board menu hides picture in picture for non-live games', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyboardShortcutsProvider.overrideWith(
            _TestKeyboardShortcutsNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder:
                (context, ref, _) => TextButton(
                  onPressed: () {
                    unawaited(
                      showBoardContextMenu(
                        ref,
                        context,
                        position: const Offset(16, 16),
                        onShareGame: () {},
                        onFlipBoard: () {},
                        onToggleBoardFocus: () {},
                        onCopyPgn: () {},
                        onCopyFen: () {},
                        onSavePgn: () {},
                        onSaveGameToLibrary: () {},
                        onOpenBoardSettings: () {},
                        onOpenPositionSetup: () {},
                        canCopyOrSavePgn: true,
                        boardFocusMode: false,
                      ),
                    );
                  },
                  child: const Text('Open menu'),
                ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open menu'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Open picture in picture'), findsNothing);
  });
}

class _TestKeyboardShortcutsNotifier extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}
