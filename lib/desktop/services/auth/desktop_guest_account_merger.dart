import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/guest_account_merge.dart';

/// Reads and writes one account's mergeable rows.
abstract interface class GuestAccountMergeGateway {
  Future<GuestAccountRows> readAccountRows(String userId);

  /// Applies [plan]. Every write must be idempotent: it runs again verbatim
  /// when a previous attempt failed partway.
  Future<void> applyPlan(GuestMergePlan plan);
}

/// Durable home of the snapshot between capture and a confirmed replay.
abstract interface class GuestMergePendingStore {
  Future<GuestAccountSnapshot?> read();
  Future<void> write(GuestAccountSnapshot snapshot);
  Future<void> clear();
}

/// Extension point for a server-authorized merge into an account that already
/// existed before the guest signed in (see
/// `docs/freemium_guest_merge_contract.md`). Such a merge can prove control of
/// both identities and reach guest rows the client can no longer read.
///
/// No such RPC is deployed, so the shipped implementation is
/// [UnavailableGuestAccountServerMerge] and every merge uses the client-side
/// replay, which carries everything the guest could read before signing in.
abstract interface class GuestAccountServerMerge {
  bool get isAvailable;

  Future<void> mergeInto({
    required GuestAccountSnapshot snapshot,
    required String targetUserId,
  });
}

class UnavailableGuestAccountServerMerge implements GuestAccountServerMerge {
  const UnavailableGuestAccountServerMerge();

  @override
  bool get isAvailable => false;

  @override
  Future<void> mergeInto({
    required GuestAccountSnapshot snapshot,
    required String targetUserId,
  }) {
    throw UnsupportedError('No server-authorized guest merge is deployed.');
  }
}

/// A sign-in landing on a user created more than this long ago joined an
/// account that already existed.
const kGuestMergeNewIdentityWindow = Duration(minutes: 10);

bool isLikelyExistingDesktopAccount({
  required String? createdAt,
  required DateTime now,
}) {
  final created = DateTime.tryParse(createdAt ?? '');
  if (created == null) return true;
  return now.toUtc().difference(created.toUtc()) > kGuestMergeNewIdentityWindow;
}

enum GuestMergeStatus { nothingPending, sameAccount, merged, failed }

@immutable
class GuestMergeOutcome {
  const GuestMergeOutcome(this.status, {this.writeCount = 0, this.error});

  final GuestMergeStatus status;
  final int writeCount;
  final Object? error;

  /// The snapshot is still stored and the next attempt retries it.
  bool get retryPending => status == GuestMergeStatus.failed;
}

/// Carries a guest's data across the anonymous to permanent switch.
///
/// 1. [captureGuest] runs while still signed in as the guest and persists the
///    snapshot before any auth call.
/// 2. [replayPending] runs as the new account. It clears the snapshot only
///    after every write succeeded; a failure keeps it for the next attempt,
///    and the guest's own rows are never deleted by the client.
class DesktopGuestAccountMerger {
  DesktopGuestAccountMerger({
    required this.gateway,
    required this.pendingStore,
    this.serverMerge = const UnavailableGuestAccountServerMerge(),
  });

  final GuestAccountMergeGateway gateway;
  final GuestMergePendingStore pendingStore;
  final GuestAccountServerMerge serverMerge;

  Future<void> _serial = Future<void>.value();

  Future<T> _queued<T>(Future<T> Function() task) {
    final result = _serial.then((_) => task());
    _serial = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// Captures the guest's rows. Throws when they cannot be read, so the caller
  /// can stop the sign-in instead of switching away from data it failed to
  /// carry. An empty guest keeps any snapshot an earlier attempt left behind.
  Future<GuestAccountSnapshot?> captureGuest(
    String guestUserId, {
    DateTime? now,
  }) {
    return _queued(() async {
      final rows = await gateway.readAccountRows(guestUserId);
      if (rows.isEmpty) return pendingStore.read();
      final snapshot = GuestAccountSnapshot(
        guestUserId: guestUserId,
        capturedAt: now ?? DateTime.now(),
        rows: rows,
      );
      await pendingStore.write(snapshot);
      return snapshot;
    });
  }

  Future<GuestMergeOutcome> replayPending({
    required String targetUserId,
    required bool targetIsExistingAccount,
  }) {
    return _queued(() async {
      final GuestAccountSnapshot? snapshot;
      try {
        snapshot = await pendingStore.read();
      } catch (e) {
        return GuestMergeOutcome(GuestMergeStatus.failed, error: e);
      }
      if (snapshot == null) {
        return const GuestMergeOutcome(GuestMergeStatus.nothingPending);
      }
      if (snapshot.guestUserId == targetUserId) {
        // The identity was linked in place: the rows already belong here.
        await pendingStore.clear();
        return const GuestMergeOutcome(GuestMergeStatus.sameAccount);
      }
      try {
        var writes = 0;
        if (targetIsExistingAccount && serverMerge.isAvailable) {
          await serverMerge.mergeInto(
            snapshot: snapshot,
            targetUserId: targetUserId,
          );
        } else {
          final destination = await gateway.readAccountRows(targetUserId);
          final plan = planGuestAccountMerge(
            snapshot: snapshot,
            destination: destination,
            targetUserId: targetUserId,
          );
          if (!plan.isEmpty) await gateway.applyPlan(plan);
          writes = plan.writeCount;
        }
        await pendingStore.clear();
        return GuestMergeOutcome(GuestMergeStatus.merged, writeCount: writes);
      } catch (e) {
        if (kDebugMode) debugPrint('[GuestMerge] replay failed, kept: $e');
        return GuestMergeOutcome(GuestMergeStatus.failed, error: e);
      }
    });
  }
}

/// Paged Supabase implementation. Pages stay under PostgREST's row cap.
class SupabaseGuestAccountMergeGateway implements GuestAccountMergeGateway {
  SupabaseGuestAccountMergeGateway(this._client);

