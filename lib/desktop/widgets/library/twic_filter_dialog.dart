import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/screens/library/widgets/library_gamebase_filter_dialog.dart'
    show GamebaseFilter;
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';

/// Forui-styled filter dialog for the desktop TWIC database.
///
/// Returns the modified [GamebaseFilter] when the user confirms, or `null`
/// when they cancel. Mirrors the inputs available on mobile but uses forui
/// chrome (FButton, FDivider, FTextField) and a desktop-sized layout.
Future<GamebaseFilter?> showTwicFilterDialog({
  required BuildContext context,
  required GamebaseFilter currentFilter,
}) {
  return showGeneralDialog<GamebaseFilter>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'TWIC filters',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, _, _) => _TwicFilterDialog(initial: currentFilter),
    transitionBuilder: (_, anim, _, child) {
      final eased = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(eased),
          child: child,
        ),
      );
    },
  );
}

class _TwicFilterDialog extends StatefulWidget {
  const _TwicFilterDialog({required this.initial});
  final GamebaseFilter initial;

  @override
  State<_TwicFilterDialog> createState() => _TwicFilterDialogState();
}

class _TwicFilterDialogState extends State<_TwicFilterDialog> {
  late GameResultFilter _result;
  late GameColorFilter _color;
  late GameTimeControlFilter _timeControl;
  late RangeValues _yearRange;
  late RangeValues _ratingRange;

  static final int _maxYear = DateTime.now().year;

  @override
  void initState() {
    super.initState();
    _result = widget.initial.result;
    _color = widget.initial.color;
    _timeControl = widget.initial.timeControl;
    _yearRange = RangeValues(
      widget.initial.minYear.toDouble(),
      widget.initial.maxYear.toDouble(),
    );
    _ratingRange = RangeValues(
      widget.initial.minRating.toDouble().clamp(
        GameFilter.defaultMinRating.toDouble(),
        GameFilter.absoluteMaxRating.toDouble(),
      ),
      widget.initial.maxRating.toDouble().clamp(
        GameFilter.defaultMinRating.toDouble(),
        GameFilter.absoluteMaxRating.toDouble(),
      ),
    );
  }

  bool get _isDirty {
    final next = _build();
    return next != widget.initial;
  }

  GamebaseFilter _build() {
    return widget.initial.copyWith(
      result: _result,
      color: _color,
      timeControl: _timeControl,
      minYear: _yearRange.start.round(),
      maxYear: _yearRange.end.round(),
      minRating: _ratingRange.start.round(),
      maxRating: _ratingRange.end.round(),
    );
  }

  void _reset() {
    setState(() {
      _result = GameResultFilter.all;
      _color = GameColorFilter.all;
      _timeControl = GameTimeControlFilter.all;
      _yearRange = RangeValues(
        GameFilter.defaultMinYear.toDouble(),
        _maxYear.toDouble(),
      );
      _ratingRange = RangeValues(
        GameFilter.defaultMinRating.toDouble(),
        GameFilter.absoluteMaxRating.toDouble(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape):
              () => Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.enter):
              () => Navigator.of(context).pop(_build()),
        },
        child: Focus(
          autofocus: true,
          child: Center(
            child: Container(
              width: 460,
              constraints: const BoxConstraints(maxHeight: 620),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 32,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  const FDivider(),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SegmentSection<GameResultFilter>(
                            label: 'Result',
                            options: GameResultFilter.values,
                            selected: _result,
                            labelOf: (v) => v.displayText,
                            onChanged: (v) => setState(() => _result = v),
                          ),
                          const SizedBox(height: 18),
                          _SegmentSection<GameColorFilter>(
                            label: 'Player color',
                            options: GameColorFilter.values,
                            selected: _color,
                            labelOf: (v) => v.displayText,
                            onChanged: (v) => setState(() => _color = v),
                          ),
                          const SizedBox(height: 18),
                          _SegmentSection<GameTimeControlFilter>(
                            label: 'Time control',
                            options: GameTimeControlFilter.values,
                            selected: _timeControl,
                            labelOf: (v) => v.displayText,
                            onChanged: (v) => setState(() => _timeControl = v),
                          ),
                          const SizedBox(height: 18),
                          _RangeSection(
                            label: 'Year',
                            min: GameFilter.absoluteMinYear.toDouble(),
                            max: _maxYear.toDouble(),
                            divisions: _maxYear - GameFilter.absoluteMinYear,
                            values: _yearRange,
                            formatter: (v) => v.round().toString(),
                            onChanged: (v) => setState(() => _yearRange = v),
                          ),
                          const SizedBox(height: 18),
                          _RangeSection(
                            label: 'Rating',
                            min: GameFilter.defaultMinRating.toDouble(),
                            max: GameFilter.absoluteMaxRating.toDouble(),
                            divisions:
                                (GameFilter.absoluteMaxRating -
                                    GameFilter.defaultMinRating) ~/
                                50,
                            values: _ratingRange,
                            formatter: (v) => v.round().toString(),
                            onChanged: (v) => setState(() => _ratingRange = v),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const FDivider(),
                  _footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
      child: Row(
        children: [
          const Icon(Icons.tune_rounded, size: 18, color: kPrimaryColor),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Filter TWIC games',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.1,
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

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Row(
        children: [
          DesktopDialogButton(
            label: 'Reset',
            tone: DesktopDialogButtonTone.ghost,
            onPress: _isDirty ? _reset : null,
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
            onPress: () => Navigator.of(context).pop(_build()),
          ),
        ],
      ),
    );
  }
}

class _SegmentSection<T> extends StatelessWidget {
  const _SegmentSection({
    required this.label,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final String label;
  final List<T> options;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in options)
              _SegmentChip(
                label: labelOf(option),
                selected: option == selected,
                onTap: () => onChanged(option),
              ),
          ],
        ),
      ],
    );
  }
}

class _SegmentChip extends StatefulWidget {
  const _SegmentChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SegmentChip> createState() => _SegmentChipState();
}

class _SegmentChipState extends State<_SegmentChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final fg =
        widget.selected
            ? kPrimaryColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.12)
            : (_hovered ? kBlack3Color : Colors.transparent);
    final border =
        widget.selected ? kPrimaryColor.withValues(alpha: 0.55) : kDividerColor;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ),
    );
  }
}

class _RangeSection extends StatelessWidget {
  const _RangeSection({
    required this.label,
    required this.min,
    required this.max,
    required this.divisions,
    required this.values,
    required this.formatter,
    required this.onChanged,
  });
  final String label;
  final double min;
  final double max;
  final int divisions;
  final RangeValues values;
  final String Function(double) formatter;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SectionLabel(label),
            const Spacer(),
            Text(
              '${formatter(values.start)} – ${formatter(values.end)}',
              style: const TextStyle(
                color: kPrimaryColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: kPrimaryColor,
            inactiveTrackColor: kBlack3Color,
            thumbColor: kPrimaryColor,
            overlayColor: kPrimaryColor.withValues(alpha: 0.12),
            rangeThumbShape: const RoundRangeSliderThumbShape(
              enabledThumbRadius: 8,
            ),
            rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
            rangeValueIndicatorShape:
                const PaddleRangeSliderValueIndicatorShape(),
            valueIndicatorTextStyle: const TextStyle(
              color: kBlackColor,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
          child: RangeSlider(
            min: min,
            max: max,
            divisions: divisions > 0 ? divisions : null,
            values: RangeValues(
              values.start.clamp(min, max),
              values.end.clamp(min, max),
            ),
            labels: RangeLabels(formatter(values.start), formatter(values.end)),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.7,
      ),
    );
  }
}
