import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_analytics.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_paywall_copy.dart';
import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing_provider.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';

/// One open paywall per window container. N simultaneous gate hits join it.
final Map<ProviderContainer, Future<bool>> _pendingDesktopPaywalls = {};

@visibleForTesting
int get debugPendingDesktopPaywallCount => _pendingDesktopPaywalls.length;

/// Test seam for the sign-in hand-off. Production calls the shared
/// `showAuthUpgradeSheet`, which opens desktop sign-in.
@visibleForTesting
Future<bool> Function(BuildContext context) debugDesktopPaywallSignIn =
    _sharedSignIn;

Future<bool> _sharedSignIn(BuildContext context) =>
    showAuthUpgradeSheet(context: context);

/// Presents a desktop access decision: pricing and checkout for
/// `premiumRequired` / `quotaExceeded`, sign-in for `accountRequired`, and
/// Retry (never pricing) for `checking` / `temporarilyUnavailable`.
///
/// Public entry point for every desktop gate (and for Botvinnik's
/// "See Premium").
///
/// * One dialog per [ProviderContainer]: concurrent calls share the first
///   call's future; later [resume]s are dropped.
/// * Resolves `true` only when a re-read of the live membership admits
///   [accessContext] (or, without one, Premium is verified active) for the
///   same account that started the flow. The dialog's own return value is
///   never trusted.
/// * [resume] runs at most once, after that verification, and only when its
///   `stillMatches` still holds. Nothing the caller had open (selection,
///   board position, draft, destination dialog) is touched.
Future<bool> showDesktopPaywall(
  BuildContext context,
  DesktopAccessDecision decision, {
  DesktopAccessContext? accessContext,
  DesktopAccessResume? resume,
  String surface = 'paywall',
}) {
  if (decision.isAllowed) return Future<bool>.value(true);
  if (decision.isStale) return Future<bool>.value(false);
  final container = ProviderScope.containerOf(context, listen: false);
  final pending = _pendingDesktopPaywalls[container];
  if (pending != null) return pending;
  final task = _presentPaywall(
    context,
    container,
    decision,
    accessContext: accessContext,
    resume: resume,
    surface: surface,
  );
  _pendingDesktopPaywalls[container] = task;
  return task.whenComplete(() {
    if (identical(_pendingDesktopPaywalls[container], task)) {
      _pendingDesktopPaywalls.remove(container);
    }
  });
}

