import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// The cover lookup deliberately excludes player lists and standings. Those
/// can dwarf the image itself and are not needed to paint an event card.
class EventArtworkSource {
  EventArtworkSource({required this.client});

  final SupabaseClient Function() client;

  static const columns = 'id,group_broadcast_id,image,location:info->>location';

  Future<List<Map<String, dynamic>>> byGroups(List<String> ids) => client()
      .from('tours')
      .select(columns)
      .inFilter('group_broadcast_id', ids)
      .order('avg_elo', ascending: false);

  Future<List<Map<String, dynamic>>> byIds(List<String> ids) =>
      client().from('tours').select(columns).inFilter('id', ids);
}

class EventArtwork {
  const EventArtwork({this.imageUrl, this.location});

  final String? imageUrl;
  final String? location;
}

/// Coalesces cards built in the same frame into small, bounded queries. An
/// in-flight lookup is also shared when a card leaves and re-enters the view.
class EventArtworkLoader {
  EventArtworkLoader({
    required this.source,
    this.timeout = const Duration(seconds: 8),
  });

  final EventArtworkSource source;
  final Duration timeout;
  static const batchSize = 24;

  final _pending = <String, Completer<EventArtwork>>{};
  final _inFlight = <String, Completer<EventArtwork>>{};

  Future<EventArtwork> load(String id) {
    final existing = _inFlight[id];
    if (existing != null) return existing.future;
    final completer = Completer<EventArtwork>();
    _inFlight[id] = completer;
    final schedule = _pending.isEmpty;
    _pending[id] = completer;
    if (schedule) Timer.run(_flush);
    return completer.future;
  }

  void _flush() {
    final entries = _pending.entries.toList();
    _pending.clear();
    for (var start = 0; start < entries.length; start += batchSize) {
      final batch = Map.fromEntries(entries.skip(start).take(batchSize));
      unawaited(_loadBatch(batch));
    }
  }

  Future<void> _loadBatch(Map<String, Completer<EventArtwork>> batch) async {
    void complete(String id, Iterable<Map<String, dynamic>> tours) {
      final completer = batch.remove(id)!;
      _inFlight.remove(id);
      completer.complete(_artwork(tours));
    }

    try {
      final groups = _groupRows(
        await source.byGroups(batch.keys.toList()).timeout(timeout),
      );
      // Publish real group covers immediately. A raw tour ID's fallback must
      // not hold up every other image in the batch.
      for (final id in batch.keys.toList()) {
        final tours = groups[id];
        if (tours != null) complete(id, tours);
      }
      if (batch.isEmpty) return;

      // For You can supply a raw tour ID. Resolve its group and consider all
      // siblings, including an image on a lower-rated sibling.
      final byId = {
        for (final row in await source
            .byIds(batch.keys.toList())
            .timeout(timeout))
          row['id'] as String: row,
      };
      final missingGroups = <String>{};
      for (final id in batch.keys.toList()) {
        final row = byId[id];
        final groupId = _text(row?['group_broadcast_id']);
        if (row == null) {
          complete(id, const []);
        } else if (groupId == null || groupId == id) {
          complete(id, [row]);
        } else if (groups.containsKey(groupId)) {
          complete(id, groups[groupId]!);
        } else {
          missingGroups.add(groupId);
        }
      }
      if (batch.isEmpty) return;

      final siblings = _groupRows(
        await source.byGroups(missingGroups.toList()).timeout(timeout),
      );
      for (final id in batch.keys.toList()) {
        final row = byId[id]!;
        complete(id, siblings[_text(row['group_broadcast_id'])] ?? [row]);
      }
    } catch (error, stackTrace) {
      for (final entry in batch.entries) {
        _inFlight.remove(entry.key);
        entry.value.completeError(error, stackTrace);
      }
    }
  }

  static Map<String, List<Map<String, dynamic>>> _groupRows(
    List<Map<String, dynamic>> rows,
  ) {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final group = _text(row['group_broadcast_id']);
      if (group != null) result.putIfAbsent(group, () => []).add(row);
    }
    return result;
  }

  static EventArtwork _artwork(Iterable<Map<String, dynamic>> tours) {
    String? image;
    String? location;
    for (final row in tours) {
      image ??= _text(row['image']);
      location ??= _text(row['location']);
    }
    return EventArtwork(
      imageUrl: image,
      location: location?.replaceFirst(RegExp(r'\.$'), ''),
    );
  }

  static String? _text(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }
}
