/// Desktop freemium policy primitives.
///
/// Everything in this file is pure: no Riverpod reads, no IO, no
/// `BuildContext`. That is deliberate - the whole outcome matrix has to be
/// testable without a widget tree. The Riverpod wrappers live in
/// `desktop_access_providers.dart`, and the single evaluator that combines
/// these primitives with a request context lives in
/// `desktop_access_decision.dart`.
///
/// This is a CLIENT admission layer, not an authorization boundary. Server
/// entitlements and RLS remain authoritative; these checks exist so the app
/// never starts expensive work it is not allowed to finish, and so the user
/// sees an honest, specific reason when it stops.
library;

import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// The six outcomes a desktop access decision can produce.
///
/// Four of them used to be collapsed into two, which is how an outage ended up
/// rendering a purchase prompt. They stay distinct here on purpose:
///
/// * [allowed] - proceed.
/// * [checking] - entitlement is in flight. Show progress, not an upsell.
/// * [accountRequired] - a permanent (non-anonymous) account is needed. Only
///   purchasing and Botvinnik entry ever produce this; browsing, analysing and
///   the whole free quota work for guests.
/// * [premiumRequired] - the entitlement is KNOWN and does not cover this.
///   This is the only outcome that may show a purchase prompt.
/// * [quotaExceeded] - free tier is intact but this specific allowance is
///   spent. The decision carries the used/limit pair so the copy can name it.
/// * [temporarilyUnavailable] - we could not determine the answer (network,
///   parse, timeout, unknown usage). Show Retry. Never a purchase prompt: an
///   outage of ours is not the user's failure to pay.
enum DesktopAccess {
  allowed,
  checking,
  accountRequired,
  premiumRequired,
  quotaExceeded,
  temporarilyUnavailable,
}

/// Free tier: 3 favourite PLAYERS.
///
/// Spec: "desktopFreeFavoritePlayers = 3 // favourite EVENTS are unlimited".
/// Matches the shared mobile cap `kFreeFavoriteLimit`
/// (`lib/utils/favorite_constants.dart`), so the limit follows a user across
/// devices. Favourite events are not counted at all.
const int desktopFreeFavoritePlayers = 3;

/// Free tier: 3 cloud databases.
///
/// Spec: "desktopFreeCloudDatabases = 3 // includes the default personal
/// database; folders are unlimited and uncounted". Matches the shared mobile
/// cap `kFreeBookCreationLimit` (`lib/utils/library_utils.dart`). A followed
/// shared book is somebody else's database and is likewise uncounted, as is
/// the Likes collection (identified by its `is_liked_games` flag, never by its
/// display name).
const int desktopFreeCloudDatabases = 3;

/// Free tier: 10 saved games in the cloud, across every database.
///
/// Spec: "desktopFreeCloudSavedGames = 10 // across all databases; Likes rows
/// excluded". Matches the shared mobile cap `kFreeSavedGamesLimit`
/// (`lib/utils/library_utils.dart`). Ten total, not ten per folder.
const int desktopFreeCloudSavedGames = 10;

/// Free tier: opening-explorer statistics through 20 played plies, INCLUSIVE.
///
/// Spec: "desktopFreeExplorerPlies = 20". 20 played plies is the position
/// after Black's 10th move; that position is free. The position after the 21st
/// ply is Premium. See [desktopExplorerPositionIsFree] for the off-by-one that
/// was fixed here.
const int desktopFreeExplorerPlies = 20;

/// Free tier: one game report per UTC day, per NEW game fingerprint.
///
/// Spec: "desktopFreeGameReportsPerUtcDay = 1 // per NEW game fingerprint".
/// Re-opening or recomputing a report that already exists for the same game
/// does not spend the daily slot.
const int desktopFreeGameReportsPerUtcDay = 1;

/// Free tier: liked games from the last 7 LOCAL calendar days.
///
/// Spec: "desktopFreeLikesWindowDays = 7 // today + previous 6 LOCAL calendar
/// days". Deliberately not 168 hours and deliberately not UTC. See
/// [desktopFreeLikesWindowStart].
const int desktopFreeLikesWindowDays = 7;

