import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/game_filter/wheel_range_filter.dart';

/// Desktop-native filter rail for the Opening Explorer pane.
///
/// Built ground-up from `gamebaseExplorerProvider` rather than wrapping
/// the mobile `GamebaseFilterPanel` (per the codebase memory rule). Same
/// notifier methods drive the state; chrome here matches the rest of the
/// desktop shell — forui dividers, FTheme-scoped FButtons for actions,
/// dense chips and a flat scroll surface instead of mobile's accordion
/// and modal sheet.
///
/// Surfaces the Gamebase filters/sorts exposed by the API for position
/// explorer + games queries so `DesktopPositionGamesTable` and the moves
/// aggregate both honor the same picks.
class DesktopExplorerFilters extends ConsumerWidget {
  const DesktopExplorerFilters({super.key, this.scopedPlayer});

  final GamebasePlayer? scopedPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(gamebaseExplorerProvider);
    final filters =
        scopedPlayer == null
            ? state.filters
            : _forceScopedPlayer(state.filters, scopedPlayer!);
    final notifier = ref.read(gamebaseExplorerProvider.notifier);
    final hasActiveSettings =
        _hasActiveFilterSettings(filters, scopedPlayer) ||
        filters.hasCustomSort;
    return FTheme(
      data: FThemes.zinc.dark,
      child: ColoredBox(
        color: kBlack2Color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              hasActiveFilters: hasActiveSettings,
              onClear:
                  () => _clearExplorerFilters(
                    notifier: notifier,
                    scopedPlayer: scopedPlayer,
                  ),
            ),
            const FDivider(),
            Expanded(
              child: SingleChildScrollView(
                physics: const DesktopScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SectionLabel('Time control'),
                    const SizedBox(height: 8),
                    _TimeControlChips(
                      selected: filters.timeControls,
                      onToggle: notifier.toggleTimeControl,
                    ),
                    const SizedBox(height: 18),
                    const _SectionLabel('Level'),
                    const SizedBox(height: 8),
                    _TitleChips(
                      selectedMinRating: filters.minRating,
                      onToggle: notifier.toggleTitle,
                    ),
                    const SizedBox(height: 18),
                    const _SectionLabel('Result'),
                    const SizedBox(height: 8),
                    _ResultChips(
                      selected: filters.gameResult,
                      onToggle: notifier.toggleGameResult,
                    ),
                    const SizedBox(height: 18),
                    const _SectionLabel('Format'),
                    const SizedBox(height: 8),
                    _FormatChips(
                      selectedIsOnline: filters.isOnline,
                      onToggle: notifier.toggleFormat,
                    ),
                    if (filters.playerIds.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const _SectionLabel('Played as'),
                      const SizedBox(height: 8),
                      _ColorChips(
                        selected: filters.playerColor,
                        onToggle: notifier.togglePlayerColor,
                      ),
                    ],
                    const SizedBox(height: 18),
                    const _SectionLabel('Rating range'),
                    const SizedBox(height: 8),
                    _RatingRange(
                      minRating: filters.minRating,
                      maxRating: filters.maxRating,
                      onChanged: notifier.setRatingRange,
                    ),
                    const SizedBox(height: 18),
                    const _SectionLabel('Year range'),
                    const SizedBox(height: 8),
                    _YearRange(
                      yearFrom: filters.yearFrom,
                      yearTo: filters.yearTo,
                      onChanged: notifier.setYearRange,
                    ),
                    const SizedBox(height: 18),
                    const _SectionLabel('Sort games'),
                    const SizedBox(height: 8),
                    _SortControls(
                      sortBy: filters.sortBy,
                      sortDirection: filters.sortDirection,
                      onChanged: notifier.setPositionGamesSort,
                    ),
                    const SizedBox(height: 18),
                    const _SectionLabel('Player'),
                    const SizedBox(height: 8),
                    if (scopedPlayer != null)
                      _SelectedPlayerPill(player: scopedPlayer!, onRemove: null)
                    else
                      _PlayerFilterField(
                        selected:
                            filters.selectedPlayers.isNotEmpty
                                ? filters.selectedPlayers.first
                                : null,
                        onAdd: notifier.addPlayerFilter,
                        onRemove: notifier.removePlayerFilter,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

GamebaseFilters _forceScopedPlayer(
  GamebaseFilters filters,
  GamebasePlayer scopedPlayer,
) {
  return filters.copyWith(
    playerIds: <String>[scopedPlayer.id],
    selectedPlayers: <GamebasePlayer>[scopedPlayer],
  );
}

bool _matchesScopedPlayer(GamebaseFilters filters, GamebasePlayer player) {
  return filters.playerIds.length == 1 &&
      filters.playerIds.first == player.id &&
      filters.selectedPlayers.length == 1 &&
      filters.selectedPlayers.first.id == player.id;
}

bool _hasActiveFilterSettings(
  GamebaseFilters filters,
  GamebasePlayer? scopedPlayer,
) {
  final hasScopedPlayer =
      scopedPlayer != null && _matchesScopedPlayer(filters, scopedPlayer);
  return filters.timeControls.isNotEmpty ||
      filters.minRating != null ||
      filters.maxRating != null ||
      filters.playerColor != null ||
      filters.gameResult != null ||
      filters.isOnline != null ||
      filters.yearFrom != null ||
      filters.yearTo != null ||
      (scopedPlayer == null ? filters.playerIds.isNotEmpty : !hasScopedPlayer);
}

void _clearExplorerFilters({
  required GamebaseExplorerNotifier notifier,
  required GamebasePlayer? scopedPlayer,
}) {
  if (scopedPlayer == null) {
    notifier.clearFilters();
    return;
  }

  notifier.updateFilters(
    GamebaseFilters(
      playerIds: <String>[scopedPlayer.id],
      selectedPlayers: <GamebasePlayer>[scopedPlayer],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.hasActiveFilters, required this.onClear});

  final bool hasActiveFilters;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(
        children: [
          const Icon(Icons.tune_outlined, size: 14, color: kPrimaryColor),
          const SizedBox(width: 8),
          const Text(
            'Filters',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          if (hasActiveFilters) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Active',
                style: TextStyle(
                  color: kPrimaryColor,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (hasActiveFilters)
            FButton(
              style: FButtonStyle.ghost(),
              onPress: onClear,
              child: const Text(
                'Clear all',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
      ),
    );
  }
}

/// Compact toggle chip used across all the filter rows. Mirrors the
/// `_FilterChip` from mobile in feel, but flatter and tuned for a
/// keyboard+mouse pointer (hover affordance, no haptic, no scaled fonts).
class _Chip extends StatefulWidget {
  const _Chip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.iconColor,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final accent = selected ? kPrimaryColor : kWhiteColor70;
    final border =
        selected
            ? kPrimaryColor.withValues(alpha: 0.55)
            : (_hovered
                ? kWhiteColor.withValues(alpha: 0.30)
                : kWhiteColor.withValues(alpha: 0.12));
    final bg =
        selected
            ? kPrimaryColor.withValues(alpha: 0.12)
            : (_hovered ? kBlack3Color : kBlack3Color.withValues(alpha: 0.55));
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 12, color: widget.iconColor ?? accent),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: selected ? kWhiteColor : kWhiteColor70,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeControlChips extends StatelessWidget {
  const _TimeControlChips({required this.selected, required this.onToggle});

  final List<TimeControl> selected;
  final void Function(TimeControl) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tc in TimeControl.values)
          _Chip(
            label: _label(tc),
            icon: _icon(tc),
            selected: selected.contains(tc),
            onTap: () => onToggle(tc),
          ),
      ],
    );
  }

  String _label(TimeControl tc) {
    switch (tc) {
      case TimeControl.classical:
        return 'Classical';
      case TimeControl.rapid:
        return 'Rapid';
      case TimeControl.blitz:
        return 'Blitz';
    }
  }

  IconData _icon(TimeControl tc) {
    switch (tc) {
      case TimeControl.classical:
        return Icons.hourglass_top_rounded;
      case TimeControl.rapid:
        return Icons.timer_outlined;
      case TimeControl.blitz:
        return Icons.bolt_rounded;
    }
  }
}

class _TitleChips extends StatelessWidget {
  const _TitleChips({required this.selectedMinRating, required this.onToggle});

  final int? selectedMinRating;
  final void Function(GamebasePlayerTitle) onToggle;

  @override
  Widget build(BuildContext context) {
    final selected = gamebasePlayerTitleForMinRating(selectedMinRating);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final t in GamebasePlayerTitle.values)
          _Chip(
            label: '${t.label} ${t.subtitle}',
            icon: _icon(t),
            selected: selected == t,
            onTap: () => onToggle(t),
          ),
      ],
    );
  }

  IconData _icon(GamebasePlayerTitle t) {
    switch (t) {
      case GamebasePlayerTitle.gm:
        return Icons.workspace_premium_rounded;
      case GamebasePlayerTitle.im:
        return Icons.military_tech_rounded;
      case GamebasePlayerTitle.fm:
        return Icons.shield_outlined;
      case GamebasePlayerTitle.cm:
        return Icons.school_outlined;
    }
  }
}

class _ResultChips extends StatelessWidget {
  const _ResultChips({required this.selected, required this.onToggle});

