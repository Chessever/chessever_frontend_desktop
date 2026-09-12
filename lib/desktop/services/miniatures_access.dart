import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Request context for [action] on a game discovered through Miniatures.
///
/// The game's date is [GamesTourModel.lastMoveTime] (a UTC calendar day).
/// Only games dated TODAY are free; older, undated and future-dated games are
/// Premium. See `desktopMiniatureIsInFreeWindow`.
DesktopAccessContext miniatureGameAccessContext(
  GamesTourModel game,
  DesktopAction action,
) {
  return DesktopAccessContext(
    feature: DesktopFeature.miniatures,
    action: action,
    origin: DesktopDiscoveryOrigin.miniatures,
    contentDate: game.lastMoveTime,
  );
}

DesktopAccessDecision miniatureGameDecision(
  GamesTourModel game,
  DesktopAction action, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  return evaluateDesktopAccess(
    context: miniatureGameAccessContext(game, action),
    subscription: subscription,
    entitlement: entitlement,
    now: now,
  );
}

/// Whether a miniature card is drawn locked at rest: the entitlement is known
/// and the game is not dated today. A loading membership is not drawn locked.
bool miniatureGameIsLockedAtRest(
  GamesTourModel game, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  return miniatureGameDecision(
        game,
        DesktopAction.openContent,
        subscription: subscription,
        entitlement: entitlement,
        now: now,
      ).outcome ==
      DesktopAccess.premiumRequired;
}

/// The miniatures that may be opened RIGHT NOW, in order. Handed to the board
/// as its game list so stepping between games cannot cross the gate.
List<GamesTourModel> openableMiniatureGames(
  Iterable<GamesTourModel> games, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return [
    for (final game in games)
      if (miniatureGameDecision(
        game,
        DesktopAction.openContent,
        subscription: subscription,
        entitlement: entitlement,
        now: at,
      ).isAllowed)
        game,
  ];
}
