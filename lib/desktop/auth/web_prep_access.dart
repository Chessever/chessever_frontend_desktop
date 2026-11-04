import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';

const webFreePrepOwnAccounts = 3;
const webFreePrepOpponents = 1;

const webPrepContentAccess = DesktopAccessContext(
  feature: DesktopFeature.prepare,
  action: DesktopAction.recompute,
  origin: DesktopDiscoveryOrigin.localFile,
);

/// A combined database is computed from existing sources, not another
/// account. Replacing/refreshing an existing source never spends a new slot.
int webPrepAccountCount(PlayerWorkspacePlayer player) =>
    player.allAccounts
        .where((account) => account.source != PlayerWorkspaceSource.combined)
        .length;

DesktopAccessReason? webPrepCapacityExceeded({
  required List<PlayerWorkspacePlayer> players,
  required PlayerWorkspacePlayer candidate,
  required String? ownPlayerId,
}) {
  final previous = players.where((p) => p.id == candidate.id).firstOrNull;
  if (candidate.id == ownPlayerId) {
    final before = previous == null ? 0 : webPrepAccountCount(previous);
    final after = webPrepAccountCount(candidate);
    return after > before && after > webFreePrepOwnAccounts
        ? DesktopAccessReason.quotaPrepOwnAccounts
        : null;
  }
  if (previous != null) return null;
  final opponents = players.where((p) => p.id != ownPlayerId).length;
  return opponents >= webFreePrepOpponents
      ? DesktopAccessReason.quotaPrepOpponents
      : null;
}

/// Enforced on the proposed workspace mutation, so typing multiple usernames
/// or entering through a player link cannot bypass phone-sized capacities.
bool admitWebPrepCapacity(
  ProviderContainer container,
  PlayerWorkspacePlayer candidate, {
  required bool ownProfile,
}) {
  if (!kIsWeb) return true;
  final owned = container.read(myPrepPlayerIdProvider);
  final players = container.read(playerWorkspaceProvider);
  final known = !players.isLoading && owned.hasValue;
  final reason =
      known
          ? webPrepCapacityExceeded(
            players: players.players,
            candidate: candidate,
            ownPlayerId: ownProfile ? candidate.id : owned.valueOrNull,
          )
          : DesktopAccessReason.usageUnknown;
  if (reason == null) return true;
  final premium = readDesktopAccess(container.read, webPrepContentAccess);
  if (premium.isAllowed) return true;
  final decision =
      reason == DesktopAccessReason.usageUnknown
          ? const DesktopAccessDecision(
            DesktopAccess.temporarilyUnavailable,
            DesktopAccessReason.usageUnknown,
          )
          : premium.mayOfferPurchase
          ? DesktopAccessDecision(DesktopAccess.quotaExceeded, reason)
          : premium;
  unawaited(
    presentDesktopAccessDecision(
      container,
      decision,
      context: webPrepContentAccess,
      surface: reason.code,
    ),
  );
  return false;
}
