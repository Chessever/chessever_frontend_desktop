import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/utils/eco_input_formatter.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:chessever/widgets/game_filter/wheel_range_filter.dart';

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
        child: _FilterTriggerButton(
          activeCount: activeCount,
          onTap: () async {
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
        child: _FilterTriggerButton(
          activeCount: activeCount,
          onTap: () async {
            final next = await showDesktopPremiumGamesFilterDialog(
              context: context,
              currentFilter: filter,
            );
            if (next == null) return;
            ref.read(premiumGamesProvider(type).notifier).applyFilter(next);
          },
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
  late PremiumGamesResult _result;
  late GameTimeControlFilter _timeControl;
  late GameFinishFilter _finish;
  late int? _selectedMinRating;
  late int? _yearFrom;
  late int? _yearTo;
  late final TextEditingController _ecoController;

  @override
  void initState() {
    super.initState();
    _result = widget.initialFilter.result;
    _timeControl = widget.initialFilter.timeControl;
    _finish = widget.initialFilter.finish;
    _yearFrom = widget.initialFilter.yearFrom;
    _yearTo = widget.initialFilter.yearTo;
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
                                  icon: _timeControlIcon(control),
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
                                  icon: _finishIcon(finish),
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
                                  label:
                                      result == PremiumGamesResult.all
                                          ? 'Any'
                                          : result.displayText,
                                  icon: _premiumResultIcon(result),
                                  selected: _result == result,
                                  onPress:
                                      () => setState(() => _result = result),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Year range',
                          subtitle: _yearRangeSubtitle(_yearFrom, _yearTo),
                          child: _YearRange(
                            yearFrom: _yearFrom,
                            yearTo: _yearTo,
                            onChanged:
                                (from, to) => setState(() {
                                  _yearFrom = from;
                                  _yearTo = to;
                                }),
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
                label: code ?? 'Any',
                icon: code == null ? Icons.apps_rounded : Icons.tag_rounded,
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
      _result = PremiumGamesResult.all;
      _timeControl = GameTimeControlFilter.all;
      _finish = GameFinishFilter.all;
      _selectedMinRating = null;
      _yearFrom = null;
      _yearTo = null;
      _ecoController.clear();
    });
  }

  PremiumGamesFilter _buildFilter() {
    final eco = _ecoController.text.trim().toUpperCase();
    return PremiumGamesFilter(
      result: _result,
      timeControl: _timeControl,
      eco: eco.isEmpty ? GameEcoFilter.all : GameEcoFilter.forCode(eco),
      finish: _finish,
      minElo: _selectedMinRating,
      maxElo: null,
      yearFrom: _yearFrom,
      yearTo: _yearTo,
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

class _MiniaturesFilterDialogState extends State<_MiniaturesFilterDialog> {
  late MiniatureGamesFilter _draft;
  late final TextEditingController _ecoController;
  late final TextEditingController _openingController;
  late final TextEditingController _variationController;
  late final TextEditingController _playerController;

  @override
  void initState() {
    super.initState();
    _draft = widget.initialFilter;
    _ecoController = TextEditingController(text: _draft.eco ?? '');
    _openingController = TextEditingController(text: _draft.opening ?? '');
    _variationController = TextEditingController(text: _draft.variation ?? '');
    _playerController = TextEditingController(text: _draft.player ?? '');
  }

  @override
  void dispose() {
    _ecoController.dispose();
    _openingController.dispose();
    _variationController.dispose();
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
    required this.onChanged,
  });

  final MiniatureGamesFilter draft;
  final TextEditingController ecoController;
  final TextEditingController openingController;
  final TextEditingController variationController;
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
                  icon: Icons.apps_rounded,
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
                    icon: _miniatureTimeControlIcon(control),
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
                      label: 'Any',
                      icon: Icons.apps_rounded,
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
                        icon: Icons.tag_rounded,
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
                  icon: Icons.flag_outlined,
                  selected: draft.maxMoves == null || draft.maxMoves == 25,
                  onPress: () => onChanged(draft.copyWith(clearMoves: true)),
                ),
                for (final move in const [20, 15])
                  _FilterChipButton(
                    label: 'By move $move',
                    icon:
                        move == 20
                            ? Icons.sports_score_outlined
                            : Icons.bolt_rounded,
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
                  icon: Icons.apps_rounded,
                  selected: draft.results.isEmpty,
                  onPress:
                      () => onChanged(
                        draft.copyWith(results: const <MiniatureGameResult>{}),
                      ),
                ),
                for (final result in MiniatureGameResult.values)
                  _FilterChipButton(
                    label: result.label,
                    icon: _miniatureResultIcon(result),
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
            title: 'Year range',
            subtitle: _yearRangeSubtitle(
              _yearFromDate(draft.dateFrom),
              _yearFromDate(draft.dateTo),
            ),
            child: _YearRange(
              yearFrom: _yearFromDate(draft.dateFrom),
              yearTo: _yearFromDate(draft.dateTo),
              onChanged:
                  (from, to) => onChanged(
                    draft
                        .copyWith(clearDates: true)
                        .copyWith(
                          dateFrom: from == null ? null : '$from-01-01',
                          dateTo: to == null ? null : '$to-12-31',
                        ),
                  ),
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
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
            const Spacer(),
            if (subtitle != null)
              Text(
                subtitle!,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
        const SizedBox(height: 9),
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
    return Wrap(spacing: 6, runSpacing: 6, children: children);
  }
}

class _FilterChipButton extends StatefulWidget {
  const _FilterChipButton({
    required this.label,
    required this.selected,
    required this.onPress,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onPress;
  final IconData? icon;

  @override
  State<_FilterChipButton> createState() => _FilterChipButtonState();
}

class _FilterChipButtonState extends State<_FilterChipButton> {
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
          onTap: widget.onPress,
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
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 12, color: accent),
                  const SizedBox(width: 6),
                ],
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
        _FilterChipButton(
          label: 'Any',
          icon: Icons.apps_rounded,
          selected: selectedMinRating == null,
          onPress: () => onChanged(null),
        ),
        for (final tier in _ratingTiers)
          _FilterChipButton(
            label: '${tier.label} ${tier.subtitle}',
            icon: tier.icon,
            selected: selectedMinRating == tier.minRating,
            onPress: () => onChanged(tier.minRating),
          ),
      ],
    );
  }
}

class _FilterTriggerButton extends StatefulWidget {
  const _FilterTriggerButton({required this.activeCount, required this.onTap});

  final int activeCount;
  final VoidCallback onTap;

  @override
  State<_FilterTriggerButton> createState() => _FilterTriggerButtonState();
}

class _FilterTriggerButtonState extends State<_FilterTriggerButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.activeCount > 0;
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
              color:
                  active
                      ? kPrimaryColor.withValues(alpha: 0.12)
                      : (_hovered ? kBlack3Color : Colors.transparent),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color:
                    active
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
                  color: active ? kPrimaryColor : kWhiteColor70,
                ),
                const SizedBox(width: 6),
                Text(
                  'Filters',
                  style: TextStyle(
                    color: active ? kWhiteColor : kWhiteColor70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                if (active) ...[
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
                      '${widget.activeCount}',
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
    );
  }
}

