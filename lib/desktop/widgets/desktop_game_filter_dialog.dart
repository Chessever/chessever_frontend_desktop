import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/utils/eco_input_formatter.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:chessever/widgets/game_filter/wheel_range_filter.dart';

Future<GameFilter?> showDesktopGameFilterDialog({
  required BuildContext context,
  required GameFilter currentFilter,
  bool showFormatFilter = false,
}) {
  return showGeneralDialog<GameFilter>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Game filters',
    barrierColor: Colors.black.withValues(alpha: 0.56),
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder:
        (ctx, _, _) => FTheme(
          data: FThemes.zinc.dark,
          child: _DesktopGameFilterDialog(
            initialFilter: currentFilter,
            showFormatFilter: showFormatFilter,
          ),
        ),
    transitionBuilder: (ctx, anim, _, child) {
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.018),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

class DesktopGameFilterButton extends StatefulWidget {
  const DesktopGameFilterButton({
    super.key,
    required this.filter,
    required this.onPress,
  });

  final GameFilter filter;
  final VoidCallback onPress;

  @override
  State<DesktopGameFilterButton> createState() =>
      _DesktopGameFilterButtonState();
}

class _DesktopGameFilterButtonState extends State<DesktopGameFilterButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.filter.hasActiveFilters;
    final activeCount = widget.filter.activeFilterCount;
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: active ? '$activeCount active game filters' : 'Filter games',
        child: ClickCursor(
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPress,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
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
    );
  }
}

class ClearDesktopGameFiltersButton extends StatelessWidget {
  const ClearDesktopGameFiltersButton({super.key, required this.onPress});

  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton(
        style: FButtonStyle.outline(),
        onPress: onPress,
        prefix: const Icon(Icons.filter_alt_off_rounded),
        child: const Text('Clear filters'),
      ),
    );
  }
}

class _DesktopGameFilterDialog extends StatefulWidget {
  const _DesktopGameFilterDialog({
    required this.initialFilter,
    required this.showFormatFilter,
  });

  final GameFilter initialFilter;
  final bool showFormatFilter;

  @override
  State<_DesktopGameFilterDialog> createState() =>
      _DesktopGameFilterDialogState();
}

class _DesktopGameFilterDialogState extends State<_DesktopGameFilterDialog> {
  late GameResultFilter _result;
  late GameColorFilter _color;
  late GameTimeControlFilter _timeControl;
  late GameOnlineFilter _online;
  late GameFinishFilter _finish;
  late int _minYear;
  late int _maxYear;
  late int? _selectedMinRating;
  late final TextEditingController _ecoController;

  @override
  void initState() {
    super.initState();
    final filter = widget.initialFilter;
    _result = filter.result;
    _color = filter.color;
    _timeControl = filter.timeControl;
    _online = filter.online;
    _finish = filter.finish;
    _minYear = filter.minYear;
    _maxYear = filter.maxYear;
    _selectedMinRating = _normalizeRatingPreset(filter.minRating);
    _ecoController = TextEditingController(text: filter.eco.code ?? '');
  }

