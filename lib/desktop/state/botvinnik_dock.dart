import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/state/botvinnik_chat.dart';

/// Default, lower and upper width of the Botvinnik dock. The user drags the
/// dock edge between the bounds; the default is only the first-open width.
const double kBotvinnikDockDefaultWidth = 420;
const double kBotvinnikDockMinWidth = 340;
const double kBotvinnikDockMaxWidth = 640;

@immutable
class BotvinnikDockState {
  const BotvinnikDockState({
    this.open = false,
    this.showingHistory = false,
    this.width = kBotvinnikDockDefaultWidth,
    this.focusRequest = 0,
  });

  final bool open;
  final bool showingHistory;
  final double width;

  /// Bumped whenever something asks for the composer to take focus.
  final int focusRequest;

  BotvinnikDockState copyWith({
    bool? open,
    bool? showingHistory,
    double? width,
    int? focusRequest,
  }) {
    return BotvinnikDockState(
      open: open ?? this.open,
      showingHistory: showingHistory ?? this.showingHistory,
      width: width ?? this.width,
      focusRequest: focusRequest ?? this.focusRequest,
    );
  }
}

/// Visibility of the shell-level Botvinnik dock. The dock sits beside the tab
/// stack, so switching or closing tabs never touches the conversation.
class BotvinnikDockNotifier extends StateNotifier<BotvinnikDockState> {
  BotvinnikDockNotifier() : super(const BotvinnikDockState());

  void open() {
    state = state.copyWith(open: true, focusRequest: state.focusRequest + 1);
  }

  void close() => state = state.copyWith(open: false);

  void toggle() => state.open ? close() : open();

  void showHistory(bool value) => state = state.copyWith(showingHistory: value);

  void setWidth(double width) {
    state = state.copyWith(
      width: width.clamp(kBotvinnikDockMinWidth, kBotvinnikDockMaxWidth),
    );
  }

  void requestComposerFocus() {
    state = state.copyWith(focusRequest: state.focusRequest + 1);
  }
}

final botvinnikDockProvider =
    StateNotifierProvider<BotvinnikDockNotifier, BotvinnikDockState>(
      (ref) => BotvinnikDockNotifier(),
    );

/// Opens the dock from a contextual launch (Events, a tournament, a player).
///
/// A launch with a new [screenContext] starts a fresh conversation about that
/// screen, the way the phone app does. The composer draft is never cleared.
void openBotvinnikDock(WidgetRef ref, {ChatScreenContext? screenContext}) {
  final chat = ref.read(botvinnikChatControllerProvider.notifier);
  if (screenContext != null) {
    final current = ref.read(botvinnikChatControllerProvider);
    final changed =
        !botvinnikSameScreenContext(current.screenContext, screenContext);
    if (changed && !current.sending) {
      chat.setScreenContext(screenContext);
      if (current.messages.isNotEmpty) chat.startNewConversation();
    }
  }
  ref.read(botvinnikDockProvider.notifier).open();
  final quota = ref.read(botvinnikQuotaProvider.notifier);
  if (chat.hasPermanentSession) quota.refresh();
}

/// Sidebar entry: toggles the dock without changing what it is about.
void toggleBotvinnikDock(WidgetRef ref) {
  final dock = ref.read(botvinnikDockProvider.notifier);
  final wasOpen = ref.read(botvinnikDockProvider).open;
  dock.toggle();
  if (!wasOpen) {
    final chat = ref.read(botvinnikChatControllerProvider.notifier);
    if (chat.hasPermanentSession) {
      ref.read(botvinnikQuotaProvider.notifier).refresh();
    }
  }
}

bool botvinnikSameScreenContext(ChatScreenContext? a, ChatScreenContext? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return mapEquals(a.toJson(), b.toJson());
}

/// Context sent when Botvinnik is launched from the Events home.
const ChatScreenContext botvinnikHomeScreenContext = ChatScreenContext(
  screen: 'home',
);

/// Context for a tournament detail launch. [eventId] is the group broadcast
/// id; the tour fields describe the tour currently selected inside it.
ChatScreenContext botvinnikTournamentScreenContext({
  required String eventId,
  required String eventName,
  String? tournamentId,
  String? tournamentName,
}) {
  String? clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  return ChatScreenContext(
    screen: 'tournament',
    eventId: eventId,
    eventName: eventName,
    tournamentId: clean(tournamentId),
    tournamentName: clean(tournamentName),
  );
}

/// Context for a player profile launch. The id preference matches the phone
/// app: FIDE id, then the gamebase player id, then the memorial route id.
ChatScreenContext botvinnikPlayerScreenContext({
  required String playerName,
  int? fideId,
  String? gamebasePlayerId,
  String? memorialRouteId,
}) {
  String? clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  final fide = fideId != null && fideId > 0 ? fideId.toString() : null;
  return ChatScreenContext(
    screen: 'player',
    playerId: fide ?? clean(gamebasePlayerId) ?? clean(memorialRouteId),
    playerName: clean(playerName),
  );
}
