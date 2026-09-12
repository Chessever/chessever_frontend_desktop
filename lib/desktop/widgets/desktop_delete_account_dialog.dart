import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/auth/desktop_account_deletion.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/theme/app_theme.dart';

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
  final deleted = await showDesktopModal<bool>(
    context,
    title: 'Delete account',
    maxWidth: 460,
    builder:
        (_) => DesktopDeleteAccountDialogBody(email: email, onDelete: onDelete),
  );
  return deleted == true;
}

/// Same semantics as the phone dialog: an explicit acknowledgement enables
/// Delete, the spinner stays inline while the request runs, failures render
/// in place, and nothing can dismiss the dialog mid-deletion (Cancel is
/// disabled, and [PopScope] blocks Esc, the close button and the barrier).
class DesktopDeleteAccountDialogBody extends ConsumerStatefulWidget {
  const DesktopDeleteAccountDialogBody({super.key, this.email, this.onDelete});

  final String? email;
  final Future<void> Function()? onDelete;

  @override
  ConsumerState<DesktopDeleteAccountDialogBody> createState() =>
      _DesktopDeleteAccountDialogBodyState();
}

class _DesktopDeleteAccountDialogBodyState
    extends ConsumerState<DesktopDeleteAccountDialogBody> {
  bool _understood = false;
  bool _deleting = false;
  String? _error;

  Future<void> _delete() async {
    if (!_understood || _deleting) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    final run = widget.onDelete ?? ref.read(desktopAccountDeletionProvider).run;
    try {
      await run();
      if (!mounted) return;
      setState(() => _deleting = false);
      Navigator.of(context).pop(true);
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
                              ? 'your account'
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
