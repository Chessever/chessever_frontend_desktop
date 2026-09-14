import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/repository/freemium/freemium_quota.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/app_typography.dart';
import 'package:chessever/utils/favorite_constants.dart';
import 'package:chessever/utils/freemium_quota_guard.dart';
import 'package:chessever/widgets/paywall/premium_paywall_sheet.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Checks whether the user can add another favorite player.
///
/// Onboarding enforces a hard cap of [kFreeFavoriteLimit] with a friendly
/// "add more after signing in" toast, never a paywall, because there's no
/// account yet. In-app, the server decides (premium bypasses the cap) and a
/// spent allowance opens the paywall.
///
/// When [currentSelectedCount] is provided (e.g. during onboarding where
/// selections are local), it is used instead of the provider count.
Future<bool> canAddMoreFavorites(
  BuildContext context,
  WidgetRef ref, {
  bool isOnboarding = false,
  int? currentSelectedCount,
}) async {
  if (isOnboarding) {
    final currentCount = currentSelectedCount ?? 0;
    if (currentCount < kFreeFavoriteLimit) return true;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'You can follow more players after signing in',
            style: AppTypography.textSmRegular.copyWith(color: kWhiteColor),
          ),
          backgroundColor: kBlack2Color.withValues(alpha: 0.95),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return false;
  }

  if (currentSelectedCount != null) {
    // Local selections that have no server rows yet are counted here.
    if (ref.read(subscriptionProvider).isSubscribed) return true;
    if (currentSelectedCount < kFreeFavoriteLimit) return true;
    if (!context.mounted) return false;
    return showPremiumPaywallSheet(context: context);
  }

  // Server-authorized admission (check_freemium_quota): premium and the
  // canonical count are decided server-side, and a spent allowance opens the
  // paywall with its capacity. Unavailable is a Retry toast, never a paywall.
  final quota = await requestFreemiumQuota(
    context,
    FreemiumQuotaKind.favoritePlayers,
  );
  if (quota.isAllowed) return true;
  if (context.mounted && quota.outcome != FreemiumQuotaOutcome.quotaExceeded) {
    showDesktopToast(context, freemiumQuotaBlockedMessage(quota), error: true);
  }
  return false;
}
