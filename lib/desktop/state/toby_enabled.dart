/// Toby on or off: one switch for every Toby surface (Toby Predicts, the
/// Toby bar, Toby's arrows, the Toby rating and Play's Toby help), kept on
/// the reader's ACCOUNT so the phone, this app and chessever.com agree.
///
/// The account value is `user_engine_settings.toby_enabled` (one row per
/// user, owner-only RLS): null means never chosen, which is on. This app
/// keeps the value on the device too (`desktop.analysis.toby.v1`, the key
/// the old device-only "Toby analysis" switch used), so a board paints from
/// it before any network answers. [TobyAccountSync] keeps the two in step
/// with the rules chessever.com uses for its raw PGN setting
/// (chessever_web_frontend `src/broadcast/lib/raw-pgn-mode.ts`):
///
/// - a pull that lands after the reader flipped the switch loses to it;
/// - an account with no choice yet takes a non-default device value (so a
///   reader who had turned the old switch off keeps it off everywhere);
/// - a push only goes out for a value the account does not already hold.
///
/// Guests and signed-out readers keep the value on this device only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/repository/local_storage/local_storage_repository.dart';

/// The device copy. Shared with builds before the account switch, whose
/// "Toby analysis" switch wrote it.
const String kTobyEnabledPrefKey = 'desktop.analysis.toby.v1';

const String kUserEngineSettingsTable = 'user_engine_settings';
const String kTobyEnabledColumn = 'toby_enabled';

/// The switch's line in Settings.
const String kTobySwitchDescription =
    'Toby Predicts, the Toby bar and the Toby rating.';

/// What a row with no choice says.
const bool kTobyEnabledDefault = true;

/// The account side of the switch.
abstract class TobyAccountStore {
  /// The account's stored value; null for no row or no choice. Throws when
  /// the account cannot be read.
  Future<bool?> read(String userId);

  Future<void> write(String userId, bool value);
}

/// The upsert body: ONLY these columns, so `merge-duplicates` leaves every
/// other setting of an existing row alone.
@visibleForTesting
Map<String, Object> tobyEnabledUpsertBody(
  String userId,
  bool value,
  DateTime at,
) => {
  'user_id': userId,
  kTobyEnabledColumn: value,
  'updated_at': at.toUtc().toIso8601String(),
};

/// Null when there is no row, or the row never chose.
@visibleForTesting
bool? parseTobyEnabledRow(Object? row) {
  if (row is! Map) return null;
  final value = row[kTobyEnabledColumn];
  return value is bool ? value : null;
}

class SupabaseTobyAccountStore implements TobyAccountStore {
  const SupabaseTobyAccountStore();

  SupabaseClient get _client {
    if (!DesktopSupabaseInit.isInitialized) {
      throw StateError('Supabase is not initialized.');
    }
    return Supabase.instance.client;
  }

  @override
  Future<bool?> read(String userId) async {
    final row =
        await _client
            .from(kUserEngineSettingsTable)
            .select(kTobyEnabledColumn)
            .eq('user_id', userId)
            .maybeSingle();
    return parseTobyEnabledRow(row);
  }

  @override
  Future<void> write(String userId, bool value) async {
    await _client
        .from(kUserEngineSettingsTable)
        .upsert(
          tobyEnabledUpsertBody(userId, value, DateTime.now()),
          onConflict: 'user_id',
        );
  }
}

final tobyAccountStoreProvider = Provider<TobyAccountStore>(
  (ref) => const SupabaseTobyAccountStore(),
);

/// The ordering rules between the device value and the account, free of
/// Flutter so they can be tested alone. A Dart port of chessever.com's
/// `createRawPgnSync`.
class TobyAccountSync {
  TobyAccountSync({
    required this.readRemote,
    required this.writeRemote,
    required this.readLocal,
    required this.writeLocal,
    this.defaultValue = kTobyEnabledDefault,
  });

  final Future<bool?> Function(String userId) readRemote;
  final Future<void> Function(String userId, bool value) writeRemote;
  final bool Function() readLocal;
  final void Function(bool value) writeLocal;
  final bool defaultValue;

  String? _userId;

  /// What we believe the account holds; null when unknown or absent.
  bool? _remote;

  /// Bumped on every account change so a stale pull cannot apply.
  int _generation = 0;

  /// The reader flipped the switch while a pull was in flight: it loses.
  bool _editedDuringPull = false;
  bool _pulling = false;
  Future<void> _writes = Future<void>.value();
  final Set<Future<void>> _inflight = <Future<void>>{};

  void _track(Future<void> request) {
    _inflight.add(request);
    unawaited(request.whenComplete(() => _inflight.remove(request)));
  }

