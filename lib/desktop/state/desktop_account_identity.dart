import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/desktop_supabase_init.dart';
import 'package:chessever/desktop/state/desktop_window_role.dart';
import 'package:chessever/repository/local_storage/local_storage_repository.dart';

/// Published by the main window whenever its signed-in account changes.
/// An empty string means "signed out"; a missing key means "unknown".
const kDesktopAccountUserIdPrefKey = 'desktop_account_identity_user_id_v1';
const kDesktopAccountAnonymousPrefKey =
    'desktop_account_identity_is_anonymous_v1';

/// Detached board engines have their own Supabase client, so they cannot hear
/// an auth event raised in the main engine. They re-read the published
/// identity on this cadence instead of adding a second handler to the
/// board/PiP window channels.
const kDesktopDetachedAccountPollInterval = Duration(seconds: 4);

/// The account a window is currently acting for.
///
/// [generation] increases every time the account changes. Async work captures
/// it before starting and must drop its result when the generation moved, so a
/// fetch started for a guest can never publish into a freshly signed-in
/// account (or the reverse).
@immutable
class DesktopAccountIdentity {
  const DesktopAccountIdentity({
    this.userId,
    this.isAnonymous = false,
    this.generation = 0,
    this.staleSession = false,
  });

  final String? userId;
  final bool isAnonymous;
  final int generation;

  /// True in a detached window after the main window switched accounts. The
  /// window keeps its board (drafts are never discarded) but must not trust
  /// account-private data it loaded for the previous account.
  final bool staleSession;

  bool get isSignedIn => userId != null;
  bool get isGuest => userId != null && isAnonymous;
  bool get isPermanent => userId != null && !isAnonymous;

  @override
  bool operator ==(Object other) =>
      other is DesktopAccountIdentity &&
      other.userId == userId &&
      other.isAnonymous == isAnonymous &&
      other.generation == generation &&
      other.staleSession == staleSession;

  @override
  int get hashCode =>
      Object.hash(userId, isAnonymous, generation, staleSession);
}

String? _normalizeUserId(String? userId) {
  final trimmed = userId?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

/// Pure transition for an auth observation inside one engine.
DesktopAccountIdentity advanceDesktopAccountIdentity(
  DesktopAccountIdentity current, {
  required String? userId,
  required bool isAnonymous,
}) {
  final id = _normalizeUserId(userId);
  final anonymous = id != null && isAnonymous;
  if (id == current.userId && anonymous == current.isAnonymous) {
    return current;
  }
  return DesktopAccountIdentity(
    userId: id,
    isAnonymous: anonymous,
    generation: current.generation + 1,
  );
}

/// Pure transition for a detached window comparing its own session with the
/// identity the main window published. [publishedUserId] `null` means nothing
/// was published yet, which is never treated as a change.
DesktopAccountIdentity reconcileDetachedAccountIdentity(
  DesktopAccountIdentity current, {
  required String? publishedUserId,
  required bool publishedIsAnonymous,
}) {
  if (publishedUserId == null) return current;
  final published = _normalizeUserId(publishedUserId);
  final matches =
      published == current.userId &&
      (published == null || publishedIsAnonymous == current.isAnonymous);
  if (matches) {
    if (!current.staleSession) return current;
    return DesktopAccountIdentity(
      userId: current.userId,
      isAnonymous: current.isAnonymous,
      generation: current.generation,
    );
  }
  if (current.staleSession) return current;
  return DesktopAccountIdentity(
    userId: current.userId,
    isAnonymous: current.isAnonymous,
    generation: current.generation + 1,
    staleSession: true,
  );
}

/// Whether a result computed under [capturedGeneration] may still be published.
bool isDesktopAccountResultCurrent({
  required int capturedGeneration,
  required DesktopAccountIdentity current,
}) {
  return capturedGeneration == current.generation && !current.staleSession;
}

final desktopAccountIdentityProvider =
    NotifierProvider<DesktopAccountIdentityNotifier, DesktopAccountIdentity>(
      DesktopAccountIdentityNotifier.new,
    );

class DesktopAccountIdentityNotifier extends Notifier<DesktopAccountIdentity> {
  @override
  DesktopAccountIdentity build() {
    if (!DesktopSupabaseInit.isInitialized) {
      return const DesktopAccountIdentity();
    }
    final auth = Supabase.instance.client.auth;
    final role = ref.read(desktopWindowRoleProvider);
    final sub = auth.onAuthStateChange.listen((event) {
      final user = event.session?.user;
      observe(userId: user?.id, isAnonymous: user?.isAnonymous == true);
    });
    ref.onDispose(sub.cancel);
    if (role == DesktopWindowRole.detached) {
      final timer = Timer.periodic(
        kDesktopDetachedAccountPollInterval,
        (_) => unawaited(syncFromMainWindow()),
      );
      ref.onDispose(timer.cancel);
    }
    final user = auth.currentUser;
    return advanceDesktopAccountIdentity(
      const DesktopAccountIdentity(),
      userId: user?.id,
      isAnonymous: user?.isAnonymous == true,
    );
  }

  int get generation => state.generation;

  /// Records an auth observation made by this engine. Only the main window
  /// publishes it for the others: a detached engine's own events are token
  /// refreshes of a session that may already be superseded.
  void observe({required String? userId, required bool isAnonymous}) {
    final next = advanceDesktopAccountIdentity(
      state,
      userId: userId,
      isAnonymous: isAnonymous,
    );
    if (identical(next, state)) return;
    state = next;
    if (ref.read(desktopWindowRoleProvider) == DesktopWindowRole.main) {
      unawaited(_publish(next));
    }
  }

  Future<void> _publish(DesktopAccountIdentity identity) async {
    try {
      final prefs = await SharedPreferencesService.instance.ensureInitialized();
      if (prefs == null) return;
      await prefs.setString(kDesktopAccountUserIdPrefKey, identity.userId ?? '');
      await prefs.setBool(kDesktopAccountAnonymousPrefKey, identity.isAnonymous);
    } catch (e) {
      if (kDebugMode) debugPrint('[DesktopAccount] publish failed: $e');
    }
  }

  /// Detached windows only: re-reads what the main window published.
  Future<void> syncFromMainWindow() async {
    try {
      final prefs = await SharedPreferencesService.instance.ensureInitialized();
      if (prefs == null) return;
      await prefs.reload();
      state = reconcileDetachedAccountIdentity(
        state,
        publishedUserId: prefs.getString(kDesktopAccountUserIdPrefKey),
        publishedIsAnonymous:
            prefs.getBool(kDesktopAccountAnonymousPrefKey) ?? false,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[DesktopAccount] sync failed: $e');
    }
  }

  /// Runs [work] and returns its result only if the account did not change
  /// while it ran. A `null` return means the result was dropped as stale.
  Future<T?> runAccountScoped<T>(Future<T> Function() work) async {
    final captured = state.generation;
    final result = await work();
    if (!isDesktopAccountResultCurrent(
      capturedGeneration: captured,
      current: state,
    )) {
      return null;
    }
    return result;
  }
}
