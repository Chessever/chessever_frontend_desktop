import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/services/auth/desktop_auth_service.dart';
import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/services/billing/desktop_pricing_provider.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/desktop_updater.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/keyboard_shortcuts_section.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/providers/app_version_provider.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop preferences pane.
///
/// Three sections to start: account (sign in/out), engine (Stockfish
/// availability + path), and a build-info footer. Each section is a card
/// with a clear status pill so the user can tell at a glance what is
/// configured. The Forui design tokens live in their own package; for now
/// we reuse the existing app palette for visual consistency with the
/// sidebar/topbar.
class SettingsPane extends HookConsumerWidget {
  const SettingsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!DesktopSupabaseInit.isInitialized) {
      return const _SettingsUnavailable();
    }

    final session = useState<Session?>(
      Supabase.instance.client.auth.currentSession,
    );
    final signingIn = useState<bool>(false);
    final lastError = useState<String?>(null);

    useEffect(() {
      final sub = Supabase.instance.client.auth.onAuthStateChange.listen(
        (event) => session.value = event.session,
      );
      return sub.cancel;
    }, const []);

    Future<void> handleGoogleSignIn() async {
      lastError.value = null;
      signingIn.value = true;
      try {
        final next = await DesktopAuthService.instance.signInWithGoogle();
        session.value = next;
      } catch (e) {
        lastError.value = e.toString();
      } finally {
        signingIn.value = false;
      }
    }

    Future<void> handleAppleSignIn() async {
      lastError.value = null;
      signingIn.value = true;
      try {
        final next = await DesktopAuthService.instance.signInWithApple();
        session.value = next;
      } catch (e) {
        lastError.value = _friendlyAuthError(e);
      } finally {
        signingIn.value = false;
      }
    }

    Future<void> handleSignOut() async {
      final confirmed = await showGeneralDialog<bool>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Sign out',
        barrierColor: Colors.black.withValues(alpha: 0.55),
        transitionDuration: const Duration(milliseconds: 140),
        pageBuilder:
            (ctx, _, _) => FTheme(
              data: FThemes.zinc.dark,
              child: Center(
                child: Container(
                  width: 420,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                  decoration: BoxDecoration(
                    color: kBlack2Color,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kDividerColor),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.logout,
                            color: Color(0xFFEB5757),
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Sign out',
                              style: TextStyle(
                                color: kWhiteColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        session.value != null
                            ? 'Are you sure you want to sign out of '
                                '${session.value!.user.email}? '
                                'You will need to sign in again to sync your data.'
                            : 'Are you sure you want to sign out? '
                                'You will need to sign in again to access your account.',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          DesktopDialogButton(
                            label: 'Cancel',
                            onPress: () => Navigator.of(ctx).pop(false),
                          ),
                          const SizedBox(width: 8),
                          DesktopDialogButton(
                            label: 'Sign out',
                            tone: DesktopDialogButtonTone.danger,
                            onPress: () => Navigator.of(ctx).pop(true),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
      );
      if (confirmed == true) {
        await DesktopAuthService.instance.signOut();
        session.value = null;
      }
    }

    return Container(
      color: kBackgroundColor,
      child: SingleChildScrollView(
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Settings',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Account, engine, and window preferences',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            const SizedBox(height: 24),
            const _BoardSettingsSection(),
            const SizedBox(height: 16),
            const _NotificationsSection(),
            const SizedBox(height: 16),
            const KeyboardShortcutsSection(),
            const SizedBox(height: 16),
            _AccountSection(
              session: session.value,
              signingIn: signingIn.value,
              onGoogleSignIn: handleGoogleSignIn,
              onAppleSignIn: handleAppleSignIn,
              onSignOut: handleSignOut,
              error: lastError.value,
            ),
            const SizedBox(height: 16),
            if (session.value != null) ...[
              const _SubscriptionSection(),
              const SizedBox(height: 16),
            ],
            const _EngineSection(),
            const SizedBox(height: 16),
            const _UpdatesSection(),
            const SizedBox(height: 16),
            const _PlatformSection(),
          ],
        ),
      ),
    );
  }
}