  @override
  void dispose() {
    _ecoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380, maxHeight: 600),
          child: Material(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _titleBar(context),
                const FDivider(),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _FilterSection(
                          title: 'Time control',
                          child: _OptionGrid<GameTimeControlFilter>(
                            value: _timeControl,
                            values: GameTimeControlFilter.values,
                            label:
                                (v) =>
                                    v == GameTimeControlFilter.all
                                        ? 'Any'
                                        : v.displayText,
                            icon: _timeControlIcon,
                            onChanged: (v) => setState(() => _timeControl = v),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Avg. Rating',
                          child: _RatingPresetGrid(
                            selectedMinRating: _selectedMinRating,
                            onChanged:
                                (value) =>
                                    setState(() => _selectedMinRating = value),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'ECO / Opening',
                          child: _ecoEditor(),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Finish',
                          child: _OptionGrid<GameFinishFilter>(
                            value: _finish,
                            values: GameFinishFilter.values,
                            label:
                                (v) =>
                                    v == GameFinishFilter.all
                                        ? 'Any'
                                        : v.displayText,
                            icon: _finishIcon,
                            onChanged: (v) => setState(() => _finish = v),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Result',
                          child: _OptionGrid<GameResultFilter>(
                            value: _result,
                            values: GameResultFilter.values,
                            label:
                                (v) =>
                                    v == GameResultFilter.all
                                        ? 'Any'
                                        : v.displayText,
                            icon: _resultIcon,
                            onChanged: (v) => setState(() => _result = v),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _FilterSection(
                          title: 'Year range',
                          subtitle: _yearRangeSubtitle(_minYear, _maxYear),
                          child: _YearRange(
                            yearFrom: _minYear,
                            yearTo: _maxYear,
                            onChanged:
                                (from, to) => setState(() {
                                  _minYear = from;
                                  _maxYear = to;
                                }),
                          ),
                        ),
                        if (widget.showFormatFilter) ...[
                          const SizedBox(height: 16),
                          _FilterSection(
                            title: 'Color',
                            child: _OptionGrid<GameColorFilter>(
                              value: _color,
                              values: GameColorFilter.values,
                              label:
                                  (v) =>
                                      v == GameColorFilter.all
                                          ? 'Any'
                                          : v.displayText,
                              icon: _colorIcon,
                              iconColor:
                                  (v) =>
                                      v == GameColorFilter.white
                                          ? kWhiteColor
                                          : null,
                              onChanged: (v) => setState(() => _color = v),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _FilterSection(
                            title: 'Format',
                            child: _OptionGrid<GameOnlineFilter>(
                              value: _online,
                              values: GameOnlineFilter.values,
                              label:
                                  (v) =>
                                      v == GameOnlineFilter.all
                                          ? 'Any'
                                          : v.displayText,
                              icon: _onlineIcon,
                              onChanged: (v) => setState(() => _online = v),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                _actions(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(BuildContext context) {
    final hasActive = _buildFilter().hasActiveFilters;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
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
          if (hasActive) ...[
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
          if (hasActive)
            FButton(
              style: FButtonStyle.ghost(),
              onPress:
                  () => setState(() {
                    _syncFromFilter(GameFilter.defaultFilter());
                  }),
              child: const Text(
                'Clear all',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          DesktopDialogIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onPress: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _ecoEditor() {
    final quickCodes = const <String?>[null, 'A', 'B', 'C', 'D', 'E'];
    final current = _ecoController.text.trim().toUpperCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final code in quickCodes)
              _FilterChipButton(
                label: code ?? 'Any',
                icon: code == null ? Icons.apps_rounded : Icons.tag_rounded,
                selected: code == null ? current.isEmpty : current == code,
                onTap:
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
          hint: 'ECO code, e.g. B90 or C',
          textCapitalization: TextCapitalization.characters,
          inputFormatters: const [EcoCodeInputFormatter()],
          onChange: (_) => setState(() {}),
        ),
      ],
    );
  }

  void _syncFromFilter(GameFilter filter) {
    _result = filter.result;
    _color = filter.color;
    _timeControl = filter.timeControl;
    _online = filter.online;
    _finish = filter.finish;
    _minYear = filter.minYear;
    _maxYear = filter.maxYear;
    _selectedMinRating = _normalizeRatingPreset(filter.minRating);
    _ecoController.text = filter.eco.code ?? '';
    _ecoController.selection = TextSelection.collapsed(
      offset: _ecoController.text.length,
    );
  }

  Widget _actions(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          const Spacer(),
          DesktopDialogButton(
            label: 'Cancel',
            onPress: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 10),
          DesktopDialogButton(
            label: 'Apply',
            tone: DesktopDialogButtonTone.primary,
            icon: Icons.check_rounded,
            onPress: () => Navigator.of(context).pop(_buildFilter()),
          ),
        ],
      ),
    );
  }

  GameFilter _buildFilter() {
    final ecoText = _ecoController.text.trim().toUpperCase();
    return GameFilter(
      result: _result,
      color: _color,
      finish: _finish,
      timeControl: _timeControl,
      online: _online,
      eco: ecoText.isEmpty ? GameEcoFilter.all : GameEcoFilter.forCode(ecoText),
      minYear: _minYear,
      maxYear: _maxYear,
      minRating: _selectedMinRating ?? GameFilter.defaultMinRating,
      maxRating: GameFilter.absoluteMaxRating,
    );
  }
}

int? _normalizeRatingPreset(int minRating) {
  if (minRating <= GameFilter.defaultMinRating) return null;
  for (final preset in _ratingPresets.reversed) {
    if (minRating >= preset) return preset;
  }
  return null;
}

const _ratingPresets = <int>[2200, 2300, 2400, 2500];

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

class _RatingPresetGrid extends StatelessWidget {
  const _RatingPresetGrid({
    required this.selectedMinRating,
    required this.onChanged,
  });

  final int? selectedMinRating;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _FilterChipButton(
          label: 'Any',
          icon: Icons.apps_rounded,
          selected: selectedMinRating == null,
          onTap: () => onChanged(null),
        ),
        for (final tier in _ratingTiers)
          _FilterChipButton(
            label: '${tier.label} ${tier.subtitle}',
            icon: tier.icon,
            selected: selectedMinRating == tier.minRating,
            onTap: () => onChanged(tier.minRating),
          ),
      ],
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

class _OptionGrid<T> extends StatelessWidget {
  const _OptionGrid({
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
    this.icon,
    this.iconColor,
  });

  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  final IconData Function(T)? icon;
  final Color? Function(T)? iconColor;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final option in values)
          _FilterChipButton(
            label: label(option),
            icon: icon?.call(option),
            iconColor: iconColor?.call(option),
            selected: option == value,
            onTap: () => onChanged(option),
          ),
      ],
    );
  }
}

class _FilterChipButton extends StatefulWidget {
  const _FilterChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.iconColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? iconColor;

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
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: 12,
                    color: widget.iconColor ?? accent,
                  ),
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

class _YearRange extends StatefulWidget {
  const _YearRange({
    required this.yearFrom,
    required this.yearTo,
    required this.onChanged,
  });

  final int yearFrom;
  final int yearTo;
  final void Function(int yearFrom, int yearTo) onChanged;

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
                  widget.onChanged(reset.start.round(), reset.end.round());
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
            widget.onChanged(value.start.round(), value.end.round());
          },
        ),
      ],
    );
  }

  RangeValues _valuesFromWidget() {
    return RangeValues(
      widget.yearFrom.toDouble().clamp(_absMin, _absMax),
      widget.yearTo.toDouble().clamp(_absMin, _absMax),
    );
  }
}

String _yearRangeSubtitle(int yearFrom, int yearTo) {
  final absMax = DateTime.now().year;
  if (yearFrom == GameFilter.defaultMinYear && yearTo == absMax) {
    return 'any year';
  }
  return '$yearFrom - $yearTo';
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

IconData _resultIcon(GameResultFilter value) {
  switch (value) {
    case GameResultFilter.all:
      return Icons.apps_rounded;
    case GameResultFilter.whiteWins:
      return Icons.flag_outlined;
    case GameResultFilter.blackWins:
      return Icons.flag_rounded;
    case GameResultFilter.draw:
      return Icons.handshake_outlined;
  }
}

IconData _colorIcon(GameColorFilter value) {
  switch (value) {
    case GameColorFilter.all:
      return Icons.apps_rounded;
    case GameColorFilter.white:
      return Icons.circle;
    case GameColorFilter.black:
      return Icons.circle_outlined;
  }
}

IconData _onlineIcon(GameOnlineFilter value) {
  switch (value) {
    case GameOnlineFilter.all:
      return Icons.apps_rounded;
    case GameOnlineFilter.online:
      return Icons.public_rounded;
    case GameOnlineFilter.otb:
      return Icons.public_off_rounded;
  }
}
