import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Compact / List / Grid switcher used wherever desktop renders game cards
/// (Library cards body, Countrymen, Tournament games view).
///
/// All three buttons write to `boardSettingsProviderNew` via
/// `setGamesListViewModeIndex`, which is the same persisted record mobile
/// reads — so changing layout here propagates to every other game-card
/// surface and survives across launches.
class GameViewModeToggle extends ConsumerWidget {
  const GameViewModeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(gamesListViewModeProvider);
    void select(GamesListViewMode next) {
      ref
          .read(boardSettingsProviderNew.notifier)
          .setGamesListViewModeIndex(next.index);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToggleButton(
          icon: Icons.view_agenda_outlined,
          tooltip: 'Card view',
          selected: mode == GamesListViewMode.gamesCard,
          onTap: () => select(GamesListViewMode.gamesCard),
        ),
        const SizedBox(width: 4),
        _ToggleButton(
          icon: Icons.view_list_rounded,
          tooltip: 'Table view',
          selected: mode == GamesListViewMode.chessBoard,
          onTap: () => select(GamesListViewMode.chessBoard),
        ),
        const SizedBox(width: 4),
        _ToggleButton(
          icon: Icons.grid_view_rounded,
          tooltip: 'Grid view',
          selected: mode == GamesListViewMode.chessBoardGrid,
          onTap: () => select(GamesListViewMode.chessBoardGrid),
        ),
      ],
    );
  }
}

class _ToggleButton extends StatefulWidget {
  const _ToggleButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ToggleButton> createState() => _ToggleButtonState();
}

class _ToggleButtonState extends State<_ToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          // forui-backed tooltip — Material's Tooltip leaks tickers under
          // RawTooltip's SingleTickerProviderStateMixin when the chip is
          // reparented (tab swap). DesktopTooltip wraps FTooltip so the
          // assert never fires. See CLAUDE.md §3.
          child: DesktopTooltip(
            message: widget.tooltip,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.15)
                        : (_hovered ? kBlack3Color : Colors.transparent),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: selected ? kPrimaryColor : kDividerColor,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 14,
                color: selected ? kPrimaryColor : kWhiteColor70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
