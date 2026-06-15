import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';

/// SharedPreferences key for "Remind me later" snooze.
const _kBillingIssueSnoozeKey = 'desktop_billing_issue_snoozed_until_ms';

/// How long to suppress the dialog after it closes (any way: button, Esc,
/// click-outside). Matches the mobile sheet so a user with both apps isn't
/// double-prompted on the same calendar day.
const _kSnoozeDuration = Duration(hours: 24);

/// chessever.com/account — the web surface that signs the user in and opens
/// the Stripe customer portal with a valid web return URL. The portal can't
/// be opened from the desktop app directly because it needs an http(s)
/// return_url, which a chessever:// deep link can't satisfy (same reasoning
/// as the Settings pane's manage-subscription flow).
final Uri _kAccountUrl = Uri.https('chessever.com', '/account');

/// Show the desktop billing-issue dialog. Returns `true` when the user
/// took the fix-payment action, `false` otherwise.
Future<bool> showDesktopBillingIssueDialog(
  BuildContext context, {
  required DateTime? expirationDate,
  required String? provider,
}) async {
  final result = await showDesktopModal<bool>(
    context,
    maxWidth: 480,
    title: 'Payment failed',
    builder: (ctx) => _BillingIssueBody(
      expirationDate: expirationDate,
      provider: provider,
    ),
  );
  return result == true;
}

/// Mount this near the desktop shell root. Watches the subscription state
/// and pops the billing-issue dialog when the user enters the grace window,
/// then snoozes for 24h once the dialog closes. Renders the [child]
/// unchanged.
class DesktopBillingIssueGate extends HookConsumerWidget {
  const DesktopBillingIssueGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<SubscriptionState>(subscriptionProvider, (prev, next) {
      final wasInGrace = prev?.inBillingGracePeriod ?? false;
      if (wasInGrace) return;
      if (!next.inBillingGracePeriod) return;
      if (!next.isSubscribed) return;
      if (kDebugMode) return;
      unawaited(_maybeShow(context, next));
    });

    final didCheckOnMount = useRef(false);
    final state = ref.read(subscriptionProvider);
    if (!didCheckOnMount.value &&
        state.isSubscribed &&
        state.inBillingGracePeriod &&
        !kDebugMode) {
      didCheckOnMount.value = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_maybeShow(context, state));
      });
    }

    return child;
  }

  Future<void> _maybeShow(BuildContext context, SubscriptionState state) async {
    final prefs = await SharedPreferences.getInstance();
    final snoozedUntilMs = prefs.getInt(_kBillingIssueSnoozeKey) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < snoozedUntilMs) return;
    if (!context.mounted) return;
    await showDesktopBillingIssueDialog(
      context,
      expirationDate: state.expirationDate,
      provider: state.provider,
    );
    // Snooze regardless of HOW the dialog closed — Esc and click-outside
    // skip the button handlers, and without this the dialog would re-fire
    // on the next launch.
    final next = DateTime.now().add(_kSnoozeDuration).millisecondsSinceEpoch;
    await prefs.setInt(_kBillingIssueSnoozeKey, next);
  }
}

class _BillingIssueBody extends StatelessWidget {
  const _BillingIssueBody({
    required this.expirationDate,
    required this.provider,
  });

  final DateTime? expirationDate;
  final String? provider;

  /// Stripe subs are fixable from here (chessever.com/account opens the
  /// Stripe customer portal with a valid web return URL). Store-billed subs
  /// (apple/google/revenuecat) can only be fixed on the device that owns
  /// the store account — desktop can't deep-link a phone, so we instruct
  /// instead of pretending a web page would help.
  bool get _isStripe => provider == 'stripe';

  String _bodyCopy() {
    if (!_isStripe) {
      final store = provider == 'google' ? 'Google Play' : 'the App Store';
      return "We couldn't process your latest ChessEver Premium payment. "
          'Your subscription is billed through $store — open the subscription '
          'settings on your phone to update your payment method before your '
          'Premium access ends.';
    }
    final exp = expirationDate;
    if (exp == null) {
      return "We couldn't process your latest ChessEver Premium payment. "
          'Update your card at chessever.com/account to keep your '
          'subscription active.';
    }
    final daysLeft = exp.difference(DateTime.now()).inDays;
    if (daysLeft <= 0) {
      return "We couldn't process your latest ChessEver Premium payment. "
          'Update your card at chessever.com/account to keep your Premium '
          'benefits.';
    }
    if (daysLeft == 1) {
      return "We couldn't process your latest ChessEver Premium payment. "
          "You'll lose Premium access tomorrow unless you update your card.";
    }
    return "We couldn't process your latest ChessEver Premium payment. "
        "You'll lose Premium access in $daysLeft days unless you update your card.";
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.credit_card_off_rounded,
                color: kPrimaryColor,
                size: 28,
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Update your payment method',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _bodyCopy(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 24),
          if (_isStripe) ...[
            DesktopDialogButton(
              label: 'Update on chessever.com',
              tone: DesktopDialogButtonTone.primary,
              fillWidth: true,
              onPress: () {
                Navigator.of(context).pop(true);
                unawaited(
                  launchUrl(_kAccountUrl, mode: LaunchMode.externalApplication),
                );
              },
            ),
            const SizedBox(height: 8),
            DesktopDialogButton(
              label: 'Remind me later',
              tone: DesktopDialogButtonTone.ghost,
              fillWidth: true,
              onPress: () => Navigator.of(context).pop(false),
            ),
          ] else
            DesktopDialogButton(
              label: 'Got it',
              tone: DesktopDialogButtonTone.primary,
              fillWidth: true,
              onPress: () => Navigator.of(context).pop(false),
            ),
        ],
      ),
    );
  }
}
