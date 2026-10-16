import 'dart:io';
import 'dart:math' as math;
import 'package:chessever/desktop/widgets/editorial/inbox_unread_anchor.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';
import 'package:window_manager/window_manager.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/services/billing/desktop_billing_service.dart';
import 'package:chessever/desktop/state/botvinnik_dock.dart';
import 'package:chessever/desktop/shell/desktop_chrome_metrics.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/widgets/bucketed_layout_builder.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_feedback_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_sidebar_premium_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/app_version_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Vertical rhythm of the sidebar rail.
///
/// At the designed spacing ([regular], 44 px rows) the rail needs about
/// 920 px for its 14–15 rows plus the pinned Premium / Settings / version
/// footer. That is taller than a maximized window on 1366×768 at 100 % or
/// 1920×1080 at 125 % / 150 % Windows scaling, where the footer used to be
/// pushed off the window. On a shorter window the rows and gaps tighten in
/// whole pixels, down to 30 px rows, so the rail fills exactly the height it
/// has. Icons and labels keep their sizes at every density, so the interface
/// never shrinks. Below the [tightest] density the nav rows scroll and the
/// footer stays pinned.
@immutable
class DesktopSidebarDensity {
  const DesktopSidebarDensity._(this.rowHeight);

  static const double maxRowHeight = 44;
  static const double minRowHeight = 30;

  /// The designed spacing, used whenever the window is tall enough.
  static const DesktopSidebarDensity regular = DesktopSidebarDensity._(
    maxRowHeight,
  );

  /// The tightest spacing; on shorter windows the nav rows scroll.
  static const DesktopSidebarDensity tightest = DesktopSidebarDensity._(
    minRowHeight,
  );

  static const double versionLineHeight = 14;

  /// The expanded Get Premium button keeps its designed 36 px height unless
  /// the row is shorter.
  static const double _premiumExpandedMaxHeight = 36;

  /// Height of one row's hover / selection pill.
  final double rowHeight;

  /// Space above and below each row's pill.
  double get rowGap => rowHeight >= 40 ? 2 : 1;

  /// Space above the first and below the last nav row.
  double get navGap => _gap(tightest: 4, regular: 8);

  /// Space above and below the Get Premium button.
  double get premiumGap => _gap(tightest: 4, regular: 8);
  double get versionTopGap => _gap(tightest: 4, regular: 8);
  double get versionBottomGap => _gap(tightest: 6, regular: 10);

  double get rowExtent => rowHeight + rowGap * 2;

  double get premiumExpandedHeight =>
      math.min(_premiumExpandedMaxHeight, rowHeight);

  /// Height of [navRows] nav rows including the gaps around them.
  double navExtent(int navRows) => navGap * 2 + navRows * rowExtent;

  /// Height of the pinned footer: Get Premium, divider, Settings, version.
  /// The Premium term uses [rowHeight], which is never shorter than either
  /// the collapsed or the expanded button.
  double footerExtent({required bool showPremium}) =>
      (showPremium ? rowHeight + premiumGap * 2 : 0) +
      1 +
      rowExtent +
      versionTopGap +
      versionLineHeight +
      versionBottomGap;

  double bodyExtent({required int navRows, required bool showPremium}) =>
      navExtent(navRows) + footerExtent(showPremium: showPremium);

