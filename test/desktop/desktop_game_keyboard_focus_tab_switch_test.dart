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
  String? activatedGameId;
  final FocusNode shellChromeFocusNode = FocusNode(
    debugLabel: 'test-shell-chrome',
  );

  @override
  void dispose() {
    shellChromeFocusNode.dispose();
    super.dispose();
  }

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

  void focusShellChrome() {
    shellChromeFocusNode.requestFocus();
  }

  void activateGame(GamesTourModel game) {
    setState(() => activatedGameId = game.gameId);
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
              Focus(
                focusNode: shellChromeFocusNode,
                child: const SizedBox(key: Key('shell-chrome')),
              ),
              if (showShellTextField)
                const TextField(key: Key('shell-field'), autofocus: true),
              Expanded(
                child: PersistentIndexedStack(
                  index: index,
                  children: [
                    _FakeGamesPane(
                      scopeId: 'pane-a',
                      loadingFirst: widget.paneALoadingFirst,
                      onActivateGame: activateGame,
                    ),
                    if (paneBMounted)
                      _FakeGamesPane(
                        scopeId: 'pane-b',
                        onActivateGame: activateGame,
                      ),
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
  const _FakeGamesPane({
    required this.scopeId,
    required this.onActivateGame,
    this.loadingFirst = false,
  });

  final String scopeId;
  final ValueChanged<GamesTourModel> onActivateGame;

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
      onActivateGame: widget.onActivateGame,
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

class _BoardIdentityProbe extends StatefulWidget {
  const _BoardIdentityProbe({super.key, required this.gameId});

  final String gameId;

  @override
  State<_BoardIdentityProbe> createState() => _BoardIdentityProbeState();
}

class _BoardIdentityProbeState extends State<_BoardIdentityProbe> {
  @override
  Widget build(BuildContext context) => Text(widget.gameId);
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

  testWidgets('key repeat does not skip games', (tester) async {
    await tester.pumpWidget(const _TwoPaneHost());
    await tester.pump();

    expect(find.text('selected:pane-a-g0'), findsOneWidget);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      find.text('selected:pane-a-g0'),
      findsOneWidget,
      reason: 'only a new physical key-down may advance the selection',
    );

    await pressArrowDown(tester);
    expect(find.text('selected:pane-a-g1'), findsOneWidget);
  });

  testWidgets('keyboard selection scrolls into view without animation', (
    tester,
  ) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final games = [_game('g0'), _game('g1'), _game('g2')];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: 120,
              child: DesktopGameKeyboardFocus(
                scopeId: 'instant-scroll',
                games: games,
                scrollController: scrollController,
                ensureInitialSelectionVisible: false,
                builder: (context, selectedGameId, selectGame, keyForGame) {
                  return ListView(
                    controller: scrollController,
                    children: [
                      for (final game in games)
                        DesktopGameKeyboardItem(
                          itemKey: keyForGame(game.gameId),
                          gameId: game.gameId,
                          onSelect: selectGame,
                          child: SizedBox(
                            height: 100,
                            child: Text(
                              selectedGameId == game.gameId
                                  ? 'selected:${game.gameId}'
                                  : 'item:${game.gameId}',
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(find.text('selected:g1'), findsOneWidget);
    expect(scrollController.offset, closeTo(80, 0.1));
    expect(scrollController.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('keyboard selection keeps each board state on its own game', (
    tester,
  ) async {
    final games = [_game('g0'), _game('g1')];

    await tester.pumpWidget(
      MaterialApp(
        home: DesktopGameKeyboardFocus(
          scopeId: 'stable-board-identity',
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
                    child: _BoardIdentityProbe(
                      key: ValueKey<String>('probe-${game.gameId}'),
                      gameId: game.gameId,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();

    final g0Before = tester.state<_BoardIdentityProbeState>(
      find.byKey(const ValueKey<String>('probe-g0')),
    );
    final g1Before = tester.state<_BoardIdentityProbeState>(
      find.byKey(const ValueKey<String>('probe-g1')),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(
      tester.state<_BoardIdentityProbeState>(
        find.byKey(const ValueKey<String>('probe-g0')),
      ),
      same(g0Before),
    );
    expect(
      tester.state<_BoardIdentityProbeState>(
        find.byKey(const ValueKey<String>('probe-g1')),
      ),
      same(g1Before),
    );
  });

  testWidgets('Enter opens the automatically selected first game', (
    tester,
  ) async {
    await tester.pumpWidget(const _TwoPaneHost());
    await tester.pump();

    final state = tester.state<_TwoPaneHostState>(find.byType(_TwoPaneHost));
    expect(find.text('selected:pane-a-g0'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(state.activatedGameId, 'pane-a-g0');
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

  testWidgets('arrow keys still move selection after opening a second tab '
      '(new pane mounts while old pane holds focus)', (tester) async {
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
  });

  testWidgets('new games pane claims focus left on sibling shell chrome', (
    tester,
  ) async {
    await tester.pumpWidget(const _TwoPaneHost());
    await tester.pump();

    final state = tester.state<_TwoPaneHostState>(find.byType(_TwoPaneHost));
    state.focusShellChrome();
    await tester.pump();
    expect(state.shellChromeFocusNode.hasFocus, isTrue);

    state.openPaneB();
    await tester.pump();
    await tester.pump();

    expect(find.text('selected:pane-b-g0'), findsOneWidget);
    await pressArrowDown(tester);
    expect(
      find.text('selected:pane-b-g1'),
      findsOneWidget,
      reason: 'sidebar/tab clicks must not leave game navigation unfocused',
    );
  });

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
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    // Switching tabs while the user is typing must not yank focus into the
    // games list.
    state.openPaneB();
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
      reason: 'text input keeps focus across tab switches',
    );
  });
}
