import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/shell/desktop_chrome_metrics.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/board_tab_fen.dart';
import 'package:chessever/desktop/state/board_tab_sound_mute.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_update_chip.dart';
import 'package:chessever/desktop/widgets/desktop_user_profile_button.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/chessboard/widgets/evaluation_bar_widget.dart';
import 'package:chessever/screens/chessboard/widgets/player_first_row_detail_widget.dart'
    show PlayerView;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart'
    show GameStatus;
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

/// Chrome-style tab bar that sits between the top bar and the content area.
///
/// Each open document/view is a [DesktopTab] in `desktopTabsProvider`.
///
/// Mouse semantics match Chrome:
///  - Left-click activates a tab
///  - Middle-click closes a closable tab
///  - Right-click opens a context menu (Close / Close others / Close right / Close all)
///  - Drag a tab horizontally to reorder it
///
/// The whole strip also accepts [GameTabDragPayload] drops — a user can
/// drag a game card off any pane and drop it here to spawn a Board tab
/// focused on that game. While a payload hovers the strip, the chrome
/// brightens and a chip-shaped placeholder is rendered at the tail to
/// telegraph the landing slot.
class DesktopTabBar extends ConsumerStatefulWidget {
  const DesktopTabBar({super.key, this.onOpenUserProfile});

  final VoidCallback? onOpenUserProfile;

  @override
  ConsumerState<DesktopTabBar> createState() => _DesktopTabBarState();
}

class _DesktopTabBarState extends ConsumerState<DesktopTabBar> {
  GameTabDragPayload? _hoverPayload;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(desktopTabsProvider);
    final boardArgsByTab = ref.watch(boardTabGameArgsByTabIdProvider);
    final notifier = ref.read(desktopTabsProvider.notifier);

