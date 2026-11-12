import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/models/player_download_preferences.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/prep_cloud_sync.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

// Prep profiles in step between this app and the mobile app (My Prep).
//
// The rules are in `services/prep_cloud_sync.dart`, shared byte for byte
// with the mobile app; this file is the desktop side of it: what a Players
// workspace profile looks like as a row of `public.prep_profiles`, and how
// a row is made into a profile here.
//
// The workspace snapshot and its files stay exactly as they were. What the
// sync remembers is kept apart, under [PrepCloudStore.storageKey], so an
// older build on the same machine reads its snapshot as it always did.
//
// What differs from mobile, and how each difference is carried:
//
// * A profile made on mobile arrives with its sources connected and
//   nothing downloaded, like a username the reader connects here: the
//   download stays the reader's choice (and Premium's).
// * Mobile's own profile (`mine`) is this app's My Prep pointer
//   ([myPrepPlayerIdProvider]).
// * Mobile has rolling date ranges ("last 12 months"); this app has fixed
//   dates. A rolling range reads here as all dates and is written back
//   untouched unless the reader changes the options here.
// * Manual PGN and Combined sources are files on this machine and are
//   never part of a row.

/// How often an open app looks for changes made on another device. It also
/// looks shortly after launch and right after a change made here.
const Duration kPrepCloudEvery = Duration(minutes: 3);

/// Not on the first frames: launch has enough to do already.
const Duration kPrepCloudLaunchDelay = Duration(seconds: 8);

const Set<String> _rollingRanges = <String>{'months3', 'year', 'years3'};

bool _syncs(PlayerWorkspaceSource source) =>
    source == PlayerWorkspaceSource.lichess ||
    source == PlayerWorkspaceSource.chesscom ||
    source == PlayerWorkspaceSource.chessever;

/// The row identity of [account], the same on every device.
String prepCloudKeyOf(PlayerWorkspaceAccount account) =>
    prepCloudAccountKey(<String, Object?>{
      'source': account.source.storageKey,
      'username': account.username,
      'externalId': account.externalId,
    });

/// A row's download options as this app holds them. A rolling range has no
/// counterpart here and reads as all dates.
PlayerDownloadPreferences prepCloudPreferences(Object? raw) {
  if (raw is! Map) return const PlayerDownloadPreferences();
  final rolling = _rollingRanges.contains(raw['range']);
  final all = raw['range'] == 'all';
  return PlayerDownloadPreferences.fromJson(<String, Object?>{
    'timeControls': raw['timeControls'],
    'fromDate': rolling || all ? null : raw['fromDate'],
    'toDate': rolling || all ? null : raw['toDate'],
  });
}

/// This app's download options in a row's shape.
PrepJson prepCloudPreferencesJson(PlayerDownloadPreferences preferences) {
  final json = preferences.toJson();
  final dated = preferences.fromDate != null || preferences.toDate != null;
  return <String, dynamic>{
    'timeControls': json['timeControls'],
    'range': dated ? 'custom' : 'all',
    'fromDate': json['fromDate'],
    'toDate': json['toDate'],
  };
}

/// [player] in the shape of its row: who it is and the sources another
/// device can download, never its games or files.
PrepJson prepCloudProfile(PlayerWorkspacePlayer player, {required bool own}) {
  final fideId = player.fideId?.trim();
  return <String, dynamic>{
    'name': player.displayName,
    'kind': own ? 'mine' : 'opponent',
    'createdAtMs': player.createdAtMs,
    if (fideId != null && fideId.isNotEmpty) 'fideIdentity': fideId,
    'accounts': <PrepJson>[
      for (final account in player.allAccounts)
        if (_syncs(account.source) && prepCloudKeyOf(account).isNotEmpty)
          <String, dynamic>{
            'source': account.source.storageKey,
            'username': account.username,
            if (account.externalId != null) 'externalId': account.externalId,
            if (account.displayName != null) 'displayName': account.displayName,
            if (account.avatarUrl != null) 'avatarUrl': account.avatarUrl,
            if (account.title != null) 'title': account.title,
            if (account.country != null) 'country': account.country,
            if (account.source == PlayerWorkspaceSource.chessever &&
                fideId != null &&
                fideId.isNotEmpty)
              'fideId': fideId,
            'preferences': prepCloudPreferencesJson(
              account.downloadPreferences,
            ),
          },
    ],
  };
}

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

