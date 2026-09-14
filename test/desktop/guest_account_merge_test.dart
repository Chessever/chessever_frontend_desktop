import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/auth/desktop_guest_account_merger.dart';
import 'package:chessever/desktop/services/auth/guest_account_merge.dart';

const _guest = 'guest-user';
const _member = 'member-user';

class _Account {
  final players = <GuestMergeRow>[];
  final events = <GuestMergeRow>[];
  final folders = <GuestMergeRow>[];
  final analyses = <GuestMergeRow>[];
  final books = <GuestMergeRow>[];
  GuestMergeRow? engine;
  GuestMergeRow? notifications;

  GuestAccountRows rows() => GuestAccountRows(
    favoritePlayers: List.of(players),
    favoriteEvents: List.of(events),
    folders: List.of(folders),
    savedAnalyses: List.of(analyses),
    bookSubscriptions: List.of(books),
    engineSettings: engine,
    notificationPreferences: notifications,
  );
}

/// In-memory stand-in with the same conflict semantics as the Supabase
/// gateway: every write ignores rows whose conflict key already exists.
class _FakeGateway implements GuestAccountMergeGateway {
  final accounts = <String, _Account>{};
  bool failReads = false;
  bool failAfterFolders = false;
  int applyCalls = 0;

  _Account account(String id) => accounts.putIfAbsent(id, _Account.new);

  @override
  Future<GuestAccountRows> readAccountRows(String userId) async {
    if (failReads) throw const SocketException('offline');
    return account(userId).rows();
  }

  void _insert(
    List<GuestMergeRow> into,
    GuestMergeRow row,
    String Function(GuestMergeRow) key,
  ) {
    if (into.any((existing) => key(existing) == key(row))) return;
    into.add(Map.of(row));
  }

  @override
  Future<void> applyPlan(GuestMergePlan plan) async {
    applyCalls++;
    String owner(GuestMergeRow row) =>
        (row['user_id'] ?? row['subscriber_id']).toString();
    for (final row in plan.folders) {
      _insert(account(owner(row)).folders, row, (r) => '${r['id']}');
    }
    if (failAfterFolders) throw const SocketException('dropped');
    for (final row in plan.savedAnalyses) {
      _insert(account(owner(row)).analyses, row, (r) => '${r['id']}');
    }
    for (final row in plan.favoritePlayers) {
      _insert(account(owner(row)).players, row, (r) => '${r['player_name']}');
    }
    for (final row in plan.favoriteEvents) {
      _insert(account(owner(row)).events, row, (r) => '${r['event_id']}');
    }
    for (final row in plan.bookSubscriptions) {
      _insert(account(owner(row)).books, row, (r) => '${r['folder_id']}');
    }
    final engine = plan.engineSettings;
    if (engine != null) account(owner(engine)).engine ??= engine;
    final notifications = plan.notificationPreferences;
    if (notifications != null) {
      account(owner(notifications)).notifications ??= notifications;
    }
  }
}

class _MemoryStore implements GuestMergePendingStore {
  GuestAccountSnapshot? snapshot;

  @override
  Future<void> clear() async => snapshot = null;

  @override
  Future<GuestAccountSnapshot?> read() async => snapshot;

  @override
  Future<void> write(GuestAccountSnapshot value) async {
    // Round-trip through JSON like the file store does.
    snapshot = GuestAccountSnapshot.tryDecode(value.encode());
  }
}

GuestMergeRow _folder(
  String id,
  String name, {
  String? parentId,
  bool? liked,
  String? shareToken,
}) => {
  'id': id,
  'user_id': _guest,
  'name': name,
  'color': '#0FB4E5',
  'icon': 'folder',
  'order_index': 0,
  'parent_id': parentId,
  if (liked != null) 'is_liked_games': liked,
  if (shareToken != null) 'share_token': shareToken,
  'created_at': '2026-09-01T00:00:00Z',
  'updated_at': '2026-09-01T00:00:00Z',
};

GuestMergeRow _analysis(String id, String? folderId, {String? gameId}) => {
  'id': id,
  'user_id': _guest,
  'folder_id': folderId,
  'title': 'Analysis $id',
  'source_game_id': gameId,
  'chess_game': {'pgn': '1. e4 e5'},
  'is_favorite': false,
};

