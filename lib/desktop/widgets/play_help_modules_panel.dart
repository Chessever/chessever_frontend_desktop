import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/widgets/desktop_header_icon_button.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/theme/app_theme.dart';

/// One switch per help module, plus where the board's arrows come from.
/// The setup screen and the in-game popover show the same list, bound to
/// the same saved choice ([playHelpModulesProvider]).
class PlayHelpModulesList extends ConsumerWidget {
  const PlayHelpModulesList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modules = ref.watch(playHelpModulesProvider);
    final notifier = ref.read(playHelpModulesProvider.notifier);
    Widget row(
      String label,
      String description,
      bool value,
      PlayHelpModules Function(bool on) change,
    ) => _ModuleRow(
      label: label,
      description: description,
      value: value,
      onChange: (on) => notifier.set(change(on)),
    );

    return FTheme(
      data: FThemes.zinc.dark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          row(
            'Engine lines',
            'Stockfish’s best lines beside the moves.',
            modules.engineLines,
            (on) => modules.copyWith(engineLines: on),
          ),
          row(
            'Eval bar',
            'Stockfish’s evaluation left of the board.',
            modules.evalBar,
            (on) => modules.copyWith(evalBar: on),
          ),
          row(
            'Toby Predicts',
            'The moves Toby expects players like you to choose.',
            modules.tobyPredictions,
            (on) => modules.copyWith(tobyPredictions: on),
          ),
          row(
            'Toby bar',
            'Toby’s win, draw and loss chances right of the board.',
            modules.tobyBar,
            (on) => modules.copyWith(tobyBar: on),
          ),
          row(
            'Move marks',
            'Book, !!, ?? and the rest on each move as it is played.',
            modules.moveMarks,
            (on) => modules.copyWith(moveMarks: on),
          ),
          row(
            'Opening explorer',
            'Games that reached the position, and what was played.',
            modules.explorer,
            (on) => modules.copyWith(explorer: on),
          ),
          row(
            'Eval on my arrows',
            'The engine’s eval on legal arrows you right-drag.',
            modules.arrowEvals,
            (on) => modules.copyWith(arrowEvals: on),
          ),
          const SizedBox(height: 14),
          const Text(
            'Board arrows',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          DesktopSegmentedTabs<PlayHelpArrows>(
            tabs: const [
              DesktopSegmentedTab(value: PlayHelpArrows.off, label: 'Off'),
              DesktopSegmentedTab(
                value: PlayHelpArrows.stockfish,
                label: 'Stockfish',
              ),
              DesktopSegmentedTab(value: PlayHelpArrows.toby, label: 'Toby'),
            ],
            selected: modules.arrows,
            onChanged:
                (arrows) => notifier.set(modules.copyWith(arrows: arrows)),
            expand: true,
          ),
        ],
      ),
    );
  }
}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
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
                    color: kSecondaryTextColor,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FSwitch(semanticsLabel: label, value: value, onChange: onChange),
        ],
      ),
    );
  }
}

/// The help modules during a game: an icon button that opens
/// [PlayHelpModulesList] in a popover, so the player can change what they
/// see without leaving the board.
class PlayHelpModulesButton extends StatefulWidget {
  const PlayHelpModulesButton({super.key, this.dimension});

  final double? dimension;

  @override
  State<PlayHelpModulesButton> createState() => _PlayHelpModulesButtonState();
}

class _PlayHelpModulesButtonState extends State<PlayHelpModulesButton>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final popover = FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder:
            (context, _) => Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.75,
              ),
              width: 340,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDividerColor),
              ),
              child: const SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Live help',
                      style: TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 8),
                    PlayHelpModulesList(),
                  ],
                ),
              ),
            ),
        child: DesktopHeaderIconButton(
          message: 'Live help',
          icon: Icons.tune_rounded,
          unboxed: true,
          onPress: _controller.toggle,
        ),
      ),
    );
    final dimension = widget.dimension;
    if (dimension == null) return popover;
    return SizedBox.square(dimension: dimension, child: popover);
  }
}