class _YearRange extends StatefulWidget {
  const _YearRange({
    required this.yearFrom,
    required this.yearTo,
    required this.onChanged,
  });

  final int? yearFrom;
  final int? yearTo;
  final void Function(int? yearFrom, int? yearTo) onChanged;

  @override
  State<_YearRange> createState() => _YearRangeState();
}

class _YearRangeState extends State<_YearRange> {
  static const double _absMin = 1800;

  late RangeValues _range;

  double get _absMax => DateTime.now().year.toDouble();

  @override
  void initState() {
    super.initState();
    _range = _valuesFromWidget();
  }

  @override
  void didUpdateWidget(covariant _YearRange oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _valuesFromWidget();
    if (_range.start != next.start || _range.end != next.end) {
      _range = next;
    }
  }

  @override
  Widget build(BuildContext context) {
    ResponsiveHelper.init(context);
    final isDefault = _range.start == _absMin && _range.end == _absMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!isDefault)
          DesktopTooltip(
            message: 'Reset year range',
            child: ClickCursor(
              child: GestureDetector(
                onTap: () {
                  final reset = RangeValues(_absMin, _absMax);
                  setState(() => _range = reset);
                  widget.onChanged(null, null);
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
          currentStart: _range.start,
          currentEnd: _range.end,
          divisions: (_absMax - _absMin).round(),
          onChanged: (value) {
            setState(() => _range = value);
            final from = value.start == _absMin ? null : value.start.round();
            final to = value.end == _absMax ? null : value.end.round();
            widget.onChanged(from, to);
          },
        ),
      ],
    );
  }

