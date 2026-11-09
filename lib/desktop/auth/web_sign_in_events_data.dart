import 'package:chessever/desktop/state/signed_out_events_presentation.dart';
import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/sorting_all_event_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:chessever/widgets/event_card/event_image_provider.dart';
import 'package:chessever/widgets/event_card/event_next_round_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Adapts the actual unpersonalized For You query projection, not Current or a
/// global game sample. All presentation, board selection and neutral sorting
/// are the same production models/helpers used after authentication.
class PublicEventsPreview {
  const PublicEventsPreview({required this.presentation});
  final SignedOutEventsPresentationData presentation;

  factory PublicEventsPreview.fromJson(Map<String, dynamic> json) {
    final capturedAt = DateTime.tryParse(json['generatedAt']?.toString() ?? '');
    final rawEvents = json['events'];
    final rawGames = json['games'];
    final rawLiveIds = json['strictLiveEventIds'];
    if (json['schemaVersion'] != 1 ||
        json['dataset'] != 'for-you' ||
        capturedAt == null ||
        !capturedAt.isUtc ||
        rawEvents is! List ||
        rawEvents.length > 20 ||
        rawGames is! List ||
        rawGames.length > 240 ||
        rawLiveIds is! List) {
      throw const FormatException('Invalid public For You projection');
    }
    final broadcasts = <GroupBroadcast>[];
    final eventIds = <String>{};
    for (final raw in rawEvents) {
      if (raw is! Map ||
          raw['id'] is! String ||
          (raw['id'] as String).isEmpty ||
          raw['id'] != (raw['id'] as String).trim() ||
          !eventIds.add(raw['id'] as String)) {
        throw const FormatException('Invalid public For You event identity');
      }
      broadcasts.add(GroupBroadcast.fromJson(Map<String, dynamic>.from(raw)));
    }
    final liveIds = <String>[];
    for (final id in rawLiveIds) {
      if (id is! String || !eventIds.contains(id) || liveIds.contains(id)) {
        throw const FormatException('Invalid strict-live event provenance');
      }
      liveIds.add(id);
    }
    final gamesByEvent = <String, List<Games>>{};
    final eventsWithUnresolvedPositions = <String>{};
    for (final raw in rawGames) {
      if (raw is! Map ||
          raw.containsKey('pgn') ||
          raw['event_id'] is! String ||
          !eventIds.contains(raw['event_id'])) {
        throw const FormatException('Invalid public For You game membership');
      }
      final fen = raw['fen']?.toString() ?? '';
      if (fen.isEmpty) {
        eventsWithUnresolvedPositions.add(raw['event_id'] as String);
      }
      if (fen.isNotEmpty && !isValidGameFen(fen)) {
        throw const FormatException('Invalid public For You position');
      }
      gamesByEvent
          .putIfAbsent(raw['event_id'] as String, () => [])
          .add(Games.fromJson(Map<String, dynamic>.from(raw)));
    }
    final events = [
      for (final broadcast in broadcasts)
        GroupEventCardModel.fromGroupBroadcast(broadcast, liveIds),
    ]..sort(compareGroupEventsByRating);
    final artwork = <String, EventImageData>{};
    final rawArtwork = json['artwork'];
    if (rawArtwork != null && rawArtwork is! Map) {
      throw const FormatException('Invalid public event artwork');
    }
    for (final entry in (rawArtwork as Map? ?? const {}).entries) {
      final raw = entry.value;
      if (!eventIds.contains(entry.key) || raw is! Map) {
        throw const FormatException('Invalid public artwork membership');
      }
      final image = raw['imageUrl'] as String?;
      if (image != null && image.isNotEmpty) {
        final uri = Uri.tryParse(image);
        if (uri == null ||
            !const {'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('Invalid public event image URL');
        }
      }
      final count = raw['playerCount'];
      if (count != null && (count is! int || count < 0)) {
        throw const FormatException('Invalid public event player count');
      }
      final location = raw['location'] as String?;
      final federation = raw['dominantFederation'] as String?;
      artwork[entry.key as String] = EventImageData(
        imageUrl: image,
        fallbackCountryCode:
            image != null && image.isNotEmpty
                ? null
                : extractCountryFromLocation(location) ??
                    countryCodeFromEventFederation(federation),
        location: location,
        playerCount: count as int? ?? 0,
      );
    }
    final nextRounds = <String, NextRoundInfo>{};
    final rawRounds = json['nextRounds'];
    if (rawRounds != null && rawRounds is! Map) {
      throw const FormatException('Invalid public round metadata');
    }
    for (final entry in (rawRounds as Map? ?? const {}).entries) {
      final raw = entry.value;
      if (!eventIds.contains(entry.key) ||
          raw is! Map ||
          raw['name'] is! String) {
        throw const FormatException('Invalid public round membership');
      }
      final startsAt = DateTime.tryParse(raw['startsAt']?.toString() ?? '');
      if (startsAt == null || !startsAt.isAfter(capturedAt)) {
        throw const FormatException('Invalid public next-round timestamp');
      }
      nextRounds[entry.key as String] = NextRoundInfo(
        name: raw['name'] as String,
        startsAt: startsAt.toLocal(),
      );
    }
    return PublicEventsPreview(
      presentation: SignedOutEventsPresentationData(
        capturedAt: capturedAt,
        forYouEvents: AsyncValue.data(events),
        snapshots: {
          for (final event in events)
            if (!eventsWithUnresolvedPositions.contains(event.id))
              event.id: buildForYouTopGamesSnapshot(
                eventId: event.id,
                games: gamesByEvent[event.id] ?? const [],
                maxGames: kDesktopForYouGamesPerEvent,
              ),
        },
        artwork: artwork,
        nextRounds: nextRounds,
      ),
    );
  }
}