void _seedGuest(_FakeGateway gateway) {
  final guest = gateway.account(_guest);
  guest.folders.addAll([
    _folder('g-root', 'Openings'),
    _folder('g-child', 'Sicilian', parentId: 'g-root', shareToken: 'tok'),
  ]);
  guest.analyses.addAll([
    _analysis('g-a1', 'g-child'),
    _analysis('g-a2', 'g-child'),
  ]);
  guest.players.add({
    'user_id': _guest,
    'fide_id': '1503014',
    'player_name': 'Carlsen, Magnus',
    'metadata': null,
  });
  guest.events.add({
    'user_id': _guest,
    'event_id': 'ev-1',
    'event_name': 'Candidates',
    'metadata': null,
  });
  guest.books.add({'folder_id': 'shared-1', 'subscriber_id': _guest});
  guest.engine = {'user_id': _guest, 'selected_country_code': 'NO'};
}

DesktopGuestAccountMerger _merger(_FakeGateway gateway, _MemoryStore store) =>
    DesktopGuestAccountMerger(gateway: gateway, pendingStore: store);

void main() {
  group('guest account merge', () {
    test('running the merge twice produces one copy of each record', () async {
      final gateway = _FakeGateway();
      final store = _MemoryStore();
      _seedGuest(gateway);
      final merger = _merger(gateway, store);

      final snapshot = await merger.captureGuest(_guest);
      final first = await merger.replayPending(
        targetUserId: _member,
        targetIsExistingAccount: false,
      );
      expect(first.status, GuestMergeStatus.merged);

      // Simulate a retry of the very same snapshot (e.g. a crash before the
      // clear landed).
      await store.write(snapshot!);
      final second = await merger.replayPending(
        targetUserId: _member,
        targetIsExistingAccount: false,
      );
      expect(second.status, GuestMergeStatus.merged);
      expect(second.writeCount, 0);

      final member = gateway.account(_member);
      expect(member.folders, hasLength(2));
      expect(member.analyses, hasLength(2));
      expect(member.players, hasLength(1));
      expect(member.events, hasLength(1));
      expect(member.books, hasLength(1));
      expect(member.engine?['selected_country_code'], 'NO');
      expect(store.snapshot, isNull);

      final replan = planGuestAccountMerge(
        snapshot: snapshot,
        destination: member.rows(),
        targetUserId: _member,
      );
      expect(replan.isEmpty, isTrue);
    });

    test('keeps hierarchy and folder links under the new ids', () async {
      final gateway = _FakeGateway();
      final store = _MemoryStore();
      _seedGuest(gateway);
      final merger = _merger(gateway, store);
      await merger.captureGuest(_guest);
      await merger.replayPending(
        targetUserId: _member,
        targetIsExistingAccount: false,
      );

      final member = gateway.account(_member);
      final root = member.folders.singleWhere((f) => f['name'] == 'Openings');
      final child = member.folders.singleWhere((f) => f['name'] == 'Sicilian');
      expect(child['parent_id'], root['id']);
      expect(member.analyses.every((a) => a['folder_id'] == child['id']), isTrue);
      expect(child['user_id'], _member);
      expect(child.containsKey('share_token'), isFalse);
      expect(child.containsKey('created_at'), isFalse);
    });

    test('an over-quota result is preserved, never trimmed', () async {
      final gateway = _FakeGateway();
      final store = _MemoryStore();
      final guest = gateway.account(_guest);
      guest.folders.add(_folder('g-db', 'Prep'));
      for (var i = 0; i < 60; i++) {
        guest.analyses.add(_analysis('g-a$i', 'g-db'));
      }
      for (var i = 0; i < 30; i++) {
        guest.players.add({
          'user_id': _guest,
          'fide_id': null,
          'player_name': 'Player $i',
        });
      }
      final member = gateway.account(_member);
      for (var i = 0; i < 25; i++) {
        member.analyses.add({'id': 'm-a$i', 'user_id': _member});
      }

      final merger = _merger(gateway, store);
      await merger.captureGuest(_guest);
      final outcome = await merger.replayPending(
        targetUserId: _member,
        targetIsExistingAccount: true,
      );

      expect(outcome.status, GuestMergeStatus.merged);
      expect(member.analyses, hasLength(85));
      expect(member.players, hasLength(30));
    });

    test('a failed merge leaves the guest snapshot intact for retry', () async {
      final gateway = _FakeGateway()..failAfterFolders = true;
      final store = _MemoryStore();
      _seedGuest(gateway);
      final merger = _merger(gateway, store);
      await merger.captureGuest(_guest);

      final failed = await merger.replayPending(
        targetUserId: _member,
        targetIsExistingAccount: false,
      );
      expect(failed.status, GuestMergeStatus.failed);
      expect(failed.retryPending, isTrue);
      expect(store.snapshot?.guestUserId, _guest);
      expect(gateway.account(_guest).analyses, hasLength(2));

      gateway.failAfterFolders = false;
      final retried = await merger.replayPending(
        targetUserId: _member,
        targetIsExistingAccount: false,
      );
      expect(retried.status, GuestMergeStatus.merged);
      expect(gateway.account(_member).folders, hasLength(2));
      expect(gateway.account(_member).analyses, hasLength(2));
      expect(store.snapshot, isNull);
    });

    test('capture failure throws and keeps an earlier pending snapshot', () async {
      final gateway = _FakeGateway();
      final store = _MemoryStore();
      _seedGuest(gateway);
      final merger = _merger(gateway, store);
      await merger.captureGuest(_guest);

      gateway.failReads = true;
      await expectLater(merger.captureGuest(_guest), throwsA(isA<SocketException>()));
      expect(store.snapshot?.rows.folders, hasLength(2));
    });

    test('an in-place link keeps the rows and clears the snapshot', () async {
      final gateway = _FakeGateway();
      final store = _MemoryStore();
      _seedGuest(gateway);
      final merger = _merger(gateway, store);
      await merger.captureGuest(_guest);

      final outcome = await merger.replayPending(
        targetUserId: _guest,
        targetIsExistingAccount: false,
      );
      expect(outcome.status, GuestMergeStatus.sameAccount);
      expect(gateway.applyCalls, 0);
      expect(store.snapshot, isNull);
    });

    test('the server merge seam is unavailable and never used', () {
      const seam = UnavailableGuestAccountServerMerge();
      expect(seam.isAvailable, isFalse);
    });
  });

  group('merge planning rules', () {
    GuestAccountSnapshot snapshotOf(GuestAccountRows rows) =>
        GuestAccountSnapshot(
          guestUserId: _guest,
          capturedAt: DateTime.utc(2026, 9, 1),
          rows: rows,
        );

    test('likes are matched by flag, duplicates merged, distinct kept', () {
      final plan = planGuestAccountMerge(
        snapshot: snapshotOf(
          GuestAccountRows(
            folders: [
              _folder('g-likes', 'Hearts', liked: true),
              _folder('g-named', 'Liked Games', liked: false),
            ],
            savedAnalyses: [
              _analysis('g-l1', 'g-likes', gameId: 'game-1'),
              _analysis('g-l2', 'g-likes', gameId: 'game-2'),
            ],
          ),
        ),
        destination: GuestAccountRows(
          folders: [
            {'id': 'm-likes', 'name': 'Favourites', 'is_liked_games': true},
          ],
          savedAnalyses: [
            {'id': 'm-l1', 'folder_id': 'm-likes', 'source_game_id': 'game-1'},
          ],
        ),
        targetUserId: _member,
      );

      // The flagged guest folder maps onto the destination's; the folder that
      // only shares the display name is copied as its own document.
      expect(plan.folders, hasLength(1));
      expect(plan.folders.single['name'], 'Liked Games');
      expect(plan.savedAnalyses, hasLength(1));
      expect(plan.savedAnalyses.single['source_game_id'], 'game-2');
      expect(plan.savedAnalyses.single['folder_id'], 'm-likes');
    });

    test('permanent folders map onto the destination defaults', () {
      final plan = planGuestAccountMerge(
        snapshot: snapshotOf(
          GuestAccountRows(
            folders: [
              _folder('g-my-folder', 'My Folder'),
              _folder('g-my-db', 'My Database', parentId: 'g-my-folder'),
            ],
            savedAnalyses: [_analysis('g-a', 'g-my-db')],
          ),
        ),
        destination: const GuestAccountRows(
          folders: [
            {'id': 'm-my-folder', 'name': 'My Folder', 'parent_id': null},
            {
              'id': 'm-my-db',
              'name': 'My Database',
              'parent_id': 'm-my-folder',
            },
          ],
        ),
        targetUserId: _member,
      );
      expect(plan.folders, isEmpty);
      expect(plan.savedAnalyses.single['folder_id'], 'm-my-db');
    });

    test('destination preferences win on conflict', () {
      final withDestination = planGuestAccountMerge(
        snapshot: snapshotOf(
          const GuestAccountRows(
            engineSettings: {'user_id': _guest, 'selected_country_code': 'NO'},
            notificationPreferences: {'user_id': _guest, 'daily_digest': true},
          ),
        ),
        destination: const GuestAccountRows(
          engineSettings: {'user_id': _member, 'selected_country_code': 'IN'},
        ),
        targetUserId: _member,
      );
      expect(withDestination.engineSettings, isNull);
      expect(withDestination.notificationPreferences?['user_id'], _member);
      expect(withDestination.notificationPreferences?['daily_digest'], isTrue);
    });

    test('a guest favourite the destination already has is not duplicated', () {
      final plan = planGuestAccountMerge(
        snapshot: snapshotOf(
          const GuestAccountRows(
            favoritePlayers: [
              {'fide_id': '1503014', 'player_name': 'Carlsen, M.'},
              {'fide_id': null, 'player_name': 'Firouzja, Alireza'},
            ],
          ),
        ),
        destination: const GuestAccountRows(
          favoritePlayers: [
            {'fide_id': '1503014', 'player_name': 'Carlsen, Magnus'},
          ],
        ),
        targetUserId: _member,
      );
      expect(plan.favoritePlayers.single['player_name'], 'Firouzja, Alireza');
    });

    test('purchased entitlements are not part of the carried data', () {
      final json = const GuestAccountRows().toJson();
      expect(
        json.keys.where((k) => k.contains('subscri') && k != 'book_subscriptions'),
        isEmpty,
      );
      expect(json.keys.any((k) => k.contains('entitlement')), isFalse);
    });

    test('never plans a merge into the guest itself or an empty target', () {
      final snapshot = snapshotOf(
        GuestAccountRows(folders: [_folder('g', 'Prep')]),
      );
      expect(
        planGuestAccountMerge(
          snapshot: snapshot,
          destination: const GuestAccountRows(),
          targetUserId: _guest,
        ).isEmpty,
        isTrue,
      );
      expect(
        planGuestAccountMerge(
          snapshot: snapshot,
          destination: const GuestAccountRows(),
          targetUserId: ' ',
        ).isEmpty,
        isTrue,
      );
    });

    test('derived ids are deterministic, distinct and uuid shaped', () {
      final a = deriveGuestMergeRowId(targetUserId: _member, guestRowId: 'x');
      final again = deriveGuestMergeRowId(
        targetUserId: _member,
        guestRowId: 'x',
      );
      final b = deriveGuestMergeRowId(targetUserId: _member, guestRowId: 'y');
      expect(a, again);
      expect(a, isNot(b));
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(a),
        isTrue,
      );
    });

    test('cyclic parent links do not recurse forever', () {
      final plan = planGuestAccountMerge(
        snapshot: snapshotOf(
          GuestAccountRows(
            folders: [
              _folder('c1', 'One', parentId: 'c2'),
              _folder('c2', 'Two', parentId: 'c1'),
            ],
          ),
        ),
        destination: const GuestAccountRows(),
        targetUserId: _member,
      );
      expect(plan.folders, hasLength(2));
    });
  });

  group('pending snapshot storage', () {
    test('file store round-trips and clears', () async {
      final dir = await Directory.systemTemp.createTemp('guest_merge_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileGuestMergePendingStore(directory: () async => dir);

      expect(await store.read(), isNull);
      await store.write(
        GuestAccountSnapshot(
          guestUserId: _guest,
          capturedAt: DateTime.utc(2026, 9, 1),
          rows: GuestAccountRows(folders: [_folder('g', 'Prep')]),
        ),
      );
      final read = await store.read();
      expect(read?.guestUserId, _guest);
      expect(read?.rows.folders.single['name'], 'Prep');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('new identity window classification', () {
      final now = DateTime.utc(2026, 9, 12, 12);
      expect(
        isLikelyExistingDesktopAccount(
          createdAt: now.subtract(const Duration(minutes: 2)).toIso8601String(),
          now: now,
        ),
        isFalse,
      );
      expect(
        isLikelyExistingDesktopAccount(
          createdAt: now.subtract(const Duration(days: 40)).toIso8601String(),
          now: now,
        ),
        isTrue,
      );
    });
  });
}
