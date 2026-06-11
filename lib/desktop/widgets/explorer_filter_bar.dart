import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/screens/gamebase/models/gamebase_game.dart'
    show TimeControl;
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/explorer_filter_availability.dart';
import 'package:chessever/desktop/widgets/explorer_filters_popover.dart';
import 'package:chessever/theme/app_theme.dart';

/// Quick-filter strip used at the bottom of explorer surfaces.
///
/// The rail intentionally exposes the fast, discrete filter surface inline:
/// level brackets, time controls, result, format, and player color. The
/// advanced popover remains available at the end for range/player/sort fields
/// that need more room than a one-row bottom rail can provide.
///
/// Used by both the dedicated `OpeningExplorerPane` and the right-rail
/// Explorer tab inside the Board pane.
class ExplorerFilterBar extends ConsumerWidget {
  const ExplorerFilterBar({super.key, this.compact = false, this.scopedPlayer});

  /// When true, drops chip labels for the time-control row to fit very
  /// narrow rails (the icon stays). Level brackets always stay as text.
  final bool compact;

  /// Non-null only for bounded Explorer scopes such as player Build Tree.
  /// Whole Database Explorer intentionally disables filters for now.
  final GamebasePlayer? scopedPlayer;

  static const _timeControls = <_TimeControlChip>[
    _TimeControlChip(
      value: TimeControl.classical,
      label: 'Classical',
      icon: Icons.schedule_rounded,
    ),
    _TimeControlChip(
      value: TimeControl.rapid,
      label: 'Rapid',
      icon: Icons.bolt_outlined,
    ),
    _TimeControlChip(
      value: TimeControl.blitz,
      label: 'Blitz',
      icon: Icons.flash_on_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(
      gamebaseExplorerProvider.select((s) => s.filters),
    );
    final notifier = ref.read(gamebaseExplorerProvider.notifier);
    final selectedTitle = gamebasePlayerTitleForMinRating(filters.minRating);
    final filtersAvailable = explorerFiltersAvailableForScope(scopedPlayer);
    final treeState =
        scopedPlayer == null
            ? null
            : ref.watch(playerOpeningTreeProvider(scopedPlayer!.id));
    void guardOrRun(VoidCallback action) {
      if (!filtersAvailable) {
        showWholeDatabaseFiltersComingSoon(context);
        return;
      }
      action();
    }

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: kBlack2Color,
        border: Border(top: BorderSide(color: kDividerColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _GroupLabel(compact ? 'Lv' : 'Level'),
            for (final title in GamebasePlayerTitle.values) ...[
              _FilterChip(
                label:
                    compact ? title.label : '${title.label} ${title.subtitle}',
                active: selectedTitle == title,
                onTap: () => guardOrRun(() => notifier.toggleTitle(title)),
              ),
              const SizedBox(width: 6),
            ],
            const _RailDivider(),
            _GroupLabel(compact ? 'TC' : 'Time'),
            for (final tc in _timeControls) ...[
              _FilterChip(
                icon: tc.icon,
                label: compact ? _shortTimeControlLabel(tc.value) : tc.label,
                active: filters.timeControls.contains(tc.value),
                onTap:
                    () =>
                        guardOrRun(() => notifier.toggleTimeControl(tc.value)),
              ),
              const SizedBox(width: 6),
            ],
            const _RailDivider(),
            _GroupLabel(compact ? 'Res' : 'Result'),
            for (final r in GamebaseGameResult.values) ...[
              _FilterChip(
                label: r.displayText,
                active: filters.gameResult == r,
                onTap: () => guardOrRun(() => notifier.toggleGameResult(r)),
              ),
              const SizedBox(width: 6),
            ],
            const _RailDivider(),
            _GroupLabel(compact ? 'Fmt' : 'Format'),
            _FilterChip(
              icon: Icons.public_off_rounded,
              label: 'OTB',
              active: filters.isOnline == false,
              onTap: () => guardOrRun(() => notifier.toggleFormat(false)),
            ),
            const SizedBox(width: 6),
            _FilterChip(
              icon: Icons.public_rounded,
              label: 'Online',
              active: filters.isOnline == true,
              onTap: () => guardOrRun(() => notifier.toggleFormat(true)),
            ),
            const _RailDivider(),
            _GroupLabel(compact ? 'Side' : 'Color'),
            _FilterChip(
              icon: Icons.circle,
              label: 'White',
              active: filters.playerColor == GamebasePlayerColor.white,
              onTap:
                  () => guardOrRun(
                    () => notifier.togglePlayerColor(GamebasePlayerColor.white),
                  ),
            ),
            const SizedBox(width: 6),
            _FilterChip(
              icon: Icons.circle_outlined,
              label: 'Black',
              active: filters.playerColor == GamebasePlayerColor.black,
              onTap:
                  () => guardOrRun(
                    () => notifier.togglePlayerColor(GamebasePlayerColor.black),
                  ),
            ),
            const _RailDivider(),
            ExplorerFiltersPopoverButton(
              compact: true,
              scopedPlayer: scopedPlayer,
            ),
            if (treeState != null) ...[
              const _RailDivider(),
              PlayerOpeningTreeProgressChip(
                state: treeState,
                onRetry:
                    () =>
                        ref
                            .read(
                              playerOpeningTreeProvider(
                                scopedPlayer!.id,
                              ).notifier,
                            )
                            .retry(),
              ),
            ],
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class PlayerOpeningTreeProgressChip extends StatelessWidget {
  const PlayerOpeningTreeProgressChip({
    super.key,
    required this.state,
    required this.onRetry,
    this.maxWidth = 300,
  });

  final PlayerOpeningTreeState state;
  final VoidCallback onRetry;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final progress = state.progress;
    final status = progress.status;
    final isError = status == PlayerOpeningTreeStatus.error;
    final isComplete = status == PlayerOpeningTreeStatus.complete;
    final fetchedLabel = _priorityFetchedLabel(progress);
    final label =
        isError
            ? 'Tree failed'
            : isComplete
            ? 'Tree complete · ${_fmt(progress.processedGames)} games'
            : '$fetchedLabel'
                ' · building ${_fmt(progress.processedGames)}'
                ' · ${_fmt(progress.indexedPositions)} positions';
    final color =
        isError
            ? kRedColor
            : isComplete
            ? kGreenColor
            : kPrimaryColor;

    return DesktopTooltip(
      message: label,
      child: InkWell(
        onTap: isError ? onRetry : null,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.36)),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status == PlayerOpeningTreeStatus.building)
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color,
                  ),
                )
              else
                Icon(
                  isError ? Icons.refresh_rounded : Icons.account_tree_outlined,
                  size: 13,
                  color: color,
                ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
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

String _priorityFetchedLabel(PlayerOpeningTreeProgress progress) {
  final priorityFetched = progress.priorityFetchedGames;
  final priorityTotal = progress.priorityTotalGames;
  final color = progress.priorityColor;
  if (priorityFetched != null && color != null && color.isNotEmpty) {
    final colorLabel = color.toLowerCase();
    if (priorityTotal != null) {
      return 'Fetched $colorLabel ${_fmt(priorityFetched)}/${_fmt(priorityTotal)}';
    }
    return 'Fetched $colorLabel ${_fmt(priorityFetched)}';
  }
  return 'Fetched ${_fmt(progress.fetchedGames)}';
}

String _fmt(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
  return value.toString();
}

String _shortTimeControlLabel(TimeControl value) {
  switch (value) {
    case TimeControl.classical:
      return 'Classical';
    case TimeControl.rapid:
      return 'Rapid';
    case TimeControl.blitz:
      return 'Blitz';
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _RailDivider extends StatelessWidget {
  const _RailDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: kDividerColor,
    );
  }
}

class _TimeControlChip {
  const _TimeControlChip({
    required this.value,
    required this.label,
    required this.icon,
  });
  final TimeControl value;
  final String label;
  final IconData icon;
}

class _FilterChip extends StatefulWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
  });

  final String? label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final fg =
        active ? kPrimaryColor : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        active
            ? kPrimaryColor.withValues(alpha: 0.14)
            : (_hovered ? kBlack3Color : Colors.transparent);
    final border =
        active ? kPrimaryColor.withValues(alpha: 0.45) : kDividerColor;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 13, color: fg),
                if (widget.label != null) const SizedBox(width: 4),
              ],
              if (widget.label != null)
                Text(
                  widget.label!,
                  style: TextStyle(
                    color: fg,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