  final SupabaseClient _client;

  static const _pageSize = 500;
  static const _writeChunk = 25;

  Future<List<GuestMergeRow>> _selectAll(
    String table, {
    required String ownerColumn,
    required String userId,
    required String orderColumn,
  }) async {
    final rows = <GuestMergeRow>[];
    for (var from = 0; ; from += _pageSize) {
      final page = await _client
          .from(table)
          .select()
          .eq(ownerColumn, userId)
          .order(orderColumn, ascending: true)
          .range(from, from + _pageSize - 1);
      rows.addAll(page.map((row) => Map<String, dynamic>.from(row)));
      if (page.length < _pageSize) return rows;
    }
  }

  Future<GuestMergeRow?> _selectOne(String table, String userId) async {
    final row =
        await _client.from(table).select().eq('user_id', userId).maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<GuestAccountRows> readAccountRows(String userId) async {
    final results = await Future.wait<Object?>([
      _selectAll(
        'user_favorite_players',
        ownerColumn: 'user_id',
        userId: userId,
        orderColumn: 'player_name',
      ),
      _selectAll(
        'user_favorite_events',
        ownerColumn: 'user_id',
        userId: userId,
        orderColumn: 'event_id',
      ),
      _selectAll(
        'user_folders',
        ownerColumn: 'user_id',
        userId: userId,
        orderColumn: 'id',
      ),
      _selectAll(
        'user_saved_analyses',
        ownerColumn: 'user_id',
        userId: userId,
        orderColumn: 'id',
      ),
      _selectAll(
        'book_subscriptions',
        ownerColumn: 'subscriber_id',
        userId: userId,
        orderColumn: 'folder_id',
      ),
      _selectOne('user_engine_settings', userId),
      _selectOne('user_notification_preferences', userId),
    ]);
    return GuestAccountRows(
      favoritePlayers: results[0]! as List<GuestMergeRow>,
      favoriteEvents: results[1]! as List<GuestMergeRow>,
      folders: results[2]! as List<GuestMergeRow>,
      savedAnalyses: results[3]! as List<GuestMergeRow>,
      bookSubscriptions: results[4]! as List<GuestMergeRow>,
      engineSettings: results[5] as GuestMergeRow?,
      notificationPreferences: results[6] as GuestMergeRow?,
    );
  }

  Future<void> _upsertIgnoringDuplicates(
    String table,
    List<GuestMergeRow> rows, {
    required String onConflict,
    int chunk = _writeChunk,
  }) async {
    for (var i = 0; i < rows.length; i += chunk) {
      final end = i + chunk < rows.length ? i + chunk : rows.length;
      await _client
          .from(table)
          .upsert(
            rows.sublist(i, end),
            onConflict: onConflict,
            ignoreDuplicates: true,
          );
    }
  }

  @override
  Future<void> applyPlan(GuestMergePlan plan) async {
    // Folders one at a time, parents first, so every parent_id already exists.
    await _upsertIgnoringDuplicates(
      'user_folders',
      plan.folders,
      onConflict: 'id',
      chunk: 1,
    );
    await _upsertIgnoringDuplicates(
      'user_saved_analyses',
      plan.savedAnalyses,
      onConflict: 'id',
    );
    await _upsertIgnoringDuplicates(
      'user_favorite_players',
      plan.favoritePlayers,
      onConflict: 'user_id,player_name',
    );
    await _upsertIgnoringDuplicates(
      'user_favorite_events',
      plan.favoriteEvents,
      onConflict: 'user_id,event_id',
    );
    for (final row in plan.bookSubscriptions) {
      try {
        await _client.from('book_subscriptions').insert(row);
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow; // already subscribed: merged
      }
    }
    final engine = plan.engineSettings;
    if (engine != null) {
      await _upsertIgnoringDuplicates(
        'user_engine_settings',
        [engine],
        onConflict: 'user_id',
      );
    }
    final notifications = plan.notificationPreferences;
    if (notifications != null) {
      await _upsertIgnoringDuplicates(
        'user_notification_preferences',
        [notifications],
        onConflict: 'user_id',
      );
    }
  }
}

/// Stores the pending snapshot as a file in application support. Saved
/// analyses carry whole games, which is too much for SharedPreferences. Writes
/// go to a temp file first and are renamed into place.
class FileGuestMergePendingStore implements GuestMergePendingStore {
  FileGuestMergePendingStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async {
    final base = await _directory();
    return File(
      '${base.path}${Platform.pathSeparator}guest_merge_pending_v1.json',
    );
  }

  @override
  Future<GuestAccountSnapshot?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    return GuestAccountSnapshot.tryDecode(await file.readAsString());
  }

  @override
  Future<void> write(GuestAccountSnapshot snapshot) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(snapshot.encode(), flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
