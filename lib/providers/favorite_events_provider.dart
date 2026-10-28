import 'dart:async';
import 'dart:convert';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/services/analytics/analytics_service.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provider for managing event favorites
/// Business logic lives here, not in a separate repository
final favoriteEventsProvider =
    AsyncNotifierProvider<FavoriteEventsNotifier, List<FavoriteEvent>>(
      FavoriteEventsNotifier.new,
    );

class FavoriteEventsNotifier extends AsyncNotifier<List<FavoriteEvent>> {
  static const String _cacheKey = 'cached_favorite_events';

  SupabaseClient get _supabase => Supabase.instance.client;

  String? _getCurrentUserId() => _supabase.auth.currentUser?.id;

  /// Guards concurrent fetches so only one Supabase request + cache write
  /// happens at a time.
  Completer<List<FavoriteEvent>>? _fetchCompleter;

  @override
  Future<List<FavoriteEvent>> build() async {
    return await _loadFavorites();
  }

  Future<List<FavoriteEvent>> _loadFavorites() async {
    try {
      final cached = await _getCachedEvents();
      if (cached.isNotEmpty) {
        unawaited(_refreshFromSupabase());
        return cached;
      }

      return await _fetchFavoritesFromSupabase();
    } catch (e, st) {
      debugPrint('[FavoriteEvents] Error fetching from Supabase: $e');
      debugPrint('[FavoriteEvents] Stack: $st');

      // Fallback to local cache
      return await _getCachedEvents();
    }
  }

  Future<List<FavoriteEvent>> _fetchFavoritesFromSupabase() async {
    // Deduplicate concurrent calls (build + unawaited refresh racing)
    if (_fetchCompleter != null) return _fetchCompleter!.future;

    _fetchCompleter = Completer<List<FavoriteEvent>>();
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        debugPrint('[FavoriteEvents] No user logged in, returning empty list');
        final result = <FavoriteEvent>[];
        _fetchCompleter!.complete(result);
        return result;
      }

      // Fetch from Supabase (source of truth)
      final response = await _supabase
          .from('user_favorite_events')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      final events =
          (response as List)
              .map((json) => FavoriteEvent.fromSupabase(json))
              .toList();

      // Cache locally in background (Supabase stays primary path)
      unawaited(_cacheEvents(events, userId));