    return DragTarget<GameTabDragPayload>(
      onWillAcceptWithDetails: (details) {
        setState(() => _hoverPayload = details.data);
        return true;
      },
      onLeave: (_) => setState(() => _hoverPayload = null),
      onAcceptWithDetails: (details) {
        setState(() => _hoverPayload = null);
        // Drag-drop intent is "open this game and look at it now" — pass
        // focus: true so the new tab foregrounds itself.
        details.data.spawn(ref, focus: true);
      },
      builder: (context, candidate, rejected) {
        final dragging = candidate.isNotEmpty;
        return SizedBox(
          // Tall enough that a 36-px chip can sit on a 6-px shoulder with the
          // bottom seam still visible below — same proportion Chrome uses.
          // Shared with the sidebar header band so both bottom borders land
          // on the same y and form one continuous horizontal seam.
          height: kDesktopChromeBarHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Brighten the strip while a payload is hovering — same
              // visual cue Chrome uses when you drag a tab onto another
              // window. Drag fill is bumped past the inactive-tab fill
              // (`kBlack3Color`) so tabs don't dissolve into the strip
              // mid-drag.
              color: dragging ? kDividerColor : kBlack2Color,
              border: const Border(bottom: BorderSide(color: kDividerColor)),
            ),
            child: Row(
              children: [
                const _TabHistoryControls(),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final widths = _computeTabWidths(
                        tabs: state.tabs,
                        boardArgsByTab: boardArgsByTab,
                        availableWidth: constraints.maxWidth,
                      );
                      return ReorderableListView.builder(
                        scrollDirection: Axis.horizontal,
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.only(left: 6, right: 6),
                        proxyDecorator: (child, index, animation) {
                          // While being dragged, the proxy gets a slight scale +
                          // raised shadow so the user feels the lift.
                          return AnimatedBuilder(
                            animation: animation,
                            builder: (context, _) {
                              final t = Curves.easeOut.transform(
                                animation.value,
                              );
                              return Material(
                                color: Colors.transparent,
                                elevation: 6 * t,
                                shadowColor: Colors.black.withValues(
                                  alpha: 0.4,
                                ),
                                child: Transform.scale(
                                  scale: 1 + 0.03 * t,
                                  child: child,
                                ),
                              );
                            },
                          );
                        },
                        // Keep legacy callback here because desktopTabsProvider.reorder
                        // still expects Flutter's pre-removal newIndex semantics.
                        // ignore: deprecated_member_use
                        onReorder: notifier.reorder,
                        itemCount: state.tabs.length,
                        itemBuilder: (context, i) {
                          final tab = state.tabs[i];
                          // Chrome-style: pointer-down on the chip immediately
                          // arms a horizontal drag (`ReorderableDragStartListener`
                          // uses ImmediateMultiDragGestureRecognizer). Short
                          // taps without movement still bubble through to the
                          // chip's GestureDetector so click-to-activate keeps
                          // working — only sustained motion past the touch-slop
                          // commits to a reorder gesture.
                          return SizedBox(
                            key: ValueKey(tab.id),
                            width: widths[tab.id],
                            child: ReorderableDragStartListener(
                              index: i,
                              child: _TabChip(
                                tab: tab,
                                active: tab.id == state.activeId,
                                onActivate: () => notifier.activate(tab.id),
                                onClose:
                                    tab.closable
                                        ? () => notifier.close(tab.id)
                                        : null,
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                if (_hoverPayload != null)
                  _DropPlaceholderChip(label: _hoverPayload!.label),
                const DesktopUpdateChip(),
                if (widget.onOpenUserProfile != null) ...[
                  const SizedBox(width: 8),
                  DesktopUserProfileButton(
                    size: 30,
                    tooltip: 'Open my player profile',
                    onPress: widget.onOpenUserProfile,
                  ),
                ],
                const SizedBox(width: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TabHistoryControls extends ConsumerWidget {
  const _TabHistoryControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canGoBack = ref.watch(desktopTabsProvider.select((s) => s.canGoBack));
    final canGoForward = ref.watch(
      desktopTabsProvider.select((s) => s.canGoForward),
    );
    final notifier = ref.read(desktopTabsProvider.notifier);

    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TabHistoryButton(
            key: const ValueKey('desktop-tab-back-button'),
            icon: Icons.arrow_back_rounded,
            tooltip: canGoBack ? 'Back' : 'No route back',
            onPress: canGoBack ? notifier.goBack : null,
          ),
          const SizedBox(width: 2),
          _TabHistoryButton(
            key: const ValueKey('desktop-tab-forward-button'),
            icon: Icons.arrow_forward_rounded,
            tooltip: canGoForward ? 'Forward' : 'No route forward',
            onPress: canGoForward ? notifier.goForward : null,
          ),
        ],
      ),
    );
  }
}

class _TabHistoryButton extends StatelessWidget {
  const _TabHistoryButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: tooltip,
        child: SizedBox.square(
          dimension: 40,
          child: FButton.icon(
            style: _tabHistoryButtonStyle(),
            onPress: onPress,
            child: Icon(icon),
          ),
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _tabHistoryButtonStyle() {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kWhiteColor.withValues(alpha: 0.08)),
        ),
        WidgetState.any: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
      }),
      iconContentStyle: (content) {
        return content.copyWith(
          padding: EdgeInsets.zero,
          iconStyle: FWidgetStateMap({
            WidgetState.disabled: IconThemeData(
              color: kWhiteColor.withValues(alpha: 0.24),
              size: 18,
            ),
            WidgetState.hovered | WidgetState.pressed: const IconThemeData(
              color: kWhiteColor,
              size: 18,
            ),
            WidgetState.any: const IconThemeData(
              color: kWhiteColor70,
              size: 18,
            ),
          }),
        );
      },
    ),
  );
}

const double _tabListHorizontalPadding = 12;
const double _regularTabPreferredWidth = 220;
const double _regularTabMinWidth = 96;
const double _gameTabPreferredWidth = 300;
const double _gameTabMinWidth = 132;

Map<String, double> _computeTabWidths({
  required List<DesktopTab> tabs,
  required Map<String, BoardTabGameArgs> boardArgsByTab,
  required double availableWidth,
}) {
  if (tabs.isEmpty) return const <String, double>{};
  if (!availableWidth.isFinite || availableWidth <= 0) {
    return <String, double>{
      for (final tab in tabs)
        tab.id: _preferredTabWidth(boardArgsByTab.containsKey(tab.id)),
    };
  }

  final usableWidth = math.max(0.0, availableWidth - _tabListHorizontalPadding);
  var preferredTotal = 0.0;
  var minTotal = 0.0;
  final specs = <String, ({double min, double preferred})>{};
  for (final tab in tabs) {
    final isGameTab = boardArgsByTab.containsKey(tab.id);
    final spec = (
      min: isGameTab ? _gameTabMinWidth : _regularTabMinWidth,
      preferred: isGameTab ? _gameTabPreferredWidth : _regularTabPreferredWidth,
    );
    specs[tab.id] = spec;
    minTotal += spec.min;
    preferredTotal += spec.preferred;
  }

  if (preferredTotal <= usableWidth) {
    return <String, double>{
      for (final entry in specs.entries) entry.key: entry.value.preferred,
    };
  }
  if (minTotal >= usableWidth) {
    return <String, double>{
      for (final entry in specs.entries) entry.key: entry.value.min,
    };
  }

  final shrinkRatio =
      (preferredTotal - usableWidth) / math.max(1.0, preferredTotal - minTotal);
  return <String, double>{
    for (final entry in specs.entries)
      entry.key: math.max(
        entry.value.min,
        entry.value.preferred -
            ((entry.value.preferred - entry.value.min) * shrinkRatio),
      ),
  };
}

double _preferredTabWidth(bool isGameTab) =>
    isGameTab ? _gameTabPreferredWidth : _regularTabPreferredWidth;

/// Chip-shaped placeholder rendered after the existing tabs while a
/// [GameTabDragPayload] is hovering the strip. Tells the user "drop here
/// → this becomes a tab" without committing to the spawn until release.
class _DropPlaceholderChip extends StatelessWidget {
  const _DropPlaceholderChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
      child: Container(
        constraints: const BoxConstraints(
          minWidth: 140,
          maxWidth: 220,
          minHeight: 40,
        ),
        decoration: BoxDecoration(
          color: kBackgroundColor.withValues(alpha: 0.6),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(10),
            topRight: Radius.circular(10),
          ),
          border: Border.all(
            color: kPrimaryColor.withValues(alpha: 0.7),
            width: 1.5,
            style: BorderStyle.solid,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.add_rounded, size: 16, color: kPrimaryColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends ConsumerStatefulWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.onActivate,
    required this.onClose,
  });

  final DesktopTab tab;
  final bool active;
  final VoidCallback onActivate;
  final VoidCallback? onClose;

  @override
  ConsumerState<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends ConsumerState<_TabChip> {
  bool _hovered = false;

  Future<void> _showContextMenu(Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final notifier = ref.read(desktopTabsProvider.notifier);
    final tabsState = ref.read(desktopTabsProvider);
    final hasOthers = tabsState.tabs.any(
      (t) => t.id != widget.tab.id && t.closable,
    );
    final myIdx = tabsState.tabs.indexWhere((t) => t.id == widget.tab.id);
    final hasRight =
        myIdx >= 0 &&
        myIdx < tabsState.tabs.length - 1 &&
        tabsState.tabs.skip(myIdx + 1).any((t) => t.closable);
    final isBoardTab = widget.tab.kind == TabKind.board;
    final isMuted = ref.read(boardTabSoundMuteProvider).contains(widget.tab.id);

    final picked = await showMenu<_TabAction>(
      context: context,
      color: kBlack2Color,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      items: [
        if (isBoardTab)
          PopupMenuItem<_TabAction>(
            value: _TabAction.toggleMute,
            child: _MenuRow(
              icon:
                  isMuted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              label: isMuted ? 'Unmute tab' : 'Mute tab',
            ),
          ),
        if (widget.onClose != null)
          const PopupMenuItem<_TabAction>(
            value: _TabAction.close,
            child: _MenuRow(icon: Icons.close_rounded, label: 'Close tab'),
          ),
        if (hasOthers)
          const PopupMenuItem<_TabAction>(
            value: _TabAction.closeOthers,
            child: _MenuRow(
              icon: Icons.tab_unselected_outlined,
              label: 'Close other tabs',
            ),
          ),
        if (hasRight)
          const PopupMenuItem<_TabAction>(
            value: _TabAction.closeRight,
            child: _MenuRow(
              icon: Icons.last_page_outlined,
              label: 'Close tabs to the right',
            ),
          ),
      ],
    );
    if (picked == null) return;
    switch (picked) {
      case _TabAction.toggleMute:
        ref.read(boardTabSoundMuteProvider.notifier).toggle(widget.tab.id);
      case _TabAction.close:
        widget.onClose?.call();
      case _TabAction.closeOthers:
        notifier.closeOthers(widget.tab.id);
      case _TabAction.closeRight:
        notifier.closeToTheRight(widget.tab.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Active tab merges into the content area below — same fill as the
    // pane background so there's no visible seam. Inactive tabs sit one
    // step *above* the strip (#1A) using `kBlack3Color` (#25) so each
    // chip is a discrete shape rather than dissolving into the strip;
    // hover lifts another step to `kDividerColor` (#2C).
    final Color color =
        widget.active
            ? kBackgroundColor
            : (_hovered ? kDividerColor : kBlack3Color);
    final Color fg =
        widget.active ? kWhiteColor : (_hovered ? kWhiteColor : kWhiteColor70);

    // Game-bearing Board tabs carry a `BoardTabGameArgs` (white/black
    // names, federations, ELOs) we can render in the chip in place of
    // the plain icon + title. The default scratch Board tab has no args
    // — falls through to the regular chip layout.
    final gameArgs =
        widget.tab.kind == TabKind.board
            ? ref.watch(
              boardTabGameArgsByTabIdProvider.select((m) => m[widget.tab.id]),
            )
            : null;
    final boardFen =
        widget.tab.kind == TabKind.board
            ? ref.watch(boardTabFenProvider.select((m) => m[widget.tab.id]))
            : null;
    final playerProfileArgs =
        widget.tab.kind == TabKind.playerProfile
            ? ref.watch(
              playerProfileByTabIdProvider.select((m) => m[widget.tab.id]),
            )
            : null;
    final hasGameFen =
        boardFen != null && boardFen.isNotEmpty && boardFen != _initialFen;
    final showGameCardEvalBar = shouldShowGameCardEvalBarFromSettings(
      ref.watch(engineSettingsProviderNew),
    );
    final soundMuted =
        widget.tab.kind == TabKind.board &&
        ref.watch(isBoardTabSoundMutedProvider(widget.tab.id));

    // Layout proportions:
    //   strip height: 46 px (set by DesktopTabBar)
    //   chip top shoulder: 6 px → chip itself is 40 px tall
    //   chip horizontal gap: 4 px on each side → real 8 px gap between chips
    //   inner padding: 14 px h / 8 px v so the icon + label + close button
    //   are not glued to the chip edges.
    // Inactive-tab hover gets a tiny upward lift (1.5 px) — the chip
    // floats toward the cursor before settling back when it leaves.
    // Active tabs sit flush; lifting them would break the merge with
    // the content area. The ease pairs with the existing colour
    // animation below.
    final lift = (!widget.active && _hovered) ? -1.5 : 0.0;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4, right: 4),
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              final btn = event.buttons;
              if (btn & kPrimaryMouseButton != 0) {
                widget.onActivate();
              } else if (btn & kTertiaryButton != 0) {
                // Middle-click — Chrome closes the tab.
                widget.onClose?.call();
              } else if (btn & kSecondaryMouseButton != 0) {
                _showContextMenu(event.position);
              }
            },
            child: SingleMotionBuilder(
              value: lift,
              motion: DesktopMotion.hover,
              builder:
                  (context, y, child) =>
                      Transform.translate(offset: Offset(0, y), child: child),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                constraints: const BoxConstraints(minHeight: 40),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    topRight: Radius.circular(10),
                  ),
                ),
                // Chip body. Game tabs stack a title row + flush-bottom
                // eval strip; everything else is a single padded row.
                // The active tab gets a 2px primary-color accent painted
                // over the top edge — overlaid via Stack so inactive and
                // active tabs share the same inner content geometry
                // (a Border.top would shove the content down 2px on the
                // active tab only).
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(10),
                        topRight: Radius.circular(10),
                      ),
                      child:
                          gameArgs != null
                              ? Column(
                                mainAxisSize: MainAxisSize.max,
                                children: [
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        12,
                                        6,
                                        8,
                                        4,
                                      ),
                                      child: _GameTabChipContent(
                                        args: gameArgs,
                                        active: widget.active,
                                        fg: fg,
                                        muted: soundMuted,
                                        onClose: widget.onClose,
                                        showClose: _hovered || widget.active,
                                      ),
                                    ),
                                  ),
                                  if (showGameCardEvalBar)
                                    // Eval strip pinned to the chip's bottom edge —
                                    // full bleed, Chrome-style indicator under the
                                    // tab title.
                                    SizedBox(
                                      height: 3,
                                      child: _HorizontalEvalBar(
                                        fen:
                                            (boardFen != null &&
                                                    boardFen.isNotEmpty)
                                                ? boardFen
                                                : (gameArgs.fenSeed ?? ''),
                                      ),
                                    ),
                                ],
                              )
                              : _RegularTabChipContent(
                                tab: widget.tab,
                                active: widget.active,
                                fg: fg,
                                hovered: _hovered,
                                boardFen: boardFen,
                                hasGameFen: hasGameFen,
                                showGameCardEvalBar: showGameCardEvalBar,
                                playerProfileArgs: playerProfileArgs,
                                onClose: widget.onClose,
                              ),
                    ),
                    if (widget.active)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 2,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: kPrimaryColor,
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(10),
                              topRight: Radius.circular(10),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Title row for a Board tab bound to a specific game. Chrome-style
