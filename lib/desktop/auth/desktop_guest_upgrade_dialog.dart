import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/auth/desktop_guest_unsaved_work.dart';
import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_icon.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/svg_asset.dart';

String _guestDaysLabel(int days) => days == 1 ? '1 day' : '$days days';

/// Day 7 and weekly after: a dismissible reminder. Returns `true` when the
/// guest signed in from it.
Future<bool> showDesktopGuestReminder(
  BuildContext context, {
  required int guestDays,
}) async {
  final upgraded = await showDesktopModal<bool>(
    context,
    maxWidth: 440,
    builder:
        (dialogContext) => _GuestAccountBody(
          surface: 'guest_reminder',
          title: 'Keep your chess, wherever you play',
          message:
              '${_guestDaysLabel(guestDays)} as a guest. '
              'A free account keeps it all safe, on every device.',
          dismissLabel: 'Not now',
          onDone: (signedIn) => Navigator.of(dialogContext).pop(signedIn),
        ),
  );
  return upgraded == true;
}

/// Day 28: sign-in is required. The modal cannot be dismissed, but the shell
/// stays mounted underneath it: no tab is closed and no draft is discarded.
/// Unsaved board analysis can be exported to PGN before signing in.
Future<void> showDesktopGuestRequiredSignIn(
  BuildContext context, {
  required int guestDays,
}) async {
  await showDesktopModal<bool>(
    context,
    maxWidth: 460,
    barrierDismissible: false,
    builder:
        (dialogContext) => PopScope(
          canPop: false,
          child: _GuestAccountBody(
            surface: 'guest_required',
            title: 'Sign in to keep going',
            message:
                '${_guestDaysLabel(guestDays)} as a guest. Sign in with a '
                'free account to keep using ChessEver. Your open boards stay '
                'exactly as they are.',
            offerUnsavedExport: true,
            onDone: (signedIn) {
              if (signedIn) Navigator.of(dialogContext).pop(true);
            },
          ),
        ),
  );
}

/// Purchasing needs a permanent account. Returns `true` when the window acts
/// for one, asking a guest to sign in first. The caller then continues the
/// purchase it was about to start.
Future<bool> ensureDesktopPermanentAccountForPurchase(
  BuildContext context,
) async {
  if (desktopCurrentUserIsPermanent()) return true;
  final signedIn = await showDesktopModal<bool>(
    context,
    maxWidth: 440,
    builder:
        (dialogContext) => _GuestAccountBody(
          surface: 'purchase',
          title: 'Sign in to subscribe',
          message:
              'Premium belongs to an account, so it follows you to every '
              'device. Sign in with a free account and checkout continues.',
          dismissLabel: 'Cancel',
          onDone: (signedIn) => Navigator.of(dialogContext).pop(signedIn),
        ),
  );
  return signedIn == true && desktopCurrentUserIsPermanent();
}

class _GuestAccountBody extends ConsumerStatefulWidget {
  const _GuestAccountBody({
    required this.surface,
    required this.title,
    required this.message,
    required this.onDone,
    this.dismissLabel,
    this.offerUnsavedExport = false,
  });

  final String surface;
  final String title;
  final String message;
  final String? dismissLabel;
  final bool offerUnsavedExport;
  final ValueChanged<bool> onDone;

  @override
  ConsumerState<_GuestAccountBody> createState() => _GuestAccountBodyState();
}

class _GuestAccountBodyState extends ConsumerState<_GuestAccountBody> {
  DesktopAccountProvider? _busyProvider;
  bool _exporting = false;
  String? _error;
  String? _exportedPath;

  List<DesktopUnsavedBoard> _unsavedBoards() {
    if (!widget.offerUnsavedExport) return const [];
    final tabs = ref.read(desktopTabsProvider).tabs;
    return collectDesktopUnsavedBoards(
      retainedSessions: ref.read(boardPaneSessionByTabIdProvider),
      liveReaders: ref.read(boardPaneSnapshotReadersProvider),
      titlesByTabId: {for (final tab in tabs) tab.id: tab.title},
    );
  }

