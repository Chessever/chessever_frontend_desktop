import 'package:flutter/services.dart';

enum EventGameCardFocusColumn { event, game }

enum EventGameCardNavigationLayout { verticalList, horizontalRow, grid }

enum EventGameCardActivationTarget { eventGameList, inGameView }

int eventGameCardPageStrideForViewport({
  required double viewportExtent,
  required double rowExtent,
  int fallback = 1,
  int maxStride = 8,
}) {
  if (viewportExtent <= 0 || rowExtent <= 0) {
    return fallback.clamp(1, maxStride).toInt();
  }
  return (viewportExtent / rowExtent).floor().clamp(1, maxStride).toInt();
}

class EventGameCardFocus {
  const EventGameCardFocus({
    required this.eventIndex,
    this.column = EventGameCardFocusColumn.event,
    this.gameIndex = 0,
  });

  final int eventIndex;
  final EventGameCardFocusColumn column;
  final int gameIndex;

  bool get isEvent => column == EventGameCardFocusColumn.event;
  bool get isGame => column == EventGameCardFocusColumn.game;

  EventGameCardFocus copyWith({
    int? eventIndex,
    EventGameCardFocusColumn? column,
    int? gameIndex,
  }) {
    return EventGameCardFocus(
      eventIndex: eventIndex ?? this.eventIndex,
      column: column ?? this.column,
      gameIndex: gameIndex ?? this.gameIndex,
    );
  }
}

EventGameCardActivationTarget eventGameCardActivationTarget(
  EventGameCardFocus focus,
) {
  return focus.isGame
      ? EventGameCardActivationTarget.inGameView
      : EventGameCardActivationTarget.eventGameList;
}

