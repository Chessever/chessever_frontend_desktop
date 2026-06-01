import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_updater.dart';
import 'package:chessever/theme/app_theme.dart';

/// Wraps the entire desktop shell. When the update archive advertises a *major*
/// version bump, this widget overlays a non-dismissible card that funnels
/// the user into the silent install + relaunch flow. The chip in the
/// corner only handles minor / patch updates — anything that bumps the
/// major version means a hard cut and we don't want users staying on an
/// older build.
class MandatoryUpdateGate extends ConsumerWidget {
  const MandatoryUpdateGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(desktopUpdateStateProvider);
    final blocking = shouldBlockForMajorDesktopUpdate(state);

    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (blocking)
          Positioned.fill(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ModalBarrier(
                  dismissible: false,
                  color: Colors.black.withValues(alpha: 0.78),
                ),
                Center(
                  child: FTheme(
                    data: FThemes.zinc.dark,
                    child: _MajorUpdateCard(state: state),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

bool shouldBlockForMajorDesktopUpdate(DesktopUpdateState state) {
  return state.isMajor &&
      (state.status == DesktopUpdateStatus.available ||
          state.status == DesktopUpdateStatus.retrying ||
          state.status == DesktopUpdateStatus.downloaded ||
          state.status == DesktopUpdateStatus.installing ||
          state.status == DesktopUpdateStatus.manualDownloadRequired);
}

class _MajorUpdateCard extends StatelessWidget {
  const _MajorUpdateCard({required this.state});

  final DesktopUpdateState state;

  @override
  Widget build(BuildContext context) {
    final terminal = state.requiresManualDownload;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
          decoration: BoxDecoration(
            color: kPopUpColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kPrimaryColor.withValues(alpha: 0.6)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 36,
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
                  const Icon(
                    Icons.rocket_launch_rounded,
                    size: 20,
                    color: kPrimaryColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Required update — ChessEver ${state.version}',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                terminal
                    ? (state.errorMessage ??
                        'The automatic updater could not complete safely. '
                            'Download the latest version from the website.')
                    : state.releaseNotes.isNotEmpty
                    ? state.releaseNotes
                    : 'A new major version is available. To keep using '
                        'ChessEver, please update now — the app will restart '
                        'automatically once the install finishes.',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: _MajorUpdateAction(state: state),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MajorUpdateAction extends StatelessWidget {
  const _MajorUpdateAction({required this.state});

  final DesktopUpdateState state;

  @override
  Widget build(BuildContext context) {
    if (state.status == DesktopUpdateStatus.installing) {
      return const _UpdateProgress(label: 'Installing update…');
    }
    if (state.requiresManualDownload) {
      return Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: [
          FButton(
            style: FButtonStyle.outline(),
            onPress: () => DesktopUpdaterService.instance.checkForUpdates(),
            mainAxisSize: MainAxisSize.min,
            child: const Text(
              'Retry updater',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          FButton(
            style: FButtonStyle.primary(),
            onPress: () => DesktopUpdaterService.instance.openDownloadPage(),
            mainAxisSize: MainAxisSize.min,
            child: const Text(
              'Open download page',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      );
    }
    if (state.isReadyToApply) {
      return FButton(
        style: FButtonStyle.primary(),
        onPress: () => DesktopUpdaterService.instance.applyUpdate(),
        mainAxisSize: MainAxisSize.min,
        child: const Text(
          'Restart & Update',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
      );
    }
    if (state.isRetrying) {
      return const _UpdateProgress(label: 'Retrying update…');
    }
    return _UpdateProgress(
      label:
          state.progress > 0 && state.progress < 1
              ? 'Downloading ${(state.progress * 100).floor()}%…'
              : 'Downloading update…',
    );
  }
}

class _UpdateProgress extends StatelessWidget {
  const _UpdateProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: kPrimaryColor,
            backgroundColor: kWhiteColor.withValues(alpha: 0.12),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