  Future<void> _signIn(DesktopAccountProvider provider) async {
    setState(() {
      _busyProvider = provider;
      _error = null;
    });
    try {
      final signedIn = await signInDesktopPermanentAccount(
        ref,
        provider,
        surface: widget.surface,
      );
      if (!mounted) return;
      if (signedIn) {
        widget.onDone(true);
        return;
      }
      setState(() => _error = 'Sign-in did not finish. Please try again.');
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'auth.guest_upgrade');
      if (mounted) setState(() => _error = desktopSignInErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busyProvider = null);
    }
  }

  Future<void> _export(List<DesktopUnsavedBoard> boards) async {
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final path = await exportDesktopUnsavedBoards(boards);
      if (mounted && path != null) setState(() => _exportedPath = path);
    } catch (e, st) {
      ErrorReporter.report(e, stackTrace: st, tag: 'auth.guest_export');
      if (mounted) setState(() => _error = 'Could not write the PGN file.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busyProvider != null;
    final unsaved = _unsavedBoards();
    final exportedName = _exportedPath?.split(RegExp(r'[\\/]')).last;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.message,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          if (unsaved.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              exportedName != null
                  ? 'Exported to $exportedName.'
                  : unsaved.length == 1
                  ? '1 board has unsaved analysis. Export it before you sign in.'
                  : '${unsaved.length} boards have unsaved analysis. '
                      'Export them before you sign in.',
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: DesktopDialogButton(
                label: _exporting ? 'Exporting…' : 'Export as PGN',
                tone: DesktopDialogButtonTone.secondary,
                onPress: busy || _exporting ? null : () => _export(unsaved),
              ),
            ),
          ],
          const SizedBox(height: 20),
          DesktopDialogButton(
            label:
                _busyProvider == DesktopAccountProvider.google
                    ? 'Opening browser…'
                    : 'Continue with Google',
            tone: DesktopDialogButtonTone.primary,
            fillWidth: true,
            prefix: const DesktopIcon(SvgAsset.googleColorIcon, size: 16),
            onPress:
                busy
                    ? null
                    : () => unawaited(_signIn(DesktopAccountProvider.google)),
          ),
          const SizedBox(height: 8),
          DesktopDialogButton(
            label:
                _busyProvider == DesktopAccountProvider.apple
                    ? 'Opening Apple sign-in…'
                    : 'Continue with Apple',
            tone: DesktopDialogButtonTone.secondary,
            fillWidth: true,
            prefix: const DesktopIcon(
              SvgAsset.appleIcon,
              size: 16,
              color: kWhiteColor,
            ),
            onPress:
                busy
                    ? null
                    : () => unawaited(_signIn(DesktopAccountProvider.apple)),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: kRedColor, fontSize: 12),
            ),
          ],
          if (widget.dismissLabel != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: DesktopDialogButton(
                label: widget.dismissLabel!,
                tone: DesktopDialogButtonTone.ghost,
                onPress: busy ? null : () => widget.onDone(false),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A general sign-in prompt for guests, used by the shared
/// `showAuthUpgradeSheet` helper. Returns `true` when the window acts for a
/// permanent account afterwards, including when it already did.
Future<bool> showDesktopAccountSignIn(
  BuildContext context, {
  required String surface,
  required String title,
  required String message,
}) async {
  if (desktopCurrentUserIsPermanent()) return true;
  final signedIn = await showDesktopModal<bool>(
    context,
    maxWidth: 440,
    builder:
        (dialogContext) => _GuestAccountBody(
          surface: surface,
          title: title,
          message: message,
          dismissLabel: 'Not now',
          onDone: (signedIn) => Navigator.of(dialogContext).pop(signedIn),
        ),
  );
  return signedIn == true && desktopCurrentUserIsPermanent();
}
