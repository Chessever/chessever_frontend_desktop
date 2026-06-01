import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

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

class DesktopGameFilterButton extends StatelessWidget {
  const DesktopGameFilterButton({
    super.key,
    required this.filter,
    required this.onPress,
  });

  final GameFilter filter;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final active = filter.hasActiveFilters;
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message:
            active
                ? '${filter.activeFilterCount} active game filters'
                : 'Filter games',
        child: FButton.icon(
          style: _filterButtonStyle(active),
          onPress: onPress,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.tune_rounded),
              if (active)
                Positioned(
                  right: -7,
                  top: -7,
                  child: Container(
                    width: 15,
                    height: 15,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: kRedColor,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${filter.activeFilterCount}',
                      style: const TextStyle(
                        color: kWhiteColor,
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
  late int _minYear;
  late int _maxYear;
  late int _minRating;
  late int _maxRating;
  late final TextEditingController _ecoController;

  @override
  void initState() {
    super.initState();
    final filter = widget.initialFilter;
    _result = filter.result;
    _color = filter.color;
    _timeControl = filter.timeControl;
    _online = filter.online;
    _minYear = filter.minYear;
    _maxYear = filter.maxYear;
    _minRating = filter.minRating;
    _maxRating = filter.maxRating;
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
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: Material(
            color: kBlack2Color,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _titleBar(context),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _FilterSection(
                          title: 'Result',
                          child: _OptionGrid<GameResultFilter>(
                            value: _result,
                            values: GameResultFilter.values,
                            label: (v) => v.displayText,
                            onChanged: (v) => setState(() => _result = v),
                          ),
                        ),
                        const SizedBox(height: 18),
                        _FilterSection(
                          title: 'Color',
                          child: _OptionGrid<GameColorFilter>(
                            value: _color,
                            values: GameColorFilter.values,
                            label: (v) => v.displayText,
                            onChanged: (v) => setState(() => _color = v),
                          ),
                        ),
                        const SizedBox(height: 18),
                        _FilterSection(
                          title: 'Time control',
                          child: _OptionGrid<GameTimeControlFilter>(
                            value: _timeControl,
                            values: GameTimeControlFilter.values,
                            label: (v) => v.displayText,
                            onChanged: (v) => setState(() => _timeControl = v),
                          ),
                        ),
                        if (widget.showFormatFilter) ...[
                          const SizedBox(height: 18),
                          _FilterSection(
                            title: 'Format',
                            child: _OptionGrid<GameOnlineFilter>(
                              value: _online,
                              values: GameOnlineFilter.values,
                              label: (v) => v.displayText,
                              onChanged: (v) => setState(() => _online = v),
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        _FilterSection(title: 'Opening', child: _ecoEditor()),
                        const SizedBox(height: 18),
                        _FilterSection(
                          title: 'Year',
                          subtitle: '$_minYear - $_maxYear',
                          child: _DesktopRangeSlider(
                            min: GameFilter.absoluteMinYear,
                            max: DateTime.now().year,
                            step: 1,
                            start: _minYear,
                            end: _maxYear,
                            onChanged:
                                (start, end) => setState(() {
                                  _minYear = start;
                                  _maxYear = end;
                                }),
                          ),
                        ),
                        const SizedBox(height: 18),
                        _FilterSection(
                          title: 'Rating',
                          subtitle: '$_minRating - $_maxRating',
                          child: _DesktopRangeSlider(
                            min: GameFilter.absoluteMinRating,
                            max: GameFilter.absoluteMaxRating,
                            step: 50,
                            start: _minRating,
                            end: _maxRating,
                            onChanged:
                                (start, end) => setState(() {
                                  _minRating = start;
                                  _maxRating = end;
                                }),
                          ),
                        ),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Game Filters',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
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
                label: code ?? 'All',
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
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-eA-E0-9]')),
            LengthLimitingTextInputFormatter(3),
            TextInputFormatter.withFunction((oldValue, newValue) {
              return newValue.copyWith(text: newValue.text.toUpperCase());
            }),
          ],
          onChange: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          DesktopDialogButton(
            label: 'Reset',
            onPress:
                () => Navigator.of(context).pop(GameFilter.defaultFilter()),
          ),
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
      timeControl: _timeControl,
      online: _online,
      eco: ecoText.isEmpty ? GameEcoFilter.all : GameEcoFilter.forCode(ecoText),
      minYear: _minYear,
      maxYear: _maxYear,
      minRating: _minRating,
      maxRating: _maxRating,
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
              title,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.1,
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
  });

  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final option in values)
          _FilterChipButton(
            label: label(option),
            selected: option == value,
            onTap: () => onChanged(option),
          ),
      ],
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  const _FilterChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FButton(
      style: _chipButtonStyle(selected),
      onPress: onTap,
      child: Text(label),
    );
  }
}

class _DesktopRangeSlider extends StatefulWidget {
  const _DesktopRangeSlider({
    required this.min,
    required this.max,
    required this.step,
    required this.start,
    required this.end,
    required this.onChanged,
  });

  final int min;
  final int max;
  final int step;
  final int start;
  final int end;
  final void Function(int start, int end) onChanged;

  @override
  State<_DesktopRangeSlider> createState() => _DesktopRangeSliderState();
}

class _DesktopRangeSliderState extends State<_DesktopRangeSlider> {
  late FContinuousSliderController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
  }

  @override
  void didUpdateWidget(covariant _DesktopRangeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.start != widget.start ||
        oldWidget.end != widget.end ||
        oldWidget.min != widget.min ||
        oldWidget.max != widget.max) {
      _controller.selection = _selection();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FSlider(controller: _controller, onChange: _handleChange);
  }

  FContinuousSliderController _buildController() {
    final span = math.max(1, widget.max - widget.min);
    return FContinuousSliderController.range(
      selection: _selection(),
      stepPercentage: (widget.step / span).clamp(0.001, 1.0),
    );
  }

  FSliderSelection _selection() {
    final start = _norm(widget.start);
    final end = _norm(widget.end).clamp(start, 1.0);
    return FSliderSelection(min: start, max: end);
  }

  double _norm(int value) {
    final span = math.max(1, widget.max - widget.min);
    return ((value - widget.min) / span).clamp(0.0, 1.0);
  }

  int _denorm(double value) {
    final span = math.max(1, widget.max - widget.min);
    final raw = widget.min + (span * value);
    final snapped = (raw / widget.step).round() * widget.step;
    return snapped.clamp(widget.min, widget.max);
  }

  void _handleChange(FSliderSelection selection) {
    final start = _denorm(selection.offset.min);
    final end = _denorm(selection.offset.max);
    widget.onChanged(start <= end ? start : end, end >= start ? end : start);
  }
}

FBaseButtonStyle Function(FButtonStyle style) _filterButtonStyle(bool active) {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: active ? kRedColor.withValues(alpha: 0.18) : kBlack3Color,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active ? kRedColor.withValues(alpha: 0.55) : kPrimaryColor,
          ),
        ),
        WidgetState.any: BoxDecoration(
          color:
              active ? kRedColor.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: active ? kRedColor : kDividerColor),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.all(7),
            iconStyle: FWidgetStateMap({
              WidgetState.any: IconThemeData(
                color: active ? kRedColor : kWhiteColor70,
                size: 15,
              ),
            }),
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