      debugPrint(
        '[FavoriteEvents] Fetched ${events.length} events from Supabase',
      );
      _fetchCompleter!.complete(events);
      return events;
    } catch (e) {
      final cached = await _getCachedEvents();
      _fetchCompleter!.complete(cached);
      return cached;
    } finally {
      _fetchCompleter = null;
    }
  }

  Future<void> _refreshFromSupabase() async {
    try {
      final events = await _fetchFavoritesFromSupabase();
      state = AsyncValue.data(events);
      _syncFavoriteCountAnalytics(events.length);
    } catch (e, st) {
      debugPrint('[FavoriteEvents] Refresh error: $e');
      debugPrint('[FavoriteEvents] Stack: $st');
    }
  }

  /// Add event to favorites (optimistic update)
  ///
  /// [extraMetadata] is merged into the row's `metadata` JSONB; smart events
  /// store their criteria there.
  Future<void> addFavorite({
    required String eventId,
    required String eventName,
    String? timeControl,
    int? maxAvgElo,
    String? dates,
    Map<String, dynamic>? extraMetadata,
  }) async {
    final userId = _getCurrentUserId();
    if (userId == null) {
      throw Exception('User must be logged in to favorite events');
    }

    final metadata = <String, dynamic>{
      if (timeControl != null) 'timeControl': timeControl,
      if (maxAvgElo != null) 'maxAvgElo': maxAvgElo,
      if (dates != null) 'dates': dates,
      ...?extraMetadata,
    };

    // Create optimistic event
    final optimisticEvent = FavoriteEvent(
      id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
      userId: userId,
      eventId: eventId,
      eventName: eventName,
      metadata: metadata,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // STEP 1: Optimistic update - update state immediately
    final currentEvents = state.valueOrNull ?? [];
    final updatedEvents = [...currentEvents, optimisticEvent];
    state = AsyncValue.data(updatedEvents);

    // Cache immediately
    await _cacheEvents(updatedEvents, userId);

    try {
      // STEP 2: Sync to Supabase in background (upsert prevents duplicates)
      await _supabase
          .from('user_favorite_events')
          .upsert(
            {
              'user_id': userId,
              'event_id': eventId,
              'event_name': eventName,
              'metadata': metadata,
            },
            onConflict: 'user_id,event_id',
            ignoreDuplicates: true,
          );

      debugPrint('[FavoriteEvents] Added event $eventId to Supabase');

      // STEP 3: Fetch fresh data from Supabase (without loading state)
      final freshEvents = await _loadFavorites();
      state = AsyncValue.data(freshEvents);
      _syncFavoriteCountAnalytics(freshEvents.length);
    } catch (e, st) {
      debugPrint('[FavoriteEvents] Error adding event: $e');
      debugPrint('[FavoriteEvents] Stack: $st');

      // STEP 4: Revert optimistic update on error
      state = AsyncValue.data(currentEvents);
      await _cacheEvents(currentEvents, userId);
      rethrow;
    }
  }

  /// Remove event from favorites (optimistic update)
  Future<void> removeFavorite(String eventId) async {
    final userId = _getCurrentUserId();
    if (userId == null) {
      throw Exception('User must be logged in to remove favorites');
    }

    // STEP 1: Optimistic update - update state immediately
    final currentEvents = state.valueOrNull ?? [];
    final updatedEvents =
        currentEvents.where((e) => e.eventId != eventId).toList();
    state = AsyncValue.data(updatedEvents);

    // Cache immediately
    await _cacheEvents(updatedEvents, userId);

    try {
      // STEP 2: Sync to Supabase in background
      await _supabase
          .from('user_favorite_events')
          .delete()
          .eq('user_id', userId)
          .eq('event_id', eventId);

      debugPrint('[FavoriteEvents] Removed event $eventId from Supabase');

      // STEP 3: Fetch fresh data from Supabase (without loading state)
      final freshEvents = await _loadFavorites();
      state = AsyncValue.data(freshEvents);
      _syncFavoriteCountAnalytics(freshEvents.length);
    } catch (e, st) {
      debugPrint('[FavoriteEvents] Error removing event: $e');
      debugPrint('[FavoriteEvents] Stack: $st');

      // STEP 4: Revert optimistic update on error
      state = AsyncValue.data(currentEvents);
      await _cacheEvents(currentEvents, userId);
      rethrow;
    }
  }

  /// Merge [patch] into a saved favorite's `metadata` JSONB (optimistic local
  /// update + Supabase UPDATE). No-op if the event isn't currently saved.
  ///
  /// Used to persist per-row data such as a smart event's refreshed member
  /// snapshot on the owning favorite row, so it syncs across devices and is
  /// deleted with the event.
  Future<void> updateMetadata(
    String eventId,
    Map<String, dynamic> patch,
  ) async {
    final userId = currentUserIdForWrites();
    if (userId == null) return;

    final currentEvents = state.valueOrNull ?? [];
    final index = currentEvents.indexWhere((e) => e.eventId == eventId);
    if (index < 0) return; // not saved — nothing to update

    final existing = currentEvents[index];
    final newMetadata = <String, dynamic>{...existing.metadata, ...patch};
    final optimistic = FavoriteEvent(
      id: existing.id,
      userId: existing.userId,
      eventId: existing.eventId,
      eventName: existing.eventName,
      metadata: newMetadata,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    final updatedEvents = [...currentEvents]..[index] = optimistic;
    state = AsyncValue.data(updatedEvents);
    await cacheFavoriteEventsLocally(updatedEvents, userId);

    try {
      await updateFavoriteRowRemote(
        userId: userId,
        matchEventId: eventId,
        values: {'metadata': newMetadata},
      );
      debugPrint('[FavoriteEvents] Updated metadata for $eventId');
    } catch (e, st) {
      debugPrint('[FavoriteEvents] Error updating metadata: $e');
      debugPrint('[FavoriteEvents] Stack: $st');
      state = AsyncValue.data(currentEvents);
      await cacheFavoriteEventsLocally(currentEvents, userId);
      rethrow;
    }
  }

  /// Re-keys the favourite row [previousEventId] to [eventId] atomically.
  ///
  /// A row's id can embed its content (a smart event's id embeds its criteria
  /// key), so changing the content changes the id. The old delete-then-add
  /// sequence could lose the row on any failure between the two writes and
  /// silently no-op on a surviving row. This instead issues ONE UPDATE that
  /// rewrites `event_id`, `event_name` and `metadata` together on the existing
  /// row. [buildMetadata] receives that row's current metadata so user-owned
  /// keys can be carried across.
  ///
  /// * No row for [previousEventId]: this is a first save, so the row is
  ///   inserted (an upsert that writes metadata, never `ignoreDuplicates`).
  /// * A different row already owns [eventId]: that row is written first and
  ///   the source row retired only afterwards. If retiring fails the user
  ///   keeps a harmless duplicate; nothing is lost.
  ///
  /// Not optimistic: local state and the cache advance only after the server
  /// confirms the write. On failure this throws and leaves both untouched.
  Future<FavoriteEvent> rekeyFavorite({
    required String previousEventId,
    required String eventId,
    required String eventName,
    required Map<String, dynamic> Function(Map<String, dynamic> existing)
    buildMetadata,
  }) async {
    final userId = currentUserIdForWrites();
    if (userId == null) {
      throw StateError('User must be logged in to update favorites');
    }

    final before = state.valueOrNull ?? const <FavoriteEvent>[];
    FavoriteEvent? source;
    FavoriteEvent? target;
    for (final row in before) {
      if (row.eventId == previousEventId) source ??= row;
      if (previousEventId != eventId && row.eventId == eventId) target ??= row;
    }

    Future<FavoriteEvent> insert(Map<String, dynamic> metadata) async {
      final row = await upsertFavoriteRowRemote({
        'user_id': userId,
        'event_id': eventId,
        'event_name': eventName,
        'metadata': metadata,
      });
      return FavoriteEvent.fromSupabase(row);
    }

    late final FavoriteEvent saved;
    var retiredSource = false;

    if (source == null) {
      saved = await insert(buildMetadata(target?.metadata ?? const {}));
    } else if (target != null) {
      final rows = await updateFavoriteRowRemote(
        userId: userId,
        matchEventId: eventId,
        values: {
          'event_name': eventName,
          'metadata': buildMetadata({...target.metadata, ...source.metadata}),
        },
      );
      saved =
          rows.isEmpty
              ? await insert(
                buildMetadata({...target.metadata, ...source.metadata}),
              )
              : FavoriteEvent.fromSupabase(rows.first);
      try {
        await deleteFavoriteRowRemote(userId: userId, eventId: previousEventId);
        retiredSource = true;
      } catch (e, st) {
        debugPrint(
          '[FavoriteEvents] Kept duplicate $previousEventId after re-key: $e',
        );
        debugPrint('[FavoriteEvents] Stack: $st');
      }
    } else {
      final metadata = buildMetadata(source.metadata);
      final rows = await updateFavoriteRowRemote(
        userId: userId,
        matchEventId: previousEventId,
        values: {
          'event_id': eventId,
          'event_name': eventName,
          'metadata': metadata,
        },
      );
      // Zero rows means another device removed it meanwhile: re-create it
      // rather than report a save that never happened.
      saved =
          rows.isEmpty
              ? await insert(metadata)
              : FavoriteEvent.fromSupabase(rows.first);
      retiredSource = true;
    }

    final after = <FavoriteEvent>[];
    var placed = false;
    for (final row in before) {
      final isSource = row.eventId == previousEventId;
      final isTarget = row.eventId == eventId;
      if (isSource && !retiredSource && !isTarget) {
        after.add(row);
        continue;
      }
      if (isSource || isTarget) {
        if (!placed) {
          after.add(saved);
          placed = true;
        }
        continue;
      }
      after.add(row);
    }
    if (!placed) after.add(saved);

    state = AsyncValue.data(after);
    await cacheFavoriteEventsLocally(after, userId);
    debugPrint('[FavoriteEvents] Re-keyed $previousEventId -> $eventId');
    return saved;
  }

  /// Signed-in user id for writes. Overridable so tests can drive the write
  /// paths without a Supabase session.
  @protected
  String? currentUserIdForWrites() => _getCurrentUserId();

  /// `UPDATE user_favorite_events SET values WHERE user_id AND event_id`,
  /// returning the updated rows (empty when nothing matched).
  @protected
  Future<List<Map<String, dynamic>>> updateFavoriteRowRemote({
    required String userId,
    required String matchEventId,
    required Map<String, dynamic> values,
  }) async {
    final response = await _supabase
        .from('user_favorite_events')
        .update(values)
        .eq('user_id', userId)
        .eq('event_id', matchEventId)
        .select();
    return (response as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }

  /// Insert-or-update on `(user_id, event_id)` that always writes metadata.
  @protected
  Future<Map<String, dynamic>> upsertFavoriteRowRemote(
    Map<String, dynamic> values,
  ) async {
    final response =
        await _supabase
            .from('user_favorite_events')
            .upsert(values, onConflict: 'user_id,event_id')
            .select()
            .single();
    return Map<String, dynamic>.from(response);
  }

  @protected
  Future<void> deleteFavoriteRowRemote({
    required String userId,
    required String eventId,
  }) async {
    await _supabase
        .from('user_favorite_events')
        .delete()
        .eq('user_id', userId)
        .eq('event_id', eventId);
  }

  @protected
  Future<void> cacheFavoriteEventsLocally(
    List<FavoriteEvent> events,
    String? userId,
  ) => _cacheEvents(events, userId);

  /// Toggle event favorite status
  Future<bool> toggleFavorite({
    required String eventId,
    required String eventName,
    String? timeControl,
    int? maxAvgElo,
    String? dates,
    Map<String, dynamic>? extraMetadata,
  }) async {
    final currentState = state.valueOrNull ?? [];
    final isFavorited = currentState.any((e) => e.eventId == eventId);

    if (isFavorited) {
      await removeFavorite(eventId);
      return false;
    } else {
      await addFavorite(
        eventId: eventId,
        eventName: eventName,
        timeControl: timeControl,
        maxAvgElo: maxAvgElo,
        dates: dates,
        extraMetadata: extraMetadata,
      );
      return true;
    }
  }

  /// Check if event is favorited
  bool isFavorited(String eventId) {
    final currentState = state.valueOrNull;
    if (currentState == null) return false;
    return currentState.any((e) => e.eventId == eventId);
  }

  /// Refresh favorites from Supabase
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _loadFavorites());
  }

  /// Sync favorites from Supabase to local cache
  Future<void> syncFromSupabase() async {
    debugPrint('[FavoriteEvents] Starting sync...');
    try {
      await refresh();
      debugPrint('[FavoriteEvents] Sync complete');
    } catch (e, st) {
      debugPrint('[FavoriteEvents] Error syncing: $e');
      debugPrint('[FavoriteEvents] Stack: $st');
    }
  }

  // Cache management
  Future<void> _cacheEvents(List<FavoriteEvent> events, String? userId) async {
    try {
      final db = AppDatabase.instance;
      final json = jsonEncode(events.map((e) => e.toSupabase()).toList());
      await db.setCache(key: _cacheKey, value: json, userId: userId);
      debugPrint('[FavoriteEvents] Cached ${events.length} events locally');
    } catch (e) {
      debugPrint('[FavoriteEvents] Error caching events: $e');
    }
  }

  Future<List<FavoriteEvent>> _getCachedEvents() async {
    try {
      final db = AppDatabase.instance;
      final userId = _getCurrentUserId();
      final entry = await db.getCache(key: _cacheKey, userId: userId);
      if (entry == null) return [];

      final list = jsonDecode(entry.value) as List;
      return list.map((json) => FavoriteEvent.fromSupabase(json)).toList();
    } catch (e) {
      debugPrint('[FavoriteEvents] Error getting cached events: $e');
      return [];
    }
  }

  /// Clear cache (useful on sign out)
  Future<void> clearCache() async {
    try {
      final db = AppDatabase.instance;
      final userId = _getCurrentUserId();
      await db.removeCache(key: _cacheKey, userId: userId);
      debugPrint('[FavoriteEvents] Cleared cache');
    } catch (e) {
      debugPrint('[FavoriteEvents] Error clearing cache: $e');
    }
  }

  void _syncFavoriteCountAnalytics(int count) {
    unawaited(
      AnalyticsService.instance.setUserProperties({
        'favorite_event_count': count,
      }),
    );
  }
}

/// Provider to check if a specific event is favorited
final isEventFavoritedProvider = Provider.family<bool, String>((ref, eventId) {
  final favorites = ref.watch(favoriteEventsProvider);
  return favorites.maybeWhen(
    data: (events) => events.any((e) => e.eventId == eventId),
    orElse: () => false,
  );
});