  /// Gaps scale with the row height so every density keeps the regular
  /// proportions.
  double _gap({required double tightest, required double regular}) {
    final t = (rowHeight - minRowHeight) / (maxRowHeight - minRowHeight);
    return (tightest + (regular - tightest) * t).roundToDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopSidebarDensity && other.rowHeight == rowHeight;

  @override
  int get hashCode => rowHeight.hashCode;

  @override
  String toString() => 'DesktopSidebarDensity(${rowHeight.toInt()} px rows)';
}

/// Loosest [DesktopSidebarDensity] whose rows and footer fit [bodyHeight],
/// the rail height below the chrome header. Falls back to
/// [DesktopSidebarDensity.tightest], where the nav rows scroll.
DesktopSidebarDensity desktopSidebarDensityFor({
  required double bodyHeight,
  required int navRows,
  required bool showPremium,
}) {
  for (
    var rowHeight = DesktopSidebarDensity.maxRowHeight;
    rowHeight >= DesktopSidebarDensity.minRowHeight;
    rowHeight--
  ) {
    final density = DesktopSidebarDensity._(rowHeight);
    if (bodyHeight >=
        density.bodyExtent(navRows: navRows, showPremium: showPremium)) {
      return density;
    }
  }
  return DesktopSidebarDensity.tightest;
}

Future<EntitlementSnapshot?> _loadCurrentEntitlement() =>
    DesktopBillingService.instance.currentEntitlement();

/// Persistent left navigation rail for the desktop shell.
///
/// Differs from the mobile bottom-nav in three ways:
/// 1. Always visible — never collapses behind a hamburger.
/// 2. Reads/writes the selected pane via callback; the shell, not navigator,
///    owns "what content is showing".
/// 3. Compact (72 px) or expanded (240 px) depending on shell width and
///    user preference.
///
/// Vertically it adapts to the window height (see [DesktopSidebarDensity]):
/// Settings and the footer are pinned below the nav rows and never clip.
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.current,
    required this.onSelect,
    required this.feedbackScreenshotKey,
    required this.onToggleExpanded,
    required this.onSearch,
    required this.onHowToUse,
    this.expanded = true,
    this.autoCollapsed = false,
    this.loadEntitlement = _loadCurrentEntitlement,
  });

  final DesktopPane? current;

  /// Sidebar tap handler. A plain click opens or activates the destination's
  /// category tab without rewriting the active tab. `inNewTab` is `true` when
  /// the user holds Cmd / Ctrl and forces an additional destination tab.
  final void Function(DesktopPane pane, {required bool inNewTab}) onSelect;
  final GlobalKey feedbackScreenshotKey;
  final VoidCallback onToggleExpanded;
  final VoidCallback onSearch;
  final VoidCallback onHowToUse;
  final bool expanded;
  final bool autoCollapsed;

  /// Resolves whether the Get Premium button shows. Tests inject a stub.
  final Future<EntitlementSnapshot?> Function() loadEntitlement;

  static const double collapsedWidth = 72;
  static const double expandedWidth = 240;

  /// Width animation length. `DesktopSidebarLayout` waits this long before
  /// narrowing the content after an expand.
  static const Duration animationDuration = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) {
    final width = expanded ? expandedWidth : collapsedWidth;
    return AnimatedContainer(
      duration: animationDuration,
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
          Expanded(
            child: _SidebarBody(
              current: current,
              expanded: expanded,
              onSelect: onSelect,
              onSearch: onSearch,
              onHowToUse: onHowToUse,
              feedbackScreenshotKey: feedbackScreenshotKey,
              loadEntitlement: loadEntitlement,
            ),
          ),
        ],
      ),
    );
  }
}

/// Everything below the header: the nav rows in a viewport that scrolls only
/// when even the densest spacing cannot fit them, then the pinned footer.
class _SidebarBody extends ConsumerStatefulWidget {
  const _SidebarBody({
    required this.current,
    required this.expanded,
    required this.onSelect,
    required this.onSearch,
    required this.onHowToUse,
    required this.feedbackScreenshotKey,
    required this.loadEntitlement,
  });

  final DesktopPane? current;
  final bool expanded;
  final void Function(DesktopPane pane, {required bool inNewTab}) onSelect;
  final VoidCallback onSearch;
  final VoidCallback onHowToUse;
  final GlobalKey feedbackScreenshotKey;
  final Future<EntitlementSnapshot?> Function() loadEntitlement;

  @override
  ConsumerState<_SidebarBody> createState() => _SidebarBodyState();
}

class _SidebarBodyState extends ConsumerState<_SidebarBody> {
  late final Future<EntitlementSnapshot?> _entitlementFuture =
      widget.loadEntitlement();