/// layout — flags anchor the edges, names share the middle and ellipsize
/// from their inside ends, the close button pins to the far right. The
/// eval indicator lives on the chip's bottom edge (rendered by the
/// parent), not in this row, so the names get the full title width.
///
/// ┌── 🇺🇸 Carlsen           Nakamura 🇮🇳   × ──┐
/// │ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  ← parent renders eval strip
/// └────────────────────────────────────────────┘
class _GameTabChipContent extends StatelessWidget {
  const _GameTabChipContent({
    required this.args,
    required this.active,
    required this.fg,
    required this.muted,
    required this.onClose,
    required this.showClose,
  });

  final BoardTabGameArgs args;
  final bool active;
  final Color fg;
  final bool muted;
  final VoidCallback? onClose;
  final bool showClose;

  /// Pull a "last name" out of "Last, First" or "First Last" — game
  /// PGNs use both conventions. Falls back to the whole string when
  /// neither shape matches.
  static String _lastName(String name) {
    final n = name.trim();
    if (n.isEmpty) return '';
    if (n.contains(',')) {
      return n.split(',').first.trim();
    }
    final parts = n.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first;
    return parts.last;
  }

  /// Normalise "Last, First" to "First Last" for wide-tab display.
  /// PGN names use either convention; show the natural form when room.
  static String _fullName(String name) {
    final n = name.trim();
    if (n.isEmpty) return '';
    if (n.contains(',')) {
      final parts = n.split(',');
      if (parts.length >= 2) {
        final last = parts[0].trim();
        final first = parts.sublist(1).join(',').trim();
        if (first.isEmpty) return last;
        return '$first $last';
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final result = args.sourceGame?.gameStatus;
    final hasResult =
        result != null &&
        result != GameStatus.ongoing &&
        result != GameStatus.unknown;
    final whiteHasTitle = args.whiteTitle.trim().isNotEmpty;
    final blackHasTitle = args.blackTitle.trim().isNotEmpty;
    final whiteHasFlag =
        args.whiteFederation.isNotEmpty || (args.whiteFideId ?? 0) > 0;
    final blackHasFlag =
        args.blackFederation.isNotEmpty || (args.blackFideId ?? 0) > 0;

    final nameStyle = TextStyle(
      color: fg,
      fontSize: 13,
      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
      letterSpacing: 0.1,
      height: 1.2,
    );
    final dividerStyle = TextStyle(
      color: fg.withValues(alpha: 0.45),
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    final titleStyle = TextStyle(
      color: kPrimaryColor.withValues(alpha: active ? 1.0 : 0.85),
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
      height: 1.2,
    );
    final resultStyle = TextStyle(
      color: fg,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
      height: 1.2,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final hasNamedSides =
            args.whiteName.trim().isNotEmpty ||
            args.blackName.trim().isNotEmpty;
        // Width tiers — each gate unlocks more metadata so the chip
        // packs tightly at any size and uses extra room when given it.
        final showFlags = w >= 150 && (whiteHasFlag || blackHasFlag);
        final showResult = hasResult && w >= 170;
        final showTitles = w >= 210 && (whiteHasTitle || blackHasTitle);
        final useFullNames = w >= 280;
        final reserveClose = onClose != null && (showClose || w >= 150);
        final rightInset =
            reserveClose ? (muted ? 40.0 : 22.0) : (muted ? 18.0 : 0.0);

        if (!hasNamedSides) {
          final label = args.label.trim().isEmpty ? 'Board' : args.label.trim();
          final content = Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: [
              if (w >= 100) ...[
                Icon(
                  _iconFor(TabKind.board),
                  size: 16,
                  color: active ? kPrimaryColor : fg,
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: nameStyle,
                ),
              ),
            ],
          );

          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(right: rightInset),
                  child: content,
                ),
              ),
              if (reserveClose)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _CloseButton(visible: showClose, onTap: onClose!),
                  ),
                ),
            ],
          );
        }

        final whiteText =
            useFullNames
                ? _fullName(args.whiteName)
                : _lastName(args.whiteName);
        final blackText =
            useFullNames
                ? _fullName(args.blackName)
                : _lastName(args.blackName);

        final centerSeparator =
            showResult
                ? _ResultChip(text: result.displayText, style: resultStyle)
                : (w >= 130
                    ? Text('–', style: dividerStyle)
                    : const SizedBox(width: 4));

        final whiteSide = <Widget>[
          if (showFlags) ...[
            BackfilledFederationFlag(
              federation: args.whiteFederation,
              fideId: args.whiteFideId,
              width: 18,
              height: 12,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(width: 6),
          ],
          if (showTitles && whiteHasTitle) ...[
            Text(args.whiteTitle, style: titleStyle),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              whiteText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: nameStyle,
            ),
          ),
        ];

        final blackSide = <Widget>[
          if (showTitles && blackHasTitle) ...[
            Text(args.blackTitle, style: titleStyle),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              blackText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: nameStyle,
            ),
          ),
          if (showFlags) ...[
            const SizedBox(width: 6),
            BackfilledFederationFlag(
              federation: args.blackFederation,
              fideId: args.blackFideId,
              width: 18,
              height: 12,
              borderRadius: BorderRadius.circular(2),
            ),
          ],
        ];

        final content = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ...whiteSide,
            const SizedBox(width: 6),
            centerSeparator,
            const SizedBox(width: 6),
            ...blackSide,
          ],
        );

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(right: rightInset),
                child: content,
              ),
            ),
            if (muted)
              Positioned(
                right: reserveClose ? 22 : 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Icon(
                    Icons.volume_off_rounded,
                    size: 14,
                    color: fg.withValues(alpha: 0.7),
                  ),
                ),
              ),
            if (reserveClose)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _CloseButton(visible: showClose, onTap: onClose!),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Small badge for finished game results (1-0 / ½-½ / 0-1). Sits in the
