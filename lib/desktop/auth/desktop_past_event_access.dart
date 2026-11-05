import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/group_event/providers/group_event_screen_provider.dart';
import 'package:chessever/screens/group_event/providers/live_group_broadcast_id_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// The phone gates opening an archived event, not browsing the Past list.
/// Native editions retain their existing discovery policy.
final desktopPastEventAccessEnabledProvider = Provider<bool>((_) => kIsWeb);

abstract interface class DesktopEventAccessLookup {
  Future<bool?> isPast(String eventId);
  Future<bool?> isCurrent(String eventId);
  Future<GroupBroadcast?> broadcast(String eventOrTourId);
  Future<GroupBroadcast?> broadcastBySlug(String slug);
}

final desktopEventAccessLookupProvider = Provider<DesktopEventAccessLookup>(
  (ref) =>
      _SupabaseEventAccessLookup(ref.read(groupBroadcastRepositoryProvider)),
);

class _SupabaseEventAccessLookup implements DesktopEventAccessLookup {
  _SupabaseEventAccessLookup(this.repository);
  final GroupBroadcastRepository repository;

  Future<bool?> _member(String view, String eventId) async {
    try {
      final rows = await Supabase.instance.client
          .from(view)
          .select('id')
          .eq('id', eventId)
          .limit(1);
      return rows.isNotEmpty;
    } catch (_) {
      // An unavailable lookup is not proof that a current event is past.
      return null;
    }
  }

  @override
  Future<bool?> isPast(String eventId) =>
      _member('group_broadcasts_past', eventId);

  @override
  Future<bool?> isCurrent(String eventId) =>
      _member('group_broadcasts_current', eventId);

