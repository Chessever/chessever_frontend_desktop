import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/services/play/play_cloud_sync.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/state/play_session.dart';

// ---------------------------------------------------------------------------
// The settings document
// ---------------------------------------------------------------------------
//
// Play preferences follow the player between devices and apps through
// `user_play_profiles.settings` (jsonb) and `settings_updated_at`:
//
//   {"v": 1,
//    "helpStyle":   {"level": "always", "hints": 3},
//    "helpModules": {"engineLines": false, ..., "arrows": "off"},
//    "sectionUpdatedAt": {"helpStyle": "2026-11-27T10:05:00.000Z",
//                         "helpModules": "2026-11-27T10:00:00.000Z"}}
//
// Keys this app does not know (top level, or inside a section) are kept
// when it writes the document back: other frontends may add their own.
// The newer side wins, section by section: each section's local edit time
// on this device is compared with that section's own time in
// `sectionUpdatedAt`, so an edit to one section never makes the other
// look newer. A section without its own time (written before them, or by
// a client that does not know them) falls back to the row's
// `settings_updated_at`, which stays the newest of the section times.

/// Version of the settings document this app writes.
const int kPlaySettingsVersion = 1;

const String kPlaySettingsHelpStyleKey = 'helpStyle';
const String kPlaySettingsHelpModulesKey = 'helpModules';

/// Top-level map of each section's own edit time (ISO 8601, UTC).
const String kPlaySettingsSectionTimesKey = 'sectionUpdatedAt';

/// Which account this device's Play preferences were last synced with
/// (permanent accounts only; a guest's preferences belong to nobody).
const String _ownerKey = 'desktop.play.settingsSync.owner.v1';

/// Debounce between a local change and its upload.
const Duration kPlaySettingsPushDelay = Duration(seconds: 1);

/// Retry after a failed upload, or while a remote change waits for the
/// running game to end.
const Duration kPlaySettingsRetryDelay = Duration(seconds: 30);

void _log(String message) => debugPrint('[PlaySync] settings: $message');