/// chip's center as a fixed-width anchor so the white/black name halves
/// pack symmetrically around it instead of hugging the chip edges.
class _ResultChip extends StatelessWidget {
  const _ResultChip({required this.text, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: style),
    );
  }
}

/// Title row for a regular (non-game) tab. Centers icon + title (and
/// optional vertical eval bar for scratch boards holding a position),
/// overlays the close button on the right. Centering avoids the void
/// gap between a short title and a right-anchored close button on wide
/// chips while still ellipsizing cleanly under pressure.
class _RegularTabChipContent extends StatelessWidget {
  const _RegularTabChipContent({
    required this.tab,
    required this.active,
    required this.fg,
    required this.hovered,
    required this.boardFen,
    required this.hasGameFen,
    required this.showGameCardEvalBar,
    required this.playerProfileArgs,
    required this.onClose,
  });

  final DesktopTab tab;
  final bool active;
  final Color fg;
  final bool hovered;
  final String? boardFen;
  final bool hasGameFen;
  final bool showGameCardEvalBar;
  final PlayerProfileArgs? playerProfileArgs;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final reserveClose = onClose != null && (hovered || active || w >= 140);

        final titleStyle = TextStyle(
          color: fg,
          fontSize: 13,
          fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          height: 1.2,
        );
        final profileArgs = playerProfileArgs;
        if (profileArgs != null) {
          final playerTitle = profileArgs.title?.trim() ?? '';
          final federation = profileArgs.federation?.trim() ?? '';
          final hasFideId =
              profileArgs.fideId != null && profileArgs.fideId! > 0;
          final lastName = _GameTabChipContent._lastName(
            profileArgs.playerName,
          );
          final profileContent = Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: [
              if (federation.isNotEmpty || hasFideId) ...[
                BackfilledFederationFlag(
                  federation: federation,
                  fideId: profileArgs.fideId,
                  width: 18,
                  height: 12,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(width: 6),
              ],
              if (playerTitle.isNotEmpty) ...[
                Text(
                  playerTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: titleStyle.copyWith(
                    color: kPrimaryColor.withValues(alpha: active ? 1.0 : 0.85),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  lastName.isEmpty ? tab.title : lastName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: titleStyle,
                ),
              ),
            ],
          );

          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    6,
                    reserveClose ? 28 : 12,
                    6,
                  ),
                  child: profileContent,
                ),
              ),
              if (reserveClose)
                Positioned(
                  right: 6,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _CloseButton(
                      visible: hovered || active,
                      onTap: onClose!,
                    ),
                  ),
                ),
            ],
          );
        }

        final content = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            if (showGameCardEvalBar && hasGameFen && w >= 110) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  width: 5,
                  height: 22,
                  child: EvaluationBarWidgetForGames(
                    width: 5,
                    height: 22,
                    fen: boardFen!,
                    playerView: PlayerView.gridView,
                    allowStockfishFallback: false,
                    showText: false,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (w >= 100) ...[
              Icon(
                _iconFor(tab.kind),
                size: 16,
                color: active ? kPrimaryColor : fg,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                tab.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: titleStyle,
              ),
            ),
          ],
        );

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 6, reserveClose ? 28 : 12, 6),
                child: content,
              ),
            ),
            if (reserveClose)
              Positioned(
                right: 6,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _CloseButton(
                    visible: hovered || active,
                    onTap: onClose!,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Thin horizontal eval bar — white wins more length on the LEFT, black on the
/// RIGHT. Tab chips can render dozens of inactive games, so this deliberately
/// uses cache/server-only evals and never starts local Stockfish work.
class _HorizontalEvalBar extends ConsumerWidget {
  const _HorizontalEvalBar({required this.fen});
  final String fen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (fen.isEmpty) {
      return const _HorizontalSplit(whiteRatio: 0.5);
    }
    return ref
        .watch(gameCardEvalCacheOnlyProvider(fen))
        .when(
          loading: () => const _HorizontalSplit(whiteRatio: 0.5),
          error: (_, __) => const _HorizontalSplit(whiteRatio: 0.5),
          data: (cloud) {
            final pv = cloud.pvs.firstOrNull;
            if (pv == null) return const _HorizontalSplit(whiteRatio: 0.5);
            // Normalise to white-perspective: positive cp = white better.
            final sign = pv.whitePerspective ? 1 : -1;
            final mate = pv.isMate ? (pv.mate ?? 0) * sign : 0;
            final eval =
                mate != 0 ? (mate > 0 ? 10.0 : -10.0) : (pv.cp * sign) / 100.0;
            return _HorizontalSplit(whiteRatio: _whiteRatio(eval));
          },
        );
  }

  static double _whiteRatio(double eval) {
    // Same logistic curve mobile uses for the vertical bar — keeps the
    // tab and the in-board bar in lock-step on the same FEN.
    const double scale = 3.0;
    const double minRatio = 0.04;
    const double maxRatio = 0.96;
    final clamped = eval.clamp(-20.0, 20.0);
    final logistic = 1.0 / (1.0 + math.exp(-clamped / scale));
    return logistic.clamp(minRatio, maxRatio);
  }
}

class _HorizontalSplit extends StatelessWidget {
  const _HorizontalSplit({required this.whiteRatio});
  final double whiteRatio;

  // Track color picked to read against both the inactive chip
  // (`kBlack2Color` #1A) and the active chip / pane background
  // (`kBackgroundColor` #0C). `kPopUpColor` #11 was too dark to see.
  static const Color _trackColor = Color(0xFF3A3A3D);

  @override
  Widget build(BuildContext context) {
    final w = whiteRatio.clamp(0.04, 0.96);
    return Row(
      children: [
        Expanded(
          flex: (w * 1000).round(),
          child: const ColoredBox(color: kWhiteColor),
        ),
        Expanded(
          flex: ((1.0 - w) * 1000).round(),
          child: const ColoredBox(color: _trackColor),
        ),
      ],
    );
  }
}

enum _TabAction { toggleMute, close, closeOthers, closeRight }

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: kWhiteColor70),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: kWhiteColor, fontSize: 13)),
      ],
    );
  }
}

