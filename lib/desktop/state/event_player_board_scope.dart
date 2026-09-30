import 'package:flutter/foundation.dart';

/// Durable ordinary-event scope, deliberately distinct from Premium Prepare.
@immutable
class EventPlayerBoardScope {
  EventPlayerBoardScope({
    required Iterable<String> tourIds,
    required this.playerName,
    required this.eventTitle,
    this.fideId,
    this.eventBroadcastId,
  }) : tourIds = List.unmodifiable(
         tourIds.where((id) => id.isNotEmpty).toSet(),
       );

  final List<String> tourIds;
  final String playerName;
  final int? fideId;
  final String eventTitle;
  final String? eventBroadcastId;

  String get title => '$playerName · $eventTitle';
  Map<String, Object?> toJson() => {
    'tourIds': tourIds,
    'playerName': playerName,
    'fideId': fideId,
    'eventTitle': eventTitle,
    'eventBroadcastId': eventBroadcastId,
  };

  static EventPlayerBoardScope? fromJson(Object? value) {
    if (value is! Map || value['tourIds'] is! List) return null;
    final ids = (value['tourIds'] as List).whereType<String>().toList();
    final name = value['playerName'];
    if (ids.isEmpty || name is! String || name.isEmpty) return null;
    return EventPlayerBoardScope(
      tourIds: ids,
      playerName: name,
      fideId: value['fideId'] is int ? value['fideId'] as int : null,
      eventTitle: value['eventTitle'] as String? ?? '',
      eventBroadcastId: value['eventBroadcastId'] as String?,
    );
  }

  @override
  String toString() =>
      '${tourIds.join('|')}:$fideId:$playerName:$eventBroadcastId';
}