/// Paywall for a caller that has no request context (the legacy shared
/// guards). Premium verified active resolves `true` without a dialog; an
/// unknown entitlement shows Retry, never pricing.
Future<bool> showDesktopPremiumPaywall(
  BuildContext context, {
  DesktopAccessDecision? decision,
  DesktopAccessContext? accessContext,
  String surface = 'legacy_premium_guard',
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  final live = readDesktopAccess(container.read, accessContext ?? _premiumProbe);
  if (live.isAllowed) return Future<bool>.value(true);
  final shown = decision ??
      (live.outcome == DesktopAccess.premiumRequired && accessContext == null
          ? const DesktopAccessDecision(
              DesktopAccess.premiumRequired,
              DesktopAccessReason.premiumPaidSource,
            )
          : live);
  return showDesktopPaywall(
    context,
    shown,
    accessContext: accessContext,
    surface: surface,
  );
}

/// Mutable facts one paywall session collects while it is open.
class _PaywallSession {
  _PaywallSession(this.account);

  /// The account the flow is bound to. A guest who signs in inside the flow
  /// rebinds it to the new permanent account; any OTHER change voids resume.
  String? account;
}

Future<bool> _presentPaywall(
  BuildContext context,
  ProviderContainer container,
  DesktopAccessDecision decision, {
  DesktopAccessContext? accessContext,
  DesktopAccessResume? resume,
  required String surface,
}) async {
  DesktopAccessAnalytics.gateShown(
    decision,
    context: accessContext,
    surface: surface,
  );
  final session = _PaywallSession(
    container.read(desktopEntitlementProvider).accountId,
  );
  await showDesktopModal<void>(
    context,
    maxWidth: 480,
    builder: (_) => DesktopPaywallView(
      decision: decision,
      accessContext: accessContext,
      surface: surface,
      onAccountBound: (account) => session.account = account,
    ),
  );
  final verified = desktopPaywallVerified(
    container.read,
    accessContext: accessContext,
    account: session.account,
  );
  if (!verified) return false;
  if (resume != null && (resume.stillMatches?.call() ?? true)) {
    DesktopAccessAnalytics.continuationResumed(
      decision,
      context: accessContext,
      surface: surface,
    );
    await resume.run();
  }
  return true;
}

/// A request that only Premium satisfies, used to ask "is Premium verified
/// active?" through the single evaluator (offline grace included).
const DesktopAccessContext _premiumProbe = DesktopAccessContext(
  feature: DesktopFeature.gamebase,
  action: DesktopAction.openContent,
  origin: DesktopDiscoveryOrigin.gamebase,
);

/// Whether the live membership admits [accessContext] for [account].
///
/// Purchase and quota requests are verified as "Premium is active", because a
/// quota context without measured usage cannot be re-evaluated here and a
/// purchase context only proves an account exists.
bool desktopPaywallVerified(
  DesktopProviderRead read, {
  DesktopAccessContext? accessContext,
  required String? account,
}) {
  final entitlement = read(desktopEntitlementProvider);
  if (entitlement.accountId != account) return false;
  final probe =
      accessContext == null ||
          accessContext.feature == DesktopFeature.purchase ||
          accessContext.effectiveQuota != DesktopQuota.none
      ? _premiumProbe
      : accessContext.copyWith(
          entitlementGeneration: desktopUnassertedGeneration,
        );
  return readDesktopAccess(read, probe).isAllowed;
}

enum _PaywallPhase { idle, openingCheckout, awaitingCheckout, refreshing }

/// The paywall body. Content is fully visible at rest; nothing waits on an
/// entrance animation.
class DesktopPaywallView extends ConsumerStatefulWidget {
  const DesktopPaywallView({
    super.key,
    required this.decision,
    this.accessContext,
    this.surface = 'paywall',
    this.onAccountBound,
  });

  final DesktopAccessDecision decision;
  final DesktopAccessContext? accessContext;
  final String surface;
  final ValueChanged<String?>? onAccountBound;

  @override
  ConsumerState<DesktopPaywallView> createState() => _DesktopPaywallViewState();
}

class _DesktopPaywallViewState extends ConsumerState<DesktopPaywallView> {
  String _interval = 'year';
  _PaywallPhase _phase = _PaywallPhase.idle;
  bool _needsSignIn = false;
  bool _closing = false;
  String? _error;
  StreamSubscription<EntitlementSnapshot>? _pollSub;

  @override
  void initState() {
    super.initState();
    _needsSignIn = widget.decision.outcome == DesktopAccess.accountRequired;
  }

  @override
  void dispose() {
    unawaited(_pollSub?.cancel());
    super.dispose();
  }

  bool get _targetsPremium {
    final context = widget.accessContext;
    return context == null ||
        context.feature == DesktopFeature.purchase ||
        widget.decision.outcome == DesktopAccess.quotaExceeded ||
        context.effectiveQuota != DesktopQuota.none;
  }

  /// The decision the dialog shows right now: the caller's specific decision,
  /// replaced by a live read when the membership moves.
  DesktopAccessDecision _live(
    SubscriptionState subscription,
    DesktopEntitlementSnapshot entitlement,
  ) {
    final context = widget.accessContext;
    final initial = widget.decision;
    if (!_targetsPremium && context != null) {
      final live = evaluateDesktopAccess(
        context: context.copyWith(
          entitlementGeneration: desktopUnassertedGeneration,
        ),
        subscription: subscription,
        entitlement: entitlement,
      );
      return live.outcome == DesktopAccess.accountRequired ? initial : live;
    }
    final premium = evaluateDesktopAccess(
      context: _premiumProbe,
      subscription: subscription,
      entitlement: entitlement,
    );
    if (premium.isAllowed) return premium;
    if (premium.outcome == DesktopAccess.temporarilyUnavailable &&
        initial.outcome != DesktopAccess.quotaExceeded) {
      return premium;
    }
    if (initial.outcome == DesktopAccess.checking ||
        initial.outcome == DesktopAccess.temporarilyUnavailable) {
      return premium.outcome == DesktopAccess.premiumRequired
          ? DesktopAccessDecision(
              DesktopAccess.premiumRequired,
              context == null
                  ? DesktopAccessReason.premiumPaidSource
                  : initial.reason,
            )
          : premium;
    }
    return initial;
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _phase = _PaywallPhase.refreshing;
      _error = null;
    });
    try {
      await DesktopSubscriptionNotifier.current?.refreshFromBackend(
        forceSessionRefresh: true,
      );
    } catch (_) {
      DesktopAccessAnalytics.operationalError(
        widget.decision,
        context: widget.accessContext,
        surface: widget.surface,
        stage: 'refresh',
      );
      if (mounted) {
        setState(() => _error = 'Could not reach ChessEver. Try again.');
      }
    } finally {
      if (mounted && _phase == _PaywallPhase.refreshing) {
        setState(() => _phase = _PaywallPhase.idle);
      }
    }
  }

  Future<void> _signIn() async {
    final signedIn = await debugDesktopPaywallSignIn(context);
    if (!mounted) return;
    final entitlement = ref.read(desktopEntitlementProvider);
    if (signedIn || entitlement.hasPermanentAccount) {
      widget.onAccountBound?.call(entitlement.accountId);
      setState(() => _needsSignIn = false);
    }
  }

  Future<void> _purchase(DesktopResolvedPricing? pricing) async {
    // Purchasing is itself a request: it needs a permanent account.
    final purchase = readDesktopAccess(
      ref.read,
      const DesktopAccessContext(
        feature: DesktopFeature.purchase,
        action: DesktopAction.create,
        origin: DesktopDiscoveryOrigin.broadcast,
      ),
    );
    if (purchase.outcome == DesktopAccess.accountRequired) {
      setState(() => _needsSignIn = true);
      return;
    }
    if (pricing == null) {
      setState(() => _error = 'Prices are still loading. Try again.');
      return;
    }
    widget.onAccountBound?.call(ref.read(desktopEntitlementProvider).accountId);
    setState(() {
      _phase = _PaywallPhase.openingCheckout;
      _error = null;
    });
    DesktopAccessAnalytics.upgradeStarted(
      widget.decision,
      context: widget.accessContext,
      surface: widget.surface,
      interval: _interval,
    );
    final String token;
    try {
      token = await DesktopBillingService.instance.openCheckout(
        tier: pricing.pricing.tier,
        interval: _interval,
      );
    } catch (_) {
      DesktopAccessAnalytics.operationalError(
        widget.decision,
        context: widget.accessContext,
        surface: widget.surface,
        stage: 'checkout_open',
      );
      if (mounted) {
        setState(() {
          _phase = _PaywallPhase.idle;
          _error = 'Checkout could not be opened. Try again.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _phase = _PaywallPhase.awaitingCheckout);
    await _pollSub?.cancel();
    _pollSub = DesktopBillingService.instance
        .pollAfterCheckout(token)
        .listen(
          (entry) {
            // The poll is a hint, not proof. Re-read the notifier; the live
            // decision closes the dialog once IT says Premium is active.
            if (entry.isActive) unawaited(_refresh());
          },
          onError: (Object _) {
            DesktopAccessAnalytics.operationalError(
              widget.decision,
              context: widget.accessContext,
              surface: widget.surface,
              stage: 'checkout_poll',
            );
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final subscription = ref.watch(subscriptionProvider);
    final entitlement = ref.watch(desktopEntitlementProvider);
    final live = _live(subscription, entitlement);
    if (live.isAllowed) _close();

    final showSignIn =
        !live.isAllowed &&
        (_needsSignIn || live.outcome == DesktopAccess.accountRequired);
    final shown = showSignIn
        ? const DesktopAccessDecision(
            DesktopAccess.accountRequired,
            DesktopAccessReason.accountRequiredForPurchase,
          )
        : live;
    final copy = desktopPaywallCopyFor(
      widget.decision.outcome == DesktopAccess.accountRequired && showSignIn
          ? widget.decision
          : shown,
      context: widget.accessContext,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 24),
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(title: copy.title),
            const SizedBox(height: 8),
            Text(
              copy.body,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            if (copy.capacityLine != null) ...[
              const SizedBox(height: 14),
              Text(
                copy.capacityLine!,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
            const SizedBox(height: 20),
            ..._bodyFor(shown),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: kRedColor, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _bodyFor(DesktopAccessDecision shown) {
    switch (shown.outcome) {
      case DesktopAccess.allowed:
        return const [];
      case DesktopAccess.checking:
        return const [_Progress(label: 'Checking your membership')];
      case DesktopAccess.temporarilyUnavailable:
        return [
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopDialogButton(
              label: _phase == _PaywallPhase.refreshing
                  ? 'Retrying'
                  : 'Retry',
              tone: DesktopDialogButtonTone.primary,
              icon: Icons.refresh_rounded,
              onPress: _phase == _PaywallPhase.refreshing ? null : _refresh,
            ),
          ),
        ];
      case DesktopAccess.accountRequired:
        return [
          Align(
            alignment: Alignment.centerLeft,
            child: DesktopDialogButton(
              label: 'Sign in',
              tone: DesktopDialogButtonTone.primary,
              icon: Icons.login_rounded,
              onPress: _signIn,
            ),
          ),
        ];
      case DesktopAccess.premiumRequired:
      case DesktopAccess.quotaExceeded:
        return _pricingBody();
    }
  }

  List<Widget> _pricingBody() {
    final pricingState = ref.watch(desktopPricingProvider);
    final pricing = pricingState.valueOrNull;
    if (_phase == _PaywallPhase.awaitingCheckout) {
      return [
        const _Progress(
          label: 'Finish checkout in your browser. This updates on its own.',
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: DesktopDialogButton(
            label: 'I have paid, refresh',
            tone: DesktopDialogButtonTone.primary,
            icon: Icons.refresh_rounded,
            onPress: _phase == _PaywallPhase.refreshing ? null : _refresh,
          ),
        ),
      ];
    }
    return [
      _PlanSelector(
        pricing: pricing,
        interval: _interval,
        onChanged: (interval) => setState(() => _interval = interval),
      ),
      const SizedBox(height: 16),
      for (final line in desktopPremiumIncludes)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            line,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ),
      const SizedBox(height: 18),
      // Wraps instead of overflowing when the dialog is narrow.
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          DesktopDialogButton(
            label: _phase == _PaywallPhase.openingCheckout
                ? 'Opening checkout'
                : 'Continue to checkout',
            tone: DesktopDialogButtonTone.primary,
            onPress: _phase == _PaywallPhase.idle
                ? () => _purchase(pricing)
                : null,
          ),
          DesktopDialogButton(
            label: 'Already Premium? Refresh',
            tone: DesktopDialogButtonTone.ghost,
            onPress: _phase == _PaywallPhase.idle ? _refresh : null,
          ),
        ],
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              title,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        DesktopDialogIconButton(
          icon: Icons.close_rounded,
          tooltip: 'Close',
          onPress: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
            backgroundColor: kDividerColor,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: kWhiteColor70, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

String _formatAmount(double amount, String currencyCode) {
  if (currencyCode == 'USD') return DesktopPricing.formatUsd(amount);
  final decimals = amount % 1 == 0 ? 0 : 2;
  return '${amount.toStringAsFixed(decimals)} $currencyCode';
}

/// Monthly / annual as ONE composed control: two equal columns inside a
/// single rounded track, each column carrying the same three rows (plan,
/// price, detail) so the rows line up regardless of copy length.
class _PlanSelector extends StatelessWidget {
  const _PlanSelector({
    required this.pricing,
    required this.interval,
    required this.onChanged,
  });

  final DesktopResolvedPricing? pricing;
  final String interval;
  final ValueChanged<String> onChanged;

  static const double _trackRadius = 10;
  static const double _trackPadding = 4;

  @override
  Widget build(BuildContext context) {
    final resolved = pricing;
    final tier = resolved?.pricing;
    final currency = resolved?.currencyCode ?? 'USD';
    final savings = tier?.annualSavingsPercent ?? 0;
    return Container(
      padding: const EdgeInsets.all(_trackPadding),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(_trackRadius),
        border: Border.all(color: kDividerColor),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _PlanColumn(
                selected: interval == 'month',
                plan: 'Monthly',
                price: tier == null
                    ? '-'
                    : _formatAmount(tier.monthlyAmount, currency),
                detail: 'per month',
                onTap: () => onChanged('month'),
              ),
            ),
            const SizedBox(width: _trackPadding),
            Expanded(
              child: _PlanColumn(
                selected: interval == 'year',
                plan: 'Annual',
                price: tier == null
                    ? '-'
                    : _formatAmount(tier.annualAmount, currency),
                detail: tier == null
                    ? 'per year'
                    : savings > 0
                    ? '${_formatAmount(tier.annualMonthlyEquivalent, currency)}'
                          ' a month, save $savings%'
                    : '${_formatAmount(tier.annualMonthlyEquivalent, currency)}'
                          ' a month',
                onTap: () => onChanged('year'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanColumn extends StatefulWidget {
  const _PlanColumn({
    required this.selected,
    required this.plan,
    required this.price,
    required this.detail,
    required this.onTap,
  });

  final bool selected;
  final String plan;
  final String price;
  final String detail;
  final VoidCallback onTap;

  @override
  State<_PlanColumn> createState() => _PlanColumnState();
}

class _PlanColumnState extends State<_PlanColumn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fill = selected
        ? kPrimaryColor.withValues(alpha: _hover ? 0.16 : 0.10)
        : _hover
        ? kBlack3Color
        : Colors.transparent;
    // Inner radius + track padding == track radius, so the corners nest.
    const innerRadius =
        _PlanSelector._trackRadius - _PlanSelector._trackPadding;
    return Semantics(
      button: true,
      selected: selected,
      label: '${widget.plan}, ${widget.price}',
      child: CursorAware(
        mode: CursorMode.hover,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(innerRadius),
                border: Border.all(
                  color: selected
                      ? kPrimaryColor.withValues(alpha: 0.35)
                      : Colors.transparent,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.plan,
                    style: TextStyle(
                      color: selected ? kPrimaryColor : kWhiteColor70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.price,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.detail,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A locked placeholder a surface renders INSTEAD of loading gated content.
///
/// Rendering it never opens a paywall and starts no fetch. Its one button is
/// an explicit action: pricing for a known denial, Retry for an unknown
/// entitlement, nothing while membership is still loading.
class DesktopAccessLockedSurface extends ConsumerWidget {
  const DesktopAccessLockedSurface({
    super.key,
    required this.decision,
    this.accessContext,
    this.surface = 'locked_surface',
    this.resume,
  });

  final DesktopAccessDecision decision;
  final DesktopAccessContext? accessContext;
  final String surface;
  final DesktopAccessResume? resume;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final copy = desktopPaywallCopyFor(decision, context: accessContext);
    final Widget? action = switch (decision.outcome) {
      DesktopAccess.allowed || DesktopAccess.checking => null,
      DesktopAccess.temporarilyUnavailable => DesktopDialogButton(
        label: 'Retry',
        tone: DesktopDialogButtonTone.primary,
        icon: Icons.refresh_rounded,
        onPress: () => unawaited(
          DesktopSubscriptionNotifier.current?.refreshFromBackend(
            forceSessionRefresh: true,
          ),
        ),
      ),
      _ => DesktopDialogButton(
        label: decision.outcome == DesktopAccess.accountRequired
            ? 'Sign in'
            : 'See Premium',
        tone: DesktopDialogButtonTone.primary,
        onPress: () => unawaited(
          showDesktopPaywall(
            context,
            decision,
            accessContext: accessContext,
            resume: resume,
            surface: surface,
          ),
        ),
      ),
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copy.title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                copy.body,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              if (copy.capacityLine != null) ...[
                const SizedBox(height: 10),
                Text(
                  copy.capacityLine!,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
              if (decision.outcome == DesktopAccess.checking) ...[
                const SizedBox(height: 16),
                const _Progress(label: 'Checking your membership'),
              ],
              if (action != null) ...[const SizedBox(height: 16), action],
            ],
          ),
        ),
      ),
    );
  }
}

/// Registers this window's paywall presenter for its container. Place it
/// inside the `MaterialApp.builder` of every desktop window root.
class DesktopPaywallHost extends StatefulWidget {
  const DesktopPaywallHost({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<DesktopPaywallHost> createState() => _DesktopPaywallHostState();
}

class _DesktopPaywallHostState extends State<DesktopPaywallHost> {
  VoidCallback? _unregister;
  ProviderContainer? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final container = ProviderScope.containerOf(context, listen: false);
    if (identical(container, _container)) return;
    _unregister?.call();
    _container = container;
    _unregister = registerDesktopPaywallPresenter(container, (
      decision, {
      DesktopAccessContext? context,
      DesktopAccessResume? resume,
      required String surface,
    }) {
      final navigatorContext = widget.navigatorKey.currentContext;
      if (navigatorContext == null || !navigatorContext.mounted) {
        return Future<bool>.value(false);
      }
      return showDesktopPaywall(
        navigatorContext,
        decision,
        accessContext: context,
        resume: resume,
        surface: surface,
      );
    });
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
