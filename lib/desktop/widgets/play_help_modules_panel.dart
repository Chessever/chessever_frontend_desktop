import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/play_help_modules.dart';
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

/// Whether the in-game Live help section is open. Shared by every Play
/// tab for the session, and closed to begin with: the switches stay out of
/// the way until the player asks for them.
final playHelpSectionExpandedProvider = StateProvider<bool>((ref) => false);

/// The help modules during a game: one quiet "Live help" row that opens
/// [PlayHelpModulesList] in place, so the player can change what they see
/// without leaving the board.
class PlayHelpModulesSection extends ConsumerWidget {
  const PlayHelpModulesSection({super.key});

  /// Taller lists scroll inside the section instead of pushing the game's
  /// controls off the panel.
  static const double _maxListHeight = 300;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(playHelpSectionExpandedProvider);
    final modules = ref.watch(playHelpModulesProvider);
    final onCount =
        [
          modules.engineLines,
          modules.evalBar,
          modules.tobyPredictions,
          modules.tobyBar,
          modules.moveMarks,
          modules.explorer,
          modules.arrowEvals,
          modules.arrows != PlayHelpArrows.off,
        ].where((on) => on).length;

    return FTheme(
      data: FThemes.zinc.dark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FTappable(
            style:
                (style) => style.copyWith(motion: (_) => FTappableMotion.none),
            semanticsLabel: expanded ? 'Hide live help' : 'Show live help',
            onPress:
                () =>
                    ref.read(playHelpSectionExpandedProvider.notifier).state =
                        !expanded,
            builder: (context, states, _) {
              final hovered = states.contains(WidgetState.hovered);
              final foreground = hovered ? kWhiteColor : kWhiteColor70;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: hovered ? kBlack3Color : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDividerColor),
                ),
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 16, color: foreground),
                    const SizedBox(width: 8),
                    Text(
                      'Live help',
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      onCount == 0 ? 'Off' : '$onCount on',
                      style: const TextStyle(
                        color: kSecondaryTextColor,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child:
                expanded
                    ? Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 2),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: _maxListHeight,
                        ),
                        child: const SingleChildScrollView(
                          padding: EdgeInsets.only(right: 6),
                          child: PlayHelpModulesList(),
                        ),
                      ),
                    )
                    : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
