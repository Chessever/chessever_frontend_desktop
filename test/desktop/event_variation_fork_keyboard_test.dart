import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/variation_fork_chooser.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  for (final update in ['source', 'pointer', 'choices', 'lifetime']) {
    testWidgets('Changed $update dismisses the Events fork', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final game = ValueNotifier(_game());
      final pointer = ValueNotifier<List<int>>([0]);
      final dismiss = ValueNotifier(0);
      final lifetime = ValueNotifier<Object>(Object());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(_Settings.new),
            keyboardShortcutsProvider.overrideWith(_Shortcuts.new),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: _Host(
                game: game,
                pointer: pointer,
                dismiss: dismiss,
                lifetime: lifetime,
                picked: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('Continue with'), findsOneWidget);
      switch (update) {
        case 'source':
          game.value = game.value.copyWith(gameId: 'replacement-game');
        case 'pointer':
          pointer.value = [1];
        case 'choices':
          game.value = game.value.copyWith(
            mainline: [
              game.value.mainline.first.copyWith(
                variations: null,
                overrideVariations: true,
              ),
              ...game.value.mainline.skip(1),
            ],
          );
        case 'lifetime':
          lifetime.value = Object();
      }
      await tester.pumpAndSettle();
      expect(find.text('Continue with'), findsNothing);
      expect(dismiss.value, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      game.dispose();
      pointer.dispose();
      dismiss.dispose();
      lifetime.dispose();
    });
  }
  for (final pointerOnly in [false, true]) {
    testWidgets(
      'Creating Events variation then ${pointerOnly ? 'same pointer' : 'metadata'} refresh keeps keyboard fork alive',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fullGame = _game();
        final game = ValueNotifier(
          fullGame.copyWith(
            mainline: [
              fullGame.mainline.first.copyWith(
                variations: null,
                overrideVariations: true,
              ),
              ...fullGame.mainline.skip(1),
            ],
          ),
        );
        final pointer = ValueNotifier<List<int>>([0]);
        final dismiss = ValueNotifier(0);
        List<int>? picked;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              boardSettingsProviderNew.overrideWith(_Settings.new),
              keyboardShortcutsProvider.overrideWith(_Shortcuts.new),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: _Host(
                  game: game,
                  pointer: pointer,
                  dismiss: dismiss,
                  picked: (p) => picked = p,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Create a private branch, select it, then return to its mainline fork.
        game.value = fullGame;
        pointer.value = [0, 0, 0];
        await tester.pumpAndSettle();
        pointer.value = [0];
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(find.text('Continue with'), findsOneWidget);
        if (!pointerOnly) {
          game.value = game.value.copyWith(
            metadata: {...game.value.metadata, 'WhiteElo': '2001'},
          );
        }
        pointer.value = List<int>.unmodifiable(pointer.value);
        await tester.pumpAndSettle();
        expect(
          find.text('Continue with'),
          findsOneWidget,
          reason:
              'An Events refresh must not cancel the same position and choices',
        );
        expect(picked, isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(picked, [0, 0, 0]);
        expect(find.text('Continue with'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        game.dispose();
        pointer.dispose();
        dismiss.dispose();
      },
    );
  }
}

class _Host extends HookWidget {
  const _Host({
    required this.game,
    required this.pointer,
    required this.dismiss,
    required this.picked,
    this.lifetime,
  });
  final ValueNotifier<ChessGame> game;
  final ValueNotifier<List<int>> pointer;
  final ValueNotifier<int> dismiss;
  final ValueChanged<List<int>?> picked;
  final ValueNotifier<Object>? lifetime;
  @override
  Widget build(BuildContext context) {
    ResponsiveHelper.init(context);
    useListenable(game);
    useListenable(pointer);
    final lifetimeOwner = useMemoized(() => ValueNotifier<Object>(Object()));
    useListenable(lifetime ?? lifetimeOwner);
    final open = useRef(false);
    final accept = useMemoized(() => ValueNotifier(0));
    // The production owner key, with the real hook, rail and popup lifecycle.
    useEffect(
      () => () {
        if (open.value) dismiss.value++;
      },
      [
        true,
        (lifetime ?? lifetimeOwner).value,
        boardVariationForkScopeKey(game: game.value, pointer: pointer.value),
      ],
    );
    return NotationOpeningPanel(
      notationChild: const Center(child: Text('Nxc7 selected')),
      currentFen: game.value.mainline[pointer.value.first].fen,
      startingFen: game.value.startingFen,
      lineUcis: [game.value.mainline.first.uci],
      onPlayUciMove: (_) {},
      onNotationStep: (delta) {
        if (delta != 1) return false;
        if (open.value) {
          accept.value++;
          return true;
        }
        final next = manualBoardForwardPointerForTesting(
          game.value,
          pointer.value,
        );
        if (next == null) return false;
        final options =
            resolveVariationForkOptions(
              game: game.value,
              current: pointer.value,
              next: next,
            )!;
        open.value = true;
        showVariationForkChooser(
          context: context,
          options: options,
          dismissSignal: dismiss,
          acceptSignal: accept,
        ).then(picked).whenComplete(() => open.value = false);
        return true;
      },
    );
  }
}

class _Settings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(useFigurine: false);
}

class _Shortcuts extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}

ChessGame _game() {
  final parent = ChessGame.fromPgn('event-fixture', '''
[SetUp "1"]
[FEN "6k1/p1pb2pp/1p1n1p2/2pN4/5B2/1PP2P2/P5PP/4K3 w - - 2 23"]
[Result "*"]

23. Nxc7 Nb7 24. c4 *
''');
  final branch = ChessGame.fromPgn('branch-fixture', '''
[SetUp "1"]
[FEN "6k1/p1Nb2pp/1p1n1p2/2p5/5B2/1PP2P2/P5PP/4K3 b - - 0 23"]
[Result "*"]

23... Nf5 24. c4 Kf7 25. Nd5 Ne7 *
''');
  return parent.copyWith(
    mainline: [
      parent.mainline.first.copyWith(
        variations: [branch.mainline],
        overrideVariations: true,
      ),
      ...parent.mainline.skip(1),
    ],
  );
}
