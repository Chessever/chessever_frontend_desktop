import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/services/auth/desktop_account_deletion.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/theme/app_theme.dart';

bool desktopAccountUsesApple(User? user) {
  final providers = user?.appMetadata['providers'];
  return user?.identities?.any((identity) => identity.provider == 'apple') ==
          true ||
      user?.appMetadata['provider'] == 'apple' ||
      (providers is List && providers.contains('apple'));
}

/// Discoverable in Account settings, without danger styling before confirmation.
class DesktopDeleteAccountAction extends StatelessWidget {
  const DesktopDeleteAccountAction({
    super.key,
    required this.isGuest,
    required this.onPress,
  });
  final bool isGuest;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => DesktopDialogButton(
    label: isGuest ? 'Delete guest account' : 'Delete account',
    tone: DesktopDialogButtonTone.ghost,
    onPress: onPress,
  );
}

/// Opens the permanent account deletion confirmation.
///
/// Resolves to `true` only when the account was deleted. [onDelete] replaces
/// the real deletion (tests); by default it runs
/// [desktopAccountDeletionProvider].
Future<bool> showDesktopDeleteAccountDialog(
  BuildContext context, {
  String? email,
  Future<void> Function()? onDelete,
}) async {
  final user = Supabase.instance.client.auth.currentUser;
  final usesApple = desktopAccountUsesApple(user);
  final deleted = await showDesktopModal<bool>(
    context,
    title: 'Delete account',
    maxWidth: 500,
    builder:
        (_) => DesktopDeleteAccountDialogBody(
          email: email,
          onDelete: onDelete,
          usesApple: usesApple,
          isGuest: user?.isAnonymous == true,
          expectedAccountId: user?.id,
        ),
  );
  return deleted == true;
}

/// Same semantics as the phone dialog: an explicit acknowledgement enables
/// Delete, the spinner stays inline while the request runs, failures render
/// in place, and nothing can dismiss the dialog mid-deletion (Cancel is
/// disabled, and [PopScope] blocks Esc, the close button and the barrier).
class DesktopDeleteAccountDialogBody extends ConsumerStatefulWidget {
  const DesktopDeleteAccountDialogBody({
    super.key,
    this.email,
    this.onDelete,
    this.usesApple = false,
    this.isGuest = false,
    this.expectedAccountId,
  });

  final String? email;
  final Future<void> Function()? onDelete;
  final bool usesApple;
  final bool isGuest;
  final String? expectedAccountId;

  @override
  ConsumerState<DesktopDeleteAccountDialogBody> createState() =>
      _DesktopDeleteAccountDialogBodyState();
}

class _DesktopDeleteAccountDialogBodyState
    extends ConsumerState<DesktopDeleteAccountDialogBody> {
  bool _understood = false;
  bool _deleting = false;
  String? _error;
  bool _deleted = false;
  DesktopAccountDeletionResult? _result;

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
      setState(() => _error = 'Could not open this link. Please try again.');
    }
  }

  Future<void> _delete() async {
    if (!_understood || _deleting) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      if (widget.expectedAccountId != null &&
          Supabase.instance.client.auth.currentUser?.id !=
              widget.expectedAccountId) {
        throw const DesktopAccountDeletionException(
          'Your account changed. Close this dialog and try again.',
        );
      }
      final DesktopAccountDeletionResult result;
      if (widget.onDelete case final onDelete?) {
        await onDelete();
        result = DesktopAccountDeletionResult(
          appleManualRevokeRequired: widget.usesApple,
        );
      } else {
        result = await ref.read(desktopAccountDeletionProvider).run();
      }
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _deleted = true;
        _result = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error =
            error is DesktopAccountDeletionException
                ? error.message
                : desktopAccountDeletionMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.email?.trim();
    if (_deleted) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your ChessEver account has been deleted.',
              style: TextStyle(color: kWhiteColor, fontSize: 14),
            ),
            if (_result?.dataRemovalPending == true) ...[
              const SizedBox(height: 12),
              const Text(
                'Some associated service data is queued for removal. Contact info@chessever.com if you need help checking its status.',
                style: TextStyle(color: kWhiteColor70, height: 1.5),
              ),
            ],
            if (_result?.appleRevocationPending == true) ...[
              const SizedBox(height: 12),
              const Text(
                'Your Sign in with Apple connection is queued for automatic removal. You can also disconnect ChessEver in your Apple Account.',
                style: TextStyle(color: kWhiteColor70, height: 1.5),
              ),
            ],
            if (_result?.appleManualRevokeRequired == true ||
                _result?.appleRevocationPending == true) ...[
              const SizedBox(height: 12),
              const Text(
                'To remove the remaining Sign in with Apple connection, open your Apple Account, choose Sign-In and Security > Sign in with Apple > ChessEver, then stop using Sign in with Apple.',
                style: TextStyle(color: kWhiteColor70, height: 1.5),
              ),
              const SizedBox(height: 12),
              DesktopDialogButton(
                label: 'Open Apple Account',
                onPress:
                    () => _open('https://account.apple.com/account/manage'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: kRedColor)),
            ],
            const SizedBox(height: 20),
            DesktopDialogButton(
              label: 'Done',
              onPress: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      );
    }
    return PopScope(
      canPop: !_deleting,
      child: FTheme(
        data: FThemes.zinc.dark,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'This permanently deletes '),
                    TextSpan(
                      text:
                          email == null || email.isEmpty
                              ? widget.isGuest
                                  ? 'your guest account'
                                  : 'your account'
                              : email,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const TextSpan(
                      text:
                          ' and everything synced to it: favorites, library '
                          'books, saved analyses and engine settings.',
                    ),
                  ],
                ),
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'It cannot be undone. Database files on this computer are '
                'not removed.',
                style: TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              if (!widget.isGuest) ...[
                const Text(
                  'Deleting your account does not cancel subscriptions. If you subscribed with Apple, billing continues until you cancel in your App Store account settings. Please cancel before deleting. You can still delete your account immediately.',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                DesktopDialogButton(
                  label: 'Manage Apple subscriptions',
                  tone: DesktopDialogButtonTone.ghost,
                  onPress:
                      _deleting
                          ? null
                          : () => _open(
                            'https://apps.apple.com/account/subscriptions',
                          ),
                ),
                const SizedBox(height: 14),
              ],
              if (widget.usesApple) ...[
                const Text(
                  'We also request removal of the Sign in with Apple connection. If a manual step is needed, we will show instructions after deletion.',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
              ],
              FCheckbox(
                value: _understood,
                enabled: !_deleting,
                onChange:
                    (value) => setState(() {
                      _understood = value;
                      _error = null;
                    }),
                label: const Text('I understand the consequences'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 16,
                        color: kRedColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: kRedColor,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    onPress:
                        _deleting
                            ? null
                            : () => Navigator.of(context).maybePop(false),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    key: const ValueKey('desktop-delete-account-confirm'),
                    label: _deleting ? 'Deleting' : 'Delete account',
                    tone: DesktopDialogButtonTone.danger,
                    prefix:
                        _deleting
                            ? const SizedBox.square(
                              dimension: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: kRedColor,
                              ),
                            )
                            : null,
                    onPress: _understood && !_deleting ? _delete : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
