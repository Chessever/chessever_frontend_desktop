import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Client UX policy, not a replacement for server authorization/RLS.
enum DesktopAccess { allowed, checking, unavailable, premiumRequired }

const desktopFreeFavoritePlayers = 3;
const desktopFreeCloudGames = 10;
const desktopFreeCloudDatabases = 3;
// Phone uses a one-indexed ply position, not a full-move count.
const desktopFreeExplorerPosition = 20;

/// Existing admitted work may finish while a routine refresh is checking.
/// It cannot survive an explicit expiry, error, or account reset.
bool desktopCanContinuePremiumWork(SubscriptionState state, {DateTime? now}) =>
    state.isSubscribed &&
    state.error == null &&
    (state.inBillingGracePeriod ||
        state.expirationDate == null ||
        state.expirationDate!.isAfter(now ?? DateTime.now()));

DesktopAccess desktopPremiumAccess(SubscriptionState state, {DateTime? now}) {
  if (state.isLoading) return DesktopAccess.checking;
  if (state.error != null) return DesktopAccess.unavailable;
  if (!state.isSubscribed) return DesktopAccess.premiumRequired;
  final expiry = state.expirationDate;
  if (!state.inBillingGracePeriod &&
      expiry != null &&
      !expiry.isAfter(now ?? DateTime.now())) {
    return DesktopAccess.premiumRequired;
  }
  return DesktopAccess.allowed;
}

bool desktopQuotaFits(int existing, int additions, int limit) =>
    existing >= 0 &&
    additions >= 0 &&
    (additions == 0 || existing + additions <= limit);

bool desktopExplorerPositionIsFree(int playedPlies) =>
    playedPlies >= 0 && playedPlies + 1 <= desktopFreeExplorerPosition;

DesktopAccess desktopExplorerAccess(
  DesktopAccess premium, {
  required int playedPlies,
  bool preparation = false,
  bool exactPosition = false,
}) {
  if (premium == DesktopAccess.allowed) return premium;
  if (!preparation &&
      !exactPosition &&
      desktopExplorerPositionIsFree(playedPlies)) {
    return DesktopAccess.allowed;
  }
  return premium;
}

final desktopPremiumAccessProvider = Provider<DesktopAccess>(
  (ref) => desktopPremiumAccess(ref.watch(subscriptionProvider)),
);

class DesktopPremiumRequiredException implements Exception {
  const DesktopPremiumRequiredException();
  @override
  String toString() => 'Premium is required. Verify your membership and retry.';
}
