import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/standings/player_standing_sections_provider.dart';
import 'package:flutter/material.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Uses the desktop's accessible select primitive with the standing section's
/// stable event id, so shared ranks never turn into an overall leaderboard.
class PlayerStandingSectionSelect extends ConsumerWidget {
  const PlayerStandingSectionSelect({
    super.key,
    required this.tourId,
    required this.sections,
  });
  final String tourId;
  final List<OfficialPlayerSection> sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = selectedOfficialPlayerSection(
      sections,
      ref.watch(selectedPlayerStandingSectionProvider(tourId)),
    );
    if (selected == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Semantics(
        label: 'Official section',
        child: DesktopSegmentedTabs<String>(
          wrap: true,
          selected: selected.id,
          tabs: [
            for (final section in sections)
              DesktopSegmentedTab(value: section.id, label: section.name),
          ],
          onChanged:
              (id) =>
                  ref
                      .read(
                        selectedPlayerStandingSectionProvider(tourId).notifier,
                      )
                      .state = id,
        ),
      ),
    );
  }
}
