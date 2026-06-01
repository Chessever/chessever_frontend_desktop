import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Gear button + popover that exposes the same engine/board controls the
/// mobile chess board settings page does. Bound to `engineSettingsProviderNew`
/// so changes persist via Supabase + the local cache exactly like mobile.
///
/// We keep the visuals using forui chrome (FPopover, FSwitch, FButton) per
/// CLAUDE.md §3, but render text with our own theme tokens so the popover
/// blends with the surrounding desktop pane.
class EngineSettingsPopover extends ConsumerStatefulWidget {
  const EngineSettingsPopover({super.key});

  @override
  ConsumerState<EngineSettingsPopover> createState() =>
      _EngineSettingsPopoverState();
}

class _EngineSettingsPopoverState extends ConsumerState<EngineSettingsPopover>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller =
      FPopoverController(vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder: (context, _) => _PopoverBody(),
        child: FButton.icon(
          onPress: _controller.toggle,
          child: const Icon(
            Icons.tune_rounded,
            color: kWhiteColor70,
            size: 18,
          ),
        ),
      ),
    );
  }
}

class _PopoverBody extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSettings = ref.watch(engineSettingsProviderNew);
    final notifier = ref.read(engineSettingsProviderNew.notifier);
    final settings =
        asyncSettings.valueOrNull ?? const EngineSettings();

    return Container(
      width: 320,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Engine & board',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          _SwitchRow(
            label: 'Engine analysis',
            description: 'Run Stockfish on the active position.',
            value: settings.showEngineAnalysis,
            onChange: notifier.toggleEngineAnalysis,
          ),
          const SizedBox(height: 10),
          _SwitchRow(
            label: 'Evaluation gauge',
            description: 'Show the bar beside the board.',
            value: settings.showEngineGauge,
            onChange: notifier.toggleEngineGauge,
          ),
          const SizedBox(height: 10),
          _SwitchRow(
            label: 'PV arrows',
            description: 'Draw arrows for the top engine lines.',
            value: settings.showPvArrows,
            onChange: notifier.togglePvArrows,
          ),
          const Divider(height: 24, color: kDividerColor),
          _SegmentedRow(
            label: 'PV count',
            options: EngineSettings.principalVariationLabels,
            selectedIndex: settings.principalVariationIndex,
            onSelect: notifier.setPrincipalVariationIndex,
          ),
          const SizedBox(height: 12),
          _SegmentedRow(
            label: 'Search time',
            options: EngineSettings.searchTimeLabels,
            selectedIndex: settings.searchTimeIndex,
            onSelect: notifier.setSearchTimeIndex,
          ),
          const SizedBox(height: 12),
          _SegmentedRow(
            label: 'Max arrows',
            options: EngineSettings.maxArrowsLabels,
            selectedIndex: settings.maxArrowsOnBoard,
            onSelect: notifier.setMaxArrowsOnBoard,
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.description,
    required this.value,
    required this.onChange,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: const TextStyle(
                  color: kLightGreyColor,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        FSwitch(value: value, onChange: onChange),
      ],
    );
  }
}

class _SegmentedRow extends StatelessWidget {
  const _SegmentedRow({
    required this.label,
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
  });

  final String label;
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: kBlack3Color,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: kDividerColor),
          ),
          padding: const EdgeInsets.all(2),
          child: Row(
            children: [
              for (var i = 0; i < options.length; i++)
                Expanded(
                  child: GestureDetector(
                    onTap: () => onSelect(i),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: i == selectedIndex
                            ? kPrimaryColor
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        options[i],
                        style: TextStyle(
                          color: i == selectedIndex
                              ? kBackgroundColor
                              : kWhiteColor70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
