import 'package:flutter/foundation.dart' show immutable;

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// Stable, machine-readable reason behind a decision.
///
/// [code] is the wire value for analytics and the key actionable UI copy is
/// chosen by. Renaming an enum member must never change a [code].
enum DesktopAccessReason {
  allowedFree('allowed_free'),
  allowedPremium('allowed_premium'),
  allowedOfflineGrace('allowed_offline_grace'),
  allowedOwnedDocument('allowed_owned_document'),
  allowedWithinFreeQuota('allowed_within_free_quota'),
  allowedNoNewSlot('allowed_no_new_slot'),
  allowedAccountPresent('allowed_account_present'),
  allowedDataStewardship('allowed_data_stewardship'),
  entitlementChecking('entitlement_checking'),
  accountRequiredForPurchase('account_required_purchase'),
  accountRequiredForBotvinnik('account_required_botvinnik'),
  premiumPaidSource('premium_paid_source'),
  premiumPrepareTarget('premium_prepare_target'),
  premiumPrepareSource('premium_prepare_source'),
  premiumPrepareComputed('premium_prepare_computed'),
  premiumEngineTournament('premium_engine_tournament'),
  premiumOpeningTreeBuild('premium_opening_tree_build'),
  premiumOpeningTreeExplore('premium_opening_tree_explore'),
  premiumExplorerDepth('premium_explorer_depth'),
  premiumExplorerPlayerScope('premium_explorer_player_scope'),
  premiumExplorerExactPosition('premium_explorer_exact_position'),
  premiumProfileFilterCombination('premium_profile_filter_combination'),
  premiumProfileBulkOperation('premium_profile_bulk'),
  premiumStructuredFilter('premium_structured_filter'),
  premiumStructuredSort('premium_structured_sort'),
  premiumMultiKeySort('premium_multi_key_sort'),
  premiumLocalPositionQuery('premium_local_position_query'),
  premiumLikesOutsideWindow('premium_likes_outside_window'),
  premiumMiniatureNotToday('premium_miniature_not_today'),
  quotaFavoritePlayers('quota_favorite_players'),
  quotaCloudDatabases('quota_cloud_databases'),
  quotaCloudSavedGames('quota_cloud_saved_games'),
  quotaGameReportsPerUtcDay('quota_game_reports_daily'),
  entitlementUnknown('entitlement_unknown'),
  usageUnknown('usage_unknown'),
  contentDateUnknown('content_date_unknown'),
  explorerDepthUnknown('explorer_depth_unknown'),
  staleEntitlement('stale_entitlement');

  const DesktopAccessReason(this.code);

  final String code;
}

/// Used/limit for one allowance, so copy can say "10 of 10 saved games used"
/// instead of a generic wall.
@immutable
class DesktopQuotaCapacity {
  const DesktopQuotaCapacity({
    required this.quota,
    required this.used,
    required this.limit,
    required this.requested,
  });

  final DesktopQuota quota;
  final int used;
  final int limit;

  /// New records the request asked for.
  final int requested;

  /// Slots left on the free tier; zero when at or over the limit (an
  /// over-limit account after a downgrade reports zero, never negative).
  int get remaining => used >= limit ? 0 : limit - used;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopQuotaCapacity &&
          other.quota == quota &&
          other.used == used &&
          other.limit == limit &&
          other.requested == requested;

  @override
  int get hashCode => Object.hash(quota, used, limit, requested);

  @override
  String toString() => '$used of $limit ${quota.name} (+$requested)';
}

/// The result of [evaluateDesktopAccess].
@immutable
class DesktopAccessDecision {
  const DesktopAccessDecision(this.outcome, this.reason, {this.capacity});

  final DesktopAccess outcome;
  final DesktopAccessReason reason;

  /// Present for quota-bearing requests whose usage was measured.
  final DesktopQuotaCapacity? capacity;

  bool get isAllowed => outcome == DesktopAccess.allowed;

  /// The context was built for a different account or entitlement generation.
  /// The caller must abort silently (the user logged out or switched accounts
  /// mid-flight) or rebuild the context, never retry the original request.
  bool get isStale => reason == DesktopAccessReason.staleEntitlement;