/// A row's source as an account connected here with nothing downloaded.
/// Null for a source this app cannot hold.
PlayerWorkspaceAccount? prepCloudAccount(PrepJson raw) {
  final source = PlayerWorkspaceSource.fromStorageKey(_text(raw['source']));
  final username = _text(raw['username']);
  if (source == null || !_syncs(source) || username == null) return null;
  return PlayerWorkspaceAccount(
    source: source,
    username: username,
    externalId: _text(raw['externalId']),
    displayName: _text(raw['displayName']),
    avatarUrl: _text(raw['avatarUrl']),
    title: _text(raw['title']),
    country: _text(raw['country']),
    downloadPreferences: prepCloudPreferences(raw['preferences']),
  );
}

/// [player] with a row's source [account] added. A player holds one
/// ChessEver database source; a second one is left out.
PlayerWorkspacePlayer prepCloudWithAccount(
  PlayerWorkspacePlayer player,
  PlayerWorkspaceAccount account, {
  String? fideId,
}) {
  if (account.source != PlayerWorkspaceSource.chessever) {
    return player.withAccount(account);
  }
  if (player.account(PlayerWorkspaceSource.chessever) != null) return player;
  final withSource = player.withAccount(account);
  return withSource.copyWith(
    chesseverPlayerId: withSource.chesseverPlayerId ?? account.externalId,
    fideId: withSource.fideId ?? fideId,
  );
}

/// A row as a player here, under [id], with nothing downloaded. Null when
/// it has no name or no source this app can hold.
PlayerWorkspacePlayer? prepCloudPlayer(String id, PrepJson profile) {
  final name = _text(profile['name']);
  if (name == null) return null;
  final created = profile['createdAtMs'];
  final fideId = _text(profile['fideIdentity']);
  var player = PlayerWorkspacePlayer(
    id: id,
    displayName: name,
    createdAtMs:
        created is int ? created : DateTime.now().millisecondsSinceEpoch,
    fideId: fideId,
  );
  for (final raw in prepCloudAccounts(profile)) {
    final account = prepCloudAccount(raw);
    if (account == null) continue;
    player = prepCloudWithAccount(
      player,
      account,
      fideId: _text(raw['fideId']) ?? fideId,
    );
    player = player.copyWith(
      title: player.title ?? account.title,
      country: player.country ?? account.country,
      avatarUrl: player.avatarUrl ?? account.avatarUrl,
    );
  }
  return player.allAccounts.isEmpty ? null : player;
}

/// The reader's rows, through Supabase.
class PrepCloudSupabase implements PrepCloudRemote {
  const PrepCloudSupabase(this.userId);

  final String userId;
  static const String _table = 'prep_profiles';

  SupabaseClient? get _client {
    if (!DesktopSupabaseInit.isInitialized) return null;
    final client = Supabase.instance.client;
    return client.auth.currentUser?.id == userId ? client : null;
  }

  @override
  Future<List<PrepCloudRow>?> fetch() async {
    final client = _client;
    if (client == null) return null;
    try {
      final rows = await client
          .from(_table)
          .select('profile_id, profile, deleted_at')
          .eq('user_id', userId);
      return <PrepCloudRow>[
        for (final row in rows)
          if (_text(row['profile_id']) != null)
            PrepCloudRow(
              id: _text(row['profile_id'])!,
              profile:
                  row['profile'] is Map
                      ? Map<String, dynamic>.from(row['profile'] as Map)
                      : <String, dynamic>{},
              deleted: row['deleted_at'] != null,
            ),
      ];
    } catch (error) {
      debugPrint('[Prepare] profiles not read from the server: $error');
      return null;
    }
  }

