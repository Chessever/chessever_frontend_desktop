import 'dart:async';
import 'package:chessever/repositories/official_round_results_repository.dart';
import 'package:chessever/repository/supabase/round/round_repository.dart';
import 'package:chessever/services/official_round_results.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final officialRoundResultsRepositoryProvider =
    Provider<OfficialRoundResultsRepository>(
      (ref) => OfficialRoundResultsRepository(
        ref.watch(roundRepositoryProvider).supabase,
      ),
    );

final officialRoundResultsRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(minutes: 1),
);

/// One read per watched section, shared by standings and all player cards.
/// Refreshes are completion-relative and stop without readers. Keep the warm
/// cache for five minutes to avoid a request for every newly hovered player.
final officialRoundResultsProvider = FutureProvider.autoDispose
    .family<List<OfficialRoundResults>, String>((ref, tourId) async {
      final repository = ref.watch(officialRoundResultsRepositoryProvider);
      final interval = ref.watch(officialRoundResultsRefreshIntervalProvider);
      final link = ref.keepAlive();
      Timer? expiry;
      Timer? refresh;
      var active = true;
      var disposed = false;
      DateTime? fetchedAt;
      void arm() {
        refresh?.cancel();
        if (!active || disposed || fetchedAt == null) return;
        final remaining = interval - DateTime.now().difference(fetchedAt);
        refresh = Timer(remaining.isNegative ? Duration.zero : remaining, () {
          if (!disposed && active) ref.invalidateSelf();
        });
      }

      ref.onCancel(() {
        active = false;
        refresh?.cancel();
        expiry?.cancel();
        expiry = Timer(const Duration(minutes: 5), link.close);
      });
      ref.onResume(() {
        active = true;
        expiry?.cancel();
        arm();
      });
      ref.onDispose(() {
        disposed = true;
        refresh?.cancel();
        expiry?.cancel();
      });
      final retained = ref.state.valueOrNull ?? const <OfficialRoundResults>[];
      final result = await repository.getByTourId(
        tourId,
        retainedOnFailure: retained,
      );
      fetchedAt = DateTime.now();
      arm();
      return result;
    });
