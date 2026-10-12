import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/widgets/variation_fork_chooser.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test(
    'h6 within a variation offers Nxc4 and Re1 without leaving the line',
    () {
      final game = _h6Game();
      const current = <int>[0, 0, 0];
      final next = manualBoardForwardPointerForTesting(game, current);
      expect(next, [0, 0, 1]);
      final options =
          resolveVariationForkOptions(
            game: game,
            current: current,
            next: next!,
          )!;
      expect(options.map((o) => o.san), ['Nxc4', 'Re1']);
      expect(options.map((o) => o.pointer), [
        [0, 0, 1],
        [0, 0, 0, 0, 0],
      ]);
      expect(
        ChessGameNavigatorState(
          game: game,
          movePointer: options[1].pointer,
        ).currentMove?.uci,
        'f1e1',
      );
      expect(manualBoardForwardPointerForTesting(game, [0, 0, 1]), isNull);
    },
  );

  final captured = Platform.environment['CHESSEVER_H6_TREE'];
  test(
    'exact captured tree has both legal h6 continuations',
    () {
      final game = ChessGame.fromJson(
        (jsonDecode(File(captured!).readAsStringSync()) as Map)
            .cast<String, dynamic>(),
      );
      const current = <int>[25, 0, 5];
      final next = manualBoardForwardPointerForTesting(game, current)!;
      expect(next, [25, 0, 6]);
      final options =
          resolveVariationForkOptions(
            game: game,
            current: current,
            next: next,
          )!;
      expect(options.map((o) => o.san), ['Nxc4', 'Re1']);
      expect(options.map((o) => o.pointer), [
        [25, 0, 6],
        [25, 0, 5, 0, 0],
      ]);
    },
    skip:
        captured == null ? 'Set CHESSEVER_H6_TREE for private capture' : false,
  );

  testWidgets('held Right opens h6 chooser without auto-selecting a move', (
    tester,
  ) async {
    final game = _h6Game();
    const current = <int>[0, 0, 0];
    final next = manualBoardForwardPointerForTesting(game, current)!;
    final options =
        resolveVariationForkOptions(game: game, current: current, next: next)!;
    List<int>? picked;
    var opened = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [boardSettingsProviderNew.overrideWith(_Settings.new)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ResponsiveHelper.init(context);
                return Focus(
                  autofocus: true,
                  onKeyEvent: (_, event) {
                    if (event.logicalKey != LogicalKeyboardKey.arrowRight ||
                        event is! KeyDownEvent ||
                        opened) {
                      return KeyEventResult.ignored;
                    }
                    opened = true;
                    showVariationForkChooser(
                      context: context,
                      options: options,
                    ).then((value) => picked = value);
                    return KeyEventResult.handled;
                  },
                  child: const Text('h6 selected'),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Continue with'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(picked, isNull, reason: 'Held key must not choose Nxc4');
      expect(find.text('Continue with'), findsOneWidget);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(picked, [0, 0, 0, 0, 0]);
    expect(find.text('Continue with'), findsNothing);
  });
}

class _Settings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(useFigurine: false);
}

// Reduced from the reported game's actual move/FEN tree. No private game,
// player metadata, comments or archive headers are included in this fixture.
ChessGame _h6Game() {
  final continuation = ChessGame.fromPgn('h6-reduced', '''
[SetUp "1"]
[FEN "r2qr1k1/1bp2ppp/pb1p1n2/8/2pPP3/4B2P/PPBN1PP1/RQ3RK1 b - - 1 16"]
[Result "*"]

16... h6 17. Nxc4 *
''');
  final alternative = ChessGame.fromPgn('h6-alternative', '''
[SetUp "1"]
[FEN "r2qr1k1/1bp2pp1/pb1p1n1p/8/2pPP3/4B2P/PPBN1PP1/RQ3RK1 w - - 0 17"]
[Result "*"]

17. Re1 Rb8 *
''');
  final branch = [
    continuation.mainline.first.copyWith(
      variations: [alternative.mainline],
      overrideVariations: true,
    ),
    ...continuation.mainline.skip(1),
  ];
  final parent = ChessGame.fromPgn('h6-parent', '''
[SetUp "1"]
[FEN "r2qr1k1/1bp2ppp/pb1p1n2/8/2pPP3/4B2P/PPBN1PP1/RQ3RK1 b - - 1 16"]
[Result "*"]

16... a5 *
''');
  return parent.copyWith(
    mainline: [
      parent.mainline.first.copyWith(
        variations: [branch],
        overrideVariations: true,
      ),
    ],
  );
}
