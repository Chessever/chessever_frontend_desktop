import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_subscription_view.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_button.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';

export 'package:chessever/desktop/auth/desktop_access_policy.dart';

final _pendingDesktopPaywalls = <ProviderContainer, Future<bool>>{};

Future<bool> requireDesktopPremium(
  BuildContext context, {
  String feature = 'This feature',
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  if (container.read(desktopPremiumAccessProvider) == DesktopAccess.allowed) {
    return Future.value(true);
  }
  final pending = _pendingDesktopPaywalls[container];
  if (pending != null) return pending;
  final task = _showDesktopPremium(context, feature: feature);
  _pendingDesktopPaywalls[container] = task;
  return task.whenComplete(() {
    if (identical(_pendingDesktopPaywalls[container], task)) {
      _pendingDesktopPaywalls.remove(container);
    }
  });
}

/// Read again after every awaited prompt: a dismissed dialog is never proof
/// of payment. Callers must also revalidate their tab/account ownership.
Future<bool> _showDesktopPremium(
  BuildContext context, {
  String feature = 'This feature',
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final account =
      DesktopSupabaseInit.isInitialized
          ? Supabase.instance.client.auth.currentUser?.id
          : null;
  if (container.read(desktopPremiumAccessProvider) == DesktopAccess.allowed) {
    return true;
  }
  await showDesktopDialog<void>(
    context,
    builder:
        (context) => Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DesktopLockedFeature(
                    feature: feature,
                    showSubscription: true,
                  ),
                  const SizedBox(height: 16),
                  DesktopPaywallButton(
                    label: 'Close',
                    onPress: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ),
        ),
  );
  return context.mounted &&
      (!DesktopSupabaseInit.isInitialized ||
          Supabase.instance.client.auth.currentUser?.id == account) &&
      container.read(desktopPremiumAccessProvider) == DesktopAccess.allowed;
}

/// Lazy child: locked/restored/detached routes cannot mount expensive providers.
class DesktopAccessGate extends ConsumerStatefulWidget {
  const DesktopAccessGate({
    super.key,
    required this.feature,
    required this.builder,
  });
  final String feature;
  final WidgetBuilder builder;
  @override
  ConsumerState<DesktopAccessGate> createState() => _DesktopAccessGateState();
}

class _DesktopAccessGateState extends ConsumerState<DesktopAccessGate> {
  bool _admitted = false;
  @override
  Widget build(BuildContext context) {
    final access = ref.watch(desktopPremiumAccessProvider);
    if (access == DesktopAccess.allowed) _admitted = true;
    // Preserve an admitted workspace during routine refresh, but new actions
    // still check the live policy and cannot start while checking.
    if (access == DesktopAccess.allowed ||
        (_admitted &&
            access == DesktopAccess.checking &&
            desktopCanContinuePremiumWork(ref.watch(subscriptionProvider)))) {
      return widget.builder(context);
    }
    _admitted = false;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: DesktopLockedFeature(feature: widget.feature),
          ),
        ),
      ),
    );
  }
}

class DesktopLockedFeature extends ConsumerWidget {
  const DesktopLockedFeature({
    super.key,
    required this.feature,
    this.showSubscription = false,
  });
  final String feature;
  final bool showSubscription;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(desktopPremiumAccessProvider);
    if (access == DesktopAccess.checking) {
      return const Text(
        'Checking membership…',
        style: TextStyle(color: kWhiteColor70),
      );
    }
    if (access == DesktopAccess.unavailable) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Membership could not be verified. Your saved work is unchanged.',
            style: TextStyle(color: kWhiteColor70),
          ),
          const SizedBox(height: 12),
          DesktopPaywallButton(
            label: 'Retry membership check',
            onPress: () async {
              await DesktopSubscriptionNotifier.current?.refreshFromBackend();
            },
          ),
        ],
      );
    }
    if (access == DesktopAccess.allowed) {
      return const Text(
        'Premium is active. Close to continue.',
        style: TextStyle(color: kWhiteColor70),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$feature · Premium',
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        if (feature == 'Prepare') ...[
          const Text(
            'Locked preview — no player data has been loaded.\n\n'
            'Overview · performance statistics and charts\n'
            'Accounts · ChessEver, Lichess and Chess.com sources\n'
            'Games · browse and open preparation games\n'
            'Build tree · explore a player’s repertoire\n\n'
            'Import, sync and reinstall sources with Premium. Existing PGN files '
            'remain available through Library for opening and export.',
            style: TextStyle(color: kWhiteColor70, height: 1.6),
          ),
          const SizedBox(height: 16),
        ],
        if (showSubscription)
          DesktopSubscriptionView(
            onSubscribed: () {},
            reason:
                'Unlock $feature with your existing cross-device membership.',
          )
        else
          DesktopPaywallButton(
            label: 'View Premium',
            onPress: () async {
              await requireDesktopPremium(context, feature: feature);
            },
          ),
      ],
    );
  }
}