  final GamebaseGameResult? selected;
  final void Function(GamebaseGameResult) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final r in GamebaseGameResult.values)
          _Chip(
            label: r.displayText,
            icon: _icon(r),
            selected: selected == r,
            onTap: () => onToggle(r),
          ),
      ],
    );
  }

  IconData _icon(GamebaseGameResult r) {
    switch (r) {
      case GamebaseGameResult.whiteWins:
        return Icons.flag_outlined;
      case GamebaseGameResult.blackWins:
        return Icons.flag_rounded;
      case GamebaseGameResult.draw:
        return Icons.handshake_outlined;
    }
  }
}

class _FormatChips extends StatelessWidget {
  const _FormatChips({required this.selectedIsOnline, required this.onToggle});

  final bool? selectedIsOnline;
  final void Function(bool isOnline) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _Chip(
          label: 'OTB',
          icon: Icons.public_off_rounded,
          selected: selectedIsOnline == false,
          onTap: () => onToggle(false),
        ),
        _Chip(
          label: 'Online',
          icon: Icons.public_rounded,
          selected: selectedIsOnline == true,
          onTap: () => onToggle(true),
        ),
      ],
    );
  }
}

class _ColorChips extends StatelessWidget {
  const _ColorChips({required this.selected, required this.onToggle});

