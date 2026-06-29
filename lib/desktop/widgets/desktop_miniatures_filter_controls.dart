import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/utils/eco_input_formatter.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

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

class DesktopPremiumGamesFilterButton extends ConsumerWidget {
  const DesktopPremiumGamesFilterButton({super.key, required this.type});

  final PremiumGamesType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(premiumGamesFilterProvider(type));
    final activeCount = _premiumFilterActiveCount(filter);
    final hasActive = activeCount > 0;

    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: hasActive ? 'Filters · $activeCount active' : 'Filters',
        child: FButton.icon(
          style: _filterTriggerStyle(hasActive),
          onPress: () async {
            final next = await showDesktopPremiumGamesFilterDialog(
              context: context,
              currentFilter: filter,
            );
            if (next == null) return;
            ref.read(premiumGamesProvider(type).notifier).applyFilter(next);
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

Future<PremiumGamesFilter?> showDesktopPremiumGamesFilterDialog({
  required BuildContext context,
  required PremiumGamesFilter currentFilter,
}) {
  return showDesktopDialog<PremiumGamesFilter>(
    context,
    builder: (_) => _PremiumGamesFilterDialog(initialFilter: currentFilter),
  );
}

class _PremiumGamesFilterDialog extends StatefulWidget {
  const _PremiumGamesFilterDialog({required this.initialFilter});

  final PremiumGamesFilter initialFilter;

  @override
  State<_PremiumGamesFilterDialog> createState() =>
      _PremiumGamesFilterDialogState();
}

class _PremiumGamesFilterDialogState extends State<_PremiumGamesFilterDialog> {
  late PremiumGamesDateRange _dateRange;
  late PremiumGamesResult _result;
  late GameTimeControlFilter _timeControl;
  late GameFinishFilter _finish;
  late int? _selectedMinRating;
  late final TextEditingController _ecoController;

  @override
  void initState() {
    super.initState();
    _dateRange = widget.initialFilter.dateRange;
    _result = widget.initialFilter.result;
    _timeControl = widget.initialFilter.timeControl;
    _finish = widget.initialFilter.finish;
    _selectedMinRating = _normalizeMiniatureRatingPreset(
      widget.initialFilter.minElo,
    );
    _ecoController = TextEditingController(
      text: widget.initialFilter.eco.code ?? '',
    );
  }

  @override
  void dispose() {
    _ecoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeCount = _premiumFilterActiveCount(_buildFilter());
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
                  title: 'Game filters',
                  activeCount: activeCount,
                  onClose: () => Navigator.of(context).pop(),
                ),
                const FDivider(),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _FilterSection(
                          title: 'Time control',
                          child: _OptionGrid(
                            children: [
                              for (final control
                                  in GameTimeControlFilter.values)
                                _FilterChipButton(
                                  label:
                                      control == GameTimeControlFilter.all
                                          ? 'Any'
                                          : control.displayText,
                                  selected: _timeControl == control,
                                  onPress:
                                      () => setState(
                                        () => _timeControl = control,
                                      ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Avg. Rating',
                          child: _MiniatureRatingPresetGrid(
                            selectedMinRating: _selectedMinRating,
                            onChanged:
                                (value) =>
                                    setState(() => _selectedMinRating = value),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'ECO / Opening',
                          child: _premiumEcoEditor(),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Finish',
                          child: _OptionGrid(
                            children: [
                              for (final finish in GameFinishFilter.values)
                                _FilterChipButton(
                                  label:
                                      finish == GameFinishFilter.all
                                          ? 'Any'
                                          : finish.displayText,
                                  selected: _finish == finish,
                                  onPress:
                                      () => setState(() => _finish = finish),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Result',
                          child: _OptionGrid(
                            children: [
                              for (final result in PremiumGamesResult.values)
                                _FilterChipButton(
                                  label: result.displayText,
                                  selected: _result == result,
                                  onPress:
                                      () => setState(() => _result = result),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Date range',
                          child: _OptionGrid(
                            children: [
                              for (final range in PremiumGamesDateRange.values)
                                _FilterChipButton(
                                  label: range.displayText,
                                  selected: _dateRange == range,
                                  onPress:
                                      () => setState(() => _dateRange = range),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
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
                              () => Navigator.of(context).pop(_buildFilter()),
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

  Widget _premiumEcoEditor() {
    final current = _ecoController.text.trim().toUpperCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OptionGrid(
          children: [
            for (final code in const <String?>[null, 'A', 'B', 'C', 'D', 'E'])
              _FilterChipButton(
                label: code ?? 'All',
                selected: code == null ? current.isEmpty : current == code,
                onPress:
                    () => setState(() {
                      _ecoController.text = code ?? '';
                      _ecoController.selection = TextSelection.collapsed(
                        offset: _ecoController.text.length,
                      );
                    }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        FTextField(
          controller: _ecoController,
          hint: 'ECO code, e.g. B03 or C50',
          textCapitalization: TextCapitalization.characters,
          inputFormatters: const [EcoCodeInputFormatter()],
          onChange: (value) {
            final eco = sanitizeEcoCode(value);
            if (eco == value) {
              setState(() {});
              return;
            }
            _ecoController.value = TextEditingValue(
              text: eco,
              selection: TextSelection.collapsed(offset: eco.length),
            );
            setState(() {});
          },
        ),
      ],
    );
  }

  void _resetDraft() {
    setState(() {
      _dateRange = PremiumGamesDateRange.allTime;
      _result = PremiumGamesResult.all;
      _timeControl = GameTimeControlFilter.all;
      _finish = GameFinishFilter.all;
      _selectedMinRating = null;
      _ecoController.clear();
    });
  }

  PremiumGamesFilter _buildFilter() {
    final eco = _ecoController.text.trim().toUpperCase();
    return PremiumGamesFilter(
      dateRange: _dateRange,
      result: _result,
      timeControl: _timeControl,
      eco: eco.isEmpty ? GameEcoFilter.all : GameEcoFilter.forCode(eco),
      finish: _finish,
      minElo: _selectedMinRating,
      maxElo: null,
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
                  title: 'Miniature filters',
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
    required this.onChanged,
  });

  final MiniatureGamesFilter draft;
  final TextEditingController ecoController;
  final TextEditingController openingController;
  final TextEditingController variationController;
  final FDateFieldController dateFromController;
  final FDateFieldController dateToController;
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
            title: 'Avg. Rating',
            child: _MiniatureRatingPresetGrid(
              selectedMinRating: _normalizeMiniatureRatingPreset(
                draft.minRating,
              ),
              onChanged:
                  (value) => onChanged(
                    draft
                        .copyWith(clearRating: true)
                        .copyWith(minRating: value, maxRating: null),
                  ),
            ),
          ),
          const SizedBox(height: 16),
          _FilterSection(
            title: 'ECO / Opening',
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
            title: 'Date range',
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
        ],
      ),
    );
  }
}

class _FilterHeader extends StatelessWidget {
  const _FilterHeader({
    required this.title,
    required this.activeCount,
    required this.onClose,
  });

  final String title;
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
                Text(
                  title,
                  style: const TextStyle(
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

class _MiniatureRatingPresetGrid extends StatelessWidget {
  const _MiniatureRatingPresetGrid({
    required this.selectedMinRating,
    required this.onChanged,
  });

  final int? selectedMinRating;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return _OptionGrid(
      children: [
        for (final rating in const <int?>[null, ..._miniatureRatingPresets])
          _FilterChipButton(
            label: rating == null ? 'Any' : '$rating+',
            selected: selectedMinRating == rating,
            onPress: () => onChanged(rating),
          ),
      ],
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

const _miniatureRatingPresets = <int>[2200, 2300, 2400, 2500];

int _premiumFilterActiveCount(PremiumGamesFilter filter) {
  var count = 0;
  if (filter.timeControl != GameTimeControlFilter.all) count += 1;
  if (filter.minElo != null || filter.maxElo != null) count += 1;
  if (!filter.eco.isAll) count += 1;
  if (filter.finish != GameFinishFilter.all) count += 1;
  if (filter.result != PremiumGamesResult.all) count += 1;
  if (filter.dateRange != PremiumGamesDateRange.allTime) count += 1;
  return count;
}

int? _normalizeMiniatureRatingPreset(int? minRating) {
  if (minRating == null) return null;
  for (final preset in _miniatureRatingPresets.reversed) {
    if (minRating >= preset) return preset;
  }
  return null;
}

String _finishSubtitle(int? maxMoves) {
  return maxMoves == null || maxMoves == 25
      ? 'by move 25'
      : 'by move $maxMoves';
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
