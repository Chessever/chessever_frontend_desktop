import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Monotonic signal for cloud Library/database rows that are fetched through
/// one-shot repository futures instead of a Riverpod stream.
///
/// Updating a saved analysis already invalidates folder streams, but open
/// desktop database workspaces keep their own `useFuture` snapshot. Bumping
/// this nonce tells those mounted workspaces to refetch immediately so closing
/// and reopening a game from the still-open database sees the updated PGN.
final cloudLibraryRefreshNonceProvider = StateProvider<int>((ref) => 0);

void notifyCloudLibraryChanged(WidgetRef ref) {
  ref.read(cloudLibraryRefreshNonceProvider.notifier).state++;
}