  final GamebasePlayerColor? selected;
  final void Function(GamebasePlayerColor) onToggle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _Chip(
          label: 'White',
          icon: Icons.circle,
          iconColor: kWhiteColor,
          selected: selected == GamebasePlayerColor.white,
          onTap: () => onToggle(GamebasePlayerColor.white),
        ),
        _Chip(
          label: 'Black',
          icon: Icons.circle_outlined,
          iconColor: kWhiteColor70,
          selected: selected == GamebasePlayerColor.black,
          onTap: () => onToggle(GamebasePlayerColor.black),
        ),
      ],
    );
  }
}

class _SortControls extends StatelessWidget {
  const _SortControls({
    required this.sortBy,
    required this.sortDirection,
    required this.onChanged,
  });

  static const List<GamebaseSortField> _fields = [
    GamebaseSortField.date,
    GamebaseSortField.avgElo,
    GamebaseSortField.whiteElo,
    GamebaseSortField.blackElo,
    GamebaseSortField.whiteName,
    GamebaseSortField.blackName,
    GamebaseSortField.result,
    GamebaseSortField.timeControl,
    GamebaseSortField.eco,
    GamebaseSortField.opening,
    GamebaseSortField.variation,
    GamebaseSortField.event,
    GamebaseSortField.site,
    GamebaseSortField.whiteTitle,
    GamebaseSortField.blackTitle,
    GamebaseSortField.whiteFed,
    GamebaseSortField.blackFed,
    GamebaseSortField.whiteFideId,
    GamebaseSortField.blackFideId,
    GamebaseSortField.whitePlayerId,
    GamebaseSortField.blackPlayerId,
    GamebaseSortField.id,
  ];

