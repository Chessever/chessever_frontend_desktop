import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final selectedBroadcastModelProvider = StateProvider<GroupBroadcast?>(
  (ref) => null,
);

/// Re-reads the canonical base-table row while an event is open.
///
/// Existing discovery views predate `broadcast_writer`. Keeping their proven
/// queries unchanged and resolving the base row only on detail surfaces gives
/// accurate attribution without adding latency to the event lists.
final canonicalSelectedBroadcastProvider =
    FutureProvider.autoDispose<GroupBroadcast?>((ref) async {
      final selected = ref.watch(selectedBroadcastModelProvider);
      if (selected == null || selected.id.trim().isEmpty) return selected;

      try {
        return await ref
            .read(groupBroadcastRepositoryProvider)
            .getGroupBroadcastById(selected.id);
      } catch (_) {
        return selected;
      }
    });

final selectedBroadcastWriterAttributionProvider = Provider<String>((ref) {
  final selected = ref.watch(selectedBroadcastModelProvider);
  final canonical = ref.watch(canonicalSelectedBroadcastProvider).valueOrNull;
  return (canonical ?? selected)?.writerAttributionLabel ??
      'Powered by Lichess';
});

final selectedTourModeProvider =
    AutoDisposeStateProvider<TournamentDetailScreenMode>(
      (ref) => TournamentDetailScreenMode.games,
    );

/// For Tabs
enum TournamentDetailScreenMode { about, games, standings }
