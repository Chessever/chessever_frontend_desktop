import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_strength.dart';
import 'package:chessever/desktop/widgets/desktop_value_slider.dart';
import 'package:chessever/theme/app_theme.dart';

class PlayStrengthControl extends StatelessWidget {
  const PlayStrengthControl({
    super.key,
    required this.engine,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final BotEngineKind engine;
  final int value;
  final ValueChanged<int> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final normalized = normalizePlayStrength(engine, value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              playStrengthControlTitle(engine),
              style: const TextStyle(
                color: kSecondaryTextColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
            const Spacer(),
            Text(
              playStrengthLabel(engine, normalized),
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          playStrengthControlCaption(engine),
          style: const TextStyle(
            color: kTertiaryTextColor,
            fontSize: 11,
            height: 1.35,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 10),
        if (usesExactEloSlider(engine))
          _EloSlider(engine: engine, value: normalized, onChanged: onChanged)
        else
          _ModeGrid(
            engine: engine,
            selectedValue: normalized,
            onChanged: onChanged,
            compact: compact,
          ),
      ],
    );
  }
}

class _EloSlider extends StatelessWidget {
  const _EloSlider({
    required this.engine,
    required this.value,
    required this.onChanged,
  });

  final BotEngineKind engine;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final range = playStrengthRangeFor(engine);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopValueSlider(
          min: range.$1.toDouble(),
          max: range.$2.toDouble(),
          value: value.clamp(range.$1, range.$2).toDouble(),
          onChanged: (v) => onChanged(v.round()),
          tooltipFormatter: (v) => v.round().toString(),
        ),
        Row(
          children: [
            Text('${range.$1}', style: _axisStyle),
            const Spacer(),
            Text('${range.$2}', style: _axisStyle),
          ],
        ),
      ],
    );
  }
}

class _ModeGrid extends StatelessWidget {
  const _ModeGrid({
    required this.engine,
    required this.selectedValue,
    required this.onChanged,
    required this.compact,
  });

  final BotEngineKind engine;
  final int selectedValue;
  final ValueChanged<int> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final options = playStrengthOptionsFor(engine);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          _ModeChip(
            option: option,
            selected: option.value == selectedValue,
            onPress: () => onChanged(option.value),
            compact: compact,
          ),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.option,
    required this.selected,
    required this.onPress,
    required this.compact,
  });

  final PlayStrengthOption option;
  final bool selected;
  final VoidCallback onPress;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton.raw(
        style: _modeButtonStyle(selected: selected),
        onPress: onPress,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: compact ? 126 : 156,
            maxWidth: compact ? 154 : 218,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: compact ? 9 : 10,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? kPrimaryColor : kWhiteColor,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  option.description,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 11,
                    height: 1.25,
                    letterSpacing: 0,
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

const TextStyle _axisStyle = TextStyle(
  color: kTertiaryTextColor,
  fontSize: 11,
  letterSpacing: 0,
  fontFeatures: [FontFeature.tabularFigures()],
);

FBaseButtonStyle Function(FButtonStyle style) _modeButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.18) : kBlack3Color,
          border: Border.all(
            color:
                selected ? kPrimaryColor : kWhiteColor.withValues(alpha: 0.16),
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        WidgetState.any: BoxDecoration(
          color:
              selected ? kPrimaryColor.withValues(alpha: 0.12) : kBlack3Color,
          border: Border.all(
            color: selected ? kPrimaryColor : kDividerColor,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(padding: EdgeInsets.zero, spacing: 0),
    ),
  );
}
