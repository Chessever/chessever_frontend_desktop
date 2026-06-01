import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/auth/desktop_subscription_view.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_button.dart';
import 'package:chessever/theme/app_theme.dart';

/// Shown when the user is authenticated but has no active premium
/// entitlement. ChessEver Desktop is premium-only, so this is the only
/// path to the shell for a free user.
///
/// Two columns:
///   - Left: brand pitch (logo + bullets) — matches [DesktopWelcomeScreen].
///   - Right: the shared [DesktopSubscriptionView] with checkout actions.
///
/// "Sign out" lives in the corner so the user can switch accounts without
/// quitting (e.g. if they paid on a different account on mobile).
class DesktopPremiumRequiredScreen extends ConsumerWidget {
  const DesktopPremiumRequiredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email ?? user?.userMetadata?['email']?.toString();

    return Scaffold(
      backgroundColor: kBackgroundColor,
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 720),
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Expanded(child: _BrandPitch()),
                    const SizedBox(width: 48),
                    Expanded(
                      child: _SubscribeCard(
                        // Gate redraws once the subscription notifier flips
                        // to subscribed, so this callback is a defensive
                        // backup — explicitly poke the gate by toggling
                        // the auth state listener pathway. In practice
                        // DesktopAuthGate observes subscriptionProvider via
                        // the same notifier and rebuilds.
                        onSubscribed: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (email != null)
            Positioned(
              top: 18,
              right: 22,
              child: _AccountChip(email: email),
            ),
        ],
      ),
    );
  }
}

class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: kPrimaryColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            email,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandPitch extends StatelessWidget {
  const _BrandPitch();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset(
            'assets/pngs/new_app_logo.png',
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'Unlock ChessEver Desktop',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 36,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'ChessEver Desktop is built for serious followers and analysts. '
          'A single subscription covers desktop, mobile, and web.',
          style: TextStyle(color: kWhiteColor70, fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 28),
        const _Bullet(
          text:
              'Already subscribed on iPhone or Android? Tap '
              '“I already subscribed — refresh” to sync.',
        ),
        const _Bullet(
          text:
              'Pay on chessever.com if you’d rather use a card you’ve '
              'saved on another device.',
        ),
        const _Bullet(
          text:
              'Cancel any time. Apple and Google handle their own '
              'subscriptions; Stripe handles web purchases.',
        ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 6, right: 12),
            width: 4,
            height: 4,
            decoration: const BoxDecoration(
              color: kPrimaryColor,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscribeCard extends StatelessWidget {
  const _SubscribeCard({required this.onSubscribed});

  final VoidCallback onSubscribed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kDividerColor),
      ),
      child: SingleChildScrollView(
        child: DesktopSubscriptionView(
          reason: 'Subscribe to use ChessEver Desktop.',
          onSubscribed: onSubscribed,
          trailing: DesktopPaywallButton(
            label: 'Sign out',
            tone: DesktopPaywallButtonTone.ghost,
            prefix: const Icon(FIcons.logOut),
            onPress: () async {
              await Supabase.instance.client.auth.signOut();
            },
          ),
        ),
      ),
    );
  }
}
