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
  int eventPageStride = 8,
}) {
  if (eventCount <= 0) return null;

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
    ),
  };
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
    return eventIndex + 1 < eventCount
        ? _eventFocus(eventIndex + 1)
        : _gameFocus(eventIndex, gameIndex);
  }
  return _gameFocus(eventIndex, gameIndex);
}
