import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/widgets/desktop_date_gate_prompt.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show openTournamentGameTab;
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Provenance of a game opened from the community ranking [query].
///
/// Only a one-day ranking carries its day; a week, month or year ranking
/// carries none, which the policy reads as Premium. So the context is the
/// same for every game in one ranking, and stepping between them on the board
/// cannot cross the gate.
DesktopAccessContext communityLikesAccessContext(
  CommunityLikesQuery query,
  DesktopAction action,
) {
  return DesktopAccessContext(
    feature: DesktopFeature.communityLikes,
    action: action,
    origin: DesktopDiscoveryOrigin.communityLikes,
    contentDate:
        query.period == CommunityLikesPeriod.today ? query.start : null,
  );
}

DesktopAccessDecision communityLikesOpenDecision(
  CommunityLikesQuery query, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  return evaluateDesktopAccess(
    context: communityLikesAccessContext(query, DesktopAction.openContent),
    subscription: subscription,
    entitlement: entitlement,
    now: now,
  );
}

/// Whether this ranking's cards are drawn locked at rest. A loading
/// membership is not drawn locked.
bool communityLikesLockedAtRest(
  CommunityLikesQuery query, {
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  return communityLikesOpenDecision(
        query,
        subscription: subscription,
        entitlement: entitlement,
        now: now,
      ).outcome ==
      DesktopAccess.premiumRequired;
}

/// Opens a ranked game after checking access at the moment of the click. A
/// denied open starts no work (no tab, no PGN fetch).
Future<void> openCommunityLikesGame(
  BuildContext context,
  WidgetRef ref,
  GamesTourModel game, {
  required CommunityLikesQuery query,
  required List<GamesTourModel> routeGames,
}) async {
  final now = DateTime.now();
  final admitted = await resolveDesktopDateGate(
    context,
    evaluate:
        () => communityLikesOpenDecision(
          query,
          subscription: ref.read(subscriptionProvider),
          entitlement: ref.read(desktopEntitlementProvider),
        ),
    title:
        query.period == CommunityLikesPeriod.today
            ? 'Earlier days need Premium'
            : '${query.period.label} rankings need Premium',
    body:
        query.period == CommunityLikesPeriod.today
            ? 'This game ranked on ${query.label(now)}. Free opens games '
                "from today's ranking; Premium opens every day."
            : 'Browsing every ranking is free. Free opens games from '
                "today's ranking; Premium opens every week, month and year.",
  );
  if (!admitted || !context.mounted) return;

  final routeTitle = 'Likes · ${query.label(now)}';
  await openTournamentGameTab(
    ref,
    game,
    game.eventName ?? game.tourName ?? routeTitle,
    routeTitle: routeTitle,
    routeGames: routeGames.isEmpty ? <GamesTourModel>[game] : routeGames,
    viewSource: ChessboardView.tour,
    accessContext: communityLikesAccessContext(
      query,
      DesktopAction.openContent,
    ),
  );
}