/// Standard chess starting position. Used to detect "fresh Board tab — no
/// game yet" so we don't draw an eval bar on every empty Board tab chip.
const String _initialFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.visible, required this.onTap});
  final bool visible;
  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 80),
      opacity: widget.visible ? 1 : 0,
      child: ClickCursor(
        enabled: widget.visible,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit:
              (_) => setState(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.visible ? widget.onTap : null,
            onTapDown:
                widget.visible ? (_) => setState(() => _pressed = true) : null,
            onTapUp:
                widget.visible ? (_) => setState(() => _pressed = false) : null,
            onTapCancel:
                widget.visible ? () => setState(() => _pressed = false) : null,
            child: SingleMotionBuilder(
              value: _pressed ? 0.85 : (_hovered ? 1.08 : 1.0),
              motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
              builder:
                  (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  // Translucent white pad so the hover affordance reads on
                  // any underlying chip fill — `kBlack3Color` was fine on
                  // the active tab (#0C) but matched the new inactive
                  // chip fill exactly, making the hover invisible.
                  color:
                      _hovered ? const Color(0x33FFFFFF) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: _hovered ? kWhiteColor : kWhiteColor70,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Single icon family across every tab kind — all `_outlined` so the strip
// reads as a coherent set rather than a Frankenstein of rounded + outlined
// + filled glyphs.
IconData _iconFor(TabKind kind) {
  switch (kind) {
    case TabKind.board:
      return Icons.grid_4x4_outlined;
    case TabKind.tournaments:
      return Icons.emoji_events_outlined;
    case TabKind.tournamentDetail:
      return Icons.emoji_events_outlined;
    case TabKind.library:
      return Icons.collections_bookmark_outlined;
    case TabKind.databaseWorkspace:
      return Icons.table_chart_outlined;
    case TabKind.favorites:
      return Icons.star_outline_outlined;
    case TabKind.players:
      return Icons.groups_outlined;
    case TabKind.calendar:
      return Icons.calendar_today_outlined;
    case TabKind.countrymen:
      return Icons.public_outlined;
    case TabKind.settings:
      return Icons.settings_outlined;
    case TabKind.openingExplorer:
      return Icons.menu_book_outlined;
    case TabKind.boardEditor:
      return Icons.brush_outlined;
    case TabKind.watch:
      return Icons.live_tv_outlined;
    case TabKind.playerScoreCard:
      return Icons.assignment_ind_outlined;
    case TabKind.playerProfile:
      return Icons.person_outline_rounded;
    case TabKind.userProfile:
      return Icons.account_circle_outlined;
    case TabKind.boardSettings:
      return Icons.tune_outlined;
    case TabKind.notificationSettings:
      return Icons.notifications_outlined;
    case TabKind.play:
      return Icons.sports_esports_outlined;
  }
}
