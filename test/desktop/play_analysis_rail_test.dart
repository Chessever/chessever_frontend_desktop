import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/widgets/board_move_badge.dart';
import 'package:chessever/desktop/widgets/board_like_button.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/widgets/play_help_trigger.dart';
import 'package:chessever/desktop/widgets/play_help_modules_panel.dart';
import 'package:chessever/desktop/widgets/play_post_game_brief.dart';
import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

const _tabId = 'play-rail-test';

Widget _harness(
  PlayHelpModules modules, {
  PlayHelpStyle style = const PlayHelpStyle(),
  List<String> startingMovesUci = const <String>[],
}) => ProviderScope(
  overrides: [
    playHelpModulesProvider.overrideWith(() => _FixedModules(modules)),
    playHelpStyleProvider.overrideWith(() => _FixedStyle(style)),
    playSessionBootEngineProvider.overrideWithValue(false),
    // A member: the game is admitted with the configured colour (White),
    // not the inert fallback's random one.
    subscriptionProvider.overrideWith(
      (_) => SubscriptionNotifier.stub(SubscriptionState(isSubscribed: true)),
    ),
    playSessionArgsByTabIdProvider.overrideWith(
      (ref) => <String, PlaySessionArgs>{
        _tabId: PlaySessionArgs(
          config: PlayConfig(
            engine: BotEngineKind.stockfish,
            elo: 1500,
            category: TimeControlCategory.blitz,
            baseSeconds: 180,
            incrementSeconds: 2,
            color: PlayColorChoice.white,
            startClockImmediately: false,
            startingFen: null,
            startingMovesUci: startingMovesUci,
          ),
          engineBinaryPath: '',
          botIdentity: const BotIdentity(
            firstName: 'Test',
            lastName: 'Bot',
            countryCode: 'US',
            elo: 1500,
          ),
        ),
      },
    ),
  ],
  child: FTheme(
    data: FThemes.zinc.dark,
    child: const MaterialApp(
      home: Scaffold(body: PlayActiveGameView(tabId: _tabId)),
    ),
  ),
);

class _FixedModules extends PlayHelpModulesNotifier {
  _FixedModules(this.modules);

  final PlayHelpModules modules;

  @override
  PlayHelpModules build() => modules;
}

class _FixedStyle extends PlayHelpStyleNotifier {
  _FixedStyle(this.style);

  final PlayHelpStyle style;

  @override
  PlayHelpStyle build() => style;
}

/// The eval bar's search waits for an engine the test never boots: let
/// its ready timeouts run out once the game is gone.
Future<void> _drainEngine(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 31));
  }
}

Position _after(String fen, String uci) =>
    Chess.fromSetup(Setup.parseFen(fen)).play(Move.parse(uci)!);