  @override
  Future<bool> write(
    String id,
    PrepJson profile, {
    required bool deleted,
  }) async {
    final client = _client;
    if (client == null) return false;
    try {
      await client.from(_table).upsert(<String, Object?>{
        'user_id': userId,
        'profile_id': id,
        'profile': profile,
        'deleted_at': deleted ? DateTime.now().toUtc().toIso8601String() : null,
      }, onConflict: 'user_id,profile_id');
      return true;
    } catch (error) {
      debugPrint('[Prepare] profile not written to the server: $error');
      return false;
    }
  }
}

/// The signed-in reader whose profiles sync, or null: signed out, a
/// session being replaced, or a board window (only the main window syncs;
/// every window shares one workspace).
final prepCloudUserProvider = Provider<String?>((ref) {
  if (ref.watch(desktopWindowRoleProvider) != DesktopWindowRole.main) {
    return null;
  }
  final identity = ref.watch(desktopAccountIdentityProvider);
  return identity.staleSession ? null : identity.userId;
});

/// The server for [userId]. A provider so tests can stand in for it.
final prepCloudRemoteProvider = Provider.family<PrepCloudRemote, String>(
  (ref, userId) => PrepCloudSupabase(userId),
);

/// What the sync remembers on this machine: whose each profile is, and
/// each reader's [PrepCloudState].
class PrepCloudStore {
  PrepCloudStore._(this._write, this.owners, this._states);

  /// A store that is forgotten with the process, for tests.
  @visibleForTesting
  PrepCloudStore.inMemory()
    : this._((_) async {}, <String, String>{}, <String, PrepCloudState>{});

  static const String storageKey = 'desktop_prep_cloud_sync';

  final Future<void> Function(Object json) _write;

  /// The reader each profile belongs to. The workspace is kept per machine,
  /// not per account: one reader's profiles never go to another's account.
  /// A profile no one owns yet goes to the reader who is signed in when it
  /// first syncs.
  final Map<String, String> owners;
  final Map<String, PrepCloudState> _states;
  Future<void> _writing = Future<void>.value();

  static Future<PrepCloudStore> open({AppDatabase? database}) async {
    final db = database ?? AppDatabase.instance;
    Object? json;
    try {
      json = await db.getJson<Object?>(storageKey);
    } catch (error) {
      // Unreadable: every profile meets its row again, which keeps both.
      debugPrint('[Prepare] sync state unreadable: $error');
    }
    final owners = json is Map ? json['owners'] : null;
    final users = json is Map ? json['users'] : null;
    return PrepCloudStore._(
      (json) => db.setJson(storageKey, json),
      <String, String>{
        if (owners is Map)
          for (final entry in owners.entries)
            if (entry.value is String)
              entry.key.toString(): entry.value as String,
      },
      <String, PrepCloudState>{
        if (users is Map)
          for (final entry in users.entries)
            entry.key.toString(): PrepCloudState.fromJson(entry.value),
      },
    );
  }

  PrepCloudState stateOf(String userId) =>
      _states.putIfAbsent(userId, PrepCloudState.new);

  Future<void> save() {
    final json = <String, Object?>{
      'version': 1,
      'owners': Map<String, String>.of(owners),
      'users': <String, Object?>{
        for (final entry in _states.entries) entry.key: entry.value.toJson(),
      },
    };
    return _writing = _writing.then((_) async {
      try {
        await _write(json);
      } catch (error) {
        debugPrint('[Prepare] sync state not saved: $error');
      }
    });
  }
}

/// The Players workspace, for [userId].
class _Device implements PrepCloudDevice {
  _Device(this._ref, this._store, this.userId);

