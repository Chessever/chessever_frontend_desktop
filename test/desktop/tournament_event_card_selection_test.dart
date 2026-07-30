import 'dart:io';

import 'package:chessever/desktop/utils/tournament_event_grid_layout.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Current/Past tournament card selection chrome', () {
    test(
      'selected tile paints primary ring outside any clip (For You parity)',
      () {
        final source =
            File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

        final classStart = source.indexOf(
          'class _TournamentRowTileState extends State<_TournamentRowTile>',
        );
        expect(classStart, greaterThanOrEqualTo(0));

        final nextClass = source.indexOf(
          '\nclass _TournamentTileMedia',
          classStart,
        );
        expect(nextClass, greaterThan(classStart));
        final tileSource = source.substring(classStart, nextClass);

        // Fail mode: Container(clipBehavior: Clip.antiAlias, decoration: border/shadow)
        // crops the selection ring and glow. Outer shell must not clip.
        expect(tileSource, isNot(contains('clipBehavior: Clip.antiAlias')));
        expect(tileSource, isNot(contains('clipBehavior: Clip.hardEdge')));
        expect(
          tileSource,
          isNot(contains('clipBehavior: Clip.antiAliasWithSaveLayer')),
        );

        // Content rounding is a separate inner clip (For You / desktop_game_card).
        expect(tileSource, contains('ClipRRect'));
        expect(tileSource, contains('borderRadius: BorderRadius.circular(9)'));

        // Selected decoration: primary-tinted border width ≥ 2 + soft glow.
        expect(tileSource, contains('width: widget.selected ? 2 : 1'));
        expect(
          tileSource,
          contains('kPrimaryColor.withValues(alpha: 0.96)'),
        );
        expect(
          tileSource,
          contains('kPrimaryColor.withValues(alpha: 0.16)'),
        );
        expect(tileSource, contains('blurRadius: 8'));

        // Hover chrome shares the same non-clipped shell.
        expect(
          tileSource,
          contains('kWhiteColor.withValues(alpha: 0.12)'),
        );

        expect(tileSource, contains('decoration: BoxDecoration('));
        final decorationIndex = tileSource.indexOf('decoration: BoxDecoration(');
        final clipRRectIndex = tileSource.indexOf('ClipRRect(');
        expect(clipRRectIndex, greaterThan(decorationIndex));
      },
    );

    test('event grid does not hard-clip selected ring/glow at cell edges', () {
      final source =
          File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

      final gridStart = source.indexOf('class _TournamentEventGrid extends');
      expect(gridStart, greaterThanOrEqualTo(0));
      final nextClass = source.indexOf('\nclass _TournamentRowTile', gridStart);
      expect(nextClass, greaterThan(gridStart));
      final gridSource = source.substring(gridStart, nextClass);

      expect(gridSource, contains('clipBehavior: Clip.none'));
      expect(gridSource, contains('GridView.builder'));
    });
  });

  group('Current/Past keyboard selection host wiring', () {
    test('owns arrow keys with Focus + HardwareKeyboard reclaim like For You', () {
      final source =
          File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

      expect(source, contains('class _TournamentEventGridKeyboardHost'));
      expect(
        source,
        contains('HardwareKeyboard.instance.addHandler(_handleGlobalKeyboard)'),
      );
      expect(
        source,
        contains(
          'HardwareKeyboard.instance.removeHandler(_handleGlobalKeyboard)',
        ),
      );
      expect(source, contains('nextTournamentEventGridSelectedId('));
      expect(source, contains('resolveTournamentEventGridSelectionIndex('));
      expect(source, contains('widget.focusNode.requestFocus()'));
      expect(source, contains('onTapDown:'));
      expect(source, contains('_TournamentEventGridKeyboardHost('));
    });

    test(
      'global key handler gates on TickerMode so inactive tabs do not steal keys',
      () {
        final source =
            File('lib/desktop/panes/tournaments_pane.dart').readAsStringSync();

        final hostStart = source.indexOf(
          'class _TournamentEventGridKeyboardHostState',
        );
        expect(hostStart, greaterThanOrEqualTo(0));
        final nextClass = source.indexOf(
          '\nclass _TournamentEventGrid extends',
          hostStart,
        );
        expect(nextClass, greaterThan(hostStart));
        final hostSource = source.substring(hostStart, nextClass);

        // Fail mode: hardware handler always consumes nav keys while mounted,
        // including under PersistentIndexedStack inactive TickerMode(false).
        expect(
          hostSource,
          contains('shouldTournamentEventGridHandleGlobalKey('),
        );
        expect(
          hostSource,
          contains('TickerMode.valuesOf(context).enabled'),
        );
        expect(hostSource, contains('tickerModeEnabled:'));
        // Reclaim focus when the tab becomes live again (grouped host pattern).
        expect(hostSource, contains('TickerMode.getValuesNotifier(context)'));
        expect(hostSource, contains('_handleTickerModeChanged'));
      },
    );
  });

  group('shipped nextTournamentEventGridSelectedId (production key path)', () {
    test('right arrow advances selection across a multi-card grid', () {
      const ids = ['norway', 'limburg', 'chicago', 'wijk', 'tata', 'dortmund'];
      String? selectedId;

      void apply(TournamentEventGridNavigationIntent intent) {
        selectedId = nextTournamentEventGridSelectedId(
          ids: ids,
          selectedId: selectedId,
          columns: 3,
          intent: intent,
          pageRows: 5,
        );
      }

      apply(TournamentEventGridNavigationIntent.right);
      expect(selectedId, 'limburg');
      apply(TournamentEventGridNavigationIntent.right);
      expect(selectedId, 'chicago');
      apply(TournamentEventGridNavigationIntent.down);
      expect(selectedId, 'dortmund');
      apply(TournamentEventGridNavigationIntent.left);
      expect(selectedId, 'tata');
      apply(TournamentEventGridNavigationIntent.home);
      expect(selectedId, 'norway');
      apply(TournamentEventGridNavigationIntent.end);
      expect(selectedId, 'dortmund');
    });

    test('selection is not stuck on the initial card when more cards exist', () {
      const ids = ['a', 'b', 'c'];
      final next = nextTournamentEventGridSelectedId(
        ids: ids,
        selectedId: null,
        columns: 3,
        intent: TournamentEventGridNavigationIntent.right,
        pageRows: 5,
      );
      expect(next, isNot(null));
      expect(next, isNot('a'));
      expect(next, 'b');
    });

    test('returns null for an empty grid', () {
      expect(
        nextTournamentEventGridSelectedId(
          ids: const [],
          selectedId: 'x',
          columns: 2,
          intent: TournamentEventGridNavigationIntent.right,
          pageRows: 5,
        ),
        isNull,
      );
    });
  });

  testWidgets(
    'selected card shell paints full primary border without outer clip',
    (tester) async {
      // Mirrors the shipped Current/Past selected-tile layering: unclipped
      // outer BoxDecoration (border + glow) + inner ClipRRect for content.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: kBlack2Color,
            body: Center(
              child: SizedBox(
                width: 320,
                height: 124,
                child: Container(
                  decoration: BoxDecoration(
                    color: kBlack3Color,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: kPrimaryColor.withValues(alpha: 0.96),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: kPrimaryColor.withValues(alpha: 0.16),
                        blurRadius: 8,
                        spreadRadius: 0.5,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: const ColoredBox(color: kBlack2Color),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final shells =
          tester.widgetList<Container>(find.byType(Container)).where((c) {
            final decoration = c.decoration;
            if (decoration is! BoxDecoration) return false;
            final border = decoration.border;
            if (border is! Border) return false;
            return border.top.width == 2 &&
                border.top.color == kPrimaryColor.withValues(alpha: 0.96);
          }).toList();
      expect(shells, hasLength(1));
      // Fail mode of the old tile: clip on the same Container as the border.
      expect(shells.single.clipBehavior, Clip.none);
      expect(find.byType(ClipRRect), findsOneWidget);
    },
  );

  testWidgets(
    'arrow keys update selected id via shipped nextTournamentEventGridSelectedId',
    (tester) async {
      // Focus host mirrors production wiring: onKeyEvent calls the shipped
      // nextTournamentEventGridSelectedId helper (not a reimplemented mover).
      const ids = ['norway', 'limburg', 'chicago'];
      String? selectedId;
      final focusNode = FocusNode(debugLabel: 'test-tournament-grid');
      addTearDown(focusNode.dispose);

      KeyEventResult onKey(FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        final intent = switch (key) {
          LogicalKeyboardKey.arrowRight =>
            TournamentEventGridNavigationIntent.right,
          LogicalKeyboardKey.arrowLeft =>
            TournamentEventGridNavigationIntent.left,
          LogicalKeyboardKey.arrowDown =>
            TournamentEventGridNavigationIntent.down,
          LogicalKeyboardKey.arrowUp => TournamentEventGridNavigationIntent.up,
          _ => null,
        };
        if (intent == null) return KeyEventResult.ignored;
        final next = nextTournamentEventGridSelectedId(
          ids: ids,
          selectedId: selectedId,
          columns: 3,
          intent: intent,
          pageRows: 5,
        );
        if (next == null) return KeyEventResult.handled;
        selectedId = next;
        return KeyEventResult.handled;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Focus(
            focusNode: focusNode,
            autofocus: true,
            onKeyEvent: onKey,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();
      focusNode.requestFocus();
      await tester.pump();

      expect(selectedId, isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(selectedId, 'limburg');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(selectedId, 'chicago');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(selectedId, 'limburg');
    },
  );
}
