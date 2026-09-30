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

/// [context] aimed at a game dated [gameDate].
///
/// Miniatures access is decided by the date of the game a request acts on. A
/// Miniatures context carried to another game (a board rail step, a drag
/// payload, a new tab or window) takes that game's date instead of keeping the
/// date it was built with, and an undated game clears it, so a request never
/// borrows today's date from the game it started on. Ownership of a retained
/// row never carries to another game either. Every other provenance is
/// returned unchanged: its gate does not depend on which game it acts on.
DesktopAccessContext retargetMiniatureAccessContext(
  DesktopAccessContext context,
  DateTime? gameDate,
) {
  if (context.feature != DesktopFeature.miniatures &&
      context.origin != DesktopDiscoveryOrigin.miniatures) {
    return context;
  }
  return DesktopAccessContext(
    feature: context.feature,
    action: context.action,
    origin: context.origin,
    contentDate: gameDate,
    playedPlies: context.playedPlies,
    filterCriteriaCount: context.filterCriteriaCount,
    sortKeyCount: context.sortKeyCount,
    playerScoped: context.playerScoped,
    accountId: context.accountId,
    entitlementGeneration: context.entitlementGeneration,
    quota: context.quota,
    additions: context.additions,
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