  final Ref _ref;
  final PrepCloudStore _store;
  final String userId;

  PlayerWorkspaceNotifier get _workspace =>
      _ref.read(playerWorkspaceProvider.notifier);

  PlayerWorkspacePlayer? _player(String id) {
    for (final player in _ref.read(playerWorkspaceProvider).players) {
      if (player.id == id) return player;
    }
    return null;
  }

  @override
  Map<String, PrepJson>? profiles() {
    if (!_workspace.isRosterLoaded) return null;
    // Unknown while it loads, and never guessed: a profile written as an
    // opponent would stop being the reader's own on their phone.
    final pointer = _ref.read(myPrepPlayerIdProvider);
    if (!pointer.hasValue) return null;
    final own = pointer.valueOrNull;
    var claimed = false;
    final mine = <String, PrepJson>{};
    for (final player in _ref.read(playerWorkspaceProvider).players) {
      final owner = _store.owners[player.id];
      if (owner == null) {
        _store.owners[player.id] = userId;
        claimed = true;
      } else if (owner != userId) {
        continue;
      }
      mine[player.id] = prepCloudProfile(player, own: player.id == own);
    }
    if (claimed) unawaited(_store.save());
    return mine;
  }

  @override
  String preferencesCore(Object? preferences) =>
      jsonEncode(prepCloudPreferences(preferences).toJson());

  @override
  String kindCore(Object? kind) => kind == 'mine' ? 'mine' : 'other';

  @override
  Future<bool> create(String id, PrepJson profile) async {
    final player = prepCloudPlayer(id, profile);
    if (player == null) return false;
    if (!await _workspace.addSyncedPlayer(player)) return false;
    _store.owners[id] = userId;
    await _link(id, profile);
    return true;
  }

  /// The reader's own profile on another device is the own profile here,
  /// unless this app already has one.
  Future<void> _link(String id, PrepJson profile) async {
    final pointer = _ref.read(myPrepPlayerIdProvider.notifier);
    final own = _ref.read(myPrepPlayerIdIfPresentProvider);
    if (profile['kind'] == 'mine') {
      if (own == null) await pointer.link(id);
    } else if (own == id) {
      await pointer.unlink();
    }
  }

  @override
  Future<void> apply(String id, PrepJson profile) async {
    final here = _player(id);
    if (here == null) return;
    final wanted = <String, PrepJson>{
      for (final account in prepCloudAccounts(profile))
        prepCloudAccountKey(account): account,
    };
    // Sources removed elsewhere go, with their files. Manual PGN and
    // Combined are never part of a row and stay.
    for (final account in here.allAccounts) {
      if (!_syncs(account.source)) continue;
      if (!wanted.containsKey(prepCloudKeyOf(account))) {
        await _workspace.removeSyncedAccount(id, account);
      }
    }
    final name = _text(profile['name']);
    final fideId = _text(profile['fideIdentity']);
    await _workspace.updateSyncedPlayer(id, (player) {
      var next = player;
      final held = <String, PlayerWorkspaceAccount>{
        for (final account in player.allAccounts)
          if (_syncs(account.source)) prepCloudKeyOf(account): account,
      };
      for (final entry in wanted.entries) {
        final account = held[entry.key];
        if (account == null) {
          final added = prepCloudAccount(entry.value);
          if (added == null) continue;
          next = prepCloudWithAccount(
            next,
            added,
            fideId: _text(entry.value['fideId']) ?? fideId,
          );
          continue;
        }
        final options = prepCloudPreferences(entry.value['preferences']);
        if (options != account.downloadPreferences) {
          // The next download of this source uses the new selection, as
          // when the reader changes it here.
          next = next.withAccount(
            account.copyWith(downloadPreferences: options),
          );
        }
      }
      if (name != null && name != next.displayName) {
        next = next.copyWith(displayName: name);
      }
      return next;
    });
    await _link(id, profile);
  }