  @override
  Future<GroupBroadcast?> broadcast(String eventOrTourId) async {
    try {
      return await repository.getGroupBroadcastById(eventOrTourId);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<GroupBroadcast?> broadcastBySlug(String slug) async {
    final value = slug.trim();
    if (value.isEmpty) return null;
    try {
      final client = Supabase.instance.client;
      final tours = await client
          .from('tours')
          .select('id')
          .eq('slug', value)
          .limit(1);
      if (tours.isNotEmpty) return await broadcast(tours.first['id'] as String);
      final targets = _broadcastIdentityVariants(value);
      if (targets.isEmpty) return null;
      for (final id in {value, ...targets.map((s) => s.replaceAll('-', '_'))}) {
        final rows = await client
            .from('group_broadcasts')
            .select()
            .eq('id', id)
            .limit(1);
        if (rows.isNotEmpty) return GroupBroadcast.fromJson(rows.first);
      }
      final tokens =
          targets.first
              .split('-')
              .where((token) => token.length > 2 && int.tryParse(token) == null)
              .take(3)
              .toList();
      if (tokens.length < 2) return null;
      final rows = await client
          .from('group_broadcasts')
          .select()
          .ilike('name', '%${tokens.join('%')}%')
          .limit(80);
      for (final row in rows) {
        if ([row['id'], row['name']].whereType<String>().any(
          (value) => _broadcastIdentityVariants(value).any(targets.contains),
        )) {
          return GroupBroadcast.fromJson(row);
        }
      }
    } catch (_) {
      // Database events may have no matching broadcast.
    }
    return null;
  }
}

Set<String> _broadcastIdentityVariants(String value) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (normalized.isEmpty) return const {};
  final tokens = normalized.split('-');
  String numbers(bool padded) => tokens
      .map((token) {
        final number = int.tryParse(token);
        if (number == null ||
            number >= (padded ? 10 : 100) ||
            (padded && number <= 0)) {
          return token;
        }
        return padded ? number.toString().padLeft(2, '0') : number.toString();
      })
      .join('-');
  return {normalized, numbers(false), numbers(true)};
}

/// Same grace periods as phone `widgets/paywall/past_event_access.dart`.
bool desktopEventWindowIsPast({
  DateTime? start,
  DateTime? end,
  required DateTime now,
}) =>
    end != null
        ? !now.isBefore(end.add(const Duration(days: 1)))
        : start != null && now.isAfter(start.add(const Duration(days: 7)));

typedef DesktopEventAccessKey =
    ({String id, DateTime? start, DateTime? end, bool fromPastList});

const desktopPastEventOpenContext = DesktopAccessContext(
  feature: DesktopFeature.eventDiscovery,
  action: DesktopAction.openContent,
  origin: DesktopDiscoveryOrigin.broadcast,
);

/// Authoritative Past membership wins, even over stale live snapshots. For
/// date-derived archives, live and Current membership preserve free access.
Future<bool> resolveDesktopEventIsPast({
  required DesktopEventAccessLookup lookup,
  required DesktopEventAccessKey event,
  required Iterable<String> liveIds,
  required DateTime now,
}) async {
  if (await lookup.isPast(event.id) == true) return true;
  if (liveIds.contains(event.id)) return false;
  var start = event.start;
  var end = event.end;
  if (!event.fromPastList && (start == null || end == null)) {
    final canonical = await lookup.broadcast(event.id);
    start ??= canonical?.dateStart;
    end ??= canonical?.dateEnd;
  }
  if (!event.fromPastList &&
      !desktopEventWindowIsPast(start: start, end: end, now: now)) {
    return false;
  }
  return await lookup.isCurrent(event.id) == false;
}

final desktopEventIsPastProvider = FutureProvider.autoDispose
    .family<bool, DesktopEventAccessKey>((ref, event) async {
      if (!ref.watch(desktopPastEventAccessEnabledProvider)) return false;
      final live =
          ref.watch(liveGroupBroadcastIdsProvider).valueOrNull ??
          ref.watch(liveBroadcastIdsProvider) ??
          const <String>[];
      return resolveDesktopEventIsPast(
        lookup: ref.read(desktopEventAccessLookupProvider),
        event: event,
        liveIds: live,
        now: DateTime.now(),
      );
    });

Future<bool> requireDesktopPastEventAccess(
  ProviderContainer container,
  DesktopEventAccessKey event,
) async {
  if (!container.read(desktopPastEventAccessEnabledProvider)) return true;
  if (readDesktopAccess(
    container.read,
    desktopPastEventOpenContext,
  ).isAllowed) {
    return true;
  }
  final subscription = container.listen(
    desktopEventIsPastProvider(event).future,
    (_, _) {},
  );
  try {
    if (!await subscription.read()) return true;
    return await requireDesktopAction(
      container,
      desktopPastEventOpenContext,
      surface: 'past_event_open',
    );
  } finally {
    subscription.close();
  }
}

/// Source-specific gates (Favorites, Countrymen, Miniatures, Likes and Smart
/// Events) remain intact. Ordinary event/profile/archive games are classified
/// by their own event, never by whichever event was selected previously.
bool desktopGameNeedsEventClassification(
  DesktopAccessContext access,
  GamesTourModel? game,
) =>
    !access.ownershipCovers &&
    game != null &&
    (access.isCollectionContent ||
        (game.source == GameSource.supabase ||
                game.source == GameSource.gamebase ||
                game.source == GameSource.twic) &&
            const {
              DesktopFeature.broadcast,
              DesktopFeature.eventDiscovery,
              DesktopFeature.playerProfile,
              DesktopFeature.gamebase,
              DesktopFeature.twic,
            }.contains(access.feature) &&
            const {
              DesktopDiscoveryOrigin.broadcast,
              DesktopDiscoveryOrigin.deepLink,
              DesktopDiscoveryOrigin.playerProfile,
              DesktopDiscoveryOrigin.gamebase,
              DesktopDiscoveryOrigin.twic,
            }.contains(access.origin));

Future<DesktopAccessContext> resolveDesktopGameEventAccess(
  ProviderContainer container, {
  required GamesTourModel game,
  required DesktopAccessContext access,
  String? eventBroadcastId,
}) async {
  if (!container.read(desktopPastEventAccessEnabledProvider) ||
      !desktopGameNeedsEventClassification(access, game)) {
    return access;
  }
  final subscription = container.listen(
    desktopGameIsPastProvider(desktopGameEventKey(game, access)).future,
    (_, _) {},
  );
  try {
    return desktopGameEventAccessContext(
      access,
      past: await subscription.read(),
    );
  } finally {
    subscription.close();
  }
}

/// Classification metadata only: PGN, clocks and board state cannot restart
/// the same event lookup while the deep link hands the game to its board.
typedef DesktopGameEventKey =
    ({
      String tourId,
      String? tourSlug,
      GameSource source,
      DateTime? day,
      bool collection,
    });

DesktopGameEventKey desktopGameEventKey(
  GamesTourModel game,
  DesktopAccessContext access,
) => (
  tourId: game.tourId,
  tourSlug: game.tourSlug,
  source: game.source,
  day: game.gameDay ?? game.dateStart ?? game.lastMoveTime,
  collection: access.isCollectionContent,
);

/// A bounded hand-off cache, not membership state. Expiry is checked on read
/// so this cache has no background timer and never retains lookup failures.
final _desktopGameEventCacheProvider = Provider((ref) {
  ref.watch(desktopEventAccessLookupProvider);
  return <DesktopGameEventKey, ({DateTime checkedAt, bool past})>{};
});

/// Shares the completed classification between pre-navigation admission and
/// the mounted board. A cached result is returned synchronously, avoiding a
/// second loading frame even if the router's provider was already disposed.
final desktopGameIsPastProvider = FutureProvider.autoDispose
    .family<bool, DesktopGameEventKey>((ref, game) {
      final cache = ref.watch(_desktopGameEventCacheProvider);
      final now = DateTime.now();
      cache.removeWhere(
        (_, result) =>
            now.difference(result.checkedAt) >= const Duration(minutes: 1),
      );
      final cached = cache[game];
      if (cached != null) return cached.past;
      return _resolveDesktopGameIsPast(ref, game).then((past) {
        cache[game] = (checkedAt: DateTime.now(), past: past);
        while (cache.length > 64) {
          cache.remove(cache.keys.first);
        }
        return past;
      });
    });

Future<bool> _resolveDesktopGameIsPast(
  Ref ref,
  DesktopGameEventKey game,
) async {
  final lookup = ref.watch(desktopEventAccessLookupProvider);
  // A persisted parent selection can belong to a different row of a mixed
  // list. The target game's own tour is the authority for admission.
  var broadcast = await lookup.broadcast(game.tourId);
  var resolvedByName = false;
  if (broadcast == null) {
    for (final slug in {
      if (game.tourSlug?.isNotEmpty == true) game.tourSlug!,
      game.tourId,
    }) {
      broadcast = await lookup.broadcastBySlug(slug);
      resolvedByName = slug == game.tourId;
      if (broadcast != null) break;
    }
  }
  final day = game.day;
  if (broadcast != null &&
      resolvedByName &&
      (day == null ||
          (broadcast.dateStart != null && day.isBefore(broadcast.dateStart!)) ||
          (broadcast.dateEnd != null &&
              !day.isBefore(
                broadcast.dateEnd!.add(const Duration(days: 1)),
              )))) {
    broadcast = null;
  }
  var past =
      game.collection
          ? desktopEventWindowIsPast(end: day, now: DateTime.now())
          : game.source != GameSource.supabase;
  if (broadcast != null) {
    final subscription = ref.container.listen(
      desktopEventIsPastProvider((
        id: broadcast.id,
        start: broadcast.dateStart,
        end: broadcast.dateEnd,
        fromPastList:
            broadcast.dateStart == null &&
            broadcast.dateEnd == null &&
            desktopEventWindowIsPast(end: game.day, now: DateTime.now()),
      )).future,
      (_, _) {},
    );
    try {
      past = await subscription.read();
    } finally {
      subscription.close();
    }
  }
  return past;
}

DesktopAccessContext desktopGameEventAccessContext(
  DesktopAccessContext access, {
  required bool past,
}) {
  return access.copyWith(
    feature:
        past
            ? DesktopFeature.eventDiscovery
            : access.isCollectionContent
            ? DesktopFeature.collection
            : DesktopFeature.broadcast,
    origin:
        access.isCollectionContent
            ? DesktopDiscoveryOrigin.collection
            : DesktopDiscoveryOrigin.broadcast,
  );
}
