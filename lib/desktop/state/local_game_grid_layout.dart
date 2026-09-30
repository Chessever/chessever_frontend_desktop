import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

const localGameGridColumns = [
  'originalOrder',
  'white',
  'whiteElo',
  'result',
  'black',
  'blackElo',
  'event',
  'eco',
  'opening',
  'date',
  'annotator',
];

@immutable
class LocalGameGridLayout {
  LocalGameGridLayout({
    Iterable<String> order = localGameGridColumns,
    Iterable<String> hidden = const [],
    Map<String, double> widths = const {},
  }) : order = List.unmodifiable({
         ...order.where(localGameGridColumns.contains),
         ...localGameGridColumns,
       }),
       hidden = Set.unmodifiable(
         hidden.where(
           (id) => localGameGridColumns.contains(id) && id != 'originalOrder',
         ),
       ),
       widths = Map.unmodifiable(
         Map.fromEntries(
           widths.entries
               .where(
                 (e) =>
                     localGameGridColumns.contains(e.key) &&
                     e.value.isFinite &&
                     e.value > 0,
               )
               .map((e) => MapEntry(e.key, e.value.clamp(36.0, 2400.0))),
         ),
       );
  final List<String> order;
  final Set<String> hidden;
  final Map<String, double> widths;
  List<String> get visible =>
      order.where((id) => !hidden.contains(id)).toList(growable: false);
  LocalGameGridLayout copyWith({
    Iterable<String>? order,
    Iterable<String>? hidden,
    Map<String, double>? widths,
  }) => LocalGameGridLayout(
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    widths: widths ?? this.widths,
  );
  Map<String, Object> toJson() => {
    'version': 1,
    'order': order,
    'hidden': hidden.toList(),
    'widths': widths,
  };
  factory LocalGameGridLayout.fromJson(Object? raw) {
    if (raw is! Map || raw['version'] != 1) return LocalGameGridLayout();
    return LocalGameGridLayout(
      order:
          raw['order'] is List
              ? (raw['order'] as List).whereType<String>()
              : localGameGridColumns,
      hidden:
          raw['hidden'] is List
              ? (raw['hidden'] as List).whereType<String>()
              : const [],
      widths:
          raw['widths'] is Map
              ? {
                for (final e in (raw['widths'] as Map).entries)
                  if (e.key is String && e.value is num)
                    e.key as String: (e.value as num).toDouble(),
              }
              : const {},
    );
  }
}

class LocalGameGridLayoutNotifier extends StateNotifier<LocalGameGridLayout> {
  LocalGameGridLayoutNotifier(this.db) : super(LocalGameGridLayout()) {
    loaded = _load();
  }
  static const preferenceKey = 'desktop.local_game_grid.layout.v1';
  final AppDatabase db;
  late final Future<void> loaded;
  Future<void> _writes = Future.value();
  bool _edited = false;
  Future<void> _load() async {
    try {
      final raw = await db.getJson<Object?>(preferenceKey);
      if (mounted && !_edited) state = LocalGameGridLayout.fromJson(raw);
    } catch (error) {
      debugPrint('Local grid preference load failed: $error');
    }
  }

  void update(LocalGameGridLayout next) {
    _edited = true;
    state = next;
  }

  Future<void> save() {
    final snapshot = state.toJson();
    _writes = _writes.then((_) async {
      await loaded;
      try {
        await db.setJson(preferenceKey, snapshot);
      } catch (error) {
        debugPrint('Local grid preference save failed: $error');
      }
    });
    return _writes;
  }

  void reset() {
    update(LocalGameGridLayout());
    unawaited(save());
  }
}

final localGameGridLayoutProvider =
    StateNotifierProvider<LocalGameGridLayoutNotifier, LocalGameGridLayout>(
      (ref) => LocalGameGridLayoutNotifier(ref.watch(appDatabaseProvider)),
    );