  /// Whether this outcome may open a purchase prompt, and then only on an
  /// explicit user action. Everything else shows progress, a sign-in ask or
  /// Retry.
  bool get mayOfferPurchase =>
      outcome == DesktopAccess.premiumRequired ||
      outcome == DesktopAccess.quotaExceeded;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopAccessDecision &&
          other.outcome == outcome &&
          other.reason == reason &&
          other.capacity == capacity;

  @override
  int get hashCode => Object.hash(outcome, reason, capacity);

  @override
  String toString() =>
      'DesktopAccessDecision(${outcome.name}, ${reason.code}'
      '${capacity == null ? '' : ', $capacity'})';
}

/// Free-tier limit for [quota], or null for [DesktopQuota.none].
int? desktopFreeLimitFor(DesktopQuota quota) {
  switch (quota) {
    case DesktopQuota.none:
      return null;
    case DesktopQuota.favoritePlayers:
      return desktopFreeFavoritePlayers;
    case DesktopQuota.cloudDatabases:
      return desktopFreeCloudDatabases;
    case DesktopQuota.cloudSavedGames:
      return desktopFreeCloudSavedGames;
    case DesktopQuota.gameReportsPerUtcDay:
      return desktopFreeGameReportsPerUtcDay;
  }
}

/// The single desktop access evaluator. Every entry point calls this.
///
/// Pure: no Riverpod, no IO, no `BuildContext`, and [now] is injectable, so
/// the whole matrix is unit-testable. Resolution order:
///
/// 1. Staleness. A context stamped for another account or generation is
///    rejected before anything else.
/// 2. Data stewardship. Removing, tagging, stopping and recovering are never
///    gated anywhere.
/// 3. Account-bound features. Purchasing and Botvinnik entry need a permanent
///    account. Nothing else does.
/// 4. The request's own requirement: free, Premium (by feature rule, by
///    provenance, by depth, scope, filters or date window), or blocked on
///    missing input. Feature rules (Prepare, tournaments, trees, explorer,
///    local files, structured database filters, the Likes window) apply even
///    to data the user owns; ownership only neutralises PROVENANCE gates.
/// 5. Premium requirements resolve against the entitlement, with the bounded
///    offline grace applied only when the live entitlement is unknown.
/// 6. Quota-bearing requests resolve against measured usage. Premium lifts
///    every quota; an unknown entitlement over the free limit is Retry, not an
///    upsell.
DesktopAccessDecision evaluateDesktopAccess({
  required DesktopAccessContext context,
  required SubscriptionState subscription,
  required DesktopEntitlementSnapshot entitlement,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();

  if (!entitlement.isCurrentFor(context)) {
    return const DesktopAccessDecision(
      DesktopAccess.temporarilyUnavailable,
      DesktopAccessReason.staleEntitlement,
    );
  }

  if (desktopNeverGatedActions.contains(context.action)) {
    return const DesktopAccessDecision(
      DesktopAccess.allowed,
      DesktopAccessReason.allowedDataStewardship,
    );
  }

  if (context.feature == DesktopFeature.purchase ||
      context.feature == DesktopFeature.botvinnik) {
    if (!entitlement.hasPermanentAccount) {
      return DesktopAccessDecision(
        DesktopAccess.accountRequired,
        context.feature == DesktopFeature.purchase
            ? DesktopAccessReason.accountRequiredForPurchase
            : DesktopAccessReason.accountRequiredForBotvinnik,
      );
    }
    return const DesktopAccessDecision(
      DesktopAccess.allowed,
      DesktopAccessReason.allowedAccountPresent,
    );
  }

  final requirement = _requirementFor(context, at);
  final premium = _premiumStatus(subscription, entitlement, at);

  final blocked = requirement.blocked;
  if (blocked != null) {
    // Missing input (a Likes date, an explorer depth) only matters when it
    // would decide between free and Premium. A member is covered either way.
    if (premium.outcome == DesktopAccess.allowed) {
      return DesktopAccessDecision(DesktopAccess.allowed, premium.reason);
    }
    return DesktopAccessDecision(blocked, requirement.reason);
  }

  if (requirement.premium) {
    switch (premium.outcome) {
      case DesktopAccess.allowed:
        return DesktopAccessDecision(DesktopAccess.allowed, premium.reason);
      case DesktopAccess.checking:
        return const DesktopAccessDecision(
          DesktopAccess.checking,
          DesktopAccessReason.entitlementChecking,
        );
      case DesktopAccess.premiumRequired:
        return DesktopAccessDecision(
          DesktopAccess.premiumRequired,
          requirement.reason,
        );
      case DesktopAccess.accountRequired:
      case DesktopAccess.quotaExceeded:
      case DesktopAccess.temporarilyUnavailable:
        return const DesktopAccessDecision(
          DesktopAccess.temporarilyUnavailable,
          DesktopAccessReason.entitlementUnknown,
        );
    }
  }

  final quota = context.effectiveQuota;
  if (quota == DesktopQuota.none) {
    return DesktopAccessDecision(DesktopAccess.allowed, requirement.reason);
  }
  return _quotaDecision(context, quota, entitlement.usage, premium);
}

class _Requirement {
  const _Requirement.free([this.reason = DesktopAccessReason.allowedFree])
    : premium = false,
      blocked = null;
  const _Requirement.premium(this.reason) : premium = true, blocked = null;
  const _Requirement.blocked(DesktopAccess this.blocked, this.reason)
    : premium = false;

  final bool premium;
  final DesktopAccess? blocked;
  final DesktopAccessReason reason;
}

const _free = _Requirement.free();
const _owned = _Requirement.free(DesktopAccessReason.allowedOwnedDocument);

/// Paid sources let anyone see a static preview and use ordinary list
/// controls. Every locked content action is Premium: opening a full game,
/// interactive preview navigation, fetching its PGN, inserting moves,
/// copying, saving, sharing and exporting (and editing, sourcing, computing
/// and bulk operations on content that is not yet unlocked).
const Set<DesktopAction> _paidSourceFreeActions = {
  DesktopAction.view,
  DesktopAction.sort,
  DesktopAction.filter,
};

const Set<DesktopDiscoveryOrigin> _paidOrigins = {
  DesktopDiscoveryOrigin.gamebase,
  DesktopDiscoveryOrigin.twic,
  DesktopDiscoveryOrigin.countrymen,
  DesktopDiscoveryOrigin.smartCollection,
  DesktopDiscoveryOrigin.playerProfile,
};

_Requirement _requirementFor(DesktopAccessContext context, DateTime now) {
  // Likes: the 7-day window decides, and owning the like row does NOT
  // short-circuit it (every like is an owned saved row).
  if (context.feature == DesktopFeature.likes ||
      context.origin == DesktopDiscoveryOrigin.likes) {
    return _likesRequirement(context, now);
  }

  switch (context.feature) {
    case DesktopFeature.prepare:
      return _prepareRequirement(context.action);
    case DesktopFeature.engineTournament:
      return _engineTournamentRequirement(context.action);
    case DesktopFeature.openingTree:
      return _openingTreeRequirement(context.action);
    case DesktopFeature.openingExplorer:
      return _explorerRequirement(context);
    case DesktopFeature.localFiles:
      return _localFilesRequirement(context);
    case DesktopFeature.miniatures:
      return _miniatureRequirement(context, now);

    case DesktopFeature.ownedDocument:
    case DesktopFeature.sharedBook:
      // Structured filters and non-default sorts are Premium even on data
      // the user owns. Text search and tags are free (callers pass 0
      // criteria for text search).
      if (context.action == DesktopAction.filter &&
          context.filterCriteriaCount > 0) {
        return const _Requirement.premium(
          DesktopAccessReason.premiumStructuredFilter,
        );
      }
      if (context.action == DesktopAction.sort) {
        return const _Requirement.premium(
          DesktopAccessReason.premiumStructuredSort,
        );
      }
      return _provenanceRequirement(context, now);

    case DesktopFeature.gamebase:
    case DesktopFeature.twic:
    case DesktopFeature.countrymen:
    case DesktopFeature.smartCollection:
      if (context.ownershipCovers) return _owned;
      return _paidSourceFreeActions.contains(context.action)
          ? _free
          : const _Requirement.premium(DesktopAccessReason.premiumPaidSource);

    case DesktopFeature.playerProfile:
      if (context.action == DesktopAction.bulkSelect) {
        return const _Requirement.premium(
          DesktopAccessReason.premiumProfileBulkOperation,
        );
      }
      if (context.action == DesktopAction.filter &&
          context.filterCriteriaCount >= 2) {
        return const _Requirement.premium(
          DesktopAccessReason.premiumProfileFilterCombination,
        );
      }
      if (context.ownershipCovers) return _owned;
      return _paidSourceFreeActions.contains(context.action)
          ? _free
          : const _Requirement.premium(DesktopAccessReason.premiumPaidSource);

    case DesktopFeature.broadcast:
    case DesktopFeature.favorites:
    case DesktopFeature.gameReport:
    case DesktopFeature.botvinnik:
    case DesktopFeature.purchase:
    case DesktopFeature.likes:
      // Free surfaces. Favourites and reports spend quota (resolved after
      // this). Botvinnik and purchase were resolved before this switch, and
      // likes above it. Content keeps the gate of wherever it was found.
      return _provenanceRequirement(context, now);
  }
}

/// Provenance follows the content: a game found through a paid origin or in
/// Miniatures keeps that gate on any surface it is carried to (a board tab,
/// a detached window, restored state). Ownership of the retained row is the
/// one thing that neutralises a provenance gate.
_Requirement _provenanceRequirement(DesktopAccessContext context, DateTime now) {
  if (context.origin == DesktopDiscoveryOrigin.miniatures) {
    return _miniatureRequirement(context, now);
  }
  if (_paidOrigins.contains(context.origin)) {
    if (context.ownershipCovers) return _owned;
    if (_paidSourceFreeActions.contains(context.action)) return _free;
    // Favouriting a player found on a profile is a favourites quota
    // decision; a report is a daily-report quota decision.
    if (_isQuotaOnlyFeature(context.feature) &&
        context.effectiveQuota != DesktopQuota.none) {
      return _free;
    }
    return const _Requirement.premium(DesktopAccessReason.premiumPaidSource);
  }
  return context.ownershipCovers ? _owned : _free;
}

bool _isQuotaOnlyFeature(DesktopFeature feature) =>
    feature == DesktopFeature.favorites ||
    feature == DesktopFeature.gameReport;

/// Free regardless of the window: seeing, sorting and filtering the
/// collection, and liking a game. (Tagging and removing are never gated.)
const Set<DesktopAction> _likesFreeActions = {
  DesktopAction.view,
  DesktopAction.sort,
  DesktopAction.filter,
  DesktopAction.create,
  DesktopAction.bulkSelect,
};

_Requirement _likesRequirement(DesktopAccessContext context, DateTime now) {
  if (_likesFreeActions.contains(context.action)) return _free;
  final likedAt = context.contentDate;
  if (likedAt == null) {
    return const _Requirement.blocked(
      DesktopAccess.temporarilyUnavailable,
      DesktopAccessReason.contentDateUnknown,
    );
  }
  return desktopLikeIsInFreeWindow(likedAt, now: now)
      ? _free
      : const _Requirement.premium(
          DesktopAccessReason.premiumLikesOutsideWindow,
        );
}

/// Free: browsing, sorting and filtering the About, Players and Games
/// metadata. Every content action needs a game dated today; an undated game
/// is Premium, not Retry.
_Requirement _miniatureRequirement(DesktopAccessContext context, DateTime now) {
  if (_paidSourceFreeActions.contains(context.action)) return _free;
  if (context.ownershipCovers) return _owned;
  return desktopMiniatureIsInFreeWindow(context.contentDate, now: now)
      ? _free
      : const _Requirement.premium(
          DesktopAccessReason.premiumMiniatureNotToday,
        );
}

/// Free: browse the saved roster, account metadata and retained game files;
/// rename, remove, export, cancel, recover. Premium: creating preparation
/// targets, connecting or importing new sources (download, sync, refresh,
/// reinstall), and computed statistics, comparisons, drilldowns and
/// combined-database generation.
_Requirement _prepareRequirement(DesktopAction action) {
  switch (action) {
    case DesktopAction.create:
      return const _Requirement.premium(
        DesktopAccessReason.premiumPrepareTarget,
      );
    case DesktopAction.acquireSource:
    case DesktopAction.fetchPgn:
      return const _Requirement.premium(
        DesktopAccessReason.premiumPrepareSource,
      );
    case DesktopAction.recompute:
      return const _Requirement.premium(
        DesktopAccessReason.premiumPrepareComputed,
      );
    case DesktopAction.view:
    case DesktopAction.openContent:
    case DesktopAction.previewNavigate:
    case DesktopAction.insertMove:
    case DesktopAction.copy:
    case DesktopAction.save:
    case DesktopAction.share:
    case DesktopAction.export:
    case DesktopAction.sort:
    case DesktopAction.filter:
    case DesktopAction.bulkSelect:
    case DesktopAction.edit:
    case DesktopAction.remove:
    case DesktopAction.cancel:
    case DesktopAction.tag:
      return _free;
  }
}

/// Engine tournaments: viewing and exporting results and stopping an active
/// run are free; creating, restarting and resuming are Premium. Single-engine
/// Play is a different surface and is not evaluated here.
_Requirement _engineTournamentRequirement(DesktopAction action) {
  return action == DesktopAction.create || action == DesktopAction.recompute
      ? const _Requirement.premium(DesktopAccessReason.premiumEngineTournament)
      : _free;
}

/// Opening trees: files and existing work are preserved and free to view,
/// export, rename and remove. Building or rebuilding a tree, and exploring
/// one interactively, are Premium.
const Set<DesktopAction> _openingTreeFreeActions = {
  DesktopAction.view,
  DesktopAction.export,
  DesktopAction.copy,
  DesktopAction.share,
  DesktopAction.sort,
  DesktopAction.edit,
};

_Requirement _openingTreeRequirement(DesktopAction action) {
  if (_openingTreeFreeActions.contains(action)) return _free;
  switch (action) {
    case DesktopAction.recompute:
    case DesktopAction.create:
    case DesktopAction.acquireSource:
      return const _Requirement.premium(
        DesktopAccessReason.premiumOpeningTreeBuild,
      );
    default:
      return const _Requirement.premium(
        DesktopAccessReason.premiumOpeningTreeExplore,
      );
  }
}

/// Local files: opening, importing, browsing, editing, appending, saving,
/// organising and text search are free, with no capacity limits. Structured
/// filters, multi-key sorts and position queries are Premium.
_Requirement _localFilesRequirement(DesktopAccessContext context) {
  switch (context.action) {
    case DesktopAction.filter:
      return context.filterCriteriaCount > 0
          ? const _Requirement.premium(
              DesktopAccessReason.premiumStructuredFilter,
            )
          : _free;
    case DesktopAction.sort:
      return context.sortKeyCount >= 2
          ? const _Requirement.premium(DesktopAccessReason.premiumMultiKeySort)
          : _free;
    case DesktopAction.acquireSource:
      return const _Requirement.premium(
        DesktopAccessReason.premiumLocalPositionQuery,
      );
    default:
      return _free;
  }
}

/// Opening explorer: only rendering (`view`) is unconditionally free.
/// Navigating, filtering or refreshing fetches statistics for a position and
/// goes through the ply check. General rating/year/result/time-control
/// filters are free; player scope and remote exact-position search are
/// Premium.
_Requirement _explorerRequirement(DesktopAccessContext context) {
  if (context.action == DesktopAction.view) return _free;
  if (context.playerScoped) {
    return const _Requirement.premium(
      DesktopAccessReason.premiumExplorerPlayerScope,
    );
  }
  if (context.action == DesktopAction.acquireSource) {
    return const _Requirement.premium(
      DesktopAccessReason.premiumExplorerExactPosition,
    );
  }
  final plies = context.playedPlies;
  if (plies == null) {
    return const _Requirement.blocked(
      DesktopAccess.temporarilyUnavailable,
      DesktopAccessReason.explorerDepthUnknown,
    );
  }
  return desktopExplorerPositionIsFree(plies)
      ? _free
      : const _Requirement.premium(DesktopAccessReason.premiumExplorerDepth);
}

/// The resolved Premium signal. [reason] names why Premium was granted
/// (live, continuing, offline grace) and is only read when [outcome] is
/// [DesktopAccess.allowed]; request-specific denial reasons come from the
/// request, not from here.
class _PremiumStatus {
  const _PremiumStatus(this.outcome, this.reason);
  final DesktopAccess outcome;
  final DesktopAccessReason reason;
}

_PremiumStatus _premiumStatus(
  SubscriptionState subscription,
  DesktopEntitlementSnapshot entitlement,
  DateTime now,
) {
  final live = desktopPremiumAccess(subscription, now: now);
  switch (live) {
    case DesktopAccess.allowed:
      return const _PremiumStatus(
        DesktopAccess.allowed,
        DesktopAccessReason.allowedPremium,
      );
    case DesktopAccess.checking:
      if (desktopCanContinuePremiumWork(subscription, now: now)) {
        return const _PremiumStatus(
          DesktopAccess.allowed,
          DesktopAccessReason.allowedPremium,
        );
      }
      return const _PremiumStatus(
        DesktopAccess.checking,
        DesktopAccessReason.entitlementChecking,
      );
    case DesktopAccess.temporarilyUnavailable:
      if (entitlement.offlineGrantsPremium(now)) {
        return const _PremiumStatus(
          DesktopAccess.allowed,
          DesktopAccessReason.allowedOfflineGrace,
        );
      }
      return const _PremiumStatus(
        DesktopAccess.temporarilyUnavailable,
        DesktopAccessReason.entitlementUnknown,
      );
    case DesktopAccess.premiumRequired:
    case DesktopAccess.accountRequired:
    case DesktopAccess.quotaExceeded:
      return const _PremiumStatus(
        DesktopAccess.premiumRequired,
        DesktopAccessReason.premiumPaidSource,
      );
  }
}

DesktopAccessDecision _quotaDecision(
  DesktopAccessContext context,
  DesktopQuota quota,
  DesktopUsage usage,
  _PremiumStatus premium,
) {
  final additions = context.additions;
  if (additions == 0 ||
      (quota == DesktopQuota.gameReportsPerUtcDay &&
          usage.existingReportForRequestedGame)) {
    return const DesktopAccessDecision(
      DesktopAccess.allowed,
      DesktopAccessReason.allowedNoNewSlot,
    );
  }
  if (premium.outcome == DesktopAccess.allowed) {
    return DesktopAccessDecision(DesktopAccess.allowed, premium.reason);
  }

  final used = usage.usedFor(quota);
  final limit = desktopFreeLimitFor(quota)!;
  if (used == null) {
    return const DesktopAccessDecision(
      DesktopAccess.temporarilyUnavailable,
      DesktopAccessReason.usageUnknown,
    );
  }
  final capacity = DesktopQuotaCapacity(
    quota: quota,
    used: used,
    limit: limit,
    requested: additions,
  );
  if (desktopQuotaFits(used, additions, limit)) {
    return DesktopAccessDecision(
      DesktopAccess.allowed,
      DesktopAccessReason.allowedWithinFreeQuota,
      capacity: capacity,
    );
  }

  switch (premium.outcome) {
    case DesktopAccess.premiumRequired:
      return DesktopAccessDecision(
        DesktopAccess.quotaExceeded,
        _quotaReason(quota),
        capacity: capacity,
      );
    case DesktopAccess.checking:
      // Premium may yet lift this; do not upsell a member mid-refresh.
      return DesktopAccessDecision(
        DesktopAccess.checking,
        DesktopAccessReason.entitlementChecking,
        capacity: capacity,
      );
    case DesktopAccess.allowed:
    case DesktopAccess.accountRequired:
    case DesktopAccess.quotaExceeded:
    case DesktopAccess.temporarilyUnavailable:
      // Over the free limit with an entitlement we could not read: we cannot
      // tell a member from a free user, so this is Retry, not a purchase.
      return DesktopAccessDecision(
        DesktopAccess.temporarilyUnavailable,
        DesktopAccessReason.entitlementUnknown,
        capacity: capacity,
      );
  }
}

DesktopAccessReason _quotaReason(DesktopQuota quota) {
  switch (quota) {
    case DesktopQuota.favoritePlayers:
      return DesktopAccessReason.quotaFavoritePlayers;
    case DesktopQuota.cloudDatabases:
      return DesktopAccessReason.quotaCloudDatabases;
    case DesktopQuota.cloudSavedGames:
      return DesktopAccessReason.quotaCloudSavedGames;
    case DesktopQuota.gameReportsPerUtcDay:
    case DesktopQuota.none:
      return DesktopAccessReason.quotaGameReportsPerUtcDay;
  }
}
