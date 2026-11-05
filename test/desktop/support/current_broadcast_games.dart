import 'package:chessever/desktop/auth/desktop_past_event_access.dart';

/// Layout, routing and live-update fixtures represent current broadcasts.
/// Resolve their access synchronously without contacting the event service.
/// Archived-game admission is covered by web_past_event_access_test.dart.
final currentBroadcastGames = desktopGameIsPastProvider.overrideWith(
  (_, _) => false,
);