  final GamebaseSortField sortBy;
  final GamebaseSortDirection sortDirection;
  final void Function(
    GamebaseSortField sortBy,
    GamebaseSortDirection sortDirection,
  )
  onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final field in _fields)
              _Chip(
                label: field.label,
                icon: _sortIcon(field),
                selected: sortBy == field,
                onTap: () => onChanged(field, sortDirection),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _Chip(
              label: 'Descending',
              icon: Icons.south_rounded,
              selected: sortDirection == GamebaseSortDirection.desc,
              onTap: () => onChanged(sortBy, GamebaseSortDirection.desc),
            ),
            _Chip(
              label: 'Ascending',
              icon: Icons.north_rounded,
              selected: sortDirection == GamebaseSortDirection.asc,
              onTap: () => onChanged(sortBy, GamebaseSortDirection.asc),
            ),
          ],
        ),
      ],
    );
  }

  IconData _sortIcon(GamebaseSortField field) {
    switch (field) {
      case GamebaseSortField.date:
        return Icons.calendar_today_outlined;
      case GamebaseSortField.avgElo:
      case GamebaseSortField.whiteElo:
      case GamebaseSortField.blackElo:
        return Icons.equalizer_rounded;
      case GamebaseSortField.whiteName:
      case GamebaseSortField.blackName:
      case GamebaseSortField.whitePlayerId:
      case GamebaseSortField.blackPlayerId:
        return Icons.person_outline_rounded;
      case GamebaseSortField.whiteTitle:
      case GamebaseSortField.blackTitle:
        return Icons.workspace_premium_rounded;
      case GamebaseSortField.whiteFideId:
      case GamebaseSortField.blackFideId:
      case GamebaseSortField.id:
        return Icons.tag_rounded;
      case GamebaseSortField.whiteFed:
      case GamebaseSortField.blackFed:
        return Icons.flag_outlined;
      case GamebaseSortField.result:
        return Icons.scoreboard_outlined;
      case GamebaseSortField.timeControl:
        return Icons.timer_outlined;
      case GamebaseSortField.eco:
      case GamebaseSortField.opening:
      case GamebaseSortField.variation:
        return Icons.account_tree_outlined;
      case GamebaseSortField.event:
        return Icons.emoji_events_outlined;
      case GamebaseSortField.site:
        return Icons.place_outlined;
    }
  }
}

class _RatingRange extends HookWidget {
  const _RatingRange({
    required this.minRating,
    required this.maxRating,
    required this.onChanged,
  });

  static const double _absMin = 0;
  static const double _absMax = 3500;
  static const int _step = 50;

  final int? minRating;
  final int? maxRating;
  final void Function(int? minRating, int? maxRating) onChanged;

  @override
  Widget build(BuildContext context) {
    final range = useState(
      RangeValues(
        (minRating?.toDouble() ?? _absMin).clamp(_absMin, _absMax),
        (maxRating?.toDouble() ?? _absMax).clamp(_absMin, _absMax),
      ),
    );

    useEffect(() {
      final newStart = (minRating?.toDouble() ?? _absMin).clamp(
        _absMin,
        _absMax,
      );
      final newEnd = (maxRating?.toDouble() ?? _absMax).clamp(_absMin, _absMax);
      if (range.value.start != newStart || range.value.end != newEnd) {
        range.value = RangeValues(newStart, newEnd);
      }
      return null;
    }, [minRating, maxRating]);

    final isDefault =
        range.value.start == _absMin && range.value.end == _absMax;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!isDefault)
          DesktopTooltip(
            message: 'Reset rating range',
            child: ClickCursor(
              child: GestureDetector(
                onTap: () {
                  range.value = const RangeValues(_absMin, _absMax);
                  onChanged(null, null);
                },
                child: const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Reset',
                    style: TextStyle(
                      color: kLightGreyColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        WheelRangeFilter(
          minValue: _absMin,
          maxValue: _absMax,
          currentStart: range.value.start,
          currentEnd: range.value.end,
          divisions: ((_absMax - _absMin) / _step).round(),
          onChanged: (v) {
            range.value = v;
            final min = v.start == _absMin ? null : v.start.round();
            final max = v.end == _absMax ? null : v.end.round();
            onChanged(min, max);
          },
        ),
      ],
    );
  }
}

class _YearRange extends HookWidget {
  const _YearRange({
    required this.yearFrom,
    required this.yearTo,
    required this.onChanged,
  });

  static const double _absMin = 1800;

  final int? yearFrom;
  final int? yearTo;
  final void Function(int? yearFrom, int? yearTo) onChanged;

