import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/utils/event_game_card_keyboard_navigation.dart';

void main() {
  group('moveEventGameCardFocus', () {
    const gameCounts = [2, 3, 0, 1];

    int gameCountForEvent(int index) => gameCounts[index];

    void expectFocus(
      EventGameCardFocus? focus, {
      required int eventIndex,
      required EventGameCardFocusColumn column,
      int gameIndex = 0,
    }) {
      expect(focus, isNotNull);
      expect(focus!.eventIndex, eventIndex);
      expect(focus.column, column);
      expect(focus.gameIndex, gameIndex);
    }

    test('page stride follows visible row count for tall For You rows', () {
      expect(
        eventGameCardPageStrideForViewport(
          viewportExtent: 720,
          rowExtent: 320,
          maxStride: 4,
        ),
        2,
      );
      expect(
        eventGameCardPageStrideForViewport(
          viewportExtent: 300,
          rowExtent: 320,
          maxStride: 4,
        ),
        1,
      );
      expect(
        eventGameCardPageStrideForViewport(
          viewportExtent: 2000,
          rowExtent: 120,
          maxStride: 4,
        ),
        4,
      );
    });

    test('down then up still lets right enter the first game card', () {
      var focus = const EventGameCardFocus(eventIndex: 0);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowDown,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.horizontalRow,
          )!;
      expectFocus(focus, eventIndex: 1, column: EventGameCardFocusColumn.event);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowUp,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.horizontalRow,
          )!;
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.event);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowRight,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.horizontalRow,
          )!;
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.game);
    });

    test('down selects and walks event cards in the event column', () {
      var focus = moveEventGameCardFocus(
        current: null,
        key: LogicalKeyboardKey.arrowDown,
        eventCount: gameCounts.length,
        gameCountForEvent: gameCountForEvent,
      );
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.event);

      focus = moveEventGameCardFocus(
        current: focus,
        key: LogicalKeyboardKey.arrowDown,
        eventCount: gameCounts.length,
        gameCountForEvent: gameCountForEvent,
      );
      expectFocus(focus, eventIndex: 1, column: EventGameCardFocusColumn.event);
    });

    test('vertical list movement steps through games and event cards', () {
      var focus = const EventGameCardFocus(eventIndex: 0);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowRight,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
          )!;
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.game);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowRight,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
          )!;
      expectFocus(
        focus,
        eventIndex: 0,
        column: EventGameCardFocusColumn.game,
        gameIndex: 1,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowDown,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
          )!;
      expectFocus(focus, eventIndex: 1, column: EventGameCardFocusColumn.event);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowLeft,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
          )!;
      expectFocus(focus, eventIndex: 1, column: EventGameCardFocusColumn.event);
    });

    test('vertical list up returns to the owning event before prior rows', () {
      var focus = const EventGameCardFocus(
        eventIndex: 0,
        column: EventGameCardFocusColumn.game,
        gameIndex: 1,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowUp,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
          )!;
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.game);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowUp,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
          )!;
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.event);
    });

    test('grid left moves to the adjacent game before the event card', () {
      var focus = const EventGameCardFocus(
        eventIndex: 0,
        column: EventGameCardFocusColumn.game,
        gameIndex: 1,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowLeft,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.grid,
            gameColumnCountForEvent: (_) => 2,
          )!;
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.game);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowLeft,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.grid,
            gameColumnCountForEvent: (_) => 2,
          )!;
      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.event);
    });

    test('grid up and down move by visual rows', () {
      var focus = const EventGameCardFocus(
        eventIndex: 1,
        column: EventGameCardFocusColumn.game,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowDown,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.grid,
            gameColumnCountForEvent: (_) => 2,
          )!;
      expectFocus(
        focus,
        eventIndex: 1,
        column: EventGameCardFocusColumn.game,
        gameIndex: 2,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowDown,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.grid,
            gameColumnCountForEvent: (_) => 2,
          )!;
      expectFocus(focus, eventIndex: 2, column: EventGameCardFocusColumn.event);
    });

    test('horizontal rows keep the same game column between events', () {
      var focus = const EventGameCardFocus(
        eventIndex: 0,
        column: EventGameCardFocusColumn.game,
        gameIndex: 1,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.arrowDown,
            eventCount: gameCounts.length,
            gameCountForEvent: gameCountForEvent,
            gameLayout: EventGameCardNavigationLayout.horizontalRow,
          )!;
      expectFocus(
        focus,
        eventIndex: 1,
        column: EventGameCardFocusColumn.game,
        gameIndex: 1,
      );
    });

    test('page keys jump event rows and clamp to list ends', () {
      var focus = const EventGameCardFocus(eventIndex: 0);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.pageDown,
            eventCount: 12,
            eventPageStride: 5,
            gameCountForEvent: (_) => 2,
          )!;
      expectFocus(focus, eventIndex: 5, column: EventGameCardFocusColumn.event);

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.pageDown,
            eventCount: 12,
            eventPageStride: 5,
            gameCountForEvent: (_) => 2,
          )!;
      expectFocus(
        focus,
        eventIndex: 10,
        column: EventGameCardFocusColumn.event,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.pageDown,
            eventCount: 12,
            eventPageStride: 5,
            gameCountForEvent: (_) => 2,
          )!;
      expectFocus(
        focus,
        eventIndex: 11,
        column: EventGameCardFocusColumn.event,
      );

      focus =
          moveEventGameCardFocus(
            current: focus,
            key: LogicalKeyboardKey.pageUp,
            eventCount: 12,
            eventPageStride: 5,
            gameCountForEvent: (_) => 2,
          )!;
      expectFocus(focus, eventIndex: 6, column: EventGameCardFocusColumn.event);
    });

    test('page keys in game column keep board focus when possible', () {
      final focus = moveEventGameCardFocus(
        current: const EventGameCardFocus(
          eventIndex: 1,
          column: EventGameCardFocusColumn.game,
          gameIndex: 2,
        ),
        key: LogicalKeyboardKey.pageDown,
        eventCount: 4,
        eventPageStride: 2,
        gameCountForEvent: gameCountForEvent,
        gameLayout: EventGameCardNavigationLayout.horizontalRow,
      );

      expectFocus(
        focus,
        eventIndex: 3,
        column: EventGameCardFocusColumn.game,
        gameIndex: 0,
      );
    });

    test('mixed arrows and page keys keep focus visible and reachable', () {
      EventGameCardFocus? focus = const EventGameCardFocus(eventIndex: 0);
      const eventCount = 12;
      const pageStride = 3;
      int gameCountForEveryEvent(int _) => 2;

      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.pageUp,
      ]) {
        focus = moveEventGameCardFocus(
          current: focus,
          key: key,
          eventCount: eventCount,
          eventPageStride: pageStride,
          gameCountForEvent: gameCountForEveryEvent,
          gameLayout: EventGameCardNavigationLayout.horizontalRow,
        );
        expect(focus, isNotNull);
        expect(focus!.eventIndex, inInclusiveRange(0, eventCount - 1));
      }

      expectFocus(focus, eventIndex: 0, column: EventGameCardFocusColumn.event);
    });

    test(
      'activation target distinguishes event list view from in-game view',
      () {
        expect(
          eventGameCardActivationTarget(
            const EventGameCardFocus(eventIndex: 0),
          ),
          EventGameCardActivationTarget.eventGameList,
        );
        expect(
          eventGameCardActivationTarget(
            const EventGameCardFocus(
              eventIndex: 0,
              column: EventGameCardFocusColumn.game,
            ),
          ),
          EventGameCardActivationTarget.inGameView,
        );
      },
    );
  });
}