  @override
  Widget build(BuildContext context) {
    final botvinnikVisible =
        ChatApi.buildEnabled &&
        (ref.watch(botvinnikEnabledProvider).valueOrNull ?? true);
    final entries = _navEntriesInOrder(botvinnikVisible: botvinnikVisible);
    return FutureBuilder<EntitlementSnapshot?>(
      future: _entitlementFuture,
      builder: (context, snapshot) {
        final showPremium = !(snapshot.data?.isActive ?? false);
        // Rebuilds only when the density tier flips, not on every frame of a
        // window resize.
        return BucketedLayoutBuilder<DesktopSidebarDensity>(
          bucket:
              (constraints) => desktopSidebarDensityFor(
                bodyHeight: constraints.maxHeight,
                navRows: entries.length,
                showPremium: showPremium,
              ),
          builder:
              (context, density) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _SidebarNavViewport(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: density.navGap),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final entry in entries)
                              _navRow(context, entry, density),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (showPremium)
                    DesktopSidebarPremiumButton(
                      expanded: widget.expanded,
                      collapsedSize: density.rowHeight,
                      expandedHeight: density.premiumExpandedHeight,
                      verticalPadding: density.premiumGap,
                      onPress:
                          () => widget.onSelect(
                            DesktopPane.settings,
                            inNewTab: false,
                          ),
                    ),
                  const Divider(height: 1, color: kDividerColor),
                  _SidebarItem(
                    entry: _settingsEntry,
                    expanded: widget.expanded,
                    density: density,
                    selected: widget.current == DesktopPane.settings,
                    onTap:
                        ({required bool inNewTab}) => widget.onSelect(
                          DesktopPane.settings,
                          inNewTab: inNewTab,
                        ),
                  ),
                  SizedBox(height: density.versionTopGap),
                  _VersionFooter(expanded: widget.expanded),
                  SizedBox(height: density.versionBottomGap),
                ],
              ),
        );
      },
    );
  }

  Widget _navRow(
    BuildContext context,
    _NavEntry entry,
    DesktopSidebarDensity density,
  ) {
    if (identical(entry, _botvinnikEntry)) {
      return _BotvinnikSidebarItem(expanded: widget.expanded, density: density);
    }
    // Search, How to use and Feedback are actions, never a selected pane.
    final VoidCallback? action = switch (entry) {
      _ when identical(entry, _searchEntry) => widget.onSearch,
      _ when identical(entry, _howToUseEntry) => widget.onHowToUse,
      _ when identical(entry, _feedbackEntry) =>
        () => DesktopFeedbackDialog.show(
          context,
          screenshotKey: widget.feedbackScreenshotKey,
        ),
      _ => null,
    };
    final item = _SidebarItem(
      entry: entry,
      expanded: widget.expanded,
      density: density,
      selected: action == null && entry.pane == widget.current,
      onTap: ({required bool inNewTab}) {
        if (action != null) {
          action();
          return;
        }
        widget.onSelect(entry.pane!, inNewTab: inNewTab);
      },
    );
    return identical(entry, _inboxEntry)
        ? DesktopInboxUnreadAnchor(child: item)
        : item;
  }
}

/// Nav rows top to bottom. Settings is not here: it lives in the pinned
/// footer.
List<_NavEntry> _navEntriesInOrder({required bool botvinnikVisible}) => [
  for (final entry in _primaryNav) ...[
    entry,
    if (entry.pane == DesktopPane.play) ...[
      _searchEntry,
      _howToUseEntry,
      _feedbackEntry,
      _inboxEntry,
      if (botvinnikVisible) _botvinnikEntry,
    ],
  ],
];

/// Scroll viewport for the nav rows. While every row fits it is inert; once
/// the rows overflow, the edge that hides rows fades into the rail colour so
/// the cut reads as "more this way" rather than a sliced row.
class _SidebarNavViewport extends StatefulWidget {
  const _SidebarNavViewport({required this.child});

  final Widget child;

  @override
  State<_SidebarNavViewport> createState() => _SidebarNavViewportState();
}

class _SidebarNavViewportState extends State<_SidebarNavViewport> {
  static const double _fadeExtent = 24;

  bool _moreAbove = false;
  bool _moreBelow = false;