/// Reads a `settings_updated_at` value; null when missing or unreadable.
DateTime? parsePlaySettingsTime(Object? raw) {
  if (raw is DateTime) return raw.toUtc();
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

Map<String, Object?>? _section(Map<String, dynamic> settings, String key) {
  final raw = settings[key];
  if (raw is! Map) return null;
  return {for (final e in raw.entries) e.key.toString(): e.value};
}

/// The section's own edit time in [settings], or null without one.
DateTime? playSettingsSectionTime(Map<String, dynamic> settings, String key) {
  final times = settings[kPlaySettingsSectionTimesKey];
  if (times is! Map) return null;
  return parsePlaySettingsTime(times[key]);
}

/// What one sync pass does for one section.
enum PlaySettingsSectionAction {
  /// Both sides agree (or neither has anything): nothing to do.
  keep,

  /// The server's section is newer: take it here.
  adopt,

  /// This device's section is newer: send it.
  push,

  /// The section here was chosen under another account and the server has
  /// none for this one: go back to the defaults here, never send it.
  reset,
}

/// Decides one section. [localAt] is when this device last changed (or
/// adopted) it, null when it never did. [foreignOwner] is true when this
/// device's preferences were last synced with another permanent account:
/// that account's choices never overwrite this one's.
@visibleForTesting
PlaySettingsSectionAction decidePlaySettingsSection({
  required bool remoteHasSection,
  required DateTime? remoteAt,
  required DateTime? localAt,
  required bool foreignOwner,
}) {
  if (remoteHasSection) {
    if (foreignOwner || localAt == null) return PlaySettingsSectionAction.adopt;
    // A section another app wrote without a time does not beat a choice
    // made here.
    if (remoteAt == null) return PlaySettingsSectionAction.push;
    if (remoteAt.isAfter(localAt)) return PlaySettingsSectionAction.adopt;
    if (localAt.isAfter(remoteAt)) return PlaySettingsSectionAction.push;
    return PlaySettingsSectionAction.keep;
  }
  // The server has nothing for it: send what this device chose, if it
  // ever chose anything, unless another account chose it.
  if (localAt == null) return PlaySettingsSectionAction.keep;
  return foreignOwner
      ? PlaySettingsSectionAction.reset
      : PlaySettingsSectionAction.push;
}

/// The plan of one sync pass.
@immutable
class PlaySettingsPlan {
  const PlaySettingsPlan({
    required this.style,
    required this.modules,
    this.remoteStyle,
    this.remoteModules,
    this.remoteStyleAt,
    this.remoteModulesAt,
  });

  final PlaySettingsSectionAction style;
  final PlaySettingsSectionAction modules;

  /// The server's sections, as read.
  final Map<String, Object?>? remoteStyle;
  final Map<String, Object?>? remoteModules;

  /// Each server section's time: its own, else the row's.
  final DateTime? remoteStyleAt;
  final DateTime? remoteModulesAt;

  bool get needsPush =>
      style == PlaySettingsSectionAction.push ||
      modules == PlaySettingsSectionAction.push;
}

@visibleForTesting
PlaySettingsPlan planPlaySettingsSync({
  required Map<String, dynamic> remoteSettings,
  required DateTime? remoteAt,
  required DateTime? styleLocalAt,
  required DateTime? modulesLocalAt,
  required bool foreignOwner,
}) {
  final remoteStyle = _section(remoteSettings, kPlaySettingsHelpStyleKey);
  final remoteModules = _section(remoteSettings, kPlaySettingsHelpModulesKey);
  final styleAt =
      playSettingsSectionTime(remoteSettings, kPlaySettingsHelpStyleKey) ??
      remoteAt;
  final modulesAt =
      playSettingsSectionTime(remoteSettings, kPlaySettingsHelpModulesKey) ??
      remoteAt;
  return PlaySettingsPlan(
    style: decidePlaySettingsSection(
      remoteHasSection: remoteStyle != null,
      remoteAt: styleAt,
      localAt: styleLocalAt,
      foreignOwner: foreignOwner,
    ),
    modules: decidePlaySettingsSection(
      remoteHasSection: remoteModules != null,
      remoteAt: modulesAt,
      localAt: modulesLocalAt,
      foreignOwner: foreignOwner,
    ),
    remoteStyle: remoteStyle,
    remoteModules: remoteModules,
    remoteStyleAt: styleAt,
    remoteModulesAt: modulesAt,
  );
}

/// The document to write back: the server's document with its unknown
/// keys kept, `v` set, and each section given as [style] / [modules] over
/// the server's own section (so a section's unknown keys survive too). A
/// null section keeps the server's section as it is.
///
/// [styleAt] / [modulesAt] are the sent sections' own times. A kept server
/// section without a time of its own is given [rowAt] (the row time it
/// was read with), so the new row time never makes it look newer.
@visibleForTesting
Map<String, dynamic> buildPlaySettingsDocument({
  required Map<String, dynamic> remoteSettings,
  Map<String, Object?>? style,
  Map<String, Object?>? modules,
  DateTime? styleAt,
  DateTime? modulesAt,
  DateTime? rowAt,
}) {
  Map<String, Object?> over(String key, Map<String, Object?> mine) => {
    ...?_section(remoteSettings, key),
    ...mine,
  };
  final rawTimes = remoteSettings[kPlaySettingsSectionTimesKey];
  final times = <String, Object?>{
    if (rawTimes is Map)
      for (final e in rawTimes.entries) e.key.toString(): e.value,
  };
  void stamp(String key, Map<String, Object?>? sent, DateTime? sentAt) {
    if (sent != null) {
      if (sentAt != null) times[key] = sentAt.toUtc().toIso8601String();
      return;
    }
    if (_section(remoteSettings, key) == null) return;
    if (playSettingsSectionTime(remoteSettings, key) != null) return;
    if (rowAt != null) times[key] = rowAt.toUtc().toIso8601String();
  }

  stamp(kPlaySettingsHelpStyleKey, style, styleAt);
  stamp(kPlaySettingsHelpModulesKey, modules, modulesAt);
  return {
    ...remoteSettings,
    'v': kPlaySettingsVersion,
    if (style != null)
      kPlaySettingsHelpStyleKey: over(kPlaySettingsHelpStyleKey, style),
    if (modules != null)
      kPlaySettingsHelpModulesKey: over(kPlaySettingsHelpModulesKey, modules),
    if (times.isNotEmpty) kPlaySettingsSectionTimesKey: times,
  };
}

// ---------------------------------------------------------------------------
// Server access
// ---------------------------------------------------------------------------

@immutable
class PlaySettingsUser {
  const PlaySettingsUser({required this.id, required this.isAnonymous});

  final String id;
  final bool isAnonymous;
}

/// The remote side of the settings sync. [fetch] throws when the read
/// fails and returns null when the player has no profile row yet, so a
/// failed read is never taken for an empty server.
abstract interface class PlaySettingsRemote {
  PlaySettingsUser? get currentUser;

  /// Fires with the signed-in user's id (null when signed out) on every
  /// sign-in, sign-out or account switch.
  Stream<String?> get userChanges;

  /// `{settings: Map, settings_updated_at: String?}`, or null without a
  /// profile row.
  Future<Map<String, dynamic>?> fetch(String userId);

  Future<void> save(Map<String, dynamic> settings, DateTime updatedAt);
}

class SupabasePlaySettingsRemote implements PlaySettingsRemote {
  SupabasePlaySettingsRemote(
    this._repository, {
    PlayCloudGateway gateway = const SupabasePlayCloudGateway(),
  }) : _gateway = gateway;

  final PlayProfileRepository _repository;
  final PlayCloudGateway _gateway;

  @override
  PlaySettingsUser? get currentUser {
    try {
      final user = _gateway.currentUser;
      if (user == null) return null;
      return PlaySettingsUser(id: user.id, isAnonymous: user.isAnonymous);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<String?> get userChanges {
    if (!DesktopSupabaseInit.isInitialized) return const Stream.empty();
    try {
      return Supabase.instance.client.auth.onAuthStateChange.map(
        (event) => event.session?.user.id,
      );
    } catch (_) {
      return const Stream.empty();
    }
  }

  @override
  Future<Map<String, dynamic>?> fetch(String userId) async {
    final row = await _gateway.fetchProfileRow(userId);
    if (row == null) return null;
    final raw = row['settings'];
    return {
      'settings':
          raw is Map
              ? Map<String, dynamic>.from(raw)
              : const <String, dynamic>{},
      'settings_updated_at': row['settings_updated_at']?.toString(),
    };
  }

  @override
  Future<void> save(Map<String, dynamic> settings, DateTime updatedAt) =>
      _repository.saveSettings(settings, updatedAt);
}

final playSettingsRemoteProvider = Provider<PlaySettingsRemote>(
  (ref) => SupabasePlaySettingsRemote(ref.watch(playProfileRepositoryProvider)),
);

// ---------------------------------------------------------------------------
// The sync
// ---------------------------------------------------------------------------

final playSettingsCloudProvider = Provider<PlaySettingsCloudSync>((ref) {
  final sync = PlaySettingsCloudSync(ref);
  ref.onDispose(sync.dispose);
  return sync;
});

/// Keeps the help style and help modules in step with the player's
/// profile row. Started by either notifier once it is built; runs in the
/// main window only. One pass at a time: a change during a pass runs one
/// more pass after it.
class PlaySettingsCloudSync {
  PlaySettingsCloudSync(this._ref);

  final Ref _ref;
  bool _started = false;
  bool _disposed = false;
  bool _running = false;
  bool _again = false;
  Timer? _timer;
  StreamSubscription<String?>? _authSub;
  Future<void>? _current;

  bool get _enabled =>
      _ref.read(desktopWindowRoleProvider) == DesktopWindowRole.main;

  PlaySettingsRemote get _remote => _ref.read(playSettingsRemoteProvider);

  /// Starts the sync (once): a pass now, and one on every sign-in or
  /// account switch.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    if (!_enabled) return;
    _authSub = _remote.userChanges.listen((userId) {
      if (userId != null) unawaited(syncNow());
    }, onError: (Object e) => _log('auth event: $e'));
    scheduleMicrotask(() => unawaited(syncNow()));
  }

  /// A preference changed here: upload it after [kPlaySettingsPushDelay].
  /// Changes inside the delay go up together.
  void localChanged() {
    if (_disposed) return;
    start();
    if (!_enabled) return;
    _schedule(kPlaySettingsPushDelay);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(syncNow()));
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_authSub?.cancel());
  }

  /// Runs one pass, or queues one after the pass in progress.
  Future<void> syncNow() {
    if (_disposed || !_enabled) return Future<void>.value();
    if (_running) {
      _again = true;
      return _current ?? Future<void>.value();
    }
    _running = true;
    return _current = () async {
      try {
        do {
          _again = false;
          await _pass();
        } while (_again && !_disposed);
      } finally {
        _running = false;
      }
    }();
  }

  /// Whether a game is being played in some Play tab: remote help modules
  /// wait for it to end, so a game's help never changes under it.
  bool _gameInProgress() {
    final args = _ref.read(playSessionArgsByTabIdProvider);
    for (final tabId in args.keys) {
      try {
        final session = _ref.read(playSessionProviderFor(tabId));
        if (!session.isGameOver && session.history.isNotEmpty) return true;
      } catch (_) {
        // A tab closing under us has no game.
      }
    }
    return false;
  }

  Future<void> _pass() async {
    final remote = _remote;
    final user = remote.currentUser;
    if (user == null) return;
    final styleNotifier = _ref.read(playHelpStyleProvider.notifier);
    final modulesNotifier = _ref.read(playHelpModulesProvider.notifier);
    await Future.wait([styleNotifier.restored, modulesNotifier.restored]);
    if (_disposed) return;

    final preferences = await SharedPreferences.getInstance();
    final owner = preferences.getString(_ownerKey);
    final foreignOwner = !user.isAnonymous && owner != null && owner != user.id;

    final Map<String, dynamic>? fetched;
    try {
      fetched = await remote.fetch(user.id);
    } catch (e) {
      _log('fetch failed: $e');
      _schedule(kPlaySettingsRetryDelay);
      return;
    }
    if (_disposed || remote.currentUser?.id != user.id) return;

    final rawSettings = fetched?['settings'];
    final remoteSettings =
        rawSettings is Map
            ? Map<String, dynamic>.from(rawSettings)
            : <String, dynamic>{};
    final remoteAt = parsePlaySettingsTime(fetched?['settings_updated_at']);
    final styleAt = styleNotifier.updatedAt;
    final modulesAt = modulesNotifier.updatedAt;
    final plan = planPlaySettingsSync(
      remoteSettings: remoteSettings,
      remoteAt: remoteAt,
      styleLocalAt: styleAt,
      modulesLocalAt: modulesAt,
      foreignOwner: foreignOwner,
    );

    var deferred = false;
    if (plan.style == PlaySettingsSectionAction.adopt) {
      // A running game keeps the style it started with (PlayHelpUsage);
      // the adopted style applies from its next game.
      styleNotifier.adoptRemote(
        PlayHelpStyle.fromJson(plan.remoteStyle!),
        plan.remoteStyleAt,
        expectedLocalAt: styleAt,
      );
    } else if (plan.style == PlaySettingsSectionAction.reset) {
      styleNotifier.adoptRemote(
        const PlayHelpStyle(),
        null,
        expectedLocalAt: styleAt,
      );
    }
    if (plan.modules == PlaySettingsSectionAction.adopt ||
        plan.modules == PlaySettingsSectionAction.reset) {
      if (_gameInProgress()) {
        deferred = true;
      } else if (plan.modules == PlaySettingsSectionAction.adopt) {
        modulesNotifier.adoptRemote(
          PlayHelpModules.fromJson(plan.remoteModules!),
          plan.remoteModulesAt,
          expectedLocalAt: modulesAt,
        );
      } else {
        modulesNotifier.adoptRemote(
          const PlayHelpModules(),
          null,
          expectedLocalAt: modulesAt,
        );
      }
    }

    if (plan.needsPush) {
      // A section the server wins keeps the server's copy, even when it
      // waits for the game to end.
      final pushStyle = plan.style == PlaySettingsSectionAction.push;
      final pushModules = plan.modules == PlaySettingsSectionAction.push;
      final document = buildPlaySettingsDocument(
        remoteSettings: remoteSettings,
        style: pushStyle ? styleNotifier.chosen.toJson() : null,
        modules: pushModules ? modulesNotifier.chosen.toJson() : null,
        styleAt: pushStyle ? styleNotifier.updatedAt : null,
        modulesAt: pushModules ? modulesNotifier.updatedAt : null,
        rowAt: remoteAt,
      );
      // The row time is the newest section time, so a client that reads
      // only the row time still sees the change.
      DateTime? at;
      for (final key in [
        kPlaySettingsHelpStyleKey,
        kPlaySettingsHelpModulesKey,
      ]) {
        final stamp = playSettingsSectionTime(document, key);
        if (stamp != null && (at == null || stamp.isAfter(at))) at = stamp;
      }
      at ??= DateTime.now().toUtc();
      if (remoteAt != null && !at.isAfter(remoteAt)) {
        // Never write a row time older than the row's: the newer rule
        // would read it backwards on the next device.
        at = remoteAt.add(const Duration(milliseconds: 1));
      }
      try {
        await remote.save(document, at);
      } catch (e) {
        // The local edit time stays newer than the server's, so the next
        // pass sends it again.
        _log('upload failed: $e');
        _schedule(kPlaySettingsRetryDelay);
        return;
      }
    }

    if (!user.isAnonymous && !deferred) {
      await preferences.setString(_ownerKey, user.id);
    }
    if (deferred) _schedule(kPlaySettingsRetryDelay);
  }
}
