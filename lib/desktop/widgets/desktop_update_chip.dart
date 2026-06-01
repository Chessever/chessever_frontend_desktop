import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_updater.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/pressable_scale.dart';
import 'package:chessever/theme/app_theme.dart';

/// Top-left "Update" chip rendered with forui primitives + the same primary
/// button vocabulary used by onboarding / board editor (cyan
/// [kPrimaryColor], `PressableScale` press feedback, 8-px radius). Hover
/// reveals a popover showing the release notes; clicking the chip (or the
/// "Restart & Update" button inside the popover) terminates the running
/// app and lets the platform installer swap the binary in place.
///
/// Renders nothing while idle so the corner stays clean for users who are
/// already on the latest build. Major-version bumps go through
/// [MandatoryUpdateGate] instead of this chip.
class DesktopUpdateChip extends ConsumerStatefulWidget {
  const DesktopUpdateChip({super.key});

  @override
  ConsumerState<DesktopUpdateChip> createState() => _DesktopUpdateChipState();
}

class _DesktopUpdateChipState extends ConsumerState<DesktopUpdateChip>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);
  Timer? _dismissTimer;
  bool _hoveringChip = false;
  bool _hoveringPopover = false;

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted) return;
      if (_hoveringChip || _hoveringPopover) return;
      _controller.hide();
    });
  }

  void _show() {
    _dismissTimer?.cancel();
    if (_controller.status != AnimationStatus.completed &&
        _controller.status != AnimationStatus.forward) {
      _controller.show();
    }
  }

  Future<void> _handleAction(DesktopUpdateState state) async {
    _dismissTimer?.cancel();
    await _controller.hide();
    if (state.requiresManualDownload) {
      await DesktopUpdaterService.instance.openDownloadPage();
      return;
    }
    await DesktopUpdaterService.instance.applyUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopUpdateStateProvider);
    final visible =
        !state.isMajor &&
        (state.isReadyToApply || state.requiresManualDownload);
    if (!visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_controller.status == AnimationStatus.completed ||
            _controller.status == AnimationStatus.forward) {
          _controller.hide();
        }
      });
      return const SizedBox.shrink();
    }

    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverAnchor: Alignment.topLeft,
        childAnchor: Alignment.bottomLeft,
        spacing: const FPortalSpacing(8),
        hideRegion: FPopoverHideRegion.anywhere,
        popoverBuilder:
            (context, _) => MouseRegion(
              onEnter: (_) {
                _hoveringPopover = true;
                _show();
              },
              onExit: (_) {
                _hoveringPopover = false;
                _scheduleDismiss();
              },
              child: _PopoverBody(
                state: state,
                onApply: () => _handleAction(state),
              ),
            ),
        child: MouseRegion(
          onEnter: (_) {
            _hoveringChip = true;
            _show();
          },
          onExit: (_) {
            _hoveringChip = false;
            _scheduleDismiss();
          },
          child: ClickCursor(
            child: PressableScale(
              hoveredScale: 1.014,
              pressedScale: 0.96,
              child: FButton(
                style: _chipPrimaryStyle(),
                onPress: () => _handleAction(state),
                mainAxisSize: MainAxisSize.min,
                prefix: const Icon(Icons.arrow_circle_up_rounded),
                child: Text(_label(state)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Always "Update [version]" — the chip is only ever rendered while the
  // download is finished and ready to install (see [isReadyToApply]). The
  // `installing` substate exists for ~80ms between the tap and the
  // platform terminate call, but the app is on its way out by then so we
  // don't flicker the label to "Updating…".
  String _label(DesktopUpdateState state) =>
      state.requiresManualDownload
          ? 'Download latest'
          : state.version.isEmpty
          ? 'Update'
          : 'Update ${state.version}';
}

class _PopoverBody extends StatelessWidget {
  const _PopoverBody({required this.state, required this.onApply});

  final DesktopUpdateState state;
  final Future<void> Function() onApply;

  @override
  Widget build(BuildContext context) {
    final notes =
        state.requiresManualDownload
            ? (state.errorMessage ?? '').trim()
            : state.releaseNotes.trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360, minWidth: 280),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: kPopUpColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kDividerColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 24,
                offset: const Offset(0, 8),
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
                    Icons.arrow_circle_up_rounded,
                    size: 16,
                    color: kPrimaryColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.version.isEmpty
                          ? (state.requiresManualDownload
                              ? 'Manual update required'
                              : 'New version available')
                          : state.requiresManualDownload
                          ? 'Download ${state.version}'
                          : 'Version ${state.version} is ready',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                notes.isNotEmpty
                    ? notes
                    : state.requiresManualDownload
                    ? 'The automatic updater could not complete safely. Open '
                        'the website and download the latest desktop version.'
                    : 'A new build of ChessEver has been downloaded in the '
                        'background. Click below to install it and restart.',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: PressableScale(
                  hoveredScale: 1.014,
                  pressedScale: 0.96,
                  child: FButton(
                    style: _chipPrimaryStyle(),
                    onPress: onApply,
                    mainAxisSize: MainAxisSize.min,
                    prefix: Icon(
                      state.requiresManualDownload
                          ? Icons.open_in_browser_rounded
                          : Icons.restart_alt_rounded,
                    ),
                    child: Text(
                      state.requiresManualDownload
                          ? 'Open download page'
                          : 'Restart & Update',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cyan primary button styling that mirrors the onboarding / editor primary
/// tone: [kPrimaryColor] fill, dark text, hover-brighten + glow, 8-px radius.
/// Lives here (rather than shared) because the chip's geometry is tighter
/// than the form-field-sized onboarding buttons.
FBaseButtonStyle Function(FButtonStyle style) _chipPrimaryStyle() {
  return FButtonStyle.primary(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          color: kPrimaryColor.withValues(alpha: 0.24),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.18)),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: const Color(0xFF22C4F4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kLightYellowColor.withValues(alpha: 0.58)),
          boxShadow: [
            BoxShadow(
              color: kPrimaryColor.withValues(alpha: 0.22),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        WidgetState.any: BoxDecoration(
          color: kPrimaryColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.65)),
          boxShadow: [
            BoxShadow(
              color: kPrimaryColor.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            spacing: 7,
            textStyle: FWidgetStateMap.all(
              const TextStyle(
                color: kBackgroundColor,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                height: 1,
              ),
            ),
            iconStyle: FWidgetStateMap.all(
              const IconThemeData(color: kBackgroundColor, size: 14),
            ),
          ),
    ),
  );
}
