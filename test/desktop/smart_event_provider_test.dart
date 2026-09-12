import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/widgets/smart_event/desktop_smart_event_shelf.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/repository/favorites/models/favorite_event.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/smart_event/smart_aggregate_event_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

PlayerCard _player(String name, int rating) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: '',
    rating: rating,
    countryCode: 'USA',
    team: null,
  );
}

GamesTourModel _game({
  String id = 'game-1',
  required int whiteRating,
  required int blackRating,
  DateTime? lastMoveTime,
  DateTime? gameDay,
  int? boardNr,
  GameStatus status = GameStatus.ongoing,
}) {
  return GamesTourModel(
    gameId: id,
    whitePlayer: _player('White', whiteRating),
    blackPlayer: _player('Black', blackRating),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: 'round-1',
    tourId: 'tour-1',
    lastMoveTime: lastMoveTime,
    gameDay: gameDay,
    boardNr: boardNr,
  );
}

GroupEventCardModel _event(String id) {
  return GroupEventCardModel(
    id: id,
    title: 'Event $id',
    dates: 'Jun 1 - 2, 2026',
    maxAvgElo: 2600,
    timeUntilStart: '',
    tourEventCategory: TourEventCategory.ongoing,
    timeControl: 'Standard',
    startDate: DateTime.utc(2026, 6, 1),
    endDate: DateTime.utc(2026, 6, 2),
  );
}

SmartEventRequest _request({
  int minElo = 2500,
  int maxElo = 3200,
  Set<String> formatsAndStates = const {},
  GameEcoFilter? eco,
  List<GroupEventCardModel> events = const [],
  SmartEventSource source = SmartEventSource.forYou,
}) {
  return SmartEventRequest(
    source: source,
    tierLabel: 'GM',
    titleSuffix: 'Games',
    minElo: minElo,
    maxElo: maxElo,
    caption: 'From your $minElo+ filter',
    countSingular: 'event',
    countPlural: 'events',
    events: events,
    formatsAndStates: formatsAndStates,
    eco: eco,
  );
}

Map<String, dynamic> _row({
  required String id,
  required String eventId,
  required String eventName,
  required Map<String, dynamic> metadata,
}) {
  return {
    'id': id,
    'user_id': 'user-1',
    'event_id': eventId,
    'event_name': eventName,
    'metadata': metadata,
    'created_at': '2026-06-03T00:00:00.000Z',
    'updated_at': '2026-06-03T00:00:00.000Z',
  };
}

/// In-memory `user_favorite_events` with the table's unique
/// `(user_id, event_id)` constraint, plus failure injection.
class _FavoriteTable {
  _FavoriteTable(List<Map<String, dynamic>> rows)
    : rows = [for (final row in rows) Map<String, dynamic>.from(row)];

  final List<Map<String, dynamic>> rows;
  Object? failUpdates;
  Object? failDeletes;
  int updates = 0;
  int upserts = 0;
  int deletes = 0;
  var _nextId = 100;

  Map<String, dynamic>? byEventId(String eventId) {
    for (final row in rows) {
      if (row['event_id'] == eventId) return row;
    }
    return null;
  }
}

class _FakeFavorites extends FavoriteEventsNotifier {
  _FakeFavorites(this.table);

  final _FavoriteTable table;

  @override
  Future<List<FavoriteEvent>> build() async =>
      table.rows.map(FavoriteEvent.fromSupabase).toList();

  @override
  String? currentUserIdForWrites() => 'user-1';

  @override
  Future<void> cacheFavoriteEventsLocally(
    List<FavoriteEvent> events,
    String? userId,
  ) async {}