/// How long a previously verified Premium entitlement keeps working while the
/// desktop app cannot reach the backend.
///
/// Bounded, account-bound, and additionally bounded by the entitlement expiry
/// that was known at verification time. An authoritative online `inactive`
/// result ends it immediately. Kept in sync with
/// `DesktopOfflineAccessCache.defaultGracePeriod` (asserted by a test rather
/// than imported, so this file stays free of IO dependencies).
const Duration desktopOfflineVerificationGrace = Duration(days: 14);

/// Sentinel for [DesktopAccessContext.entitlementGeneration] meaning "this
/// context makes no claim about which entitlement generation it was built
/// against", so the evaluator skips the staleness check instead of failing a
/// caller that simply did not stamp it.
const int desktopUnassertedGeneration = -1;

/// Whether work that was already admitted may run to completion.
///
/// A routine refresh (`isLoading`) on top of a still-valid known entitlement
/// is not a reason to tear down an open board or abort an in-flight save. An
/// explicit expiry, an error, or an account reset is.
bool desktopCanContinuePremiumWork(SubscriptionState state, {DateTime? now}) =>
    state.isSubscribed &&
    state.error == null &&
    (state.inBillingGracePeriod ||
        state.expirationDate == null ||
        state.expirationDate!.isAfter(now ?? DateTime.now()));

/// Reads the raw Premium signal out of [SubscriptionState].
///
/// Returns exactly one of [DesktopAccess.allowed], [DesktopAccess.checking],
/// [DesktopAccess.premiumRequired] or [DesktopAccess.temporarilyUnavailable].
/// It never returns [DesktopAccess.premiumRequired] for a failed lookup - an
/// unknown entitlement is [DesktopAccess.temporarilyUnavailable], because we
/// cannot tell a lapsed member from a lost connection and must not accuse the
/// user of the latter.
///
/// Offline grace is NOT applied here; it needs the account-bound cache record
/// and is layered on by `evaluateDesktopAccess`.
DesktopAccess desktopPremiumAccess(SubscriptionState state, {DateTime? now}) {
  if (state.isLoading) return DesktopAccess.checking;
  if (state.error != null) return DesktopAccess.temporarilyUnavailable;
  if (!state.isSubscribed) return DesktopAccess.premiumRequired;
  final expiry = state.expirationDate;
  if (!state.inBillingGracePeriod &&
      expiry != null &&
      !expiry.isAfter(now ?? DateTime.now())) {
    // Cancelled-but-not-lapsed stays Premium; the boundary itself is exclusive.
    return DesktopAccess.premiumRequired;
  }
  return DesktopAccess.allowed;
}

/// Whether [additions] more records fit under [limit] given [existing] records.
///
/// Zero additions ALWAYS fit. Editing, renaming, re-saving or exporting a
/// record does not claim a new slot, so a user who is over the limit after a
/// downgrade keeps full read/edit/remove/export access to what they already
/// have. Nothing is ever auto-deleted to get back under a cap.
bool desktopQuotaFits(int existing, int additions, int limit) =>
    existing >= 0 &&
    additions >= 0 &&
    (additions == 0 || existing + additions <= limit);

/// Whether an opening-explorer position at [playedPlies] is free.
///
/// OFF-BY-ONE, FIXED - DO NOT "CORRECT" THIS BACK. An earlier attempt wrote
/// `playedPlies + 1 <= 20`, which yields 19 free plies, and pinned that error
/// in a test. Statistics are free THROUGH 20 played plies inclusive (the
/// position after Black's 10th move). Ply 21 and deeper is Premium.
///
/// Callers holding the phone's one-indexed `currentMoveNumber` must pass
/// `currentMoveNumber - 1`.
bool desktopExplorerPositionIsFree(int playedPlies) =>
    playedPlies >= 0 && playedPlies <= desktopFreeExplorerPlies;

