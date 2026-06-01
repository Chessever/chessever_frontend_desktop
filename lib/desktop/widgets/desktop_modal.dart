import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';

/// Shared desktop replacement for `showModalBottomSheet`.
///
/// Bottom sheets are a phone idiom — sliding a panel up from the bottom
/// of a 1440 × 900 display feels wrong on desktop. This helper presents
/// the same content as a centred floating modal with:
///  - dimmed backdrop, click-outside to dismiss
///  - configurable max width / max height (defaults are sane for forms)
///  - rounded forui-feeling chrome with our `kBlack2Color` surface
///  - Esc-to-close
///  - `barrierDismissible` toggle for required-input modals
///
/// The signature mirrors `showModalBottomSheet<T>` so call sites convert
/// 1:1: replace the function name and (optionally) drop the
/// `isScrollControlled` / `useSafeArea` / shape arguments — this helper
/// handles all that internally.
Future<T?> showDesktopModal<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxWidth = 520,
  double? maxHeight,
  bool barrierDismissible = true,
  String? title,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: title ?? 'modal',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, anim, secondary) {
      final mq = MediaQuery.of(ctx);
      final effectiveMaxHeight =
          maxHeight ?? (mq.size.height * 0.85).clamp(360.0, 920.0);
      return _DesktopModalShell(
        title: title,
        maxWidth: maxWidth,
        maxHeight: effectiveMaxHeight,
        child: Builder(builder: builder),
      );
    },
    transitionBuilder: (ctx, anim, secondary, child) {
      // Subtle fade + slight upward slide. No bouncy spring — desktop
      // dialogs should feel quick, not playful.
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

/// True on desktop OSes; `false` on iOS/Android. Lets shared mobile
/// screens conditionally route their bottom sheets through
/// [showDesktopModal] without breaking the mobile build.
bool get isDesktopPlatform =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Convenience: behaves like `showModalBottomSheet` on mobile, like
/// [showDesktopModal] on desktop. Use this from shared screens so a
/// single call site works on both targets.
Future<T?> showSmartSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double desktopMaxWidth = 520,
  double? desktopMaxHeight,
  bool barrierDismissible = true,
  String? title,
  // Mobile passthrough knobs — kept here so mobile call sites don't
  // need to branch on platform. The helper swallows whichever ones
  // don't apply on desktop.
  bool isScrollControlled = true,
  bool useSafeArea = true,
  Color? backgroundColor,
  Color? barrierColor,
  ShapeBorder? shape,
  BoxConstraints? constraints,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  if (isDesktopPlatform) {
    return showDesktopModal<T>(
      context,
      builder: builder,
      // If the call site supplied a width through `constraints`, prefer
      // that — otherwise fall back to our default.
      maxWidth:
          constraints?.maxWidth.isFinite == true
              ? constraints!.maxWidth
              : desktopMaxWidth,
      maxHeight:
          desktopMaxHeight ??
          (constraints?.maxHeight.isFinite == true
              ? constraints!.maxHeight
              : null),
      barrierDismissible: barrierDismissible && isDismissible,
      title: title,
    );
  }
  // Mobile path — defer to Material's bottom sheet, preserving the
  // existing call-site intent.
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: backgroundColor,
    barrierColor: barrierColor,
    shape: shape,
    constraints: constraints,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
  );
}

class _DesktopModalShell extends StatelessWidget {
  const _DesktopModalShell({
    required this.child,
    required this.maxWidth,
    required this.maxHeight,
    this.title,
  });

  final Widget child;
  final double maxWidth;
  final double maxHeight;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Material(
          // forui-feel dark chrome — same surface palette the rest of
          // the desktop shell uses so the modal sits in the design
          // system rather than next to it.
          color: kBlack2Color,
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: _EscDismissable(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null) _ModalTitleBar(title: title!),
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModalTitleBar extends StatelessWidget {
  const _ModalTitleBar({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          DesktopDialogIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onPress: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

/// Wraps a modal's content with an Esc-to-close shortcut. Desktop users
/// expect Esc to dismiss popovers / dialogs.
class _EscDismissable extends StatelessWidget {
  const _EscDismissable({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
