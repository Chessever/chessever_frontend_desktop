import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/widgets/desktop_toolbar_metrics.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/live_first_mark.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/png_asset.dart';

/// One-click "Live first" toggle for every list of events or games.
///
/// The same control as the web's `RailLiveFirst`: the mark and the words, ink
/// for the state. Pressed, it wears the primary tone; the caller owns the
/// state and what pressing does.
class DesktopLiveFirstButton extends StatelessWidget {
  const DesktopLiveFirstButton({
    super.key,
    required this.pressed,
    required this.onPress,
    this.subject = 'games',
    this.height = desktopToolbarControlHeight,
    this.pillKey,
  });

  final bool pressed;

  /// `null` renders the muted, disabled pill.
  final VoidCallback? onPress;

  /// What the list holds, for the tooltip: `events` or `games`.
  final String subject;
  final double height;

  /// Key for the inner [DesktopToolbarPillButton], for callers whose tests
  /// already look the pill up by key.
  final Key? pillKey;

  @override
  Widget build(BuildContext context) {
    return _QuickToggleChrome(
      pressed: pressed,
      onPress: onPress,
      child: DesktopToolbarPillButton(
        key: pillKey,
        label: 'Live first',
        leading: const LiveFirstMark(),
        height: height,
        tone:
            pressed
                ? DesktopToolbarPillTone.primary
                : DesktopToolbarPillTone.neutral,
        tooltip:
            pressed
                ? 'Live $subject are shown first'
                : 'Show live $subject first',
        onPress: onPress,
      ),
    );
  }
}

/// One-click Classical-only filter, wearing the classical time-control mark
/// the event cards and chessever.com use.
class DesktopClassicalOnlyButton extends StatelessWidget {
  const DesktopClassicalOnlyButton({
    super.key,
    required this.pressed,
    required this.onPress,
    this.height = desktopToolbarControlHeight,
  });

  final bool pressed;
  final VoidCallback? onPress;
  final double height;

  @override
  Widget build(BuildContext context) {
    return _QuickToggleChrome(
      pressed: pressed,
      onPress: onPress,
      child: DesktopToolbarPillButton(
        label: 'Classical',
        leading: Image.asset(
          PngAsset.classicalIcon,
          width: 16,
          height: 16,
          filterQuality: FilterQuality.medium,
        ),
        height: height,
        tone:
            pressed
                ? DesktopToolbarPillTone.primary
                : DesktopToolbarPillTone.neutral,
        tooltip:
            pressed
                ? 'Showing classical games only'
                : 'Show classical games only',
        onPress: onPress,
      ),
    );
  }
}

/// Keyboard reach and toggle semantics for a quick-toggle pill.
///
/// The pill itself only answers the pointer. This adds the pill's single tab
/// stop, which Enter and Space activate, a focus ring drawn on the pill's own
/// radius, and a `toggled` semantics flag so assistive tech reads the state.
class _QuickToggleChrome extends StatefulWidget {
  const _QuickToggleChrome({
    required this.pressed,
    required this.onPress,
    required this.child,
  });

  final bool pressed;
  final VoidCallback? onPress;
  final Widget child;

  @override
  State<_QuickToggleChrome> createState() => _QuickToggleChromeState();
}

class _QuickToggleChromeState extends State<_QuickToggleChrome> {
  bool _focusHighlight = false;

  @override
  Widget build(BuildContext context) {
    final onPress = widget.onPress;
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: onPress != null,
        toggled: widget.pressed,
        child: FocusableActionDetector(
          enabled: onPress != null,
          onShowFocusHighlight:
              (value) => setState(() => _focusHighlight = value),
          // Bound here, not left to the app's defaults: the browser build maps
          // Enter to ButtonActivateIntent, which the actions below answer too.
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onPress?.call();
                return null;
              },
            ),
            ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
              onInvoke: (_) {
                onPress?.call();
                return null;
              },
            ),
          },
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    _focusHighlight
                        ? kPrimaryColor.withValues(alpha: 0.75)
                        : const Color(0x00000000),
              ),
            ),
            // The pill's tooltip has its own focus node; this detector is
            // the one Tab stop.
            child: ExcludeFocus(child: widget.child),
          ),
        ),
      ),
    );
  }
}