void main() {
  group('play analysis rail', () {
    testWidgets('engine lines bring the watching rail, without Like', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(const PlayHelpModules(engineLines: true)),
      );
      // Drain the board-size preference read's timeout timer.
      await tester.pump(const Duration(seconds: 5));

      final rail = tester.widget<NotationOpeningPanel>(
        find.byType(NotationOpeningPanel),
      );
      expect(rail.showEngine, isTrue);
      // The explorer is its own module, off here.
      expect(rail.showExplorer, isFalse);
      expect(find.byType(EnginePanel), findsOneWidget);
      // Liked games are listed publicly; a game against a bot is private.
      expect(find.byType(DesktopBoardLikeButton), findsNothing);
      // The modules stay one click away during the game, folded away.
      expect(find.byType(PlayHelpModulesSection), findsOneWidget);
      expect(find.byType(PlayHelpModulesList), findsNothing);
      expect(find.text('Resign'), findsOneWidget);
      expect(find.text('Abort'), findsOneWidget);
    });

    testWidgets('the explorer alone opens the rail without the engine', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_harness(const PlayHelpModules(explorer: true)));
      await tester.pump(const Duration(seconds: 5));

      final rail = tester.widget<NotationOpeningPanel>(
        find.byType(NotationOpeningPanel),
      );
      expect(rail.showExplorer, isTrue);
      expect(rail.showEngine, isFalse);
    });

    testWidgets('hold to peek: the help shows only while held', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          const PlayHelpModules(engineLines: true),
          style: const PlayHelpStyle(level: PlayHelpLevel.peek),
        ),
      );
      await tester.pump(const Duration(seconds: 5));

      // Held back: the rail keeps its place, a curtain stands in.
      expect(find.byType(NotationOpeningPanel), findsOneWidget);
      expect(find.byType(PlayHelpCurtain), findsOneWidget);
      expect(find.byType(EnginePanel), findsNothing);
      expect(find.byType(PlayHelpTrigger), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PlayHelpTrigger)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EnginePanel), findsOneWidget);
      expect(find.byType(PlayHelpCurtain), findsNothing);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EnginePanel), findsNothing);
      expect(find.byType(PlayHelpCurtain), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      expect(container.read(playHelpUsageProvider(_tabId)).peeks, 1);
      // Peeking again at the same position is free.
      await tester.tap(find.byType(PlayHelpTrigger));
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(playHelpUsageProvider(_tabId)).peeks, 1);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('hints: one spent shows the help, and they run out', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          const PlayHelpModules(engineLines: true),
          style: const PlayHelpStyle(level: PlayHelpLevel.hints, hints: 1),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(PlayHelpCurtain), findsOneWidget);
      Finder onTrigger(String text) => find.descendant(
        of: find.byType(PlayHelpTrigger),
        matching: find.text(text),
      );
      expect(onTrigger('Hint'), findsOneWidget);

      await tester.tap(find.byType(PlayHelpTrigger));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(EnginePanel), findsOneWidget);
      expect(onTrigger('Hint shown'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      final usage = container.read(playHelpUsageProvider(_tabId));
      expect(usage.hints, 1);
      expect(usage.hintsLeft, 0);
    });

    testWidgets('a module key peeks at that module alone', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          const PlayHelpModules(engineLines: true, evalBar: true),
          style: const PlayHelpStyle(level: PlayHelpLevel.peek),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      PlayHelpModules shown() => container.read(playHelpShownProvider(_tabId));

      // The shelf lists all help and each chosen module, with its key (a
      // narrow shelf shows a module as its key alone, named for readers).
      final shelf = find.byType(PlayHelpCurtain);
      Finder entry(String name) => find.descendant(
        of: shelf,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              (w.properties.label?.startsWith('Hold to see $name') ?? false),
        ),
      );
      expect(entry('All help'), findsOneWidget);
      expect(entry('Engine lines'), findsOneWidget);
      expect(entry('Eval bar'), findsOneWidget);
      expect(entry('Move marks'), findsNothing);

      // Shift+E: the eval bar only; the engine lines stay behind the shelf.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyE);
      await tester.pump(const Duration(milliseconds: 50));
      expect(shown(), const PlayHelpModules(evalBar: true));
      expect(find.byType(EnginePanel), findsNothing);
      expect(find.byType(PlayHelpCurtain), findsOneWidget);
      // Shift comes up first; the key coming up still ends the peek.
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
      await tester.pump(const Duration(milliseconds: 50));
      expect(shown(), const PlayHelpModules());

      // Shift+L: the engine lines open the pane, without the eval bar.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL);
      await tester.pump(const Duration(milliseconds: 50));
      expect(shown(), const PlayHelpModules(engineLines: true));
      expect(find.byType(EnginePanel), findsOneWidget);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EnginePanel), findsNothing);

      // Two modules peeked at one position count as one peek; a key for a
      // module that is off does nothing.
      expect(container.read(playHelpUsageProvider(_tabId)).peeks, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM);
      await tester.pump(const Duration(milliseconds: 50));
      expect(shown(), const PlayHelpModules());
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      // Holding a shelf entry peeks at it; the release ends the peek even
      // though the pane took the shelf's place.
      final gesture = await tester.startGesture(
        tester.getCenter(entry('Engine lines')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EnginePanel), findsOneWidget);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EnginePanel), findsNothing);
      expect(container.read(playHelpUsageProvider(_tabId)).peeking, isFalse);
      await _drainEngine(tester);
    });

    testWidgets('a hint on one module costs one hint', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          const PlayHelpModules(engineLines: true, evalBar: true),
          style: const PlayHelpStyle(level: PlayHelpLevel.hints, hints: 3),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      final usage = container.read(playHelpUsageProvider(_tabId).notifier);
      PlayHelpUsage read() => container.read(playHelpUsageProvider(_tabId));

      // A module that is off: nothing shown, nothing spent.
      expect(usage.useHint(PlayHelpModule.explorer), isFalse);
      expect(read().hints, 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 50));
      expect(read().hints, 1);
      expect(
        container.read(playHelpShownProvider(_tabId)),
        const PlayHelpModules(evalBar: true),
      );
      // Asking again for what shows is free.
      expect(usage.useHint(PlayHelpModule.evalBar), isFalse);
      expect(read().hints, 1);
      // Another module at the same position costs another hint.
      expect(usage.useHint(PlayHelpModule.engineLines), isTrue);
      expect(read().hints, 2);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EnginePanel), findsOneWidget);
      // Everything is on screen now, so all help is free too.
      expect(usage.useHint(), isFalse);
      expect(read().hintsLeft, 1);
      await _drainEngine(tester);
    });

    testWidgets('a saved legacy threat flag is no help: nothing to peek '
        'at or spend a hint on', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final level in [PlayHelpLevel.peek, PlayHelpLevel.hints]) {
        await tester.pumpWidget(
          _harness(
            const PlayHelpModules(threats: true),
            style: PlayHelpStyle(level: level),
          ),
        );
        await tester.pump(const Duration(seconds: 5));
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayActiveGameView)),
        );
        final usage = container.read(playHelpUsageProvider(_tabId).notifier);
        expect(find.byType(PlayHelpTrigger), findsNothing);
        expect(find.byType(PlayHelpCurtain), findsNothing);
        expect(usage.beginPeek(), isFalse);
        expect(usage.useHint(), isFalse);
        final read = container.read(playHelpUsageProvider(_tabId));
        expect(read.peeks + read.hints, 0);
        expect(read.usedAny, isFalse);
        expect(playHelpGainFactor(read), 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      }
    });

    testWidgets('a hint shows for the live position only, not for moves '
        'stepped back to', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          const PlayHelpModules(engineLines: true, evalBar: true),
          style: const PlayHelpStyle(level: PlayHelpLevel.hints, hints: 3),
          startingMovesUci: const ['e2e4', 'e7e5'],
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      final usage = container.read(playHelpUsageProvider(_tabId).notifier);
      PlayHelpModules shown() => container.read(playHelpShownProvider(_tabId));
      expect(container.read(playSessionProviderFor(_tabId)).history.length, 2);

      expect(usage.useHint(), isTrue);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(EnginePanel), findsOneWidget);
      expect(shown(), const PlayHelpModules(engineLines: true, evalBar: true));

      // One move back: the help is held back again, and a hint there
      // cannot be spent.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(playHelpAtLiveTipProvider(_tabId)), isFalse);
      expect(shown(), const PlayHelpModules());
      expect(find.byType(EnginePanel), findsNothing);
      expect(find.byType(PlayHelpCurtain), findsOneWidget);
      expect(find.byType(PlayHeldBackBar), findsOneWidget);
      expect(usage.useHint(PlayHelpModule.evalBar), isFalse);
      expect(container.read(playHelpUsageProvider(_tabId)).hints, 1);

      // Back at the live position the hint shows again, at no cost.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(playHelpAtLiveTipProvider(_tabId)), isTrue);
      expect(shown(), const PlayHelpModules(engineLines: true, evalBar: true));
      expect(container.read(playHelpUsageProvider(_tabId)).hints, 1);
      await _drainEngine(tester);
    });

    testWidgets('a short engine pane shows every help entry', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> pumpCurtain(
        PlayHelpLevel level,
        PlayHelpModules modules,
        Size size,
      ) async {
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey((level, modules, size)),
            overrides: [
              playHelpModulesProvider.overrideWith(
                () => _FixedModules(modules),
              ),
              playHelpStyleProvider.overrideWith(
                () => _FixedStyle(PlayHelpStyle(level: level)),
              ),
              playSessionBootEngineProvider.overrideWithValue(false),
            ],
            child: FTheme(
              data: FThemes.zinc.dark,
              child: MaterialApp(
                home: Scaffold(
                  body: Center(
                    child: SizedBox.fromSize(
                      size: size,
                      child: const PlayHelpCurtain(tabId: _tabId),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 5));
        expect(tester.takeException(), isNull);
      }

      const every = PlayHelpModules(
        engineLines: true,
        evalBar: true,
        tobyPredictions: true,
        tobyBar: true,
        moveMarks: true,
        explorer: true,
        arrowEvals: true,
        arrows: PlayHelpArrows.stockfish,
      );
      final curtain = find.byType(PlayHelpCurtain);
      for (final level in [PlayHelpLevel.peek, PlayHelpLevel.hints]) {
        // Every module in a short engine pane: one row, modules as their
        // keys, named in tooltips, with no scrollbar; an arrow at the side
        // brings every entry into view.
        for (final size in const [Size(320, 76), Size(320, 120)]) {
          await pumpCurtain(level, every, size);
          expect(find.text('All help'), findsOneWidget);
          expect(find.text('Stockfish arrows'), findsNothing);
          expect(
            find.text(level == PlayHelpLevel.peek ? 'Hold' : 'Hint'),
            findsOneWidget,
          );
          expect(find.byType(Scrollbar), findsNothing);
          final strip = tester.getRect(
            find.descendant(
              of: curtain,
              matching: find.byType(ScrollEdgeArrows),
            ),
          );
          expect(tester.getRect(curtain).contains(strip.bottomRight), isTrue);
          final caps = find.descendant(
            of: curtain,
            matching: find.byType(PlayHelpKeycap),
          );
          expect(caps, findsNWidgets(9));
          final more = find.byIcon(Icons.chevron_right_rounded);
          expect(more, findsOneWidget, reason: '$level $size: no arrow');
          for (var i = 0; i < 9; i++) {
            bool inView() {
              final rect = tester.getRect(caps.at(i));
              return rect.left >= strip.left - 0.5 &&
                  rect.right <= strip.right + 0.5;
            }

            for (var press = 0; press < 12 && !inView(); press++) {
              await tester.tap(more);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
            }
            expect(
              inView(),
              isTrue,
              reason: '$level $size: entry $i never comes into $strip',
            );
          }
          // At the far end the right arrow goes and the left one shows.
          for (
            var press = 0;
            press < 12 && more.evaluate().isNotEmpty;
            press++
          ) {
            await tester.tap(more);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
          }
          expect(more, findsNothing);
          expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
        }

        // A few modules keep their names.
        await pumpCurtain(
          level,
          const PlayHelpModules(engineLines: true, evalBar: true),
          const Size(720, 120),
        );
        expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
        expect(find.text('Engine lines'), findsOneWidget);
        expect(find.text('Eval bar'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('in Always on the help keys do nothing', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(const PlayHelpModules(engineLines: true)),
      );
      await tester.pump(const Duration(seconds: 5));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump(const Duration(milliseconds: 50));
      final usage = container.read(playHelpUsageProvider(_tabId));
      expect(usage.peeks + usage.hints, 0);
      expect(find.byType(PlayHelpCurtain), findsNothing);
      expect(find.byType(EnginePanel), findsOneWidget);
    });

    testWidgets('with no help the game is played as in competition', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_harness(const PlayHelpModules()));
      await tester.pump(const Duration(seconds: 5));

      // Moves and game controls only: no engine, Toby or explorer.
      expect(find.byType(NotationOpeningPanel), findsNothing);
      expect(find.byType(EnginePanel), findsNothing);
      expect(find.byType(NotationLadderView), findsOneWidget);
      expect(find.byType(PlayHelpModulesSection), findsOneWidget);
      expect(find.text('Resign'), findsOneWidget);
      expect(find.text('Abort'), findsOneWidget);

      // Folded until asked for, then every switch is there.
      expect(find.byType(FSwitch), findsNothing);
      await tester.tap(find.text('Live help'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PlayHelpModulesList), findsOneWidget);
      expect(find.byType(FSwitch), findsNWidgets(7));
      await tester.tap(find.text('Live help'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FSwitch), findsNothing);
    });
  });

  group('show threat', () {
    testWidgets('the button is beside the player\'s clock with no help on', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_harness(const PlayHelpModules()));
      await tester.pump(const Duration(seconds: 5));
      // Once, beside the player's own clock.
      expect(find.text('Show threat'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      await tester.tap(find.text('Show threat'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(playThreatShownProvider(_tabId)), isTrue);
      expect(find.text('Hide threat'), findsOneWidget);
      // Drain the pill's motion before teardown.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });

    test('a threat is read only on the player\'s turn, out of check', () {
      final start = Chess.initial;
      expect(playThreatApplies(start, humanSide: Side.white), isTrue);
      expect(playThreatApplies(start, humanSide: Side.black), isFalse);
      // 1.f3 e5 2.g4 Qh4+: White to move, in check, cannot pass.
      var checked = Chess.initial as Position;
      for (final uci in ['f2f3', 'e7e5', 'g2g4', 'd8h4']) {
        checked = checked.play(Move.parse(uci)!);
      }
      expect(checked.isCheck, isTrue);
      expect(playThreatApplies(checked, humanSide: Side.white), isFalse);
    });
  });

  group('board move badge square', () {
    test('sits on the square the piece landed on', () {
      final after = _after(Chess.initial.fen, 'g1f3');
      expect(boardMoveBadgeSquare(after, Move.parse('g1f3')), Square.f3);
    });

    test('a king-to-rook castle anchors to the king, not the rook', () {
      const castleFen = 'r3k2r/pppppppp/8/8/8/8/PPPPPPPP/R3K2R w KQkq - 0 1';
      final kingSide = _after(castleFen, 'e1h1');
      expect(boardMoveBadgeSquare(kingSide, Move.parse('e1h1')), Square.g1);
      final queenSide = _after(castleFen, 'e1a1');
      expect(boardMoveBadgeSquare(queenSide, Move.parse('e1a1')), Square.c1);
    });

    test('a rook move to a corner stays on the rook', () {
      const fen = '4k3/8/8/8/8/8/8/R3K3 w Q - 0 1';
      final after = _after(fen, 'a1a8');
      expect(boardMoveBadgeSquare(after, Move.parse('a1a8')), Square.a8);
    });
  });

  group('the result after the game', () {
    Future<void> resign(WidgetTester tester) async {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayActiveGameView)),
      );
      container.read(playSessionProviderFor(_tabId).notifier).resign();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    void expectActionsOnScreen(WidgetTester tester, double height) {
      for (final action in ['Rematch', 'New game', 'Full report']) {
        final rect = tester.getRect(find.text(action));
        expect(rect.bottom, lessThanOrEqualTo(height), reason: action);
      }
    }

    testWidgets('leads the analysis rail, with the analysis kept under it', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          const PlayHelpModules(engineLines: true),
          startingMovesUci: const ['e2e4', 'e7e5'],
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      await resign(tester);

      final brief = tester.widget<PlayPostGameBrief>(
        find.byType(PlayPostGameBrief),
      );
      expect(brief.fill, isTrue);
      expect(find.text('You lost'), findsOneWidget);
      // Moves, engine, explorer, flip and share stay for the review.
      expect(find.byType(NotationOpeningPanel), findsOneWidget);
      expect(find.byType(NotationLadderView), findsOneWidget);
      // The game's own controls are gone; the help switches stay, so the
      // review can bring in more help.
      expect(find.byType(PlayHelpModulesSection), findsOneWidget);
      expect(find.text('Resign'), findsNothing);
      expectActionsOnScreen(tester, 900);
      // The result sits above the analysis, not under it.
      expect(
        tester.getRect(find.text('Rematch')).bottom,
        lessThan(tester.getRect(find.byType(NotationOpeningPanel)).top),
      );
      expect(tester.takeException(), isNull);
      await _drainEngine(tester);
    });

    testWidgets('takes the plain side panel, the moves under it', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          const PlayHelpModules(),
          startingMovesUci: const ['e2e4', 'e7e5'],
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      await resign(tester);

      expect(find.text('You lost'), findsOneWidget);
      expect(find.text('Moves'), findsOneWidget);
      expect(find.byType(NotationLadderView), findsOneWidget);
      expect(find.byType(PlayHelpModulesSection), findsOneWidget);
      expect(find.text('Resign'), findsNothing);
      expectActionsOnScreen(tester, 900);
      expect(tester.takeException(), isNull);
      await _drainEngine(tester);
    });

    testWidgets('a short window still keeps the moves and the actions', (
      tester,
    ) async {
      // The shortest the desktop window goes, less its chrome.
      await tester.binding.setSurfaceSize(const Size(1440, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_harness(const PlayHelpModules()));
      await tester.pump(const Duration(seconds: 5));
      // The test font draws every glyph a full em wide, so the player rows
      // beside a board this small overflow during the game (here only, not
      // with real fonts). Anything thrown after the resign still fails.
      tester.takeException();
      await resign(tester);

      expect(find.text('You lost'), findsOneWidget);
      expect(find.byType(NotationLadderView), findsOneWidget);
      expect(
        tester.getSize(find.byType(NotationLadderView)).height,
        greaterThanOrEqualTo(150),
      );
      expectActionsOnScreen(tester, 620);
      expect(tester.takeException(), isNull);
      await _drainEngine(tester);
    });
  });
}
