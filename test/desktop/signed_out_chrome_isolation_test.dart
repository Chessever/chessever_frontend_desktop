import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('inert game focus cannot claim focus or change selection', (
    tester,
  ) async {
    void Function(String)? select;
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopGameKeyboardFocus(
            enabled: false,
            scopeId: 'public-readonly-fixture',
            games: const [],
            builder: (_, current, choose, _) {
              selected = current;
              select = choose;
              return const Text('Inert game presentation');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final focus = tester
        .widgetList<Focus>(find.byType(Focus))
        .singleWhere(
          (widget) =>
              widget.focusNode?.debugLabel ==
              'desktop-game-keyboard-public-readonly-fixture',
        );
    expect(focus.canRequestFocus, isFalse);
    select!('unavailable-game');
    await tester.pump();
    expect(selected, isNull);
  });

  testWidgets(
    'real inert tab strip never reads private board or engine state',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardTabGameArgsByTabIdProvider.overrideWith(
              (ref) => throw StateError('Private board state must not be read'),
            ),
            engineSettingsProviderNew.overrideWith(
              () =>
                  throw StateError(
                    'Persisted engine settings must not be read',
                  ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: DesktopTabBar(readOnlyPresentation: true)),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Events'), findsNothing);
      expect(find.text('Home'), findsNothing);
      expect(find.byType(DesktopTabBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