  @override
  Widget build(BuildContext context) {
    final absMax = DateTime.now().year.toDouble();
    final range = useState(
      RangeValues(
        (yearFrom?.toDouble() ?? _absMin).clamp(_absMin, absMax),
        (yearTo?.toDouble() ?? absMax).clamp(_absMin, absMax),
      ),
    );

    useEffect(() {
      final newStart = (yearFrom?.toDouble() ?? _absMin).clamp(_absMin, absMax);
      final newEnd = (yearTo?.toDouble() ?? absMax).clamp(_absMin, absMax);
      if (range.value.start != newStart || range.value.end != newEnd) {
        range.value = RangeValues(newStart, newEnd);
      }
      return null;
    }, [yearFrom, yearTo, absMax]);

    final isDefault = range.value.start == _absMin && range.value.end == absMax;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!isDefault)
          DesktopTooltip(
            message: 'Reset year range',
            child: ClickCursor(
              child: GestureDetector(
                onTap: () {
                  range.value = RangeValues(_absMin, absMax);
                  onChanged(null, null);
                },
                child: const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Reset',
                    style: TextStyle(
                      color: kLightGreyColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        WheelRangeFilter(
          minValue: _absMin,
          maxValue: absMax,
          currentStart: range.value.start,
          currentEnd: range.value.end,
          divisions: (absMax - _absMin).round(),
          onChanged: (v) {
            range.value = v;
            final from = v.start == _absMin ? null : v.start.round();
            final to = v.end == absMax ? null : v.end.round();
            onChanged(from, to);
          },
        ),
      ],
    );
  }
}

class _PlayerFilterField extends HookConsumerWidget {
  const _PlayerFilterField({
    required this.selected,
    required this.onAdd,
    required this.onRemove,
  });

  final GamebasePlayer? selected;
  final void Function(GamebasePlayer) onAdd;
  final void Function(String id) onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final query = useState<String>('');
    final debounced = useState<String>('');
    final debounceTimer = useRef<Timer?>(null);
    final focusNode = useFocusNode();
    final isFocused = useState<bool>(false);

    useEffect(() {
      void onFocus() => isFocused.value = focusNode.hasFocus;
      focusNode.addListener(onFocus);
      return () => focusNode.removeListener(onFocus);
    }, [focusNode]);

    useEffect(() {
      return () => debounceTimer.value?.cancel();
    }, const []);

    if (selected != null) {
      return _SelectedPlayerPill(
        player: selected!,
        onRemove: () => onRemove(selected!.id),
      );
    }

    final results =
        debounced.value.length >= 2
            ? ref.watch(playerSearchProvider(debounced.value))
            : const AsyncValue<List<GamebasePlayer>>.data([]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopSearchField(
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search players (min 2 chars)',
          onChanged: (v) {
            query.value = v;
            debounceTimer.value?.cancel();
            if (v.trim().length < 2) {
              debounced.value = '';
              return;
            }
            debounceTimer.value = Timer(
              const Duration(milliseconds: 250),
              () => debounced.value = v.trim(),
            );
          },
          onClear: () {
            debounceTimer.value?.cancel();
            debounced.value = '';
            query.value = '';
          },
        ),
        if (isFocused.value && query.value.trim().length >= 2)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: kDividerColor),
              ),
              child: results.when(
                data: (players) {
                  if (players.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'No players found',
                        style: TextStyle(color: kLightGreyColor, fontSize: 11),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    physics: const DesktopScrollPhysics(),
                    itemCount: players.length,
                    separatorBuilder:
                        (_, __) =>
                            const Divider(color: kDividerColor, height: 1),
                    itemBuilder: (context, i) {
                      final p = players[i];
                      return _PlayerSearchHit(
                        player: p,
                        onTap: () {
                          onAdd(p);
                          controller.clear();
                          query.value = '';
                          debounced.value = '';
                          focusNode.unfocus();
                        },
                      );
                    },
                  );
                },
                loading:
                    () => const Padding(
                      padding: EdgeInsets.all(14),
                      child: Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                          ),
                        ),
                      ),
                    ),
                error:
                    (_, __) => const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'Search failed',
                        style: TextStyle(color: kRedColor, fontSize: 11),
                      ),
                    ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SelectedPlayerPill extends StatelessWidget {
  const _SelectedPlayerPill({required this.player, required this.onRemove});

  final GamebasePlayer player;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.1),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          FederationFlag(
            federation: player.fed,
            width: 16,
            height: 11,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              player.titleAndName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onRemove != null)
            ClickCursor(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: kPrimaryColor,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlayerSearchHit extends StatefulWidget {
  const _PlayerSearchHit({required this.player, required this.onTap});

  final GamebasePlayer player;
  final VoidCallback onTap;

  @override
  State<_PlayerSearchHit> createState() => _PlayerSearchHitState();
}

class _PlayerSearchHitState extends State<_PlayerSearchHit> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            color: _hovered ? kBlack2Color : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                FederationFlag(
                  federation: widget.player.fed,
                  width: 16,
                  height: 11,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.player.titleAndName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.player.highestRating != null)
                  Text(
                    '${widget.player.highestRating}',
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