  RangeValues _valuesFromWidget() {
    return RangeValues(
      (widget.yearFrom?.toDouble() ?? _absMin).clamp(_absMin, _absMax),
      (widget.yearTo?.toDouble() ?? _absMax).clamp(_absMin, _absMax),
    );
  }
}

const _miniatureRatingPresets = <int>[2200, 2300, 2400, 2500];

const _ratingTiers = <_RatingTier>[
  _RatingTier('CM', '+2200', 2200, Icons.school_outlined),
  _RatingTier('FM', '+2300', 2300, Icons.shield_outlined),
  _RatingTier('IM', '+2400', 2400, Icons.military_tech_rounded),
  _RatingTier('GM', '+2500', 2500, Icons.workspace_premium_rounded),
];

class _RatingTier {
  const _RatingTier(this.label, this.subtitle, this.minRating, this.icon);

  final String label;
  final String subtitle;
  final int minRating;
  final IconData icon;
}

int _premiumFilterActiveCount(PremiumGamesFilter filter) {
  var count = 0;
  if (filter.timeControl != GameTimeControlFilter.all) count += 1;
  if (filter.minElo != null || filter.maxElo != null) count += 1;
  if (!filter.eco.isAll) count += 1;
  if (filter.finish != GameFinishFilter.all) count += 1;
  if (filter.result != PremiumGamesResult.all) count += 1;
  if (filter.dateRange != PremiumGamesDateRange.allTime) count += 1;
  if (filter.yearFrom != null || filter.yearTo != null) count += 1;
  return count;
}

int? _normalizeMiniatureRatingPreset(int? minRating) {
  if (minRating == null) return null;
  for (final preset in _miniatureRatingPresets.reversed) {
    if (minRating >= preset) return preset;
  }
  return null;
}

IconData _timeControlIcon(GameTimeControlFilter value) {
  switch (value) {
    case GameTimeControlFilter.all:
      return Icons.apps_rounded;
    case GameTimeControlFilter.classical:
      return Icons.hourglass_top_rounded;
    case GameTimeControlFilter.rapid:
      return Icons.timer_outlined;
    case GameTimeControlFilter.blitz:
      return Icons.bolt_rounded;
  }
}

IconData _miniatureTimeControlIcon(MiniatureGameTimeControl value) {
  switch (value) {
    case MiniatureGameTimeControl.classical:
      return Icons.hourglass_top_rounded;
    case MiniatureGameTimeControl.rapid:
      return Icons.timer_outlined;
    case MiniatureGameTimeControl.blitz:
      return Icons.bolt_rounded;
  }
}

IconData _finishIcon(GameFinishFilter value) {
  switch (value) {
    case GameFinishFilter.all:
      return Icons.apps_rounded;
    case GameFinishFilter.byMove25:
      return Icons.flag_outlined;
    case GameFinishFilter.byMove20:
      return Icons.sports_score_outlined;
    case GameFinishFilter.byMove15:
      return Icons.bolt_rounded;
  }
}

IconData _premiumResultIcon(PremiumGamesResult value) {
  switch (value) {
    case PremiumGamesResult.all:
      return Icons.apps_rounded;
    case PremiumGamesResult.whiteWins:
      return Icons.flag_outlined;
    case PremiumGamesResult.blackWins:
      return Icons.flag_rounded;
    case PremiumGamesResult.draw:
      return Icons.handshake_outlined;
  }
}

IconData _miniatureResultIcon(MiniatureGameResult value) {
  switch (value) {
    case MiniatureGameResult.whiteWins:
      return Icons.flag_outlined;
    case MiniatureGameResult.blackWins:
      return Icons.flag_rounded;
  }
}

String _finishSubtitle(int? maxMoves) {
  return maxMoves == null || maxMoves == 25
      ? 'by move 25'
      : 'by move $maxMoves';
}

String _yearRangeSubtitle(int? from, int? to) {
  if (from == null && to == null) return 'any year';
  return '${from ?? 'start'} - ${to ?? DateTime.now().year}';
}

int? _yearFromDate(String? value) {
  final text = value?.trim();
  if (text == null || text.length < 4) return null;
  return int.tryParse(text.substring(0, 4));
}

String? _normalizedText(String value) {
  final text = value.trim();
  return text.isEmpty ? null : text;
}