EventGameCardFocus? moveEventGameCardFocus({
  required EventGameCardFocus? current,
  required LogicalKeyboardKey key,
  required int eventCount,
  required int Function(int eventIndex) gameCountForEvent,
  EventGameCardNavigationLayout gameLayout =
      EventGameCardNavigationLayout.verticalList,
  int Function(int eventIndex)? gameColumnCountForEvent,
  int eventColumnCount = 1,
  int eventPageStride = 8,
  bool preferGameCards = false,
  bool hierarchicalGroups = false,
}) {
  if (eventCount <= 0) return null;

  if (hierarchicalGroups) {
    return _moveHierarchicalGroupFocus(
      current: current,
      key: key,
      eventCount: eventCount,
      gameCountForEvent: gameCountForEvent,
      gameColumnCountForEvent: gameColumnCountForEvent,
      eventPageStride: eventPageStride,
    );
  }

  if (preferGameCards) {
    return _moveGameOnlyFocus(
      current: current,
      key: key,
      eventCount: eventCount,
      gameCountForEvent: gameCountForEvent,
      gameColumnCountForEvent: gameColumnCountForEvent,
      eventColumnCount: eventColumnCount,
      eventPageStride: eventPageStride,
    );
  }

  if (current == null) {
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end) {
      return EventGameCardFocus(
        eventIndex: key == LogicalKeyboardKey.end ? eventCount - 1 : 0,
      );
    }
    return null;
  }

  final eventIndex = _clampInt(current.eventIndex, 0, eventCount - 1);
  final gameCount = _clampInt(gameCountForEvent(eventIndex), 0, 1000000);
  final gameIndex =
      gameCount <= 0 ? 0 : _clampInt(current.gameIndex, 0, gameCount - 1);
  final pageStride = _clampInt(eventPageStride, 1, eventCount);
  final eventColumns = _clampInt(eventColumnCount, 1, eventCount);

  EventGameCardFocus pageEventFocus(int targetEventIndex) {
    final clampedEventIndex = _clampInt(targetEventIndex, 0, eventCount - 1);
    if (current.isGame) {
      final targetGameCount = _clampInt(
        gameCountForEvent(clampedEventIndex),
        0,
        1000000,
      );
      if (targetGameCount > 0) {
        return _gameFocus(
          clampedEventIndex,
          _clampInt(gameIndex, 0, targetGameCount - 1),
        );
      }
    }
    return _eventFocus(clampedEventIndex);
  }

  if (key == LogicalKeyboardKey.pageDown) {
    return pageEventFocus(eventIndex + pageStride);
  }
  if (key == LogicalKeyboardKey.pageUp) {
    return pageEventFocus(eventIndex - pageStride);
  }

  if (current.isEvent) {
    if (eventColumns > 1) {
      final eventColumn = eventIndex % eventColumns;
      if (key == LogicalKeyboardKey.arrowRight) {
        final target = eventIndex + 1;
        return eventColumn + 1 < eventColumns && target < eventCount
            ? current.copyWith(eventIndex: target, gameIndex: 0)
            : current.copyWith(eventIndex: eventIndex, gameIndex: 0);
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        return eventColumn > 0
            ? current.copyWith(eventIndex: eventIndex - 1, gameIndex: 0)
            : current.copyWith(eventIndex: eventIndex, gameIndex: 0);
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        if (gameCount > 0) {
          return current.copyWith(
            eventIndex: eventIndex,
            column: EventGameCardFocusColumn.game,
            gameIndex: 0,
          );
        }
        return current.copyWith(
          eventIndex: _clampInt(eventIndex + eventColumns, 0, eventCount - 1),
          gameIndex: 0,
        );
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        return current.copyWith(
          eventIndex: _clampInt(eventIndex - eventColumns, 0, eventCount - 1),
          gameIndex: 0,
        );
      }
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      return current.copyWith(
        eventIndex: _clampInt(eventIndex + 1, 0, eventCount - 1),
        gameIndex: 0,
      );
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      return current.copyWith(
        eventIndex: _clampInt(eventIndex - 1, 0, eventCount - 1),
        gameIndex: 0,
      );
    }
    if (key == LogicalKeyboardKey.home) {
      return current.copyWith(eventIndex: 0, gameIndex: 0);
    }
    if (key == LogicalKeyboardKey.end) {
      return current.copyWith(eventIndex: eventCount - 1, gameIndex: 0);
    }
    if (key == LogicalKeyboardKey.arrowRight && gameCount > 0) {
      return current.copyWith(
        eventIndex: eventIndex,
        column: EventGameCardFocusColumn.game,
        gameIndex: 0,
      );
    }
    return current.copyWith(eventIndex: eventIndex, gameIndex: 0);
  }

  if (gameCount <= 0) {
    return current.copyWith(
      eventIndex: eventIndex,
      column: EventGameCardFocusColumn.event,
      gameIndex: 0,
    );
  }

  if (key == LogicalKeyboardKey.home) {
    return current.copyWith(eventIndex: eventIndex, gameIndex: 0);
  }
  if (key == LogicalKeyboardKey.end) {
    return current.copyWith(eventIndex: eventIndex, gameIndex: gameCount - 1);
  }

  return switch (gameLayout) {
    EventGameCardNavigationLayout.verticalList => _moveVerticalGameFocus(
      eventIndex: eventIndex,
      eventCount: eventCount,
      gameIndex: gameIndex,
      gameCount: gameCount,
      key: key,
    ),
    EventGameCardNavigationLayout.horizontalRow => _moveHorizontalGameFocus(
      eventIndex: eventIndex,
      eventCount: eventCount,
      gameIndex: gameIndex,
      gameCount: gameCount,
      key: key,
      gameCountForEvent: gameCountForEvent,
    ),
    EventGameCardNavigationLayout.grid => _moveGridGameFocus(
      eventIndex: eventIndex,
      eventCount: eventCount,
      gameIndex: gameIndex,
      gameCount: gameCount,
      key: key,
      gameColumnCount:
          gameColumnCountForEvent == null
              ? 1
              : gameColumnCountForEvent(eventIndex),
      eventColumnCount: eventColumns,
    ),
  };
}

