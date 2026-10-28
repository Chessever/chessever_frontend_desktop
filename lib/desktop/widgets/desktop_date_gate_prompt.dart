import 'package:flutter/material.dart';

import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/paywall/premium_paywall_sheet.dart';

/// Resolves a date-window gate (Likes window, today-only Miniatures) for an
/// action the user just took.
///
/// [evaluate] is called now, at the moment of the action, and again after the
/// paywall closes, so a pane left open across midnight or a purchase made in
/// the sheet is judged by the current clock and entitlement.
///
/// * allowed: returns true.
/// * checking: progress copy, returns false. Never an upsell.
/// * premiumRequired: explains the specific rule ([title], [body]) and only
///   opens the paywall if the user asks for it.
/// * anything else: Retry copy, never a purchase prompt.
Future<bool> resolveDesktopDateGate(
  BuildContext context, {
  required DesktopAccessDecision Function() evaluate,
  required String title,
  required String body,
}) async {
  final decision = evaluate();
  switch (decision.outcome) {
    case DesktopAccess.allowed:
      return true;
    case DesktopAccess.checking:
      showDesktopToast(
        context,
        'Checking your membership. Try again in a moment.',
      );
      return false;
    case DesktopAccess.premiumRequired:
      final wantsPremium =
          await showDesktopDialog<bool>(
            context,
            builder: (_) => DesktopDateGateDialog(title: title, body: body),
          ) ??
          false;
      if (!wantsPremium || !context.mounted) return false;
      await showPremiumPaywallSheet(
        context: context,
        desktopDecision: decision,
      );
      if (!context.mounted) return false;
      return evaluate().isAllowed;
    case DesktopAccess.accountRequired:
    case DesktopAccess.quotaExceeded:
    case DesktopAccess.temporarilyUnavailable:
      showDesktopToast(
        context,
        "Couldn't confirm your membership. Check your connection and try again.",
        error: true,
      );
      return false;
  }
}

/// The explanation shown before any purchase prompt. Pops `true` when the
/// user asks to see Premium.
///
/// With an [actionLabel] the dialog answers an action the user already asked
/// for (an export that is partly free): that action is the primary button,
/// See Premium steps down to secondary, and the dismiss button cancels.
class DesktopDateGateDialog extends StatelessWidget {
  const DesktopDateGateDialog({
    super.key,
    required this.title,
    required this.body,
    this.premiumLabel = 'See Premium',
    this.dismissLabel = 'Not now',
    this.onDismiss,
    this.onPremium,
    this.actionLabel,
    this.onAction,
  }) : assert(
         (actionLabel == null) == (onAction == null),
         'actionLabel and onAction go together',
       );

  final String title;
  final String body;
  final String premiumLabel;
  final String dismissLabel;

  /// Defaults to popping `false`.
  final VoidCallback? onDismiss;

  /// Defaults to popping `true`.
  final VoidCallback? onPremium;

  /// The free part of the action the user asked for, drawn as the primary
  /// button. Null for a plain gate, where See Premium is the primary.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kDividerColor),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                // Wraps rather than overflows when the labels outgrow the
                // dialog's width; on one line it reads as an end-aligned row.
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 8,
                  children: [
                    DesktopDialogButton(
                      label: dismissLabel,
                      tone: DesktopDialogButtonTone.ghost,
                      onPress:
                          onDismiss ?? () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: 8),
                    DesktopDialogButton(
                      label: premiumLabel,
                      tone:
                          actionLabel == null
                              ? DesktopDialogButtonTone.primary
                              : DesktopDialogButtonTone.secondary,
                      onPress:
                          onPremium ?? () => Navigator.of(context).pop(true),
                    ),
                    if (actionLabel != null) ...[
                      const SizedBox(width: 8),
                      DesktopDialogButton(
                        label: actionLabel!,
                        tone: DesktopDialogButtonTone.primary,
                        onPress: onAction,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
