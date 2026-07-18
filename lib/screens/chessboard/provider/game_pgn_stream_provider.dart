import 'dart:async';

import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

@immutable
class LiveStreamArrival<T> {
  const LiveStreamArrival({
    required this.value,
    required this.sessionEpoch,
    required this.sequence,
    required this.isFallback,
  });

  final T value;

  /// Increments whenever lifecycle pause/resume recreates the remote channel.
  final int sessionEpoch;

  /// One-based diagnostic arrival index within the current remote channel.
  /// Supabase's table stream emits full query snapshots and does not identify
  /// whether any sequence number came from an initial select, reconnect, or
  /// mutation. Never use this value as position authority.
  final int sequence;
  final bool isFallback;
}

/// Stream provider for PGN updates of a specific game.
/// Auto-disposes when the widget is no longer in view.
final gamePgnStreamProvider = AutoDisposeStreamProvider.family<String?, String>(
  (ref, gameId) {
    return _lifecycleRetainedStream(
      ref: ref,
      initialValue: null,
      createSource:
          () => ref.read(gameStreamRepositoryProvider).subscribeToPgn(gameId),
    );
  },
);

/// Comprehensive game updates stream for live data (FEN, PGN, clocks, status).
///
/// Focused board views may use a single-game stream. Multi-game broadcast
/// surfaces must use [gameUpdatesBatchStreamProvider] so they do not exceed
/// Supabase's channel limits.
final gameUpdatesStreamProvider = AutoDisposeStreamProvider.family<
  Map<String, dynamic>?,
  String
>((ref, gameId) {
  // Board surfaces consume this legacy-Map view; live cards consume the typed
  // [liveGameUpdateStreamProvider]. Re-emit that SAME provider here so the board
  // and its card share ONE Supabase Realtime channel per game (Riverpod dedups
  // the family instance) instead of opening a second independent subscription
  // that could deliver the same row a beat apart — the source of the open board
  // and its card briefly disagreeing. The upstream provider already
  // `.distinct()`s identical rows.
  final controller = StreamController<Map<String, dynamic>?>();
  ref.onDispose(controller.close);
  ref.listen<AsyncValue<LiveGameUpdate?>>(
    liveGameUpdateStreamProvider(gameId),
    (_, next) => next.when(
      data: (update) => controller.add(update?.toLegacyMap()),
      error: controller.addError,
      loading: () {},
    ),
    fireImmediately: true,
  );
  return controller.stream;
});

final liveGameUpdateArrivalStreamProvider = AutoDisposeStreamProvider.family<
  LiveStreamArrival<LiveGameUpdate?>,
  String
>((ref, gameId) {
  return _lifecycleRetainedArrivalStream(
    ref: ref,
    initialValue: null,
    createSource:
        () => ref
            .read(gameStreamRepositoryProvider)
            .subscribeToLiveGameUpdate(gameId),
  );
});

final liveGameUpdateStreamProvider =
    AutoDisposeStreamProvider.family<LiveGameUpdate?, String>((ref, gameId) {
      final controller = StreamController<LiveGameUpdate?>();
      ref.onDispose(controller.close);
      ref.listen<AsyncValue<LiveStreamArrival<LiveGameUpdate?>>>(
        liveGameUpdateArrivalStreamProvider(gameId),
        (_, next) => next.when(
          data: (arrival) => controller.add(arrival.value),
          error: controller.addError,
          loading: () {},
        ),
        fireImmediately: true,
      );
      return controller.stream;
    });

@immutable
class LiveGamesBatchKey {
  LiveGamesBatchKey({
    required this.scopeId,
    required Iterable<String> gameIds,
    this.roundId,
    this.tourId,
  }) : gameIds = List.unmodifiable(
         gameIds.where((id) => id.isNotEmpty).toSet().toList()..sort(),
       );

  final String scopeId;
  final List<String> gameIds;
  final String? roundId;
  final String? tourId;

  bool get isScopedFilter =>
      (roundId != null && roundId!.isNotEmpty) ||
      (tourId != null && tourId!.isNotEmpty);

