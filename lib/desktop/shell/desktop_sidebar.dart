import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/shell/desktop_chrome_metrics.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_feedback_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_sidebar_premium_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/app_version_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Persistent left navigation rail for the desktop shell.
///
/// Differs from the mobile bottom-nav in three ways:
/// 1. Always visible — never collapses behind a hamburger.
/// 2. Reads/writes the selected pane via callback; the shell, not navigator,
///    owns "what content is showing".
/// 3. Compact (72 px) or expanded (240 px) depending on shell width and
///    user preference.
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.current,
    required this.onSelect,
    required this.feedbackScreenshotKey,
    required this.onToggleExpanded,
    required this.onSearch,
    this.expanded = true,
    this.autoCollapsed = false,
  });

  final DesktopPane? current;

  /// Sidebar tap handler. A plain click opens or activates the destination's
  /// category tab without rewriting the active tab. `inNewTab` is `true` when
  /// the user holds Cmd / Ctrl and forces an additional destination tab.
  final void Function(DesktopPane pane, {required bool inNewTab}) onSelect;
  final GlobalKey feedbackScreenshotKey;
  final VoidCallback onToggleExpanded;
  final VoidCallback onSearch;
  final bool expanded;
  final bool autoCollapsed;

  static const double collapsedWidth = 72;
  static const double expandedWidth = 240;

  @override
  Widget build(BuildContext context) {
    final width = expanded ? expandedWidth : collapsedWidth;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: width,
      decoration: const BoxDecoration(
        color: kBlack2Color,
        border: Border(right: BorderSide(color: kDividerColor, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header band stands exactly one chrome bar tall and carries the
          // same bottom border as the tab strip, so the divider line is
          // collinear with the tab strip's bottom seam — the two bars read
          // as one continuous horizontal control bar across the window top,
          // meeting the sidebar's right edge in a clean corner.
          SizedBox(
            height: kDesktopChromeBarHeight,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: kDividerColor, width: 1),
                ),
              ),
              child: _SidebarHeader(
                expanded: expanded,
                autoCollapsed: autoCollapsed,
                onToggleExpanded: onToggleExpanded,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final entry in _primaryNav) ...[
            _SidebarItem(
              entry: entry,
              expanded: expanded,
              selected: entry.pane == current,
              onTap:
                  ({required bool inNewTab}) =>
                      onSelect(entry.pane!, inNewTab: inNewTab),
            ),
            if (entry.pane == DesktopPane.play) ...[
              _SidebarItem(
                entry: _searchEntry,
                expanded: expanded,
                selected: false,
                onTap: ({required bool inNewTab}) => onSearch(),
              ),
              _SidebarItem(
                entry: _feedbackEntry,
                expanded: expanded,
                selected: false,
                onTap:
                    ({required bool inNewTab}) => DesktopFeedbackDialog.show(
                      context,
                      screenshotKey: feedbackScreenshotKey,
                    ),
              ),
            ],
          ],
          const Spacer(),
          _PremiumSidebarSlot(
            expanded: expanded,
            onPress: () => onSelect(DesktopPane.settings, inNewTab: false),
          ),
          const Divider(height: 1, color: kDividerColor),
          _SidebarItem(
            entry: _settingsEntry,
            expanded: expanded,
            selected: current == DesktopPane.settings,
            onTap:
                ({required bool inNewTab}) =>
                    onSelect(DesktopPane.settings, inNewTab: inNewTab),
          ),
          const SizedBox(height: 8),
          _VersionFooter(expanded: expanded),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _VersionFooter extends ConsumerWidget {
  const _VersionFooter({required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).valueOrNull;
    if (version == null) return const SizedBox(height: 14);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: expanded ? Alignment.centerLeft : Alignment.center,
        child: Text(
          'v$version',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 11,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _PremiumSidebarSlot extends StatefulWidget {
  const _PremiumSidebarSlot({required this.expanded, required this.onPress});

  final bool expanded;
  final VoidCallback onPress;

  @override
  State<_PremiumSidebarSlot> createState() => _PremiumSidebarSlotState();
}

class _PremiumSidebarSlotState extends State<_PremiumSidebarSlot> {
  late Future<EntitlementSnapshot?> _entitlementFuture;

  @override
  void initState() {
    super.initState();
    _entitlementFuture = DesktopBillingService.instance.currentEntitlement();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EntitlementSnapshot?>(
      future: _entitlementFuture,
      builder: (context, snapshot) {
        if (snapshot.data?.isActive ?? false) {
          return const SizedBox.shrink();
        }

        return DesktopSidebarPremiumButton(
          expanded: widget.expanded,
          onPress: widget.onPress,
        );
      },
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({
    required this.expanded,
    required this.autoCollapsed,
    required this.onToggleExpanded,
  });

  final bool expanded;
  final bool autoCollapsed;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    // A 72 px collapsed rail cannot fit both the native macOS traffic lights
    // and a 40 px toggle. In that state the traffic-light area remains a
    // draggable title surface and DesktopTabBar renders the toggle beside its
    // history controls instead.
    if (Platform.isMacOS && !expanded) {
      return const DragToMoveArea(child: SizedBox.expand());
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (Platform.isMacOS) const SizedBox(width: 64),
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          DesktopSidebarToggleButton(
            expanded: expanded,
            autoCollapsed: autoCollapsed,
            onTap: onToggleExpanded,
          ),
        ],
      ),
    );
  }
}

/// Shell-native sidebar toggle shared by the sidebar header and the tab strip
/// when the collapsed macOS rail is occupied by native traffic lights.
class DesktopSidebarToggleButton extends StatelessWidget {
  const DesktopSidebarToggleButton({
    super.key,
    required this.expanded,
    required this.autoCollapsed,
    required this.onTap,
  });

  final bool expanded;
  final bool autoCollapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tooltip =
        autoCollapsed && !expanded
            ? 'Sidebar auto-collapsed for compact width (⌘B)'
            : (expanded ? 'Collapse sidebar (⌘B)' : 'Expand sidebar (⌘B)');
    return DesktopTooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 40,
        child: _SidebarHeaderButton(
          icon: expanded ? Icons.menu_open_rounded : Icons.menu_rounded,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _SidebarHeaderButton extends StatefulWidget {
  const _SidebarHeaderButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_SidebarHeaderButton> createState() => _SidebarHeaderButtonState();
}

class _SidebarHeaderButtonState extends State<_SidebarHeaderButton>
    with DeferredPointerStateMixin<_SidebarHeaderButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit:
            (_) => setStateAfterPointerEvent(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setStateAfterPointerEvent(() => _pressed = true),
          onTapUp: (_) => setStateAfterPointerEvent(() => _pressed = false),
          onTapCancel: () => setStateAfterPointerEvent(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.97 : (_hovered ? 1.012 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) => Transform.scale(
                  scale: scale,
                  filterQuality: FilterQuality.medium,
                  child: child,
                ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: _hovered ? kBlack3Color : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      _hovered
                          ? kWhiteColor.withValues(alpha: 0.10)
                          : Colors.transparent,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 19,
                color: _hovered ? kWhiteColor : kWhiteColor70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.entry,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  final _NavEntry entry;
  final bool expanded;
  final bool selected;

  /// Tap handler. `inNewTab` is `true` when the user holds Cmd/Ctrl
  /// while clicking — Chrome convention.
  final void Function({required bool inNewTab}) onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem>
    with DeferredPointerStateMixin<_SidebarItem> {
  bool _hovered = false;
  bool _pressed = false;

  bool _modifierHeld() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
  }

  /// Tooltip-friendly label for the new-tab modifier per platform.
  String _modifierHintLabel() => Platform.isMacOS ? '⌘' : 'Ctrl';

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final shortcut = _shortcutLabelForEntry(widget.entry);
    final fg =
        selected ? kPrimaryColor : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        selected
            ? kPrimaryColor.withValues(alpha: 0.10)
            : (_hovered ? kBlack3Color : Colors.transparent);

    // Tiny spring-driven nudge: on hover the row content slides 3px to
    // the right; on press it dips back ~1.5px. The Container background
    // and border stay put — only the inner Row translates — so the
    // hover affordance reads as "the item is reaching toward the
    // cursor" rather than "the whole pill jiggled."
    final nudgeX = _pressed ? -1.5 : (_hovered ? 3.0 : 0.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: CursorAware(
        mode: CursorMode.hover,
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit:
              (_) => setStateAfterPointerEvent(() {
                _hovered = false;
                _pressed = false;
              }),
          child: DesktopTooltip(
            message:
                widget.expanded
                    ? ''
                    : '${widget.entry.label} (${_modifierHintLabel()}-click for new tab)',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown:
                  (_) => setStateAfterPointerEvent(() => _pressed = true),
              onTapUp: (_) => setStateAfterPointerEvent(() => _pressed = false),
              onTapCancel:
                  () => setStateAfterPointerEvent(() => _pressed = false),
              onTap: () => widget.onTap(inNewTab: _modifierHeld()),
              child: Container(
                height: 44,
                padding:
                    widget.expanded
                        ? const EdgeInsets.symmetric(horizontal: 12)
                        : EdgeInsets.zero,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                  border:
                      selected
                          ? Border.all(
                            color: kPrimaryColor.withValues(alpha: 0.35),
                          )
                          : null,
                ),
                child: SingleMotionBuilder(
                  value: nudgeX,
                  motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
                  builder:
                      (context, x, child) => Transform.translate(
                        offset: Offset(widget.expanded ? x : x * 0.35, 0),
                        child: child,
                      ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final showLabel =
                          widget.expanded && constraints.maxWidth >= 112;
                      return Row(
                        mainAxisAlignment:
                            showLabel
                                ? MainAxisAlignment.start
                                : MainAxisAlignment.center,
                        children: [
                          widget.entry.pane == DesktopPane.board
                              ? _ChessboardIcon(size: 18, color: fg)
                              : Icon(widget.entry.icon, size: 18, color: fg),
                          if (showLabel) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.entry.label,
                                style: TextStyle(
                                  color: fg,
                                  fontSize: 13,
                                  fontWeight:
                                      selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (shortcut != null)
                              Text(
                                shortcut,
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 11,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavEntry {
  const _NavEntry({
    required this.label,
    required this.icon,
    this.pane,
    this.primaryShortcutKey,
  });
  _NavEntry.fromMainRoute(DesktopMainRoute route)
    : pane = route.pane,
      label = route.label,
      icon = route.icon,
      primaryShortcutKey = null;

  final DesktopPane? pane;
  final String label;

  /// Material `_outlined` icon. The brand SVGs under `assets/svgs/` were
  /// inconsistent (Favorites and Players shared the same two-people glyph,
  /// Board and Board Editor were both abstract grids, mix of filled and
  /// stroked styles). The outlined Material family ships uniform stroke
  /// weight, sizing, and proportion across every entry — and the panes
  /// already use it (`account_tree_outlined`, `emoji_events_outlined`,
  /// `menu_book_outlined`, …) so the sidebar finally matches them.
  final IconData icon;
  final String? primaryShortcutKey;
}

const _NavEntry _searchEntry = _NavEntry(
  label: 'Search',
  icon: Icons.search,
  primaryShortcutKey: 'F',
);

final List<_NavEntry> _primaryNav = desktopMainRoutes
    .map(_NavEntry.fromMainRoute)
    .toList(growable: false);

const _NavEntry _feedbackEntry = _NavEntry(
  pane: DesktopPane.settings,
  label: 'Feedback',
  icon: Icons.feedback_outlined,
);

const _NavEntry _settingsEntry = _NavEntry(
  pane: DesktopPane.settings,
  label: 'Settings',
  icon: Icons.settings_outlined,
  primaryShortcutKey: ',',
);

String? _shortcutLabelForEntry(_NavEntry entry, {bool? isMacOS}) {
  final pane = entry.pane;
  if (pane != null) {
    final routeShortcut = desktopMainRouteShortcutLabel(pane, isMacOS: isMacOS);
    if (routeShortcut != null) return routeShortcut;
  }
  final key = entry.primaryShortcutKey;
  if (key == null) return null;
  return desktopPrimaryShortcutLabel(key, isMacOS: isMacOS);
}

@visibleForTesting
List<String> debugDesktopSidebarLabelsInOrder() {
  final labels = <String>[];
  for (final entry in _primaryNav) {
    labels.add(entry.label);
    if (entry.pane == DesktopPane.play) {
      labels.add(_searchEntry.label);
      labels.add(_feedbackEntry.label);
    }
  }
  labels.add(_settingsEntry.label);
  return labels;
}

@visibleForTesting
DesktopPane? debugDesktopSidebarPaneForLabel(String label) {
  if (_searchEntry.label == label) return _searchEntry.pane;
  for (final entry in _primaryNav) {
    if (entry.label == label) return entry.pane;
  }
  if (_settingsEntry.label == label) return _settingsEntry.pane;
  return null;
}

@visibleForTesting
String? debugDesktopSidebarShortcutForLabel(String label, {bool? isMacOS}) {
  if (_searchEntry.label == label) {
    return _shortcutLabelForEntry(_searchEntry, isMacOS: isMacOS);
  }
  for (final entry in _primaryNav) {
    if (entry.label == label) {
      return _shortcutLabelForEntry(entry, isMacOS: isMacOS);
    }
  }
  if (_settingsEntry.label == label) {
    return _shortcutLabelForEntry(_settingsEntry, isMacOS: isMacOS);
  }
  return null;
}

class _ChessboardIcon extends StatelessWidget {
  const _ChessboardIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _ChessboardIconPainter(color: color)),
    );
  }
}

class _ChessboardIconPainter extends CustomPainter {
  _ChessboardIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..isAntiAlias = true;
    final fill =
        Paint()
          ..color = color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;

    final radius = Radius.circular(size.shortestSide * 0.14);
    final outer = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        stroke.strokeWidth / 2,
        stroke.strokeWidth / 2,
        size.width - stroke.strokeWidth,
        size.height - stroke.strokeWidth,
      ),
      radius,
    );
    canvas.drawRRect(outer, stroke);

    canvas.save();
    canvas.clipRRect(outer);
    final cell = size.width / 4;
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 4; col++) {
        if ((row + col).isOdd) {
          canvas.drawRect(
            Rect.fromLTWH(col * cell, row * cell, cell, cell),
            fill,
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChessboardIconPainter old) =>
      old.color != color;
}