  @override
  Future<List<Map<String, dynamic>>> updateFavoriteRowRemote({
    required String userId,
    required String matchEventId,
    required Map<String, dynamic> values,
  }) async {
    table.updates++;
    final failure = table.failUpdates;
    if (failure != null) throw failure;
    final matched = table.byEventId(matchEventId);
    if (matched == null) return const [];
    final newEventId = values['event_id'] as String?;
    if (newEventId != null && newEventId != matchEventId) {
      if (table.byEventId(newEventId) != null) {
        throw StateError('duplicate key value violates unique constraint');
      }
    }
    matched.addAll(values);
    return [Map<String, dynamic>.from(matched)];
  }

  @override
  Future<Map<String, dynamic>> upsertFavoriteRowRemote(
    Map<String, dynamic> values,
  ) async {
    table.upserts++;
    final existing = table.byEventId(values['event_id'] as String);
    if (existing != null) {
      existing.addAll(values);
      return Map<String, dynamic>.from(existing);
    }
    final row = _row(
      id: 'row-${table._nextId++}',
      eventId: values['event_id'] as String,
      eventName: values['event_name'] as String,
      metadata: Map<String, dynamic>.from(values['metadata'] as Map),
    );
    table.rows.add(row);
    return Map<String, dynamic>.from(row);
  }

  @override
  Future<void> deleteFavoriteRowRemote({
    required String userId,
    required String eventId,
  }) async {
    table.deletes++;
    final failure = table.failDeletes;
    if (failure != null) throw failure;
    table.rows.removeWhere((row) => row['event_id'] == eventId);
  }
}

class _EmptyDaysRepository implements GameRepository {
  int dayReads = 0;
  final DateTime newestDay = DateTime(2026, 9, 10);

  @override
  Future<DateTime?> getCurrentSmartEventDay({
    bool liveOnly = false,
    bool requiresMove = false,
    bool completedOnly = false,
    int? minGameAverageElo,
    DateTime? before,
    String? searchQuery,
    GameFilter? extraFilter,
  }) async => newestDay;