class _SettingsUnavailable extends StatelessWidget {
  const _SettingsUnavailable();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBackgroundColor,
      child: SingleChildScrollView(
        physics: const DesktopScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Settings',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 18),
            Container(
              width: 560,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kDividerColor),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Backend unavailable',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Supabase did not initialize. Account sync and remote data are disabled for this launch.',
                    style: TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountSection extends StatelessWidget {
  const _AccountSection({
    required this.session,
    required this.signingIn,
    required this.onGoogleSignIn,
    required this.onAppleSignIn,
    required this.onSignOut,
    required this.error,
  });

  final Session? session;
  final bool signingIn;
  final VoidCallback onGoogleSignIn;
  final VoidCallback onAppleSignIn;
  final VoidCallback onSignOut;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final email = session?.user.email;
    return _Card(
      title: 'Account',
      icon: Icons.account_circle_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (email != null) ...[
            Row(
              children: [
                const _StatusPill(label: 'Signed in', color: kGreenColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    email,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                _SecondaryButton(label: 'Sign out', onTap: onSignOut),
              ],
            ),
          ] else ...[
            const _StatusPill(label: 'Signed out', color: kLightGreyColor),
            const SizedBox(height: 12),
            const Text(
              'Sign in to sync favorites, library, and settings across '
              'devices.',
              style: TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _PrimaryButton(
                  icon: Icons.account_circle_rounded,
                  label: signingIn ? 'Signing in…' : 'Sign in with Google',
                  onTap: signingIn ? null : onGoogleSignIn,
                ),
                const SizedBox(width: 8),
                _SecondaryButton(
                  label: 'Sign in with Apple',
                  onTap: signingIn ? null : onAppleSignIn,
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: const TextStyle(color: kRedColor, fontSize: 12),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _SubscriptionSection extends HookConsumerWidget {
  const _SubscriptionSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final futureSnapshot = useMemoized(
      DesktopBillingService.instance.currentEntitlement,
      const [],
    );
    final snapshot = useFuture(futureSnapshot);
    final loading = useState<bool>(false);
    final error = useState<String?>(null);
    final live = useState<EntitlementSnapshot?>(null);
    final pollSub = useRef<StreamSubscription<EntitlementSnapshot>?>(null);
    final pricingState = ref.watch(desktopPricingProvider);
    final pricing = pricingState.valueOrNull?.pricing;
    useEffect(() {
      return () => pollSub.value?.cancel();
    }, const []);

    final entitlement = live.value ?? snapshot.data;

    Future<void> upgrade() async {
      error.value = null;
      loading.value = true;
      String token;
      try {
        final checkoutPricing = pricing;
        if (checkoutPricing == null) {
          throw StateError('Pricing is still loading. Try again in a moment.');
        }
        token = await DesktopBillingService.instance.openCheckout(
          tier: checkoutPricing.tier,
          interval: 'year',
        );
      } catch (e) {
        error.value = e.toString();
        loading.value = false;
        return;
      }
      // Browser is open — release the UI immediately. The poll continues
      // in the background and naturally times out (see _pollTimeout) so a
      // user who walks away from the Stripe tab does not pin the Settings
      // pane in a "loading" state forever.
      loading.value = false;
      await pollSub.value?.cancel();
      late final StreamSubscription<EntitlementSnapshot> sub;
      sub = DesktopBillingService.instance.pollAfterCheckout(token).listen((
        entry,
      ) {
        live.value = entry;
        if (entry.isActive) unawaited(sub.cancel());
      }, onError: (Object e) => error.value = e.toString());
      pollSub.value = sub;
    }

    final isPro = entitlement?.isActive ?? false;
    final statusLabel =
        !isPro
            ? 'Free'
            : entitlement!.willRenew
            ? 'Pro · renews'
            : 'Pro · cancels at term end';
    final statusColor = isPro ? kGreenColor : kLightGreyColor;

    Future<void> openManageOnWeb() async {
      error.value = null;
      loading.value = true;
      try {
        final uri = Uri.https('chessever.com', '/account');
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok) {
          error.value =
              'Could not open chessever.com/account in your browser.';
        }
      } catch (e) {
        error.value = e.toString();
      } finally {
        loading.value = false;
      }
    }

    return _Card(
      title: 'Subscription',
      icon: Icons.workspace_premium_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusPill(label: statusLabel, color: statusColor),
              if (entitlement?.expiresAt != null) ...[
                const SizedBox(width: 12),
                Text(
                  'until ${_formatExpiry(entitlement!.expiresAt!)}',
                  style: const TextStyle(color: kLightGreyColor, fontSize: 11),
                ),
              ],
              const Spacer(),
              if (!isPro)
                _PrimaryButton(
                  icon: Icons.workspace_premium_rounded,
                  label:
                      loading.value
                          ? 'Opening browser…'
                          : pricing == null
                          ? 'Loading pricing…'
                          : 'Upgrade to Pro',
                  onTap: loading.value || pricing == null ? null : upgrade,
                )
              else ...[
                _SecondaryButton(
                  label:
                      loading.value
                          ? 'Opening browser…'
                          : 'Manage web subscription',
                  onTap: loading.value ? null : openManageOnWeb,
                ),
                const SizedBox(width: 8),
                const _SecondaryButton(
                  label: 'Manage mobile subscription',
                  onTap: null,
                ),
              ],
            ],
          ),
          if (!isPro) ...[
            const SizedBox(height: 12),
            const Text(
              'Subscribe on the web or in the iOS / Android app. One plan unlocks every ChessEver surface.',
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          if (error.value != null) ...[
            const SizedBox(height: 12),
            Text(
              error.value!,
              style: const TextStyle(color: kRedColor, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

String _friendlyAuthError(Object error) {
  final text = error.toString();
  if (text.contains('canceled')) return 'Sign-in was cancelled.';
  if (text.contains('Apple sign-in is not available') ||
      text.contains('Sign in with Apple capability')) {
    return 'Apple sign-in is not available for this build.';
  }
  if (text.contains('Apple sign-in timed out') ||
      text.contains('Provider sign-in timed out') ||
      text.contains('timed out')) {
    return 'Apple sign-in timed out. Check Supabase Apple OAuth and allow '
        'http://127.0.0.1:*/auth/callback as a redirect URL.';
  }
  final tail = text.length > 220 ? '${text.substring(0, 220)}…' : text;
  return tail;
}

String _formatExpiry(DateTime when) {
  final months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[when.month - 1]} ${when.day}, ${when.year}';
}

class _EngineSection extends HookWidget {
  const _EngineSection();

  @override
  Widget build(BuildContext context) {
    final pathFuture = useMemoized(findStockfishBinary, const []);
    final snapshot = useFuture(pathFuture);
    final ready = StockfishSingleton().isEngineHealthy;
    final path = snapshot.data;
    final loading = snapshot.connectionState != ConnectionState.done;

    String statusLabel;
    Color statusColor;
    String description;
    if (loading) {
      statusLabel = 'Checking…';
      statusColor = kLightGreyColor;
      description = 'Looking for a Stockfish binary on this machine.';
    } else if (path == null) {
      statusLabel = 'Not configured';
      statusColor = kRedColor;
      description =
          'No Stockfish binary found. Install via brew (macOS), put one '
          'on PATH, or bundle one under assets/engine/. See '
          'lib/desktop/services/engine/desktop_engine_assets.md.';
    } else if (!ready) {
      statusLabel = 'Found, not started';
      statusColor = kPrimaryColor;
      description = 'Engine binary located at:\n$path';
    } else {
      statusLabel = 'Running';
      statusColor = kGreenColor;
      description = path;
    }

    return _Card(
      title: 'Engine',
      icon: Icons.memory_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusPill(label: statusLabel, color: statusColor),
              const Spacer(),
              if (path != null && !ready)
                _SecondaryButton(
                  label: 'Initialize',
                  onTap: () => StockfishSingleton().warmUp(),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _BoardSettingsSection extends ConsumerWidget {
  const _BoardSettingsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.read(desktopTabsProvider.notifier);
    return _Card(
      title: 'Board settings',
      icon: Icons.dashboard_customize_outlined,
      child: _SettingsLinkRow(
        icon: Icons.dashboard_customize_outlined,
        title: 'Open board settings',
        subtitle: 'Theme, piece set, sound, auto-pin, board coordinates.',
        onTap: () => tabs.open(TabKind.boardSettings),
      ),
    );
  }
}

class _NotificationsSection extends ConsumerWidget {
  const _NotificationsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.read(desktopTabsProvider.notifier);
    return _Card(
      title: 'Notifications',
      icon: Icons.notifications_outlined,
      child: _SettingsLinkRow(
        icon: Icons.notifications_outlined,
        title: 'Open notification preferences',
        subtitle: 'Push alerts and per-event notification preferences.',
        onTap: () => tabs.open(TabKind.notificationSettings),
      ),
    );
  }
}

class _SettingsLinkRow extends StatefulWidget {
  const _SettingsLinkRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_SettingsLinkRow> createState() => _SettingsLinkRowState();
}

class _SettingsLinkRowState extends State<_SettingsLinkRow> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final nudgeX = _pressed ? -1.5 : (_hovered ? 4.0 : 0.0);
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit:
            (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
            color: _hovered ? kBlack3Color : Colors.transparent,
            child: SingleMotionBuilder(
              value: nudgeX,
              motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
              builder:
                  (context, x, child) =>
                      Transform.translate(offset: Offset(x, 0), child: child),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: kPrimaryColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Icon(widget.icon, size: 16, color: kPrimaryColor),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: kLightGreyColor,
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

class _UpdatesSection extends HookConsumerWidget {
  const _UpdatesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = Platform.isMacOS || Platform.isWindows;
    final update = supported ? ref.watch(desktopUpdateStateProvider) : null;
    final checking = useState<bool>(false);
    final lastCheckedAt = useState<DateTime?>(null);
    final error = useState<String?>(null);

    Future<void> handleCheck() async {
      if (checking.value) return;
      error.value = null;
      checking.value = true;
      try {
        await DesktopUpdaterService.instance.checkForUpdates();
        // Give the updater pipeline a beat to push a listener event
        // into [state] before we drop the spinner — keeps the UI from
        // flashing back to "Up to date" while a callback is still in
        // flight.
        await Future<void>.delayed(const Duration(seconds: 2));
        lastCheckedAt.value = DateTime.now();
      } catch (e) {
        error.value = e.toString();
      } finally {
        checking.value = false;
      }
    }

    Future<void> handleInstall() async {
      await DesktopUpdaterService.instance.applyUpdate();
    }

    Future<void> handleOpenDownloadPage() async {
      await DesktopUpdaterService.instance.openDownloadPage();
    }

    final status = update?.status ?? DesktopUpdateStatus.idle;
    final ready = update?.isReadyToApply ?? false;
    final installing = status == DesktopUpdateStatus.installing;
    final manual = status == DesktopUpdateStatus.manualDownloadRequired;

    String pillLabel;
    Color pillColor;
    String description;

    if (!supported) {
      pillLabel = 'Not available';
      pillColor = kLightGreyColor;
      description =
          'Automatic updates are only wired for macOS and Windows builds. '
          'Reinstall from chessever.com to update.';
    } else if (installing) {
      pillLabel = 'Installing…';
      pillColor = kPrimaryColor;
      description =
          'Quitting ChessEver to install v${update?.version ?? ''}. The app '
          'will relaunch automatically.';
    } else if (manual) {
      pillLabel = 'Manual update needed';
      pillColor = kRedColor;
      description =
          update?.errorMessage ??
          'Automatic update could not complete safely. Open the website and '
              'download the latest desktop version.';
    } else if (ready) {
      pillLabel = 'Update ready';
      pillColor = kGreenColor;
      description =
          'Version ${update?.version ?? ''} downloaded and ready to install. '
          'Installing will quit and relaunch ChessEver.';
    } else if (status == DesktopUpdateStatus.available) {
      pillLabel = 'Downloading…';
      pillColor = kPrimaryColor;
      description =
          'Version ${update?.version ?? ''} is downloading in the background. '
          'You can keep working — we\'ll prompt you once it\'s ready.';
    } else if (status == DesktopUpdateStatus.retrying) {
      pillLabel = 'Retrying…';
      pillColor = kPrimaryColor;
      final retryLabel =
          update == null || update.maxRetryAttempts == 0
              ? ''
              : ' Attempt ${update.retryAttempt}/${update.maxRetryAttempts}.';
      description =
          'Automatic update failed and will retry shortly.$retryLabel '
          'You can retry now or open the website if this keeps failing.';
    } else if (checking.value || status == DesktopUpdateStatus.checking) {
      pillLabel = 'Checking…';
      pillColor = kLightGreyColor;
      description = 'Contacting the update feed…';
    } else if (status == DesktopUpdateStatus.error) {
      pillLabel = 'Check failed';
      pillColor = kRedColor;
      description =
          update?.errorMessage ??
          'Could not reach the update feed. Check your connection and try '
              'again.';
    } else {
      pillLabel = 'Up to date';
      pillColor = kGreenColor;
      description =
          lastCheckedAt.value == null
              ? 'ChessEver checks for updates automatically once an hour. You can '
                  'also check manually below.'
              : 'No new version available as of '
                  '${_formatLastChecked(lastCheckedAt.value!)}.';
    }

    return _Card(
      title: 'Updates',
      icon: Icons.system_update_alt_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusPill(label: pillLabel, color: pillColor),
              const Spacer(),
              if (supported && manual) ...[
                _SecondaryButton(
                  label: checking.value ? 'Retrying…' : 'Retry updater',
                  onTap: checking.value || installing ? null : handleCheck,
                ),
                const SizedBox(width: 8),
                _PrimaryButton(
                  icon: Icons.open_in_browser_rounded,
                  label: 'Download page',
                  onTap: handleOpenDownloadPage,
                ),
              ] else if (supported && ready && !installing)
                _PrimaryButton(
                  icon: Icons.download_done_rounded,
                  label: 'Install and relaunch',
                  onTap: handleInstall,
                )
              else if (supported)
                _SecondaryButton(
                  label: checking.value ? 'Checking…' : 'Check for updates',
                  onTap: checking.value || installing ? null : handleCheck,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          if (error.value != null) ...[
            const SizedBox(height: 12),
            Text(
              error.value!,
              style: const TextStyle(color: kRedColor, fontSize: 12),
            ),
          ],
          if ((update?.releaseNotes ?? '').isNotEmpty &&
              (ready || status == DesktopUpdateStatus.available)) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kBlack3Color.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: kDividerColor),
              ),
              child: Text(
                update!.releaseNotes,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatLastChecked(DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(when.hour)}:${two(when.minute)}';
}

class _PlatformSection extends ConsumerWidget {
  const _PlatformSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appVersion = ref.watch(appVersionProvider).valueOrNull;
    return _Card(
      title: 'Platform',
      icon: Icons.computer_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValueRow(
            'App version',
            appVersion == null ? '—' : 'v$appVersion',
          ),
          _KeyValueRow('Operating System', Platform.operatingSystem),
          _KeyValueRow(
            'Number of processors',
            Platform.numberOfProcessors.toString(),
          ),
          const SizedBox(height: 12),
          const Text(
            'Window position, sidebar state, and pane sizes are persisted '
            'in the local SQLite database and restored on next launch.',
            style: TextStyle(color: kLightGreyColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow(this.k, this.v);
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 180,
            child: Text(
              k,
              style: const TextStyle(color: kLightGreyColor, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(color: kWhiteColor70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: kWhiteColor70),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: kDividerColor, height: 1),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return ClickCursor(
      enabled: !disabled,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit:
            (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
          onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
          onTapCancel: disabled ? null : () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: disabled ? 1.0 : (_pressed ? 0.96 : (_hovered ? 1.02 : 1.0)),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:
                    disabled
                        ? kPrimaryColor.withValues(alpha: 0.4)
                        : (_hovered
                            ? kPrimaryColor
                            : kPrimaryColor.withValues(alpha: 0.92)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 16, color: kBackgroundColor),
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: kBackgroundColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
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

class _SecondaryButton extends StatefulWidget {
  const _SecondaryButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  State<_SecondaryButton> createState() => _SecondaryButtonState();
}

class _SecondaryButtonState extends State<_SecondaryButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return ClickCursor(
      enabled: !disabled,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit:
            (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
          onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
          onTapCancel: disabled ? null : () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: disabled ? 1.0 : (_pressed ? 0.96 : (_hovered ? 1.02 : 1.0)),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:
                    disabled
                        ? kBlack3Color.withValues(alpha: 0.45)
                        : (_hovered ? kBlack3Color : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDividerColor),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: disabled ? kWhiteColor70 : kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
