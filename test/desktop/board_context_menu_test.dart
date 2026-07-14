import 'dart:async';

import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/board_context_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
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
}

class _TestKeyboardShortcutsNotifier extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}
