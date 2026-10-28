import 'dart:async';

import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final officialTeamInfoRefreshIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 30),
);

final officialTeamInfoLoaderProvider =
    Provider<Future<TourInfo?> Function(String)>((ref) {
      final repository = ref.watch(tourRepositoryProvider);
      return (tourId) async {
        final tours = await repository.getToursByIds([tourId]);
        for (final tour in tours) {
          if (tour.id == tourId) return tour.info;
        }
        return null;
      };
    });

/// Official standings can land after the final streamed move. Refresh only
/// while observed, and use the immutable tour ID so a board rail cannot inherit
/// the currently selected event's table. An absent snapshot clears the old one.
final officialTeamInfoProvider = StreamProvider.autoDispose
    .family<TourInfo?, String>((ref, rawTourId) {
      final tourId = rawTourId.trim();
      if (tourId.isEmpty) return Stream.value(null);
      final load = ref.watch(officialTeamInfoLoaderProvider);
      final interval = ref.watch(officialTeamInfoRefreshIntervalProvider);
      final controller = StreamController<TourInfo?>();
      Timer? timer;
      var disposed = false;

      Future<void> refresh() async {
        try {
          final info = await load(tourId);
          if (!disposed) controller.add(info);
        } catch (error, stack) {
          if (!disposed) controller.addError(error, stack);
        } finally {
          // Schedule after completion: a slow request never overlaps a tick.
          if (!disposed) timer = Timer(interval, refresh);
        }
      }

      controller.onListen = refresh;
      ref.onDispose(() {
        disposed = true;
        timer?.cancel();
        unawaited(controller.close());
      });
      return controller.stream;
    });
