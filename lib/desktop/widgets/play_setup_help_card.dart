import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/widgets/play_help_modules_panel.dart';
import 'package:chessever/desktop/widgets/play_setup_layout.dart';
import 'package:chessever/theme/app_theme.dart';

/// Whether the setup pages show every Live help switch. Closed to begin
/// with, so the setup fits on one screen; shared by single games and
/// tournaments for the session.
final playSetupHelpExpandedProvider = StateProvider<bool>((ref) => false);

/// Names of the help that is on, in the order the switches list them.
List<String> playHelpSummaryParts(PlayHelpModules modules) => [
  if (modules.engineLines) 'Engine lines',
  if (modules.evalBar) 'Eval bar',
  if (modules.tobyPredictions) 'Toby Predicts',
  if (modules.tobyBar) 'Toby bar',
  if (modules.moveMarks) 'Move marks',
  if (modules.explorer) 'Opening explorer',
  if (modules.arrowEvals) 'Eval on my arrows',
  switch (modules.arrows) {
    PlayHelpArrows.off => null,
    PlayHelpArrows.stockfish => 'Stockfish arrows',
    PlayHelpArrows.toby => 'Toby arrows',
  },
].whereType<String>().toList(growable: false);

/// The Live help card of a setup page. Closed, it says in one line what is
/// on; its title row opens the full [PlayHelpModulesList] in place.
class PlaySetupHelpCard extends ConsumerWidget {
  const PlaySetupHelpCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(playSetupHelpExpandedProvider);
    final parts = playHelpSummaryParts(ref.watch(playHelpModulesProvider));
    final style = ref.watch(playHelpStyleProvider);
    final how = switch (style.level) {
      PlayHelpLevel.always => '',
      PlayHelpLevel.peek => 'Hold to peek: ',
      PlayHelpLevel.hints =>
        style.hints == 1 ? '1 hint a game: ' : '${style.hints} hints a game: ',
    };
    final summary =
        parts.isEmpty
            ? 'All off. Games play as in competition.'
            : '$how${parts.join(', ')}';

    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            FTappable(
              style:
                  (style) =>
                      style.copyWith(motion: (_) => FTappableMotion.none),
              semanticsLabel:
                  expanded
                      ? 'Hide live help switches'
                      : 'Show live help switches',
              onPress:
                  () =>
                      ref.read(playSetupHelpExpandedProvider.notifier).state =
                          !expanded,
              builder: (context, states, _) {
                final hovered = states.contains(WidgetState.hovered);
                final focused = states.contains(WidgetState.focused);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: EdgeInsets.fromLTRB(20, 18, 16, expanded ? 6 : 18),
                  decoration: BoxDecoration(
                    color:
                        hovered && !expanded
                            ? kBlack3Color
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border:
                        focused
                            ? Border.all(
                              color: kPrimaryColor.withValues(alpha: 0.55),
                            )
                            : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const PlaySetupCardTitle('Live help'),
                            if (!expanded) ...[
                              const SizedBox(height: 8),
                              Text(
                                summary,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      parts.isEmpty
                                          ? kSecondaryTextColor
                                          : kWhiteColor70,
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        expanded
                            ? 'Hide'
                            : parts.isEmpty
                            ? 'Edit'
                            : '${parts.length} on',
                        style: TextStyle(
                          color: hovered ? kWhiteColor : kSecondaryTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: hovered ? kWhiteColor : kWhiteColor70,
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
                      ? const Padding(
                        padding: EdgeInsets.fromLTRB(20, 8, 20, 20),
                        child: PlayHelpModulesList(),
                      )
                      : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
