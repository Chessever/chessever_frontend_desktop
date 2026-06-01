import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_explorer_filters.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/explorer_filter_availability.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';

/// "Filters" trigger button + popover. Replaces the always-visible filter
/// rail in the opening-explorer games column — users only see the chrome
/// when they ask for it (#461 Trello feedback).
///
/// The button surfaces an active-count badge so it never lies about state:
/// even with the popover closed, the user can tell at a glance whether any
/// filter is in effect.
class ExplorerFiltersPopoverButton extends ConsumerStatefulWidget {
  const ExplorerFiltersPopoverButton({
    super.key,
    this.compact = false,
    this.scopedPlayer,
  });

  final bool compact;
  final GamebasePlayer? scopedPlayer;

  @override
  ConsumerState<ExplorerFiltersPopoverButton> createState() =>
      _ExplorerFiltersPopoverButtonState();
}

class _ExplorerFiltersPopoverButtonState
    extends ConsumerState<ExplorerFiltersPopoverButton>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);
  bool _hovered = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gamebaseExplorerProvider);
    final activeCount = _activeFilterCount(state.filters, widget.scopedPlayer);
    final hasActive = activeCount > 0;
    final filtersAvailable = explorerFiltersAvailableForScope(
      widget.scopedPlayer,
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder:
            (context, _) => SizedBox(
              width: 360,
              height: 560,
              child: ColoredBox(
                color: kBlack2Color,
                child: DesktopExplorerFilters(
                  scopedPlayer: widget.scopedPlayer,
                ),
              ),
            ),
        child: DesktopTooltip(
          message:
              filtersAvailable
                  ? (hasActive ? 'Filters · $activeCount active' : 'Filters')
                  : wholeDatabaseFiltersComingSoonMessage,
          child: ClickCursor(
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!filtersAvailable) {
                    showWholeDatabaseFiltersComingSoon(context);
                    return;
                  }
                  _controller.toggle();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color:
                        hasActive
                            ? kPrimaryColor.withValues(alpha: 0.12)
                            : (_hovered ? kBlack3Color : Colors.transparent),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color:
                          hasActive
                              ? kPrimaryColor.withValues(alpha: 0.45)
                              : (_hovered
                                  ? kWhiteColor.withValues(alpha: 0.18)
                                  : kDividerColor),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        size: 13,
                        color: hasActive ? kPrimaryColor : kWhiteColor70,
                      ),
                      if (!widget.compact) ...[
                        const SizedBox(width: 6),
                        Text(
                          'Filters',
                          style: TextStyle(
                            color: hasActive ? kWhiteColor : kWhiteColor70,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                      if (hasActive) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: kPrimaryColor,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$activeCount',
                            style: const TextStyle(
                              color: kBackgroundColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ],
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

int _activeFilterCount(dynamic filters, GamebasePlayer? scopedPlayer) {
  // Lightweight introspection of the explorer filters object — we avoid
  // a hard dependency on its concrete type so this widget keeps compiling
  // if the filter shape grows. `hasActiveFilters` already exists on the
  // explorer state for the boolean case; we count individually for the
  // badge.
  var count = 0;
  try {
    final tcs = filters.timeControls as List;
    if (tcs.isNotEmpty) count += 1;
  } catch (_) {}
  try {
    if (filters.gameResult != null) count += 1;
  } catch (_) {}
  try {
    if (filters.playerColor != null) count += 1;
  } catch (_) {}
  try {
    if (filters.minRating != null || filters.maxRating != null) count += 1;
  } catch (_) {}
  try {
    if (filters.yearFrom != null || filters.yearTo != null) count += 1;
  } catch (_) {}
  try {
    if (filters.isOnline != null) count += 1;
  } catch (_) {}
  try {
    final sortByName = filters.sortBy.name as String;
    final directionName = filters.sortDirection.name as String;
    if (sortByName != 'date' || directionName != 'desc') count += 1;
  } catch (_) {}
  try {
    final players = filters.selectedPlayers as List;
    final playerIsScope =
        scopedPlayer != null &&
        players.length == 1 &&
        players.first is GamebasePlayer &&
        (players.first as GamebasePlayer).id == scopedPlayer.id;
    if (players.isNotEmpty && !playerIsScope) count += 1;
  } catch (_) {}
  return count;
}
