import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chessever/desktop/services/desktop_updater.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/theme/app_theme.dart';

bool _desktopUpdateCommandRunning = false;

/// Runs the user-facing update command from native menus and any future
/// command-palette entry.
Future<void> runDesktopUpdateCommand(BuildContext context) async {
  final service = DesktopUpdaterService.instance;
  final initialState = service.state.value;

  if (initialState.isReadyToApply) {
    await _showReadyToInstallDialog(context, initialState);
    return;
  }

  if (initialState.requiresManualDownload) {
    await _showManualDownloadDialog(context, initialState);
    return;
  }

  if (_desktopUpdateCommandRunning) {
    showDesktopToast(context, 'Already checking for updates...');
    return;
  }

  _desktopUpdateCommandRunning = true;
  showDesktopToast(context, 'Checking for updates...');

  try {
    await service.checkForUpdates();
    if (!context.mounted) return;

    final nextState = service.state.value;
    if (nextState.isReadyToApply) {
      await _showReadyToInstallDialog(context, nextState);
      return;
    }
    if (nextState.requiresManualDownload) {
      await _showManualDownloadDialog(context, nextState);
      return;
    }
    if (nextState.isRetrying) {
      showDesktopToast(
        context,
        'Update check failed. ChessEver will retry in the background.',
        error: true,
        duration: const Duration(seconds: 4),
      );
      return;
    }
    if (nextState.status == DesktopUpdateStatus.error) {
      showDesktopToast(
        context,
        nextState.errorMessage ?? 'Could not check for updates.',
        error: true,
        duration: const Duration(seconds: 4),
      );
      return;
    }
    if (nextState.status == DesktopUpdateStatus.available) {
      final versionLabel =
          nextState.version.isEmpty ? '' : ' ${nextState.version}';
      showDesktopToast(context, 'Downloading update$versionLabel...');
      return;
    }

    showDesktopToast(context, 'ChessEver is up to date.');
  } catch (e) {
    if (!context.mounted) return;
    showDesktopToast(
      context,
      'Could not check for updates: $e',
      error: true,
      duration: const Duration(seconds: 4),
    );
  } finally {
    _desktopUpdateCommandRunning = false;
  }
}

Future<void> _showReadyToInstallDialog(
  BuildContext context,
  DesktopUpdateState state,
) {
  return showDesktopDialog<void>(
    context,
    barrierDismissible: false,
    child: Center(
      child: _DesktopUpdateCommandDialog(
        icon: Icons.arrow_circle_up_rounded,
        title:
            state.version.isEmpty
                ? 'Update ready'
                : 'ChessEver ${state.version} is ready',
        message:
            'The update has been downloaded. Installing will quit and relaunch '
            'ChessEver.',
        releaseNotes: state.releaseNotes,
        primaryLabel: 'Install and relaunch',
        primaryIcon: Icons.restart_alt_rounded,
        onPrimary: () {
          Navigator.of(context, rootNavigator: true).pop();
          unawaited(DesktopUpdaterService.instance.applyUpdate());
        },
        secondaryLabel: 'Later',
      ),
    ),
  );
}

Future<void> _showManualDownloadDialog(
  BuildContext context,
  DesktopUpdateState state,
) {
  return showDesktopDialog<void>(
    context,
    child: Center(
      child: _DesktopUpdateCommandDialog(
        icon: Icons.open_in_browser_rounded,
        title: 'Manual update needed',
        message:
            state.errorMessage ??
            'The automatic updater could not complete safely. Download the '
                'latest desktop version from the website.',
        primaryLabel: 'Open download page',
        primaryIcon: Icons.open_in_browser_rounded,
        onPrimary: () {
          Navigator.of(context, rootNavigator: true).pop();
          unawaited(DesktopUpdaterService.instance.openDownloadPage());
        },
        secondaryLabel: 'Close',
      ),
    ),
  );
}

class _DesktopUpdateCommandDialog extends StatelessWidget {
  const _DesktopUpdateCommandDialog({
    required this.icon,
    required this.title,
    required this.message,
    required this.primaryLabel,
    required this.primaryIcon,
    required this.onPrimary,
    required this.secondaryLabel,
    this.releaseNotes = '',
  });

  final IconData icon;
  final String title;
  final String message;
  final String releaseNotes;
  final String primaryLabel;
  final IconData primaryIcon;
  final VoidCallback onPrimary;
  final String secondaryLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 440,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        decoration: BoxDecoration(
          color: kPopUpColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.34)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 34,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: kPrimaryColor),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            if (releaseNotes.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: kBlack3Color.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDividerColor),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    releaseNotes.trim(),
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DesktopDialogButton(
                  label: secondaryLabel,
                  onPress:
                      () => Navigator.of(context, rootNavigator: true).pop(),
                  tone: DesktopDialogButtonTone.ghost,
                ),
                const SizedBox(width: 10),
                DesktopDialogButton(
                  label: primaryLabel,
                  icon: primaryIcon,
                  onPress: onPrimary,
                  tone: DesktopDialogButtonTone.primary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
