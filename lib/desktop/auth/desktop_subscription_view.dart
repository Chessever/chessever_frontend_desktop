import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart' as forui;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing_provider.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_button.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';

/// The desktop subscription body, reused by both the onboarding "Subscribe"
/// step and the standalone [DesktopPremiumRequiredScreen].
///
/// Listens to [subscriptionProvider] and, the moment the user becomes
/// premium (either via deep-link from Stripe or the polled refresh from
/// the entitlement edge function), invokes [onSubscribed].
///
/// Three actions are available:
///   - **Continue** opens Stripe Checkout in the user's default browser
///     for the selected interval. The success URL is the desktop
///     `chessever://billing/success` deep link.
///   - **Subscribe on web** opens chessever.com/pricing in the browser
///     for users who'd rather pay on another device.
///   - **I already subscribed** triggers an entitlement refresh — covers
///     the case where the user already paid via App Store / Play Store
///     and their mobile RC entry just needs to mirror in.
class DesktopSubscriptionView extends ConsumerStatefulWidget {
  const DesktopSubscriptionView({
    super.key,
    required this.onSubscribed,
    this.reason,
    this.trailing,
  });

  /// Called once `subscriptionProvider.isSubscribed` flips to true. Usually
  /// the caller uses this to advance onboarding / leave the gate screen.
  final VoidCallback onSubscribed;

  /// Optional context line shown under the title. e.g. "Subscribe to use
  /// ChessEver Desktop" or "Free accounts can follow up to N players".
  final String? reason;

  /// Optional widget rendered below the "I already subscribed" refresh
  /// button. Used by [DesktopPremiumRequiredScreen] to host a sign-out
  /// action without re-rendering a top-bar.
  final Widget? trailing;

  @override
  ConsumerState<DesktopSubscriptionView> createState() =>
      _DesktopSubscriptionViewState();
}

class _DesktopSubscriptionViewState
    extends ConsumerState<DesktopSubscriptionView> {
  String _interval = 'year';
  bool _busy = false;
  bool _refreshingMembership = false;
  bool _waitingForCheckout = false;
  bool _completed = false;
  String? _error;
  String? _notice;
  StreamSubscription<EntitlementSnapshot>? _checkoutSub;

  @override
  void dispose() {
    _checkoutSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pricingState = ref.watch(desktopPricingProvider);
    final pricing = pricingState.valueOrNull?.pricing;
    final subscriptionError = ref.watch(
      subscriptionProvider.select((state) => state.error),
    );
    ref.listen<SubscriptionState>(subscriptionProvider, (prev, next) {
      if (next.isSubscribed && (prev?.isSubscribed != true) && mounted) {
        _completeOnce();
      }
    });

    final visibleError = _error ?? subscriptionError;

    return forui.FTheme(
      data: forui.FThemes.zinc.dark,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(reason: widget.reason),
          const SizedBox(height: 20),
          const _FeatureList(),
          const SizedBox(height: 24),
          _IntervalToggle(
            value: _interval,
            onChanged: (v) => setState(() => _interval = v),
          ),
          const SizedBox(height: 16),
          if (pricing == null)
            const _PriceLinePlaceholder()
          else
            _PriceLine(pricing: pricing, interval: _interval),
          if (_waitingForCheckout) ...[
            const SizedBox(height: 14),
            _CheckoutStatus(),
          ],
          const SizedBox(height: 20),
          if (visibleError != null) ...[
            Text(
              visibleError,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
            const SizedBox(height: 12),
          ],
          if (_notice != null && visibleError == null) ...[
            _NoticeBanner(message: _notice!),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: DesktopPaywallButton(
                  label:
                      _busy
                          ? 'Opening Stripe...'
                          : pricing == null
                          ? 'Loading pricing...'
                          : 'Continue',
                  tone: DesktopPaywallButtonTone.primary,
                  fillWidth: true,
                  loading: _busy,
                  prefix: const Icon(forui.FIcons.creditCard),
                  onPress:
                      (_busy || _waitingForCheckout || pricing == null)
                          ? null
                          : () => _continueInApp(pricing.tier),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DesktopPaywallButton(
                  label: 'Open web checkout',
                  tone: DesktopPaywallButtonTone.secondary,
                  fillWidth: true,
                  prefix: const Icon(forui.FIcons.externalLink),
                  onPress: (_busy || _waitingForCheckout) ? null : _openWebsite,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: DesktopPaywallButton(
              label:
                  _refreshingMembership
                      ? 'Checking membership...'
                      : 'I already subscribed — refresh',
              tone: DesktopPaywallButtonTone.ghost,
              loading: _refreshingMembership,
              prefix: const Icon(forui.FIcons.refreshCw),
              onPress:
                  _busy || _refreshingMembership ? null : _refreshMembership,
            ),
          ),
          if (widget.trailing != null) ...[
            const SizedBox(height: 6),
            Center(child: widget.trailing!),
          ],
        ],
      ),
    );
  }

  void _completeOnce() {
    if (_completed) return;
    _completed = true;
    widget.onSubscribed();
  }

  Future<void> _continueInApp(int tier) async {
    setState(() {
      _busy = true;
      _waitingForCheckout = false;
      _error = null;
      _notice = null;
    });
    try {
      await _checkoutSub?.cancel();
      _checkoutSub = DesktopBillingService.instance
          .startCheckout(tier: tier, interval: _interval)
          .listen(
            (snapshot) {
              if (!mounted) return;
              if (!snapshot.isActive) return;
              unawaited(
                DesktopSubscriptionNotifier.current?.refreshFromBackend(
                  forceSessionRefresh: true,
                ),
              );
              _completeOnce();
            },
            onError: (Object e, StackTrace st) {
              ErrorReporter.report(e, stackTrace: st, tag: 'billing.checkout');
              if (mounted) {
                setState(() {
                  _waitingForCheckout = false;
                  _error = ErrorReporter.genericUserMessage;
                });
              }
            },
            onDone: () {
              if (mounted && !_completed) {
                setState(() => _waitingForCheckout = false);
              }
            },
          );
      if (mounted) setState(() => _waitingForCheckout = true);
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'billing.checkout_start');
      if (mounted) {
        setState(() => _error = ErrorReporter.genericUserMessage);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWebsite() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final uri = Uri.https('chessever.com', '/pricing', {
        'source': 'desktop_app',
        'return_to': 'desktop',
        'action': 'checkout',
        'interval': _interval,
      });
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw StateError('Could not open browser.');
      if (!mounted) return;
      // Drive `_waitingForCheckout` off the entitlement watcher's lifecycle
      // so we never sit in "waiting" forever if the user closes the browser
      // without paying. The stream caps itself at the service's poll
      // timeout (~3 min); `onDone` clears the flag.
      await _checkoutSub?.cancel();
      _checkoutSub = DesktopBillingService.instance.watchEntitlement().listen(
        (snapshot) {
          if (!mounted) return;
          if (!snapshot.isActive) return;
          unawaited(
            DesktopSubscriptionNotifier.current?.refreshFromBackend(
              forceSessionRefresh: true,
            ),
          );
          _completeOnce();
        },
        onError: (Object e, StackTrace st) {
          ErrorReporter.report(e, stackTrace: st, tag: 'billing.watch_ent');
          if (mounted) {
            setState(() {
              _waitingForCheckout = false;
              _error = ErrorReporter.genericUserMessage;
            });
          }
        },
        onDone: () {
          if (mounted && !_completed) {
            setState(() => _waitingForCheckout = false);
          }
        },
      );
      setState(() => _waitingForCheckout = true);
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'billing.open_web');
      if (mounted) {
        setState(() => _error = ErrorReporter.genericUserMessage);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshMembership() async {
    setState(() {
      _refreshingMembership = true;
      _error = null;
      _notice = null;
    });

    try {
      final notifier = DesktopSubscriptionNotifier.current;
      if (notifier == null) {
        throw StateError('Subscription sync is not ready yet.');
      }

      final ent = await notifier.refreshFromBackend(forceSessionRefresh: true);
      if (!mounted) return;

      if (ent?.isActive == true) {
        _completeOnce();
        return;
      }

      final signedIn = Supabase.instance.client.auth.currentSession != null;
      setState(() {
        _notice =
            signedIn
                ? 'No active Premium membership was found for this signed-in account yet. If you just paid, wait a few seconds and refresh again.'
                : 'Sign in again with the account that owns the subscription.';
      });
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'billing.refresh_member');
      if (mounted) {
        setState(() => _error = ErrorReporter.genericUserMessage);
      }
    } finally {
      if (mounted) setState(() => _refreshingMembership = false);
    }
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.26)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
      ),
    );
  }
}

