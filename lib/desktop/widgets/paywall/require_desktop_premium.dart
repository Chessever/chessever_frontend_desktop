import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/paywall/desktop_paywall_dialog.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// Returns true if the desktop user has an active subscription. Otherwise
/// shows the desktop paywall and returns whether the user converted.
///
/// Use at the *start* of any premium-only desktop action:
/// ```dart
/// if (!await requireDesktopPremium(context, ref, reason: '...')) return;
/// ```
Future<bool> requireDesktopPremium(
  BuildContext context,
  WidgetRef ref, {
  String? reason,
}) async {
  if (ref.read(subscriptionProvider).isSubscribed) return true;
  if (!context.mounted) return false;
  return showDesktopPaywallDialog(context, ref: ref, reason: reason);
}