  @override
  Future<bool> remove(String id) async {
    final here = _player(id);
    if (here == null) return true;
    // A profile holding files imported here is the reader's only copy of
    // them.
    if (here.allAccounts.any(
      (account) => account.source == PlayerWorkspaceSource.manual,
    )) {
      return false;
    }
    await _workspace.removePlayer(id);
    _store.owners.remove(id);
    return true;
  }
}

/// Opens what the sync remembers. A provider so tests can stand in for it.
final prepCloudStoreProvider = Provider<Future<PrepCloudStore> Function()>(
  (ref) => PrepCloudStore.open,
);

/// How long after launch the first look happens. A provider so tests need
/// not wait.
final prepCloudLaunchDelayProvider = Provider<Duration>(
  (ref) => kPrepCloudLaunchDelay,
);

/// Keeps the Players workspace and the reader's account in step (see the
/// top of this file). Watch it from the shell.
final prepCloudSyncProvider = Provider<void>((ref) {
  PrepCloudSync? sync;
  PrepCloudStore? store;
  var disposed = false;
  var launched = false;
  Timer? soon;

  Future<void> run() async {
    final engine = sync;
    if (engine == null || disposed || !launched) return;
    try {
      // The roster is read from disk first: a look before it is there
      // would find nothing to compare.
      await ref.read(playerWorkspaceProvider.notifier).rosterReady;
      if (disposed) return;
      await engine.pass();
    } catch (error) {
      debugPrint('[Prepare] sync pass failed: $error');
    }
  }

  /// A change here is written a moment later, once it has settled.
  void changed() {
    if (!launched || !(sync?.dirty ?? false)) return;
    soon?.cancel();
    soon = Timer(const Duration(seconds: 2), () => unawaited(run()));
  }

  Future<void> start(String? userId) async {
    sync = null;
    if (userId == null) return;
    final PrepCloudStore opened;
    try {
      opened = store ??= await ref.read(prepCloudStoreProvider)();
    } catch (error) {
      // No storage to remember in: nothing is synced this session.
      debugPrint('[Prepare] sync not started: $error');
      return;
    }
    if (disposed || ref.read(prepCloudUserProvider) != userId) return;
    sync = PrepCloudSync(
      remote: ref.read(prepCloudRemoteProvider(userId)),
      device: _Device(ref, opened, userId),
      state: opened.stateOf(userId),
      save: (_) => opened.save(),
    );
    await run();
  }

  ref.listen<String?>(
    prepCloudUserProvider,
    (_, userId) => unawaited(start(userId)),
  );
  final launch = Timer(ref.read(prepCloudLaunchDelayProvider), () {
    launched = true;
    // From here on the workspace is watched: a profile the reader deletes
    // has its row marked deleted, and a change is written.
    ref.listen<PlayerWorkspaceState>(playerWorkspaceProvider, (before, after) {
      final workspace = ref.read(playerWorkspaceProvider.notifier);
      if (!workspace.isRosterLoaded) return;
      if (before != null && !identical(before.players, after.players)) {
        final held = <String>{for (final player in after.players) player.id};
        for (final old in before.players) {
          if (held.contains(old.id)) continue;
          store?.owners.remove(old.id);
          unawaited(sync?.forget(old.id));
        }
      }
      changed();
    });
    ref.listen<AsyncValue<String?>>(myPrepPlayerIdProvider, (before, after) {
      // Which profile is the reader's own is read from disk too.
      if (before?.hasValue != true && after.hasValue) {
        unawaited(run());
      } else {
        changed();
      }
    });
    unawaited(run());
  });
  final tick = Timer.periodic(kPrepCloudEvery, (_) => unawaited(run()));
  ref.onDispose(() {
    disposed = true;
    soon?.cancel();
    launch.cancel();
    tick.cancel();
  });
  unawaited(start(ref.read(prepCloudUserProvider)));
});