/// Composes explorer access out of the raw [premium] signal and the request.
///
/// Free: statistics for the opening 20 plies of an ordinary line, and every
/// personal board or FEN edit (moving pieces on your own board is never a
/// database query).
///
/// Premium: depth past ply 20, player-scoped preparation queries, and remote
/// exact-position search.
///
/// When the request is free the raw [premium] signal is irrelevant and the
/// result is [DesktopAccess.allowed] - a free position must not be blocked by
/// an entitlement that happens to be loading or unreachable.
DesktopAccess desktopExplorerAccess(
  DesktopAccess premium, {
  required int playedPlies,
  bool playerFilters = false,
  bool remoteExactPosition = false,
  bool personalPosition = false,
}) {
  if (personalPosition) return DesktopAccess.allowed;
  if (premium == DesktopAccess.allowed) return DesktopAccess.allowed;
  if (!playerFilters &&
      !remoteExactPosition &&
      desktopExplorerPositionIsFree(playedPlies)) {
    return DesktopAccess.allowed;
  }
  return premium;
}

/// First LOCAL calendar day inside the free Likes window: midnight local time,
/// [desktopFreeLikesWindowDays] - 1 days before [now]'s day.
///
/// Computed with calendar arithmetic (`DateTime(y, m, d - 6)`), not
/// `subtract(Duration(days: 6))`. Duration subtraction is absolute elapsed
/// time, so across a daylight-saving transition it lands at 23:00 or 01:00 on
/// the wrong side of a day boundary. Calendar arithmetic always returns local
/// midnight.
DateTime desktopFreeLikesWindowStart(
  DateTime now, {
  int windowDays = desktopFreeLikesWindowDays,
}) => DateTime(now.year, now.month, now.day - (windowDays - 1));

/// Whether a liked game saved at [likedAt] is inside the free window.
///
/// The window is today plus the previous six LOCAL calendar days, so a like
/// made at 23:50 six days ago is still free at 00:10 today, and a like made
/// seven days ago is Premium even if fewer than 168 hours have elapsed.
///
/// A future-dated row (clock skew between devices) counts as inside the
/// window: skew is our problem, not something to charge for. Likes outside the
/// window are never deleted, only gated.
bool desktopLikeIsInFreeWindow(
  DateTime likedAt, {
  required DateTime now,
  int windowDays = desktopFreeLikesWindowDays,
}) {
  final start = desktopFreeLikesWindowStart(now, windowDays: windowDays);
  final likedDay = DateTime(likedAt.year, likedAt.month, likedAt.day);
  return !likedDay.isBefore(start);
}

/// Whether a Miniatures game's content is free: only games dated TODAY.
///
/// Ported from mobile, including its deliberate MIXED frame: "today" is the
/// LOCAL calendar day of [now], while the game's day is its UTC calendar day
/// (miniature dates are stored as UTC dates). Mobile accepts `!isBefore`;
/// desktop additionally gates future-dated games, so only an exact match is
/// free.
///
/// An undated game is GATED (Premium), not Retry: mobile locks undated
/// games, and older, undated and future-dated content is all Premium.
bool desktopMiniatureIsInFreeWindow(DateTime? gameDate, {DateTime? now}) {
  if (gameDate == null) return false;
  final ref = now ?? DateTime.now();
  final todayStart = DateTime(ref.year, ref.month, ref.day);
  final utc = gameDate.toUtc();
  final gameDay = DateTime(utc.year, utc.month, utc.day);
  return gameDay == todayStart;
}

/// Thrown when a repository or service refuses work that needs Premium.
///
/// Callers convert this into a decision-driven surface; it exists so a guard
/// deep inside a repository can abort without importing any UI.
class DesktopPremiumRequiredException implements Exception {
  const DesktopPremiumRequiredException([this.reasonCode]);

  /// Stable machine-readable reason code, when one is known. Mirrors
  /// `DesktopAccessReason.code`.
  final String? reasonCode;

  @override
  String toString() =>
      'DesktopPremiumRequiredException('
      '${reasonCode ?? 'premium_required'})';
}
