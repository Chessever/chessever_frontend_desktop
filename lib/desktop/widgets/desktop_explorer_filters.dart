import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/explorer_filter_scope.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
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
    final isBuildTreeScope = scopedPlayer != null;
    final filters =
        scopedPlayer == null
            ? state.filters
            : sanitizeBuildTreeExplorerFilters(state.filters, scopedPlayer!);
    if (isBuildTreeScope && filters != state.filters) {
      Future.microtask(() {
        ref.read(gamebaseExplorerProvider.notifier).updateFilters(filters);
      });
    }
    final notifier = ref.read(gamebaseExplorerProvider.notifier);
    final hasActiveSettings = _hasActiveFilterSettings(filters, scopedPlayer);
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
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _SectionLabel('Time control'),
                    const SizedBox(height: 5),
                    _TimeControlChips(
                      selected: filters.timeControls,
                      onToggle: notifier.toggleTimeControl,
                    ),
                    if (!isBuildTreeScope) ...[
                      const SizedBox(height: 10),
                      const _SectionLabel('Level'),
                      const SizedBox(height: 5),
                      _TitleChips(
                        selectedMinRating: filters.minRating,
                        onToggle: notifier.toggleTitle,
                      ),
                      const SizedBox(height: 10),
                      const _SectionLabel('Result'),
                      const SizedBox(height: 5),
                      _ResultChips(
                        selected: filters.gameResult,
                        onToggle: notifier.toggleGameResult,
                      ),
                    ],
                    const SizedBox(height: 10),
                    const _SectionLabel('Format'),
                    const SizedBox(height: 5),
                    _FormatChips(
                      selectedIsOnline: filters.isOnline,
                      onToggle: notifier.toggleFormat,
                    ),
                    if (filters.playerIds.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const _SectionLabel('Played as'),
                      const SizedBox(height: 5),
                      _ColorChips(
                        selected: filters.playerColor,
                        onToggle: notifier.togglePlayerColor,
                      ),
                    ],
                    if (!isBuildTreeScope) ...[
                      const SizedBox(height: 10),
                      const _SectionLabel('Rating range'),
                      const SizedBox(height: 5),
                      _RatingRange(
                        minRating: filters.minRating,
                        maxRating: filters.maxRating,
                        onChanged: notifier.setRatingRange,
                      ),
                      const SizedBox(height: 10),
                      const _SectionLabel('Year range'),
                      const SizedBox(height: 5),
                      _YearRange(
                        yearFrom: filters.yearFrom,
                        yearTo: filters.yearTo,
                        onChanged: notifier.setYearRange,
                      ),
                    ],
                    const SizedBox(height: 10),
                    const _SectionLabel('Player'),
                    const SizedBox(height: 5),
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
      padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
      child: Row(
        children: [
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
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: border),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: selected ? kWhiteColor : kWhiteColor70,
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
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
      case TimeControl.bullet:
        return 'Bullet';
      case TimeControl.ultrabullet:
        return 'Ultrabullet';
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
            selected: selected == t,
            onTap: () => onToggle(t),
          ),
      ],
    );
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
            selected: selected == r,
            onTap: () => onToggle(r),
          ),
      ],
    );
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
          selected: selectedIsOnline == false,
          onTap: () => onToggle(false),
        ),
        _Chip(
          label: 'Online',
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
          selected: selected == GamebasePlayerColor.white,
          onTap: () => onToggle(GamebasePlayerColor.white),
        ),
        _Chip(
          label: 'Black',
          selected: selected == GamebasePlayerColor.black,
          onTap: () => onToggle(GamebasePlayerColor.black),
        ),
      ],
    );
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

    useEffect(() {
      return () => debounceTimer.value?.cancel();
    }, const []);

    if (selected != null) {
      return _SelectedPlayerPill(
        player: selected!,
        onRemove: () => onRemove(selected!.id),
      );
    }

    final normalizedQuery = query.value.trim();
    final isSearchable = normalizedQuery.length >= 2;
    final isDebouncing = isSearchable && debounced.value != normalizedQuery;
    final results =
        isSearchable && !isDebouncing
            ? ref.watch(playerSearchProvider(debounced.value))
            : const AsyncValue<List<GamebasePlayer>>.data([]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopSearchField(
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search players (min 2 chars)',
          trailing:
              isDebouncing
                  ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                    ),
                  )
                  : null,
          onChanged: (v) {
            query.value = v;
            debounceTimer.value?.cancel();
            final normalized = v.trim();
            if (normalized.length < 2) {
              debounced.value = '';
              return;
            }
            debounceTimer.value = Timer(
              const Duration(milliseconds: 180),
              () => debounced.value = normalized,
            );
          },
          onClear: () {
            debounceTimer.value?.cancel();
            debounced.value = '';
            query.value = '';
          },
        ),
        if (isSearchable)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: kDividerColor),
              ),
              child:
                  isDebouncing
                      ? const _PlayerSearchStatus(
                        message: 'Searching players...',
                        loading: true,
                      )
                      : results.when(
                        data: (players) {
                          if (players.isEmpty) {
                            return const _PlayerSearchStatus(
                              message: 'No players found',
                            );
                          }
                          return ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            physics: const DesktopScrollPhysics(),
                            itemCount: players.length,
                            separatorBuilder:
                                (_, __) => const Divider(
                                  color: kDividerColor,
                                  height: 1,
                                ),
                            itemBuilder: (context, i) {
                              final p = players[i];
                              return _PlayerSearchHit(
                                player: p,
                                onTap: () {
                                  debounceTimer.value?.cancel();
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
                            () => const _PlayerSearchStatus(
                              message: 'Searching players...',
                              loading: true,
                            ),
                        error:
                            (_, __) => const _PlayerSearchStatus(
                              message: 'Search failed',
                              color: kRedColor,
                            ),
                      ),
            ),
          ),
      ],
    );
  }
}

class _PlayerSearchStatus extends StatelessWidget {
  const _PlayerSearchStatus({
    required this.message,
    this.loading = false,
    this.color = kLightGreyColor,
  });

  final String message;
  final bool loading;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(message, style: TextStyle(color: color, fontSize: 11)),
          ),
        ],
      ),
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
