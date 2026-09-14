import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/services/miniatures_access.dart';
import 'package:chessever/desktop/widgets/desktop_date_gate_prompt.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show openTournamentGameTab;
import 'package:chessever/repository/gamebase/miniatures/miniatures_order.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Title for the explanation shown when a miniature is not free to open.
String miniatureGateTitle(GamesTourModel game, {DateTime? now}) {
  final date = game.lastMoveTime;
  if (date == null) return 'Undated miniatures need Premium';
  return _isAfterToday(date, now ?? DateTime.now())
      ? 'Future-dated miniatures need Premium'
      : 'Older miniatures need Premium';
}

/// Body naming the exact rule and this game's day.
String miniatureGateBody(GamesTourModel game, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final date = game.lastMoveTime;
  if (date == null) {
    return 'This miniature has no date. Free opens only games dated today; '
        'Premium opens every day, including undated games.';
  }
  final label = formatMiniatureDayHeader(miniatureUtcDateKey(date), now: clock);
  final day = label == 'Yesterday' ? 'yesterday' : label;
  if (_isAfterToday(date, clock)) {
    return 'This game is dated $day, after today. Free opens only games '
        'dated today.';
  }
  return "This game is from $day. Free opens today's miniatures; Premium "
      'opens every day.';
}

bool _isAfterToday(DateTime gameDate, DateTime now) {
  final gameDay = miniatureUtcDayKey(gameDate)!;
  final today = now.year * 10000 + now.month * 100 + now.day;
  return gameDay > today;
}

/// Opens a miniature after checking access at the moment of the click.
///
/// Rendering never gates; this does. A denied open starts no work (no tab, no
/// PGN fetch). An allowed open hands the board only the miniatures that are
/// open right now, so stepping between games cannot cross the gate. The board
/// carries Miniatures provenance, so a rail step, a new tab, a detached window
/// or a restored tab is judged by the same date rule at the operation
/// boundary rather than as a free broadcast.
Future<void> openMiniatureGame(
  BuildContext context,
  WidgetRef ref,
  GamesTourModel game, {
  required String routeTitle,
  required List<GamesTourModel> routeGames,
}) async {
  DesktopAccessDecision evaluate() => miniatureGameDecision(
    game,
    DesktopAction.openContent,
    subscription: ref.read(subscriptionProvider),
    entitlement: ref.read(desktopEntitlementProvider),
  );

  final admitted = await resolveDesktopDateGate(
    context,
    evaluate: evaluate,
    title: miniatureGateTitle(game),
    body: miniatureGateBody(game),
  );
  if (!admitted || !context.mounted) return;

  final boardGames = openableMiniatureGames(
    routeGames,
    subscription: ref.read(subscriptionProvider),
    entitlement: ref.read(desktopEntitlementProvider),
  );
  await openTournamentGameTab(
    ref,
    game,
    game.tourSlug ?? routeTitle,
    routeTitle: routeTitle,
    routeGames: boardGames.isEmpty ? <GamesTourModel>[game] : boardGames,
    viewSource: ChessboardView.tour,
    accessContext: miniatureGameAccessContext(game, DesktopAction.openContent),
  );
}
