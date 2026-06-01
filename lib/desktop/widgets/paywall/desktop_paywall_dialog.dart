import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_subscription_view.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';

/// Desktop paywall dialog — kept as a thin wrapper around
/// [DesktopSubscriptionView] so any caller that still wants a modal (rather
/// than the full-page subscription screen) gets the same experience.
///
/// Returns `true` once an active subscription is observed, `false` if the
/// user dismissed without subscribing.
///
/// New desktop UX gates subscription at the door (see
/// [DesktopPremiumRequiredScreen]) and as the final onboarding step, so
/// this dialog is rarely the active surface — but the design is shared.
Future<bool> showDesktopPaywallDialog(
  BuildContext context, {
  required WidgetRef ref,
  String? reason,
}) async {
  final result = await showDesktopModal<bool>(
    context,
    maxWidth: 560,
    title: 'ChessEver Premium',
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
      child: DesktopSubscriptionView(
        reason: reason,
        onSubscribed: () => Navigator.of(ctx).pop(true),
      ),
    ),
  );
  return result == true;
}
