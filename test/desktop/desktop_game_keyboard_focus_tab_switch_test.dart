import 'package:chessever/desktop/widgets/desktop_game_keyboard_focus.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

GamesTourModel _game(String id) {
  return GamesTourModel(
    gameId: id,
    source: GameSource.twic,
    whitePlayer: _player('White $id'),
    blackPlayer: _player('Black $id'),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.ongoing,
    roundId: 'round-1',
    tourId: 'event-1',
    lastMoveTime: DateTime.utc(2026),
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: '',
    title: '',
    rating: 2700,
    countryCode: '',
    team: null,
  );
}

class _TwoPaneHost extends StatefulWidget {
  const _TwoPaneHost({this.paneALoadingFirst = false});

  final bool paneALoadingFirst;

  @override
  State<_TwoPaneHost> createState() => _TwoPaneHostState();
}

class _TwoPaneHostState extends State<_TwoPaneHost> {
  int index = 0;
  bool paneBMounted = false;
  bool showShellTextField = false;

  void openPaneB() {
    setState(() {
      paneBMounted = true;
      index = 1;
    });
  }

  void backToPaneA() {
    setState(() => index = 0);
  }

  void showTextField() {
    setState(() => showShellTextField = true);
  }

  @override
  Widget build(BuildContext context) {
    // Mirrors the real desktop shell: a FocusableActionDetector with
    // autofocus wraps the whole pane stack (desktop_shell.dart), so the
    // shell chrome owns keyboard focus before any pane claims it.
    return MaterialApp(
      home: Scaffold(
        body: FocusableActionDetector(
          autofocus: true,
          child: Column(
            children: [
              if (showShellTextField)
                const TextField(key: Key('shell-field'), autofocus: true),
              Expanded(
                child: PersistentIndexedStack(
                  index: index,
                  children: [
                    _FakeGamesPane(
                      scopeId: 'pane-a',
                      loadingFirst: widget.paneALoadingFirst,
                    ),
                    if (paneBMounted) _FakeGamesPane(scopeId: 'pane-b'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FakeGamesPane extends StatefulWidget {
  const _FakeGamesPane({required this.scopeId, this.loadingFirst = false});

  final String scopeId;

  /// Mimics real panes: a loading placeholder renders first and the
  /// keyboard-focus host only mounts on a later frame once data arrives.
  final bool loadingFirst;

  @override
  State<_FakeGamesPane> createState() => _FakeGamesPaneState();
}

class _FakeGamesPaneState extends State<_FakeGamesPane> {
  late bool loading = widget.loadingFirst;

  void finishLoading() {
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Text('loading');
    final scopeId = widget.scopeId;
    final games = [for (var i = 0; i < 4; i++) _game('$scopeId-g$i')];
    return DesktopGameKeyboardFocus(
      scopeId: scopeId,
      games: games,
      ensureInitialSelectionVisible: false,
      builder: (context, selectedGameId, selectGame, keyForGame) {
        return Column(
          children: [
            for (final game in games)
              DesktopGameKeyboardItem(
                itemKey: keyForGame(game.gameId),
                gameId: game.gameId,
                onSelect: selectGame,
                child: Text(
                  selectedGameId == game.gameId
                      ? 'selected:${game.gameId}'
                      : 'item:${game.gameId}',
                ),
              ),
          ],
        );
      },
    );
  }
}

void main() {
  Future<void> pressArrowDown(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
  }

  testWidgets('arrow keys move selection on freshly opened pane', (
    tester,
  ) async {
    await tester.pumpWidget(const _TwoPaneHost());
    await tester.pump();

    expect(find.text('selected:pane-a-g0'), findsOneWidget);
    await pressArrowDown(tester);
    expect(find.text('selected:pane-a-g1'), findsOneWidget);
  });

  testWidgets(
    'arrow keys move selection when games mount after a loading frame '
    '(shell chrome already autofocused)',
    (tester) async {
      await tester.pumpWidget(const _TwoPaneHost(paneALoadingFirst: true));
      await tester.pump();
      expect(find.text('loading'), findsOneWidget);

      // Data arrives on a later frame — the shell FocusableActionDetector
      // already holds primary focus by now, exactly like the real app.
      final paneState = tester.state<_FakeGamesPaneState>(
        find.byType(_FakeGamesPane),
      );
      paneState.finishLoading();
      await tester.pump();
      await tester.pump();

      await pressArrowDown(tester);
      expect(
        find.text('selected:pane-a-g1'),
        findsOneWidget,
        reason: 'games list must claim focus from idle shell chrome',
      );
    },
  );

  testWidgets(
    'arrow keys still move selection after opening a second tab '
    '(new pane mounts while old pane holds focus)',
    (tester) async {
      await tester.pumpWidget(const _TwoPaneHost());
      await tester.pump();

      // Pane A owns focus. Now the user opens a new tab: pane B mounts and
      // becomes active in the same frame, pane A becomes ExcludeFocus'd.
      final state = tester.state<_TwoPaneHostState>(find.byType(_TwoPaneHost));
      state.openPaneB();
      await tester.pump();
      await tester.pump();

      expect(find.text('selected:pane-b-g0'), findsOneWidget);
      await pressArrowDown(tester);
      expect(
        find.text('selected:pane-b-g1'),
        findsOneWidget,
        reason: 'arrow keys must drive the newly active pane',
      );
    },
  );

  testWidgets('arrow keys still move selection after switching back to a '
      'previously visited tab', (tester) async {
    await tester.pumpWidget(const _TwoPaneHost());
    await tester.pump();

    final state = tester.state<_TwoPaneHostState>(find.byType(_TwoPaneHost));
    state.openPaneB();
    await tester.pump();
    await tester.pump();

    // Back to pane A (kept alive by the IndexedStack the whole time).
    state.backToPaneA();
    await tester.pump();
    await tester.pump();

    await pressArrowDown(tester);
    expect(
      find.text('selected:pane-a-g1'),
      findsOneWidget,
      reason: 'arrow keys must drive the re-activated pane',
    );
  });

  testWidgets('tab activation does not steal focus from a text input', (
    tester,
  ) async {
    await tester.pumpWidget(const _TwoPaneHost());
    await tester.pump();

    final state = tester.state<_TwoPaneHostState>(find.byType(_TwoPaneHost));
    state.showTextField();
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode
          .hasFocus,
      isTrue,
    );

    // Switching tabs while the user is typing must not yank focus into the
    // games list.
    state.openPaneB();
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode
          .hasFocus,
      isTrue,
      reason: 'text input keeps focus across tab switches',
    );
  });
}