  @override
  Future<CurrentSmartEventDayPage> getCurrentSmartEventGamesOnDay({
    required DateTime day,
    bool liveOnly = false,
    bool requiresMove = false,
    bool completedOnly = false,
    int? minGameAverageElo,
    int? maxGameAverageElo,
    List<String>? eventTimeControls,
    String? searchQuery,
    GameFilter? extraFilter,
    bool withBroadcastIdentity = false,
  }) async {
    dayReads++;
    // Every day survives the probe but is emptied by narrowing, forever.
    return CurrentSmartEventDayPage(
      day: day,
      games: const [],
      nextDay: day.subtract(const Duration(days: 1)),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected repository call: $invocation');
}

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('criteria.key is byte-stable', () {
    test('pre-ECO keys are unchanged when the opening is "all"', () {
      expect(_request().criteriaKey, '2500-3200:');
      expect(
        _request(formatsAndStates: {'blitz'}).criteriaKey,
        '2500-3200:blitz',
      );
      // Tokens are sorted, trimmed and lower-cased; order of entry is not
      // identity.
      expect(
        _request(formatsAndStates: {' Live', 'blitz'}).criteriaKey,
        '2500-3200:blitz|live',
      );
      expect(
        _request(formatsAndStates: {'blitz', 'live'}).criteriaKey,
        _request(formatsAndStates: {'live', 'blitz'}).criteriaKey,
      );
    });

    test('an ECO suffix is appended only when an opening is set', () {
      expect(
        _request(eco: GameEcoFilter.forCode('B90')).criteriaKey,
        '2500-3200::eco=B90',
      );
      expect(
        _request(
          formatsAndStates: {'rapid'},
          eco: GameEcoFilter.forCode('b90'),
        ).criteriaKey,
        '2500-3200:rapid:eco=B90',
      );
    });

    test('derived identities hang off the criteria key only', () {
      final forYou = _request(events: [_event('a')]);
      final current = _request(
        source: SmartEventSource.current,
        events: [_event('a'), _event('b')],
      );
      expect(forYou.scopeId, forYou.criteriaKey);
      expect(forYou.cardDismissKey, 'smart_event_card:2500-3200:');
      expect(forYou.favoriteEventId, 'smart_event:v2:2500-3200:');
      expect(current.cardDismissKey, forYou.cardDismissKey);
      expect(current.favoriteEventId, forYou.favoriteEventId);
    });
  });

  group('rating is the game-level two-player average', () {
    // Pinned because it has flipped between average and strongest player
    // twice, and each flip shipped as a user-visible bug.
    test('uses the individual game average, not the event average', () {
      expect(
        smartGameAverageElo(_game(whiteRating: 2600, blackRating: 2400)),
        2500,
      );
      expect(
        smartGameAverageElo(_game(whiteRating: 2591, blackRating: 2371)),
        2481,
      );
      expect(
        smartGameAverageElo(_game(whiteRating: 2600, blackRating: 0)),
        2600,
      );
    });

    test('GM excludes strong-player boards whose average is below 2500', () {
      for (final game in [
        _game(id: 'gm-1', whiteRating: 2591, blackRating: 2371),
        _game(id: 'gm-2', whiteRating: 2521, blackRating: 2440),
      ]) {
        expect(smartGameMatchesTier(game, 'GM'), isFalse);
        expect(
          matchesSmartEventAverageEloForTest(
            game,
            minAverageElo: 2500,
            maxAverageElo: GameFilter.absoluteMaxRating,
          ),
          isFalse,
        );
      }
    });

    test('an average exactly on the floor is included', () {
      final onFloor = _game(whiteRating: 2560, blackRating: 2440);
      expect(smartGameMatchesTier(onFloor, 'GM'), isTrue);
    });

    test('an unrated board never satisfies an active floor', () {
      final unrated = _game(whiteRating: 0, blackRating: 0);
      expect(smartGameMatchesTier(unrated, 'CM'), isFalse);
      expect(
        matchesSmartEventAverageEloForTest(
          unrated,
          minAverageElo: 2200,
          maxAverageElo: GameFilter.absoluteMaxRating,
        ),
        isFalse,
      );
      expect(
        matchesSmartEventAverageEloForTest(
          unrated,
          minAverageElo: GameFilter.defaultMinRating,
          maxAverageElo: GameFilter.absoluteMaxRating,
        ),
        isTrue,
      );
    });
  });

  group('rating tiers are open-ended floors', () {
    test('a 3250-average board is included in GM', () {
      final superGm = _game(whiteRating: 3250, blackRating: 3250);
      expect(smartGameAverageElo(superGm), 3250);
      expect(smartGameMatchesTier(superGm, 'GM'), isTrue);

      final scope = smartEventFetchScopeFor(
        SmartEventGamesQuery(request: _request(minElo: 2500, maxElo: 3200)),
      );
      // kFilterMaxElo (3200) is a UI bound, never a cap.
      expect(scope.minGameAverageElo, 2500);
      expect(scope.maxGameAverageElo, isNull);
      expect(
        matchesSmartEventAverageEloForTest(
          superGm,
          minAverageElo: scope.minGameAverageElo!,
          maxAverageElo:
              scope.maxGameAverageElo ?? GameFilter.absoluteMaxRating,
        ),
        isTrue,
      );
    });

    test('every tier re-keys to its floor without a ceiling', () {
      for (final entry
          in {'GM': 2500, 'IM': 2400, 'FM': 2300, 'CM': 2200}.entries) {
        final request = _request(minElo: 0).withTierSelection(entry.key);
        expect(request.minElo, entry.value);
        final scope = smartEventFetchScopeFor(
          SmartEventGamesQuery(request: request),
        );
        expect(scope.minGameAverageElo, entry.value, reason: entry.key);
        expect(scope.maxGameAverageElo, isNull, reason: entry.key);
      }
    });

    test('time controls resolve both spellings for the tour-id lookup', () {
      final scope = smartEventFetchScopeFor(
        SmartEventGamesQuery(
          request: _request(minElo: 0, formatsAndStates: {'standard'}),
        ),
      );
      expect(
        scope.eventTimeControls,
        containsAll(<String>['standard', 'classical', 'Standard', 'Classical']),
      );
    });
  });

  group('whole-day pagination', () {
    test('skipping days emptied by narrowing stops after 12', () async {
      final repository = _EmptyDaysRepository();
      final container = ProviderContainer(
        overrides: [gameRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final query = SmartEventGamesQuery(request: _request());
      final subscription = container.listen(
        smartAggregateEventRepositoryProvider(query),
        (_, __) {},
      );
      addTearDown(subscription.close);

      await _settle();

      final state = container.read(
        smartAggregateEventRepositoryProvider(query),
      );
      // The newest day plus at most 12 skipped days, then an honest empty.
      expect(repository.dayReads, 13);
      expect(state.valueOrNull?.games, isEmpty);
      expect(state.valueOrNull?.hasMore, isFalse);
    });

    test('merging an older day dedups by gameId and keeps newest rows', () {
      final newer = SmartAggregateEvent.empty.copyWith(
        games: [
          _game(id: 'a', whiteRating: 2700, blackRating: 2700),
          _game(id: 'b', whiteRating: 2600, blackRating: 2600),
        ],
        events: [_event('e1')],
        gameEventIds: {'a': 'e1', 'b': 'e1'},
        gameEventNames: {'a': 'Event e1', 'b': 'Event e1'},
      );
      final older = SmartAggregateEvent.empty.copyWith(
        games: [
          _game(id: 'b', whiteRating: 2100, blackRating: 2100),
          _game(id: 'c', whiteRating: 2500, blackRating: 2500),
        ],
        events: [_event('e2')],
        gameEventIds: {'b': 'e2', 'c': 'e2'},
        gameEventNames: {'b': 'Event e2', 'c': 'Event e2'},
        hasMore: true,
      );

      final merged = mergeOlderSmartEventDayForTest(newer, older);

      expect(merged.games.map((game) => game.gameId), ['a', 'b', 'c']);
      expect(merged.games[1].whitePlayer.rating, 2600);
      expect(merged.tournamentCount, 2);
      expect(merged.hasMore, isTrue);
    });
  });

  group('ordering is deterministic', () {
    test('day, pinned, average Elo, top Elo, board, then id', () {
      final today = DateTime(2026, 6, 9);
      final yesterday = DateTime(2026, 6, 8);
      final sorted = sortSmartGamesForTest(
        [
          _game(
            id: 'older-high',
            whiteRating: 2800,
            blackRating: 2800,
            gameDay: yesterday,
          ),
          _game(
            id: 'today-low',
            whiteRating: 2300,
            blackRating: 2300,
            gameDay: today,
          ),
          _game(
            id: 'today-pinned',
            whiteRating: 2200,
            blackRating: 2200,
            gameDay: today,
          ),
          _game(
            id: 'today-board-2',
            whiteRating: 2600,
            blackRating: 2600,
            gameDay: today,
            boardNr: 2,
          ),
          _game(
            id: 'today-board-1',
            whiteRating: 2600,
            blackRating: 2600,
            gameDay: today,
            boardNr: 1,
          ),
        ],
        pinnedIds: const ['today-pinned'],
      );

      expect(sorted.map((game) => game.gameId), [
        'today-pinned',
        'today-board-1',
        'today-board-2',
        'today-low',
        'older-high',
      ]);
    });

    test('a game going live does not reshuffle the list', () {
      final day = DateTime(2026, 6, 9);
      List<GamesTourModel> games(GameStatus secondStatus) => [
        _game(
          id: 'x',
          whiteRating: 2650,
          blackRating: 2650,
          gameDay: day,
          status: GameStatus.whiteWins,
        ),
        _game(
          id: 'y',
          whiteRating: 2550,
          blackRating: 2550,
          gameDay: day,
          status: secondStatus,
        ),
        _game(
          id: 'z',
          whiteRating: 2450,
          blackRating: 2450,
          gameDay: day,
          status: GameStatus.draw,
        ),
      ];

      final before = sortSmartGamesForTest(
        games(GameStatus.unknown),
        pinnedIds: const [],
      ).map((game) => game.gameId);
      final after = sortSmartGamesForTest(
        games(GameStatus.ongoing),
        pinnedIds: const [],
      ).map((game) => game.gameId);

      expect(after, before);
      expect(after, ['x', 'y', 'z']);
    });
  });

  group('atomic update/rekey of a saved smart event', () {
    late _FavoriteTable table;
    late ProviderContainer container;
    late SmartEventRequest saved;

    setUp(() async {
      saved = _request(minElo: 2500);
      table = _FavoriteTable([
        _row(
          id: 'row-1',
          eventId: saved.favoriteEventId,
          eventName: saved.displayName,
          metadata: {
            ...saved.toFavoriteMetadata(),
            'notificationsEnabled': true,
            'hiddenTournaments': ['tour-9'],
            'pinnedBy': 'user',
          },
        ),
      ]);
      container = ProviderContainer(
        overrides: [
          favoriteEventsProvider.overrideWith(() => _FakeFavorites(table)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(favoriteEventsProvider.future);
    });

    FavoriteEvent savedRow() =>
        container.read(smartEventSavedFavoriteProvider(saved.criteriaKey))!;

    test('one UPDATE re-keys the row and keeps user-owned metadata', () async {
      final updated = saved.withCriteria(formatsAndStates: {'blitz'});

      await persistSmartEventCriteriaChange(
        notifier: container.read(favoriteEventsProvider.notifier),
        savedFavorite: savedRow(),
        updated: updated,
      );

      expect(table.updates, 1);
      expect(table.upserts, 0);
      expect(table.deletes, 0);
      expect(table.rows, hasLength(1));
      final row = table.rows.single;
      expect(row['id'], 'row-1', reason: 'rewritten in place, not re-created');
      expect(row['event_id'], updated.favoriteEventId);
      final metadata = row['metadata'] as Map<String, dynamic>;
      expect(metadata['notificationsEnabled'], isTrue);
      expect(metadata['hiddenTournaments'], ['tour-9']);
      expect(metadata['pinnedBy'], 'user');
      expect(metadata['formatsAndStates'], ['blitz']);

      final state = container.read(favoriteEventsProvider).requireValue;
      expect(state.single.eventId, updated.favoriteEventId);
      expect(
        container.read(smartEventSavedFavoriteProvider(updated.criteriaKey)),
        isNotNull,
      );
    });

    test('clearing an opening drops the stale ECO criteria', () async {
      final withOpening = saved.withCriteria(eco: GameEcoFilter.forCode('B90'));
      final notifier = container.read(favoriteEventsProvider.notifier);
      await persistSmartEventCriteriaChange(
        notifier: notifier,
        savedFavorite: savedRow(),
        updated: withOpening,
      );
      final openingRow =
          container.read(
            smartEventSavedFavoriteProvider(withOpening.criteriaKey),
          )!;
      expect(openingRow.metadata['ecoCode'], 'B90');

      final cleared = withOpening.withCriteria(eco: GameEcoFilter.all);
      await persistSmartEventCriteriaChange(
        notifier: notifier,
        savedFavorite: openingRow,
        updated: cleared,
      );

      final metadata = table.rows.single['metadata'] as Map<String, dynamic>;
      expect(metadata.containsKey('ecoCode'), isFalse);
      expect(metadata.containsKey('openingContext'), isFalse);
      expect(metadata['notificationsEnabled'], isTrue);
    });

    test('a failed write leaves the row and the baseline intact', () async {
      final updated = saved.withCriteria(formatsAndStates: {'rapid'});
      final original = Map<String, dynamic>.from(table.rows.single);
      final originalMetadata = Map<String, dynamic>.from(
        original['metadata'] as Map,
      );
      table.failUpdates = StateError('JWT expired');

      // The pane's contract: the saved baseline advances only after the
      // write returns.
      var tab = DesktopSmartEventTabState(
        request: updated,
        savedCriteriaKey: saved.criteriaKey,
      );
      await expectLater(() async {
        await persistSmartEventCriteriaChange(
          notifier: container.read(favoriteEventsProvider.notifier),
          savedFavorite: savedRow(),
          updated: updated,
        );
        tab = tab.attachedTo(updated.criteriaKey);
      }(), throwsA(isA<StateError>()));

      expect(table.rows, hasLength(1), reason: 'nothing was deleted');
      expect(table.rows.single['event_id'], original['event_id']);
      expect(table.rows.single['metadata'], originalMetadata);
      expect(table.deletes, 0);
      final state = container.read(favoriteEventsProvider).requireValue;
      expect(state.single.eventId, saved.favoriteEventId);
      expect(tab.savedCriteriaKey, saved.criteriaKey);
      expect(tab.hasUnsavedCriteria, isTrue);
    });

    test('with no existing row it falls back to one insert', () async {
      table.rows.clear();
      await container
          .read(favoriteEventsProvider.notifier)
          .rekeyFavorite(
            previousEventId: 'smart_event:v2:missing',
            eventId: saved.favoriteEventId,
            eventName: saved.displayName,
            buildMetadata:
                (existing) => mergeSmartFavoriteMetadata(
                  existing: existing,
                  criteria: saved,
                ),
          );
      expect(table.upserts, 1);
      expect(table.rows.single['event_id'], saved.favoriteEventId);
    });

    test(
      're-keying onto a surviving row writes it, then retires the source',
      () async {
        final target = saved.withCriteria(formatsAndStates: {'blitz'});
        table.rows.add(
          _row(
            id: 'row-2',
            eventId: target.favoriteEventId,
            eventName: target.displayName,
            metadata: {...target.toFavoriteMetadata(), 'caption': 'stale'},
          ),
        );
        container.invalidate(favoriteEventsProvider);
        await container.read(favoriteEventsProvider.future);

        await persistSmartEventCriteriaChange(
          notifier: container.read(favoriteEventsProvider.notifier),
          savedFavorite: savedRow(),
          updated: target,
        );

        expect(table.rows, hasLength(1));
        final row = table.rows.single;
        expect(row['id'], 'row-2');
        final metadata = row['metadata'] as Map<String, dynamic>;
        expect(
          metadata['caption'],
          target.caption,
          reason: 'not a silent no-op',
        );
        expect(metadata['notificationsEnabled'], isTrue);
        expect(metadata['hiddenTournaments'], ['tour-9']);
      },
    );

    test(
      'if retiring the source fails, the duplicate is kept, never lost',
      () async {
        final target = saved.withCriteria(formatsAndStates: {'blitz'});
        table.rows.add(
          _row(
            id: 'row-2',
            eventId: target.favoriteEventId,
            eventName: target.displayName,
            metadata: target.toFavoriteMetadata(),
          ),
        );
        container.invalidate(favoriteEventsProvider);
        await container.read(favoriteEventsProvider.future);
        table.failDeletes = StateError('network down');

        await persistSmartEventCriteriaChange(
          notifier: container.read(favoriteEventsProvider.notifier),
          savedFavorite: savedRow(),
          updated: target,
        );

        expect(table.rows, hasLength(2));
        final state = container.read(favoriteEventsProvider).requireValue;
        expect(
          state.map((row) => row.eventId),
          containsAll([saved.favoriteEventId, target.favoriteEventId]),
        );
      },
    );
  });

  group('legacy identity compatibility', () {
    Map<String, dynamic> legacyMetadata({bool withFormats = true}) => {
      'type': 'smart_event',
      'source': 'forYou',
      'tierLabel': 'GM Blitz',
      'titleSuffix': 'Games',
      'minElo': 2500,
      'maxElo': 3200,
      'caption': 'From your 2500+ Blitz filter',
      'countSingular': 'event',
      'countPlural': 'events',
      if (withFormats) 'formatsAndStates': ['blitz'],
      'events': const <Map<String, dynamic>>[],
    };

    test('a smart favourite is recognised by type OR id prefix', () {
      FavoriteEvent favorite(String eventId, Map<String, dynamic> metadata) =>
          FavoriteEvent.fromSupabase(
            _row(
              id: 'r',
              eventId: eventId,
              eventName: 'GM Games',
              metadata: metadata,
            ),
          );
      expect(
        isSmartFavoriteEvent(favorite('abc', {'type': 'smart_event'})),
        isTrue,
      );
      expect(
        isSmartFavoriteEvent(favorite('smart_event:forYou:x', {})),
        isTrue,
      );
      expect(isSmartFavoriteEvent(favorite('broadcast-1', {})), isFalse);
    });

    test(
      'v1 and v2 rows of the same criteria resolve to the same saved favourite',
      () async {
        final v2Key = _request(formatsAndStates: {'blitz'}).criteriaKey;
        for (final eventId in [
          'smart_event:forYou:2500-3200:event-a',
          'smart_event:v2:$v2Key',
        ]) {
          final container = ProviderContainer(
            overrides: [
              favoriteEventsProvider.overrideWith(
                () => _FakeFavorites(
                  _FavoriteTable([
                    _row(
                      id: 'row-1',
                      eventId: eventId,
                      eventName: 'GM Blitz Games',
                      metadata: legacyMetadata(),
                    ),
                  ]),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);
          await container.read(favoriteEventsProvider.future);
          final match = container.read(smartEventSavedFavoriteProvider(v2Key));
          expect(match?.eventId, eventId);
        }
      },
    );

    test(
      'a legacy row without formatsAndStates recovers tokens from its label',
      () {
        FavoriteEvent row(String tierLabel) => FavoriteEvent.fromSupabase(
          _row(
            id: 'row-1',
            eventId: 'smart_event:forYou:2500-3200:event-a',
            eventName: '$tierLabel Games',
            metadata: {
              ...legacyMetadata(withFormats: false),
              'tierLabel': tierLabel,
            },
          ),
        );
        expect(
          SmartEventRequest.fromFavoriteEvent(row('GM Blitz')).formatsAndStates,
          {'blitz'},
        );
        expect(
          SmartEventRequest.fromFavoriteEvent(
            row('Classical'),
          ).formatsAndStates,
          {'standard'},
        );
        expect(
          SmartEventRequest.fromFavoriteEvent(row('GM Blitz')).criteriaKey,
          _request(formatsAndStates: {'blitz'}).criteriaKey,
        );
      },
    );

    test('legacy labels heal on restore', () {
      final restored = SmartEventRequest.fromFavoriteEvent(
        FavoriteEvent.fromSupabase(
          _row(
            id: 'row-1',
            eventId: 'smart_event:forYou:2500-3200:event-a',
            eventName: 'GM Games',
            metadata: {
              'type': 'smart_event',
              'titleSuffix': 'Live Games',
              'minElo': 2500,
              'maxElo': 3200,
              'caption': 'Saved smart event',
              'countSingular': 'live event',
              'countPlural': 'live events',
            },
          ),
        ),
      );
      expect(restored.tierLabel, 'GM');
      expect(restored.titleSuffix, 'Games');
      expect(restored.caption, 'From your 2500+ filter');
      expect(restored.countSingular, 'event');
      expect(restored.countPlural, 'events');
    });

    test(
      'refresh migrates v1 to v2 atomically and collapses duplicates',
      () async {
        final request = _request(formatsAndStates: {'blitz'});
        final table = _FavoriteTable([
          _row(
            id: 'row-v1',
            eventId: 'smart_event:forYou:2500-3200:event-a',
            eventName: 'GM Blitz Games',
            metadata: {
              ...legacyMetadata(),
              'notificationsEnabled': true,
              'hiddenTournaments': ['tour-3'],
            },
          ),
          _row(
            id: 'row-v2',
            eventId: request.favoriteEventId,
            eventName: request.displayName,
            metadata: request.toFavoriteMetadata(),
          ),
        ]);
        final resolved = [_event('fresh')];
        final container = ProviderContainer(
          overrides: [
            favoriteEventsProvider.overrideWith(() => _FakeFavorites(table)),
            smartEventResolvedEventsProvider.overrideWith(
              (ref, criteria) async => resolved,
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(favoriteEventsProvider.future);
        final subscription = container.listen(
          savedSmartEventSyncProvider(request.criteriaKey),
          (_, __) {},
        );
        addTearDown(subscription.close);

        await _settle();

        expect(
          table.rows,
          hasLength(1),
          reason: 'duplicates collapse to one v2 row',
        );
        final row = table.rows.single;
        expect(row['event_id'], request.favoriteEventId);
        final metadata = row['metadata'] as Map<String, dynamic>;
        expect(metadata['notificationsEnabled'], isTrue);
        expect(metadata['hiddenTournaments'], ['tour-3']);
      },
    );
  });

  group('For You smart cards', () {
    test(
      'a visible generated card replaces the saved card of the same criteria',
      () {
        final generated = SmartEventCardData(
          request: _request(formatsAndStates: {'blitz'}),
          eventCount: 3,
          avgElo: 2600,
        );
        final cards = selectDesktopSmartEventCards(
          generated: generated,
          dismissedKeys: const {},
          savedRequests: [
            _request(formatsAndStates: {'blitz'}),
            _request(formatsAndStates: {'rapid'}),
          ],
        );
        expect(cards.generated, same(generated));
        expect(cards.saved.map((request) => request.criteriaKey), [
          _request(formatsAndStates: {'rapid'}).criteriaKey,
        ]);
      },
    );

    test(
      'dismissal is keyed on criteria, and a dismissed card frees its saved twin',
      () {
        final generated = SmartEventCardData(
          request: _request(
            source: SmartEventSource.current,
            formatsAndStates: {'blitz'},
          ),
          eventCount: 3,
          avgElo: 2600,
        );
        final dismissedFromOtherTab =
            _request(formatsAndStates: {'blitz'}).cardDismissKey;
        final cards = selectDesktopSmartEventCards(
          generated: generated,
          dismissedKeys: {dismissedFromOtherTab},
          savedRequests: [
            _request(formatsAndStates: {'blitz'}),
          ],
        );
        expect(cards.generated, isNull);
        expect(cards.saved, hasLength(1));
      },
    );

    test('legacy duplicates of one criteria render a single saved card', () {
      final cards = selectDesktopSmartEventCards(
        generated: null,
        dismissedKeys: const {},
        savedRequests: [
          _request(),
          _request(events: [_event('x')]),
        ],
      );
      expect(cards.saved, hasLength(1));
    });
  });

  group('opening navigation seam', () {
    test('only exact ECO codes are accepted, upper-cased', () {
      expect(normalizeSmartEventOpeningCode(' b90 '), 'B90');
      expect(normalizeSmartEventOpeningCode('E99'), 'E99');
      for (final rejected in ['B9', 'F00', 'B900', 'B9x', '', 'B20-B99']) {
        expect(
          normalizeSmartEventOpeningCode(rejected),
          isNull,
          reason: rejected,
        );
      }
    });

    test('an opening code opens the global opening smart event', () {
      final request = SmartEventRequest.forOpening(
        GameEcoFilter.forCode(normalizeSmartEventOpeningCode('b90')!),
      );
      expect(request.eco.code, 'B90');
      expect(request.events, isEmpty);
      expect(request.criteriaKey, '0-3200::eco=B90');
    });
  });
}