  bool contains(String gameId) {
    return gameIds.contains(gameId) || (isScopedFilter && gameId.isNotEmpty);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! LiveGamesBatchKey) return false;
    if (other.scopeId != scopeId ||
        other.roundId != roundId ||
        other.tourId != tourId ||
        other.gameIds.length != gameIds.length) {
      return false;
    }
    for (var i = 0; i < gameIds.length; i++) {
      if (gameIds[i] != other.gameIds[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(scopeId, roundId, tourId, Object.hashAll(gameIds));
}

final gameUpdatesBatchArrivalStreamProvider = AutoDisposeStreamProvider.family<
  LiveStreamArrival<Map<String, LiveGameUpdate>>,
  LiveGamesBatchKey
>((ref, key) {
  final repository = ref.read(gameStreamRepositoryProvider);
  final roundId = key.roundId?.trim();
  if (roundId != null && roundId.isNotEmpty) {
    return _lifecycleRetainedArrivalStream(
      ref: ref,
      initialValue: const <String, LiveGameUpdate>{},
      createSource:
          () => repository.subscribeToLiveGameUpdatesForRound(roundId),
    );
  }
  final tourId = key.tourId?.trim();
  if (tourId != null && tourId.isNotEmpty) {
    return _lifecycleRetainedArrivalStream(
      ref: ref,
      initialValue: const <String, LiveGameUpdate>{},
      createSource: () => repository.subscribeToLiveGameUpdatesForTour(tourId),
    );
  }
  return _lifecycleRetainedArrivalStream(
    ref: ref,
    initialValue: const <String, LiveGameUpdate>{},
    createSource: () => repository.subscribeToLiveGameUpdatesBatch(key.gameIds),
  );
});

final gameUpdatesBatchStreamProvider = AutoDisposeStreamProvider.family<
  Map<String, LiveGameUpdate>,
  LiveGamesBatchKey
>((ref, key) {
  final controller = StreamController<Map<String, LiveGameUpdate>>();
  ref.onDispose(controller.close);
  ref.listen<AsyncValue<LiveStreamArrival<Map<String, LiveGameUpdate>>>>(
    gameUpdatesBatchArrivalStreamProvider(key),
    (_, next) => next.when(
      data: (arrival) => controller.add(arrival.value),
      error: controller.addError,
      loading: () {},
    ),
    fireImmediately: true,
  );
  return controller.stream;
});

Stream<LiveStreamArrival<T>> _lifecycleRetainedArrivalStream<T>({
  required Ref ref,
  required T initialValue,
  required Stream<T> Function() createSource,
}) {
  final controller = StreamController<LiveStreamArrival<T>>();
  StreamSubscription<T>? remoteSubscription;
  Timer? reconnectTimer;
  var activityEpoch = 0;
  var sourceGeneration = 0;
  var sessionEpoch = 0;
  var reconnectAttempt = 0;
  var disposed = false;
  var lifecycleActive = ref.read(liveGameStreamingLifecycleProvider);

  const reconnectDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 10),
  ];
  const stableConnectionWindow = Duration(seconds: 10);

  late void Function(int epoch) startRemoteSynchronously;

  void scheduleReconnect(int epoch) {
    if (disposed || !lifecycleActive || epoch != activityEpoch) return;
    reconnectTimer?.cancel();
    final delayIndex =
        reconnectAttempt < reconnectDelays.length
            ? reconnectAttempt
            : reconnectDelays.length - 1;
    reconnectAttempt++;
    reconnectTimer = Timer(reconnectDelays[delayIndex], () {
      reconnectTimer = null;
      if (disposed || !lifecycleActive || epoch != activityEpoch) return;
      startRemoteSynchronously(epoch);
    });
  }

  void endSourceAndReconnect(
    int epoch,
    int generation, {
    required bool cancelSource,
    required DateTime startedAt,
  }) {
    if (disposed ||
        !lifecycleActive ||
        epoch != activityEpoch ||
        generation != sourceGeneration) {
      return;
    }
    if (DateTime.now().difference(startedAt) >= stableConnectionWindow) {
      reconnectAttempt = 0;
    }
    sourceGeneration++;
    final previous = remoteSubscription;
    remoteSubscription = null;
    if (cancelSource) unawaited(previous?.cancel());
    scheduleReconnect(epoch);
  }

  startRemoteSynchronously = (int epoch) {
    if (disposed || !lifecycleActive || epoch != activityEpoch) return;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    final generation = ++sourceGeneration;
    final currentSessionEpoch = ++sessionEpoch;
    final startedAt = DateTime.now();
    var sequence = 0;
    try {
      final subscription = createSource().listen(
        (value) {
          if (!disposed &&
              lifecycleActive &&
              epoch == activityEpoch &&
              generation == sourceGeneration) {
            controller.add(
              LiveStreamArrival<T>(
                value: value,
                sessionEpoch: currentSessionEpoch,
                sequence: ++sequence,
                isFallback: false,
              ),
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!disposed &&
              lifecycleActive &&
              epoch == activityEpoch &&
              generation == sourceGeneration) {
            controller.addError(error, stackTrace);
            endSourceAndReconnect(
              epoch,
              generation,
              cancelSource: true,
              startedAt: startedAt,
            );
          }
        },
        onDone:
            () => endSourceAndReconnect(
              epoch,
              generation,
              cancelSource: false,
              startedAt: startedAt,
            ),
      );
      if (!disposed &&
          lifecycleActive &&
          epoch == activityEpoch &&
          generation == sourceGeneration) {
        remoteSubscription = subscription;
      } else {
        unawaited(subscription.cancel());
      }
    } catch (error, stackTrace) {
      if (!disposed &&
          lifecycleActive &&
          epoch == activityEpoch &&
          generation == sourceGeneration) {
        controller.addError(error, stackTrace);
        endSourceAndReconnect(
          epoch,
          generation,
          cancelSource: true,
          startedAt: startedAt,
        );
      }
    }
  };

  Future<void> setLifecycleActive(bool active) async {
    lifecycleActive = active;
    final epoch = ++activityEpoch;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    sourceGeneration++;
    final previous = remoteSubscription;
    remoteSubscription = null;
    await previous?.cancel();
    if (!active || disposed || epoch != activityEpoch) return;
    reconnectAttempt = 0;
    startRemoteSynchronously(epoch);
  }

  controller.add(
    LiveStreamArrival<T>(
      value: initialValue,
      sessionEpoch: activityEpoch,
      sequence: 0,
      isFallback: true,
    ),
  );
  if (lifecycleActive) {
    startRemoteSynchronously(activityEpoch);
  }
  ref.listen<bool>(liveGameStreamingLifecycleProvider, (previous, next) {
    if (previous == next) return;
    unawaited(setLifecycleActive(next));
  });
  ref.onDispose(() {
    disposed = true;
    lifecycleActive = false;
    activityEpoch++;
    sourceGeneration++;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    final previous = remoteSubscription;
    remoteSubscription = null;
    unawaited(previous?.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
}

/// Publishes one harmless fallback, then retains the most recent live value
/// while the app is paused or detached.
///
/// Besides making consumers deterministic while Supabase performs its first
/// select, this matters for disposal: Riverpod 2 keeps a still-loading
/// `StreamProvider.future` subscription alive until it receives a value. By
/// emitting first, an auto-disposed hidden Board tab can cancel the remote
/// subscription even when that initial network request is stalled. Lifecycle
/// changes cancel/recreate only the remote subscription; they do not rebuild
/// this provider with `null`/`{}` and temporarily erase the last accurate row.
Stream<T> _lifecycleRetainedStream<T>({
  required Ref ref,
  required T initialValue,
  required Stream<T> Function() createSource,
}) {
  final controller = StreamController<T>();
  StreamSubscription<T>? remoteSubscription;
  Timer? reconnectTimer;
  var activityEpoch = 0;
  var sourceGeneration = 0;
  var reconnectAttempt = 0;
  var disposed = false;
  var lifecycleActive = ref.read(liveGameStreamingLifecycleProvider);

  const reconnectDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 10),
  ];
  const stableConnectionWindow = Duration(seconds: 10);

  late void Function(int epoch) startRemoteSynchronously;

  void scheduleReconnect(int epoch) {
    if (disposed || !lifecycleActive || epoch != activityEpoch) return;
    reconnectTimer?.cancel();
    final delayIndex =
        reconnectAttempt < reconnectDelays.length
            ? reconnectAttempt
            : reconnectDelays.length - 1;
    reconnectAttempt++;
    reconnectTimer = Timer(reconnectDelays[delayIndex], () {
      reconnectTimer = null;
      if (disposed || !lifecycleActive || epoch != activityEpoch) return;
      startRemoteSynchronously(epoch);
    });
  }

  void endSourceAndReconnect(
    int epoch,
    int generation, {
    required bool cancelSource,
    required DateTime startedAt,
  }) {
    if (disposed ||
        !lifecycleActive ||
        epoch != activityEpoch ||
        generation != sourceGeneration) {
      return;
    }
    if (DateTime.now().difference(startedAt) >= stableConnectionWindow) {
      reconnectAttempt = 0;
    }
    sourceGeneration++;
    final previous = remoteSubscription;
    remoteSubscription = null;
    if (cancelSource) unawaited(previous?.cancel());
    scheduleReconnect(epoch);
  }

  startRemoteSynchronously = (int epoch) {
    if (disposed || !lifecycleActive || epoch != activityEpoch) return;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    final generation = ++sourceGeneration;
    final startedAt = DateTime.now();
    try {
      final subscription = createSource().listen(
        (value) {
          if (!disposed &&
              lifecycleActive &&
              epoch == activityEpoch &&
              generation == sourceGeneration) {
            controller.add(value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!disposed &&
              lifecycleActive &&
              epoch == activityEpoch &&
              generation == sourceGeneration) {
            controller.addError(error, stackTrace);
            endSourceAndReconnect(
              epoch,
              generation,
              cancelSource: true,
              startedAt: startedAt,
            );
          }
        },
        onDone:
            () => endSourceAndReconnect(
              epoch,
              generation,
              cancelSource: false,
              startedAt: startedAt,
            ),
      );
      if (!disposed &&
          lifecycleActive &&
          epoch == activityEpoch &&
          generation == sourceGeneration) {
        remoteSubscription = subscription;
      } else {
        unawaited(subscription.cancel());
      }
    } catch (error, stackTrace) {
      if (!disposed &&
          lifecycleActive &&
          epoch == activityEpoch &&
          generation == sourceGeneration) {
        controller.addError(error, stackTrace);
        endSourceAndReconnect(
          epoch,
          generation,
          cancelSource: true,
          startedAt: startedAt,
        );
      }
    }
  };

  Future<void> setLifecycleActive(bool active) async {
    lifecycleActive = active;
    final epoch = ++activityEpoch;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    sourceGeneration++;
    final previous = remoteSubscription;
    remoteSubscription = null;
    // Calling cancel happens before the first await, so a pause tears down the
    // Supabase channel synchronously even when its cleanup future completes
    // later. The epoch rejects any event already queued by the old channel.
    await previous?.cancel();
    if (!active || disposed || epoch != activityEpoch) return;
    reconnectAttempt = 0;
    startRemoteSynchronously(epoch);
  }

  controller.add(initialValue);
  if (lifecycleActive) {
    startRemoteSynchronously(activityEpoch);
  }
  ref.listen<bool>(liveGameStreamingLifecycleProvider, (previous, next) {
    if (previous == next) return;
    unawaited(setLifecycleActive(next));
  });
  ref.onDispose(() {
    disposed = true;
    lifecycleActive = false;
    activityEpoch++;
    sourceGeneration++;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    final previous = remoteSubscription;
    remoteSubscription = null;
    unawaited(previous?.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
}
