import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/utils/eco_input_formatter.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_range_slider.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopMiniaturesFilterButton extends ConsumerWidget {
  const DesktopMiniaturesFilterButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(miniatureGamesFilterProvider);
    final activeCount = filter.activeFilterCount;
    final hasActive = activeCount > 0;

    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: hasActive ? 'Filters · $activeCount active' : 'Filters',
        child: FButton.icon(
          style: _filterTriggerStyle(hasActive),
          onPress: () async {
            final next = await showDesktopMiniaturesFilterDialog(
              context: context,
              currentFilter: filter,
            );
            if (next == null) return;
            unawaited(
              ref
                  .read(
                    premiumGamesProvider(PremiumGamesType.miniatures).notifier,
                  )
                  .applyMiniatureFilter(next),
            );
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.tune_rounded,
                size: 16,
                color: hasActive ? kPrimaryColor : kWhiteColor70,
              ),
              if (hasActive)
                Positioned(
                  right: -7,
                  top: -7,
                  child: Container(
                    width: 15,
                    height: 15,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: kPrimaryColor,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$activeCount',
                      style: const TextStyle(
                        color: kBackgroundColor,
                        fontSize: 9,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
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

Future<MiniatureGamesFilter?> showDesktopMiniaturesFilterDialog({
  required BuildContext context,
  required MiniatureGamesFilter currentFilter,
}) {
  return showDesktopDialog<MiniatureGamesFilter>(
    context,
    builder: (_) => _MiniaturesFilterDialog(initialFilter: currentFilter),
  );
}

class _MiniaturesFilterDialog extends StatefulWidget {
  const _MiniaturesFilterDialog({required this.initialFilter});

  final MiniatureGamesFilter initialFilter;

  @override
  State<_MiniaturesFilterDialog> createState() =>
      _MiniaturesFilterDialogState();
}

class _MiniaturesFilterDialogState extends State<_MiniaturesFilterDialog>
    with TickerProviderStateMixin {
  late MiniatureGamesFilter _draft;
  late final TextEditingController _ecoController;
  late final TextEditingController _openingController;
  late final TextEditingController _variationController;
  late final FDateFieldController _dateFromController;
  late final FDateFieldController _dateToController;
  late final TextEditingController _playerController;

  @override
  void initState() {
    super.initState();
    _draft = widget.initialFilter;
    _ecoController = TextEditingController(text: _draft.eco ?? '');
    _openingController = TextEditingController(text: _draft.opening ?? '');
    _variationController = TextEditingController(text: _draft.variation ?? '');
    _dateFromController = FDateFieldController(
      vsync: this,
      initialDate: _parseIsoDate(_draft.dateFrom),
    );
    _dateToController = FDateFieldController(
      vsync: this,
      initialDate: _parseIsoDate(_draft.dateTo),
    );
    _playerController = TextEditingController(text: _draft.player ?? '');
  }

  @override
  void dispose() {
    _ecoController.dispose();
    _openingController.dispose();
    _variationController.dispose();
    _dateFromController.dispose();
    _dateToController.dispose();
    _playerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeCount = _draft.activeFilterCount;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 640),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kDividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 40,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                Navigator.of(context).maybePop();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FilterHeader(
                  activeCount: activeCount,
                  onClose: () => Navigator.of(context).pop(),
                ),
                const FDivider(),
                Flexible(
                  child: _MiniaturesFilterBody(
                    draft: _draft,
                    ecoController: _ecoController,
                    openingController: _openingController,
                    variationController: _variationController,
                    dateFromController: _dateFromController,
                    dateToController: _dateToController,
                    playerController: _playerController,
                    onChanged: (next) => setState(() => _draft = next),
                  ),
                ),
                const FDivider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: DesktopDialogButton(
                          label: 'Reset',
                          tone: DesktopDialogButtonTone.secondary,
                          fillWidth: true,
                          onPress: activeCount == 0 ? null : _resetDraft,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DesktopDialogButton(
                          label: 'Apply',
                          tone: DesktopDialogButtonTone.primary,
                          fillWidth: true,
                          onPress:
                              () =>
                                  Navigator.of(context).pop(_normalizedDraft()),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _resetDraft() {
    _syncDraft(
      MiniatureGamesFilter.defaultFilter.copyWith(
        sort: widget.initialFilter.sort,
        order: widget.initialFilter.order,
        search: widget.initialFilter.search,
        clearSearch: widget.initialFilter.search == null,
      ),
    );
  }

  MiniatureGamesFilter _normalizedDraft() {
    final normalizedEco = _normalizedEco;
    return MiniatureGamesFilter(
      window: _draft.window,
      sort: _draft.sort,
      order: _draft.order,
      results: _draft.results,
      eco: normalizedEco,
      opening: _normalizedText(_openingController.text),
      variation: _normalizedText(_variationController.text),
      ecoCategories:
          normalizedEco == null ? _draft.ecoCategories : const <String>{},
      timeControls: _draft.timeControls,
      isOnline: _draft.isOnline,
      minRating: _draft.minRating,
      maxRating: _draft.maxRating,
      minMoves: _draft.minMoves,
      maxMoves: _draft.maxMoves,
      dateFrom: _draft.dateFrom,
      dateTo: _draft.dateTo,
      search: _draft.search,
      player: _normalizedText(_playerController.text),
    );
  }

  String? get _normalizedEco {
    final value = _ecoController.text.trim().toUpperCase();
    return value.isEmpty ? null : value;
  }

  void _syncDraft(MiniatureGamesFilter filter) {
    setState(() {
      _draft = filter;
      _ecoController.text = filter.eco ?? '';
      _openingController.text = filter.opening ?? '';
      _variationController.text = filter.variation ?? '';
      _dateFromController.value = _parseIsoDate(filter.dateFrom);
      _dateToController.value = _parseIsoDate(filter.dateTo);
      _playerController.text = filter.player ?? '';
    });
  }
}

class _MiniaturesFilterBody extends StatelessWidget {
  const _MiniaturesFilterBody({
    required this.draft,
    required this.ecoController,
    required this.openingController,
    required this.variationController,
    required this.dateFromController,
    required this.dateToController,
    required this.playerController,
    required this.onChanged,
  });

  final MiniatureGamesFilter draft;
  final TextEditingController ecoController;
  final TextEditingController openingController;
  final TextEditingController variationController;
  final FDateFieldController dateFromController;
  final FDateFieldController dateToController;
  final TextEditingController playerController;
  final ValueChanged<MiniatureGamesFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FilterSection(
            title: 'Window',
            child: _OptionGrid(
              children: [
                for (final window in MiniatureGamesWindow.values)
                  _FilterChipButton(
                    label: window.label,
                    selected: draft.window == window,
                    onPress: () => onChanged(draft.copyWith(window: window)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Result',
            child: _OptionGrid(
              children: [
                _FilterChipButton(
                  label: 'Any',
                  selected: draft.results.isEmpty,
                  onPress:
                      () => onChanged(
                        draft.copyWith(results: const <MiniatureGameResult>{}),
                      ),
                ),
                for (final result in MiniatureGameResult.values)
                  _FilterChipButton(
                    label: result.label,
                    selected: draft.results.contains(result),
                    onPress:
                        () => onChanged(
                          draft.copyWith(
                            results: <MiniatureGameResult>{result},
                          ),
                        ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Finish',
            subtitle: _finishSubtitle(draft.maxMoves),
            child: _OptionGrid(
              children: [
                _FilterChipButton(
                  label: 'By move 25',
                  selected: draft.maxMoves == null || draft.maxMoves == 25,
                  onPress: () => onChanged(draft.copyWith(clearMoves: true)),
                ),
                for (final move in const [20, 15])
                  _FilterChipButton(
                    label: 'By move $move',
                    selected: draft.maxMoves == move,
                    onPress:
                        () => onChanged(
                          draft.copyWith(minMoves: null, maxMoves: move),
                        ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Time control',
            child: _OptionGrid(
              children: [
                _FilterChipButton(
                  label: 'Any',
                  selected: draft.timeControls.isEmpty,
                  onPress:
                      () => onChanged(
                        draft.copyWith(
                          timeControls: const <MiniatureGameTimeControl>{},
                        ),
                      ),
                ),
                for (final control in MiniatureGameTimeControl.values)
                  _FilterChipButton(
                    label: control.label,
                    selected: draft.timeControls.contains(control),
                    onPress:
                        () => onChanged(
                          draft.copyWith(
                            timeControls: <MiniatureGameTimeControl>{control},
                          ),
                        ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Source',
            child: _OptionGrid(
              children: [
                _FilterChipButton(
                  label: 'Any',
                  selected: draft.isOnline == null,
                  onPress: () => onChanged(draft.copyWith(clearOnline: true)),
                ),
                _FilterChipButton(
                  label: 'OTB',
                  selected: draft.isOnline == false,
                  onPress: () => onChanged(draft.copyWith(isOnline: false)),
                ),
                _FilterChipButton(
                  label: 'Online',
                  selected: draft.isOnline == true,
                  onPress: () => onChanged(draft.copyWith(isOnline: true)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Rating',
            subtitle: _ratingSubtitle(draft.minRating, draft.maxRating),
            child: DesktopRangeSlider(
              min: _kMinRating,
              max: _kMaxRating,
              step: _kRatingStep,
              start: draft.minRating ?? _kMinRating,
              end: draft.maxRating ?? _kMaxRating,
              onChanged: (start, end) {
                final nextMin = start <= _kMinRating ? null : start;
                final nextMax = end >= _kMaxRating ? null : end;
                onChanged(
                  draft
                      .copyWith(clearRating: true)
                      .copyWith(minRating: nextMin, maxRating: nextMax),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Opening',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _OptionGrid(
                  children: [
                    _FilterChipButton(
                      label: 'All',
                      selected:
                          draft.ecoCategories.isEmpty &&
                          ecoController.text.trim().isEmpty &&
                          openingController.text.trim().isEmpty &&
                          variationController.text.trim().isEmpty,
                      onPress: () {
                        ecoController.clear();
                        openingController.clear();
                        variationController.clear();
                        onChanged(
                          draft.copyWith(
                            clearEco: true,
                            clearOpening: true,
                            clearVariation: true,
                            ecoCategories: const <String>{},
                          ),
                        );
                      },
                    ),
                    for (final category in const ['A', 'B', 'C', 'D', 'E'])
                      _FilterChipButton(
                        label: category,
                        selected: draft.ecoCategories.contains(category),
                        onPress: () {
                          ecoController.clear();
                          onChanged(
                            draft.copyWith(
                              clearEco: true,
                              ecoCategories: <String>{category},
                            ),
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                FTextField(
                  controller: ecoController,
                  hint: 'ECO code, e.g. B03 or C50',
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: const [EcoCodeInputFormatter()],
                  onChange: (value) {
                    final eco = sanitizeEcoCode(value);
                    onChanged(
                      draft.copyWith(
                        eco: eco,
                        clearEco: eco.isEmpty,
                        ecoCategories: const <String>{},
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                FTextField(
                  controller: openingController,
                  hint: 'Opening name, e.g. Sicilian Defense',
                  onChange: (value) {
                    final opening = _normalizedText(value);
                    onChanged(
                      draft.copyWith(
                        opening: opening,
                        clearOpening: opening == null,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                FTextField(
                  controller: variationController,
                  hint: 'Variation, e.g. Najdorf',
                  onChange: (value) {
                    final variation = _normalizedText(value);
                    onChanged(
                      draft.copyWith(
                        variation: variation,
                        clearVariation: variation == null,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Date',
            subtitle: _dateSubtitle(draft.dateFrom, draft.dateTo),
            child: Row(
              children: [
                Expanded(
                  child: FDateField.calendar(
                    controller: dateFromController,
                    hint: 'From',
                    clearable: true,
                    start: _minFilterDate,
                    end: _maxFilterDate(),
                    onChange:
                        (date) => onChanged(
                          draft
                              .copyWith(clearDates: true)
                              .copyWith(
                                dateFrom: _formatIsoDate(date),
                                dateTo: draft.dateTo,
                              ),
                        ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FDateField.calendar(
                    controller: dateToController,
                    hint: 'To',
                    clearable: true,
                    start: _minFilterDate,
                    end: _maxFilterDate(),
                    onChange:
                        (date) => onChanged(
                          draft
                              .copyWith(clearDates: true)
                              .copyWith(
                                dateFrom: draft.dateFrom,
                                dateTo: _formatIsoDate(date),
                              ),
                        ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'Player',
            child: FTextField(
              controller: playerController,
              hint: 'Name or surname',
              onChange: (_) => onChanged(draft),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterHeader extends StatelessWidget {
  const _FilterHeader({required this.activeCount, required this.onClose});

  final int activeCount;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final hasActive = activeCount > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            color: kPrimaryColor,
            size: 17,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Miniature filters',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasActive
                      ? '$activeCount active filter${activeCount == 1 ? '' : 's'}'
                      : 'No filters applied',
                  style: TextStyle(
                    color:
                        hasActive
                            ? kPrimaryColor
                            : kWhiteColor.withValues(alpha: 0.5),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          DesktopDialogIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onPress: onClose,
          ),
        ],
      ),
    );
  }
}

class _FilterSection extends StatelessWidget {
  const _FilterSection({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style: TextStyle(
                  color: kWhiteColor.withValues(alpha: 0.56),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _OptionGrid extends StatelessWidget {
  const _OptionGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    required this.label,
    required this.selected,
    required this.onPress,
  });

  final String label;
  final bool selected;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: _chipButtonStyle(selected),
      onPress: onPress,
      child: Text(label),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _filterTriggerStyle(bool active) {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: active ? kPrimaryColor.withValues(alpha: 0.18) : kBlack3Color,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color:
                active
                    ? kPrimaryColor.withValues(alpha: 0.55)
                    : kWhiteColor.withValues(alpha: 0.16),
          ),
        ),
        WidgetState.any: BoxDecoration(
          color:
              active
                  ? kPrimaryColor.withValues(alpha: 0.12)
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: active ? kPrimaryColor : kDividerColor),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _chipButtonStyle(bool selected) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.22) : kBlack3Color,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.56)
                    : kWhiteColor.withValues(alpha: 0.14),
          ),
        ),
        WidgetState.any: BoxDecoration(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.15)
                  : kBlack3Color.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.44)
                    : kDividerColor,
          ),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            textStyle: FWidgetStateMap({
              WidgetState.any: TextStyle(
                color: selected ? kWhiteColor : kWhiteColor70,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            }),
          ),
    ),
  );
}

const int _kMinRating = 0;
const int _kMaxRating = 4000;
const int _kRatingStep = 50;

String _finishSubtitle(int? maxMoves) {
  return maxMoves == null || maxMoves == 25
      ? 'by move 25'
      : 'by move $maxMoves';
}

String _ratingSubtitle(int? min, int? max) {
  if (min == null && max == null) return 'any rating';
  return '${min ?? _kMinRating} – ${max ?? _kMaxRating}';
}

String _dateSubtitle(String? from, String? to) {
  if (from == null && to == null) return 'any date';
  return '${from ?? 'start'} – ${to ?? 'today'}';
}

DateTime? _parseIsoDate(String? value) {
  final text = value?.trim();
  if (text == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    return null;
  }
  final parts = text.split('-');
  return DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

String? _formatIsoDate(DateTime? value) {
  if (value == null) return null;
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

final DateTime _minFilterDate = DateTime.utc(1900);

DateTime _maxFilterDate() {
  final now = DateTime.now().toUtc();
  return DateTime.utc(now.year, now.month, now.day);
}

String? _normalizedText(String value) {
  final text = value.trim();
  return text.isEmpty ? null : text;
}