EventGameCardFocus _moveHierarchicalGroupFocus({
  required EventGameCardFocus? current,
  required LogicalKeyboardKey key,
  required int eventCount,
  required int Function(int eventIndex) gameCountForEvent,
  required int Function(int eventIndex)? gameColumnCountForEvent,
  required int eventPageStride,
}) {
  int gameCountAt(int eventIndex) =>
      _clampInt(gameCountForEvent(eventIndex), 0, 1000000);

  if (current == null) return _eventFocus(0);
  final eventIndex = _clampInt(current.eventIndex, 0, eventCount - 1);
  final pageStride = _clampInt(eventPageStride, 1, eventCount);

  if (key == LogicalKeyboardKey.home) return _eventFocus(0);
  if (key == LogicalKeyboardKey.end) {
    final lastEvent = eventCount - 1;
    final lastGameCount = gameCountAt(lastEvent);
    return lastGameCount > 0
        ? _gameFocus(lastEvent, lastGameCount - 1)
        : _eventFocus(lastEvent);
  }
  if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.pageDown) {
    final direction = key == LogicalKeyboardKey.pageUp ? -1 : 1;
    return _eventFocus(
      _clampInt(eventIndex + direction * pageStride, 0, eventCount - 1),
    );
  }

  if (current.isEvent) {
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      final gameCount = gameCountAt(eventIndex);
      if (gameCount > 0) return _gameFocus(eventIndex, 0);
      if (key == LogicalKeyboardKey.arrowRight) {
        return _eventFocus(eventIndex);
      }
      return eventIndex + 1 < eventCount
          ? _eventFocus(eventIndex + 1)
          : _eventFocus(eventIndex);
    }
    if (key == LogicalKeyboardKey.arrowUp && eventIndex > 0) {
      final previousEvent = eventIndex - 1;
      final previousGameCount = gameCountAt(previousEvent);
      return previousGameCount > 0
          ? _gameFocus(previousEvent, previousGameCount - 1)
          : _eventFocus(previousEvent);
    }
    return _eventFocus(eventIndex);
  }

  final gameCount = gameCountAt(eventIndex);
  if (gameCount <= 0) return _eventFocus(eventIndex);
  final gameIndex = _clampInt(current.gameIndex, 0, gameCount - 1);
  if (key == LogicalKeyboardKey.arrowLeft) {
    return gameIndex > 0
        ? _gameFocus(eventIndex, gameIndex - 1)
        : _eventFocus(eventIndex);
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    return gameIndex + 1 < gameCount
        ? _gameFocus(eventIndex, gameIndex + 1)
        : _gameFocus(eventIndex, gameIndex);
  }

  final columns = _clampInt(
    gameColumnCountForEvent == null ? 1 : gameColumnCountForEvent(eventIndex),
    1,
    gameCount,
  );
  if (key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown) {
    final direction = key == LogicalKeyboardKey.arrowUp ? -1 : 1;
    final preferredColumn = gameIndex % columns;
    for (
      var targetEvent = eventIndex + direction;
      targetEvent >= 0 && targetEvent < eventCount;
      targetEvent += direction
    ) {
      final targetCount = gameCountAt(targetEvent);
      if (targetCount > 0) {
        return _gameFocus(
          targetEvent,
          _clampInt(preferredColumn, 0, targetCount - 1),
        );
      }
    }
  }
  return _gameFocus(eventIndex, gameIndex);
}