class _CheckoutStatus extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.28)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: kPrimaryColor,
            ),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Finish checkout in your browser. This screen unlocks as soon as Stripe confirms the subscription or the browser returns here.',
              style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.reason});
  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ChessEver Premium',
          style: TextStyle(
            color: kPrimaryColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Follow chess like a pro.',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (reason != null) ...[
          const SizedBox(height: 8),
          Text(
            reason!,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }
}

class _FeatureList extends StatelessWidget {
  const _FeatureList();

  static const _features = [
    ('Unlimited favorites', 'Follow every player, no cap.'),
    (
      'Opponent prep tools',
      'Repertoire-aware preparation against specific players.',
    ),
    (
      'Advanced search & filters',
      'Filter the gamebase by rating, time control, year, result.',
    ),
    ('Library + cloud sync', 'Save analyses, organize folders, share books.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (title, body) in _features)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle, size: 16, color: kPrimaryColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        body,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _IntervalToggle extends StatelessWidget {
  const _IntervalToggle({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DesktopSegmentedTabs<String>(
      expand: true,
      selected: value,
      onChanged: onChanged,
      tabs: const [
        DesktopSegmentedTab(
          value: 'month',
          label: 'Monthly',
          icon: Icons.calendar_view_month_rounded,
        ),
        DesktopSegmentedTab(
          value: 'year',
          label: 'Annual · 2 months free',
          icon: Icons.calendar_today_rounded,
        ),
      ],
    );
  }
}

class _PriceLinePlaceholder extends StatelessWidget {
  const _PriceLinePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 140,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(width: 12),
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: kPrimaryColor,
          ),
        ),
      ],
    );
  }
}

class _PriceLine extends StatelessWidget {
  const _PriceLine({required this.pricing, required this.interval});
  final DesktopTierPricing pricing;
  final String interval;

  @override
  Widget build(BuildContext context) {
    final monthly = pricing.monthlyAmount;
    final annual = pricing.annualAmount;
    final amount = interval == 'year' ? annual : monthly;
    final unit = interval == 'year' ? '/year' : '/month';
    final monthlyEquiv =
        interval == 'year' ? pricing.annualMonthlyEquivalent : monthly;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          DesktopPricing.formatUsd(amount),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 32,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          unit,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 14,
          ),
        ),
        const Spacer(),
        if (interval == 'year')
          Text(
            'Just ${DesktopPricing.formatUsd(monthlyEquiv)}/mo',
            style: TextStyle(
              color: kPrimaryColor.withValues(alpha: 0.85),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}