  void _push(String id, bool value) {
    final at = _generation;
    _remote = value;
    _writes = _writes.then((_) => writeRemote(id, value)).catchError((
      Object error,
    ) {
      debugPrint('Toby setting could not be saved to the account: $error');
      // Forgetting the belief makes the next local change try again.
      if (_generation == at && _remote == value) _remote = null;
    });
    _track(_writes);
  }

  void _pull(String id) {
    final at = _generation;
    _pulling = true;
    _editedDuringPull = false;
    Future<bool?> read;
    try {
      read = readRemote(id);
    } catch (error) {
      read = Future<bool?>.error(error);
    }
    final request = read.then<void>(
      (stored) {
        if (_generation != at) return;
        _pulling = false;
        final local = readLocal();
        if (_editedDuringPull) {
          // The reader's latest word is the value, on both sides.
          if (stored != local) {
            _push(id, local);
          } else {
            _remote = stored;
          }
          return;
        }
        if (stored == null) {
          // No choice on the account yet. A non-default device choice is
          // worth keeping; the default needs no row to say it.
          if (local != defaultValue) _push(id, local);
          return;
        }
        _remote = stored;
        if (stored != local) writeLocal(stored);
      },
      onError: (Object error) {
        if (_generation == at) _pulling = false;
        // Unreachable account: the device value stands, and a later local
        // change still pushes because the account value is still unknown.
        debugPrint('Toby setting could not be read from the account: $error');
      },
    );
    _track(request);
  }

  /// The signed-in (non-guest) account changed; null when there is none.
  void setUser(String? next) {
    final id = next?.trim();
    final normalized = id == null || id.isEmpty ? null : id;
    if (normalized == _userId) return;
    _generation += 1;
    _userId = normalized;
    _remote = null;
    _pulling = false;
    _editedDuringPull = false;
    if (normalized != null) _pull(normalized);
  }

  /// The device value was written by the reader.
  void localChanged() {
    if (_pulling) _editedDuringPull = true;
    final id = _userId;
    if (id == null || _pulling) return;
    final local = readLocal();
    if (_remote == local) return;
    _push(id, local);
  }

  /// Settles every request in flight. Tests await it.
  Future<void> idle() async {
    while (_inflight.isNotEmpty) {
      await Future.wait(
        _inflight.toList().map((f) => f.catchError((Object _) {})),
      );
    }
  }
}

/// The account a value is synced for: a permanent, current account. Guests
/// and signed-out readers keep it on this device.
String? tobySyncUserId(DesktopAccountIdentity identity) =>
    identity.isPermanent && !identity.staleSession ? identity.userId : null;

/// Whether Toby is on. True until the reader turns it off.
final tobyEnabledProvider = NotifierProvider<TobyEnabledNotifier, bool>(
  TobyEnabledNotifier.new,
);

class TobyEnabledNotifier extends Notifier<bool> {
  late TobyAccountSync _sync;
  bool _edited = false;
  bool _disposed = false;
  Future<void> _ready = Future<void>.value();
  Future<void> _writes = Future<void>.value();

  /// For tests: settles the device read and every account request.
  @visibleForTesting
  Future<void> idle() async {
    await _ready;
    await _sync.idle();
    await _writes;
  }

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    final store = ref.read(tobyAccountStoreProvider);
    // The app's preferences are usually loaded before the first board, so
    // the board paints the device value in its first frame.
    final cached = SharedPreferencesService.instance.prefsOrNull?.getBool(
      kTobyEnabledPrefKey,
    );
    if (SharedPreferencesService.instance.prefsOrNull == null) {
      _ready = _restore();
    }
    _sync = TobyAccountSync(
      // The account is asked once the device value is known, so the
      // comparison is made against the reader's own choice.
      readRemote: (id) async {
        await _ready;
        return store.read(id);
      },
      writeRemote: store.write,
      readLocal: () => state,
      writeLocal: _applyFromAccount,
    );
    ref.listen<DesktopAccountIdentity>(
      desktopAccountIdentityProvider,
      (_, identity) => _sync.setUser(tobySyncUserId(identity)),
      fireImmediately: true,
    );
    return cached ?? kTobyEnabledDefault;
  }

  Future<void> _restore() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_disposed || _edited) return;
      final stored = preferences.getBool(kTobyEnabledPrefKey);
      if (stored != null && stored != state) state = stored;
    } catch (error) {
      debugPrint('Toby setting could not be restored: $error');
    }
  }

  /// The reader's switch.
  void set(bool value) {
    _edited = true;
    if (value == state) return;
    state = value;
    _save(value);
    _sync.localChanged();
  }

  void _applyFromAccount(bool value) {
    if (_disposed || value == state) return;
    state = value;
    _save(value);
  }

  void _save(bool value) {
    _writes = _writes
        .then((_) async {
          final preferences = await SharedPreferences.getInstance();
          await preferences.setBool(kTobyEnabledPrefKey, value);
        })
        .catchError((Object error) {
          debugPrint('Toby setting could not be saved: $error');
        });
  }
}