EventGameCardFocus? _moveGameOnlyFocus({
  required EventGameCardFocus? current,
  required LogicalKeyboardKey key,
  required int eventCount,
  required int Function(int eventIndex) gameCountForEvent,
  required int Function(int eventIndex)? gameColumnCountForEvent,
  required int eventColumnCount,
  required int eventPageStride,
}) {
  int gameCountAt(int index) {
    if (index < 0 || index >= eventCount) return 0;
    return _clampInt(gameCountForEvent(index), 0, 1000000);
  }

  int? findEventWithGames(int start, int step) {
    if (step == 0) return null;
    for (var index = start; index >= 0 && index < eventCount; index += step) {
      if (gameCountAt(index) > 0) return index;
    }
    return null;
  }

  EventGameCardFocus? firstOrLastGame({required bool last}) {
    final eventIndex = findEventWithGames(
      last ? eventCount - 1 : 0,
      last ? -1 : 1,
    );
    if (eventIndex == null) return null;
    return _gameFocus(eventIndex, last ? gameCountAt(eventIndex) - 1 : 0);
  }

  if (current == null || current.isEvent) {
    if (key == LogicalKeyboardKey.end) {
      return firstOrLastGame(last: true);
    }
    if (current != null) {
      final eventIndex = _clampInt(current.eventIndex, 0, eventCount - 1);
      if (gameCountAt(eventIndex) > 0) return _gameFocus(eventIndex, 0);
    }
    return firstOrLastGame(last: false);
  }

  var eventIndex = _clampInt(current.eventIndex, 0, eventCount - 1);
  var gameCount = gameCountAt(eventIndex);
  if (gameCount <= 0) {
    final replacement =
        findEventWithGames(eventIndex, 1) ??
        findEventWithGames(eventIndex - 1, -1);
    if (replacement == null) return null;
    eventIndex = replacement;
    gameCount = gameCountAt(eventIndex);
  }
  final gameIndex = _clampInt(current.gameIndex, 0, gameCount - 1);
  final eventColumns = _clampInt(eventColumnCount, 1, eventCount);
  final pageStride = _clampInt(eventPageStride, 1, eventCount);
  final gameColumns = _clampInt(
    gameColumnCountForEvent == null ? 1 : gameColumnCountForEvent(eventIndex),
    1,
    gameCount,
  );
  final gameColumn = gameIndex % gameColumns;

  if (key == LogicalKeyboardKey.home) {
    return firstOrLastGame(last: false);
  }
  if (key == LogicalKeyboardKey.end) {
    return firstOrLastGame(last: true);
  }
  if (key == LogicalKeyboardKey.pageUp || key == LogicalKeyboardKey.pageDown) {
    final direction = key == LogicalKeyboardKey.pageUp ? -1 : 1;
    final target = _clampInt(
      eventIndex + pageStride * direction,
      0,
      eventCount - 1,
    );
    final targetEvent =
        findEventWithGames(target, direction) ??
        findEventWithGames(target - direction, -direction);
    if (targetEvent == null) return _gameFocus(eventIndex, gameIndex);
    final targetCount = gameCountAt(targetEvent);
    return _gameFocus(targetEvent, _clampInt(gameIndex, 0, targetCount - 1));
  }

  if (key == LogicalKeyboardKey.arrowLeft) {
    if (gameColumn > 0) return _gameFocus(eventIndex, gameIndex - 1);
    if (eventIndex % eventColumns == 0) {
      return _gameFocus(eventIndex, gameIndex);
    }
    final previousEvent = findEventWithGames(eventIndex - 1, -1);
    if (previousEvent == null ||
        previousEvent ~/ eventColumns != eventIndex ~/ eventColumns) {
      return _gameFocus(eventIndex, gameIndex);
    }
    return _gameFocus(previousEvent, gameCountAt(previousEvent) - 1);
  }

  if (key == LogicalKeyboardKey.arrowRight) {
    if (gameColumn + 1 < gameColumns && gameIndex + 1 < gameCount) {
      return _gameFocus(eventIndex, gameIndex + 1);
    }
    final atLastEventColumn = eventIndex % eventColumns == eventColumns - 1;
    if (atLastEventColumn || eventIndex + 1 >= eventCount) {
      return _gameFocus(eventIndex, gameIndex);
    }
    final nextEvent = findEventWithGames(eventIndex + 1, 1);
    if (nextEvent == null ||
        nextEvent ~/ eventColumns != eventIndex ~/ eventColumns) {
      return _gameFocus(eventIndex, gameIndex);
    }
    return _gameFocus(nextEvent, 0);
  }

  if (key == LogicalKeyboardKey.arrowUp) {
    final target = gameIndex - gameColumns;
    if (target >= 0) return _gameFocus(eventIndex, target);
    for (
      var targetEvent = eventIndex - eventColumns;
      targetEvent >= 0;
      targetEvent -= eventColumns
    ) {
      final targetCount = gameCountAt(targetEvent);
      if (targetCount > 0) {
        return _gameFocus(
          targetEvent,
          _clampInt(gameColumn, 0, targetCount - 1),
        );
      }
    }
    return _gameFocus(eventIndex, gameIndex);
  }

  if (key == LogicalKeyboardKey.arrowDown) {
    final target = gameIndex + gameColumns;
    if (target < gameCount) return _gameFocus(eventIndex, target);
    for (
      var targetEvent = eventIndex + eventColumns;
      targetEvent < eventCount;
      targetEvent += eventColumns
    ) {
      final targetCount = gameCountAt(targetEvent);
      if (targetCount > 0) {
        return _gameFocus(
          targetEvent,
          _clampInt(gameColumn, 0, targetCount - 1),
        );
      }
    }
  }
  return _gameFocus(eventIndex, gameIndex);
}

