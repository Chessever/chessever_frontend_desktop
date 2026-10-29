import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/auth/desktop_guest_upgrade_dialog.dart';
import 'package:chessever/desktop/services/billing/mac_app_store_billing.dart';
import 'package:chessever/desktop/services/desktop_subscription_stub.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Store prices and purchase actions. No web checkout or inferred trial price.
class MacAppStorePlans extends ConsumerStatefulWidget {
  const MacAppStorePlans({super.key, this.onAccountBound});

  final ValueChanged<String?>? onAccountBound;

  @override
  ConsumerState<MacAppStorePlans> createState() => _MacAppStorePlansState();
}

class _MacAppStorePlansState extends ConsumerState<MacAppStorePlans> {
  late Future<List<Package>> _packages;
  Package? _selected;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _packages =
        ref.read(desktopWindowRoleProvider) == DesktopWindowRole.main
            ? MacAppStoreBilling.instance.packages()
            : Future.value(const []);
  }

  Future<void> _run({Package? package}) async {
    if (_busy) return;
    if (!await ensureDesktopPermanentAccountForPurchase(context)) return;
    if (!mounted || _busy) return;
    final accountId = Supabase.instance.client.auth.currentUser?.id;
    if (accountId == null) return;
    widget.onAccountBound?.call(accountId);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final info =
          package == null
              ? await MacAppStoreBilling.instance.restore()
              : await MacAppStoreBilling.instance.purchase(package);
      final storeActive = MacAppStoreBilling.snapshotFrom(info).isActive;
      final confirmed = await DesktopSubscriptionNotifier.current
          ?.refreshAfterStoreTransaction(
            accountId: accountId,
            reconcile:
                () => MacAppStoreBilling.instance.reconcileStoreTransaction(
                  accountId: accountId,
                  expectActive: storeActive,
                ),
          );
      if (Supabase.instance.client.auth.currentUser?.id != accountId) return;
      if (mounted) {
        setState(() {
          _message =
              confirmed?.isActive == true
                  ? 'Premium is active on your ChessEver account.'
                  : storeActive
                  ? 'Your purchase has not been confirmed for this ChessEver account. Use Restore purchases to check again.'
                  : package == null
                  ? 'No active purchases were found for this Apple Account.'
                  : 'Your purchase is pending. Premium will appear when approved.';
        });
      }
    } on PlatformException catch (error) {
      final code = PurchasesErrorHelper.getErrorCode(error);
      if (mounted &&
          Supabase.instance.client.auth.currentUser?.id == accountId &&
          code != PurchasesErrorCode.purchaseCancelledError) {
        setState(
          () =>
              _message =
                  code == PurchasesErrorCode.paymentPendingError
                      ? 'Your purchase is awaiting approval from Apple.'
                      : 'The App Store could not complete this request. Please try again.',
        );
      }
    } catch (_) {
      if (mounted &&
          Supabase.instance.client.auth.currentUser?.id == accountId) {
        setState(
          () =>
              _message =
                  'Your membership could not be updated. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _message = 'This link could not be opened. Please retry.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(desktopWindowRoleProvider) == DesktopWindowRole.detached) {
      return const Text(
        'Manage Premium in Settings in the main ChessEver window.',
        style: TextStyle(color: kWhiteColor70, height: 1.5),
      );
    }
    final subscribed = ref.watch(subscriptionProvider).isSubscribed;
    return FutureBuilder<List<Package>>(
      future: _packages,
      builder: (context, snapshot) {
        final packages = snapshot.data;
        final selected = _selected ?? packages?.last;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (subscribed)
              const Text(
                'Your ChessEver Premium membership is active.',
                style: TextStyle(color: kWhiteColor70),
              )
            else if (snapshot.hasError) ...[
              const Text(
                'App Store prices could not be loaded.',
                style: TextStyle(color: kWhiteColor70),
              ),
              const SizedBox(height: 12),
              DesktopDialogButton(
                label: 'Retry loading prices',
                onPress:
                    () => setState(() {
                      _selected = null;
                      _packages = MacAppStoreBilling.instance.packages();
                    }),
              ),
            ] else if (packages == null)
              const Text(
                'Loading App Store prices…',
                style: TextStyle(color: kWhiteColor70),
              )
            else
              for (final package in packages) ...[
                DesktopDialogButton(
                  label:
                      '${package.packageType == PackageType.annual ? 'Annual' : 'Monthly'}: '
                      '${package.storeProduct.priceString} '
                      '${package.packageType == PackageType.annual ? 'per year' : 'per month'}',
                  tone:
                      selected == package
                          ? DesktopDialogButtonTone.primary
                          : DesktopDialogButtonTone.ghost,
                  fillWidth: true,
                  icon: selected == package ? Icons.check_rounded : null,
                  onPress:
                      _busy ? null : () => setState(() => _selected = package),
                ),
                const SizedBox(height: 8),
              ],
            if (!subscribed) ...[
              const SizedBox(height: 12),
              DesktopDialogButton(
                label:
                    _busy ? 'Waiting for App Store…' : 'Subscribe with Apple',
                tone: DesktopDialogButtonTone.primary,
                fillWidth: true,
                onPress:
                    _busy || selected == null
                        ? null
                        : () => _run(package: selected),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Payment is charged to your Apple Account. The subscription renews '
              'automatically unless cancelled at least 24 hours before the current '
              'period ends. Manage or cancel in your App Store account settings.',
              style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                DesktopDialogButton(
                  label: 'Restore purchases',
                  tone: DesktopDialogButtonTone.ghost,
                  onPress: _busy ? null : () => _run(),
                ),
                DesktopDialogButton(
                  label: 'Manage subscriptions',
                  tone: DesktopDialogButtonTone.ghost,
                  onPress:
                      () =>
                          _open('https://apps.apple.com/account/subscriptions'),
                ),
                DesktopDialogButton(
                  label: 'Privacy policy',
                  tone: DesktopDialogButtonTone.ghost,
                  onPress: () => _open('https://chessever.com/privacy-policy'),
                ),
                DesktopDialogButton(
                  label: 'Terms of use',
                  tone: DesktopDialogButtonTone.ghost,
                  onPress: () => _open('https://chessever.com/terms-of-use'),
                ),
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                style: const TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
            ],
          ],
        );
      },
    );
  }
}