  bool _onMetrics(ScrollMetrics metrics) {
    final moreAbove = metrics.extentBefore > 0.5;
    final moreBelow = metrics.extentAfter > 0.5;
    if (moreAbove != _moreAbove || moreBelow != _moreBelow) {
      setState(() {
        _moreAbove = moreAbove;
        _moreBelow = moreBelow;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) => _onMetrics(notification.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) => _onMetrics(notification.metrics),
        child: Stack(
          children: [
            Positioned.fill(
              child: SingleChildScrollView(
                key: const ValueKey('desktop-sidebar-nav-scroll'),
                child: widget.child,
              ),
            ),
            _edgeFade(top: true, visible: _moreAbove),
            _edgeFade(top: false, visible: _moreBelow),
          ],
        ),
      ),
    );
  }

  Widget _edgeFade({required bool top, required bool visible}) {
    return Positioned(
      left: 0,
      right: 0,
      top: top ? 0 : null,
      bottom: top ? null : 0,
      height: _fadeExtent,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: [kBlack2Color, kBlack2Color.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
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
    // A fixed line height keeps DesktopSidebarDensity.footerExtent exact
    // whatever font metrics the platform resolves.
    if (version == null) {
      return const SizedBox(height: DesktopSidebarDensity.versionLineHeight);
    }
    return SizedBox(
      height: DesktopSidebarDensity.versionLineHeight,
      child: Padding(
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
              height: 1.2,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
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
    required this.density,
    required this.selected,
    required this.onTap,
  });

  final _NavEntry entry;
  final bool expanded;
  final DesktopSidebarDensity density;
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
  void didUpdateWidget(covariant _SidebarItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A pane selected by shortcut or tab switch may sit in the scrolled-away
    // part of a short rail. Bring it into view with the least movement.
    if (widget.selected && !oldWidget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || Scrollable.maybeOf(context) == null) return;
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        Scrollable.ensureVisible(
          context,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
      });
    }
  }

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
      padding: EdgeInsets.symmetric(
        horizontal: 12,
        vertical: widget.density.rowGap,
      ),
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
                height: widget.density.rowHeight,
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
                  // Rebuilds only when the label fits or stops fitting, not on
                  // every frame of the sidebar's width animation.
                  child: BucketedLayoutBuilder<bool>(
                    bucket: (constraints) => constraints.maxWidth >= 112,
                    builder: (context, labelFits) {
                      final showLabel = widget.expanded && labelFits;
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
    .where((route) => route.pane != DesktopPane.inbox)
    .map(_NavEntry.fromMainRoute)
    .toList(growable: false);

const _NavEntry _inboxEntry = _NavEntry(
  pane: DesktopPane.inbox,
  label: 'Inbox',
  icon: Icons.inbox_outlined,
);

const _NavEntry _feedbackEntry = _NavEntry(
  pane: DesktopPane.settings,
  label: 'Feedback',
  icon: Icons.feedback_outlined,
);

const _NavEntry _botvinnikEntry = _NavEntry(
  label: 'Botvinnik',
  icon: Icons.forum_outlined,
);

/// Toggles the shell's Botvinnik dock. Not a tab route, so it takes no
/// Cmd/Ctrl+number shortcut and never reshuffles the route list.
class _BotvinnikSidebarItem extends ConsumerWidget {
  const _BotvinnikSidebarItem({required this.expanded, required this.density});

  final bool expanded;
  final DesktopSidebarDensity density;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(botvinnikDockProvider.select((dock) => dock.open));
    return _SidebarItem(
      entry: _botvinnikEntry,
      expanded: expanded,
      density: density,
      selected: open,
      onTap: ({required bool inNewTab}) => toggleBotvinnikDock(ref),
    );
  }
}

const _NavEntry _howToUseEntry = _NavEntry(
  label: 'How to use',
  icon: Icons.help_outline,
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
List<String> debugDesktopSidebarLabelsInOrder() => [
  for (final entry in _navEntriesInOrder(botvinnikVisible: true)) entry.label,
  _settingsEntry.label,
];

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