EventGameCardFocus _eventFocus(int eventIndex) {
  return EventGameCardFocus(eventIndex: eventIndex);
}

EventGameCardFocus _gameFocus(int eventIndex, int gameIndex) {
  return EventGameCardFocus(
    eventIndex: eventIndex,
    column: EventGameCardFocusColumn.game,
    gameIndex: gameIndex,
  );
}

int _clampInt(int value, int min, int max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

EventGameCardFocus _moveVerticalGameFocus({
  required int eventIndex,
  required int eventCount,
  required int gameIndex,
  required int gameCount,
  required LogicalKeyboardKey key,
}) {
  if (key == LogicalKeyboardKey.arrowLeft) {
    return _eventFocus(eventIndex);
  }
  if (key == LogicalKeyboardKey.arrowUp) {
    if (gameIndex <= 0) return _eventFocus(eventIndex);
    return _gameFocus(eventIndex, gameIndex - 1);
  }
  if (key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.arrowDown) {
    if (gameIndex + 1 < gameCount) {
      return _gameFocus(eventIndex, gameIndex + 1);
    }
    return eventIndex + 1 < eventCount
        ? _eventFocus(eventIndex + 1)
        : _gameFocus(eventIndex, gameCount - 1);
  }
  return _gameFocus(eventIndex, gameIndex);
}

EventGameCardFocus _moveHorizontalGameFocus({
  required int eventIndex,
  required int eventCount,
  required int gameIndex,
  required int gameCount,
  required LogicalKeyboardKey key,
  required int Function(int eventIndex) gameCountForEvent,
}) {
  if (key == LogicalKeyboardKey.arrowLeft) {
    if (gameIndex <= 0) return _eventFocus(eventIndex);
    return _gameFocus(eventIndex, gameIndex - 1);
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    if (gameIndex + 1 < gameCount) {
      return _gameFocus(eventIndex, gameIndex + 1);
    }
    return eventIndex + 1 < eventCount
        ? _eventFocus(eventIndex + 1)
        : _gameFocus(eventIndex, gameCount - 1);
  }
  if (key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown) {
    final nextEventIndex =
        key == LogicalKeyboardKey.arrowUp ? eventIndex - 1 : eventIndex + 1;
    if (nextEventIndex < 0 || nextEventIndex >= eventCount) {
      return _gameFocus(eventIndex, gameIndex);
    }
    final nextGameCount = _clampInt(
      gameCountForEvent(nextEventIndex),
      0,
      1000000,
    );
    if (nextGameCount <= 0) return _eventFocus(nextEventIndex);
    return _gameFocus(
      nextEventIndex,
      _clampInt(gameIndex, 0, nextGameCount - 1),
    );
  }
  return _gameFocus(eventIndex, gameIndex);
}

EventGameCardFocus _moveGridGameFocus({
  required int eventIndex,
  required int eventCount,
  required int gameIndex,
  required int gameCount,
  required LogicalKeyboardKey key,
  required int gameColumnCount,
  required int eventColumnCount,
}) {
  final columns = _clampInt(gameColumnCount, 1, gameCount);
  final column = gameIndex % columns;

  if (key == LogicalKeyboardKey.arrowLeft) {
    if (column <= 0) return _eventFocus(eventIndex);
    return _gameFocus(eventIndex, gameIndex - 1);
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    if (column + 1 < columns && gameIndex + 1 < gameCount) {
      return _gameFocus(eventIndex, gameIndex + 1);
    }
    return _gameFocus(eventIndex, gameIndex);
  }
  if (key == LogicalKeyboardKey.arrowUp) {
    final target = gameIndex - columns;
    if (target < 0) return _eventFocus(eventIndex);
    return _gameFocus(eventIndex, target);
  }
  if (key == LogicalKeyboardKey.arrowDown) {
    final target = gameIndex + columns;
    if (target < gameCount) return _gameFocus(eventIndex, target);
    return eventIndex + eventColumnCount < eventCount
        ? _eventFocus(eventIndex + eventColumnCount)
        : _gameFocus(eventIndex, gameIndex);
  }
  return _gameFocus(eventIndex, gameIndex);
}
