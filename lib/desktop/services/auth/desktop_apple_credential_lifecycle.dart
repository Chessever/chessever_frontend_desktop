import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/desktop/services/auth/desktop_account_deletion.dart';
import 'package:chessever/desktop/services/mac_app_store.dart';
import 'package:chessever/repository/local_storage/local_storage_repository.dart';

/// Checks restored Apple credentials on launch, resume, and native revocation.
/// The server notification handler separately removes revoked account data.
class DesktopAppleCredentialLifecycle with WidgetsBindingObserver {
  DesktopAppleCredentialLifecycle._()
    : _loadPreferences = SharedPreferencesService.instance.ensureInitialized;

  @visibleForTesting
  DesktopAppleCredentialLifecycle.forTesting({
    required Future<SharedPreferences?> Function() loadPreferences,
  }) : _loadPreferences = loadPreferences;

  static final instance = DesktopAppleCredentialLifecycle._();
  static const _channel = MethodChannel('chessever.desktop/apple_credentials');
  final Future<SharedPreferences?> Function() _loadPreferences;
  StreamSubscription<AuthState>? _authSubscription;
  bool _started = false;

  /// Call after Supabase initialization in the main store-edition engine.
  void start() {
    if (_started || kIsWeb || !isMacAppStore) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'credentialRevoked') await check();
    });
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((
      state,
    ) {
      if (state.session != null) unawaited(check());
    });
    unawaited(check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(check());
  }

  /// Transient native errors leave existing sessions intact. Only an explicit
  /// revoked/notFound result for the same session clears its local session.
  Future<void> check() async {
    // One bounded retry obtains fresh credential state after token rotation.
    // Repeated concurrent changes are checked by the next auth/resume event.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!await _checkOnce()) return;
    }
  }

  static String? _sessionId(Session session) {
    try {
      final parts = session.accessToken.split('.');
      if (parts.length != 3) return null;
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final id = claims is Map ? claims['session_id'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> _checkOnce() async {
    final auth = Supabase.instance.client.auth;
    final session = auth.currentSession;
    if (session == null) return false;
    final user = session.user;
    final subjects =
        user.identities
            ?.where((identity) => identity.provider == 'apple')
            .map((identity) => identity.identityData?['sub'])
            .whereType<String>();
    final subject = subjects?.firstOrNull;
    if (subject == null) return false;
    bool accountMatches() =>
        auth.currentUser?.id == user.id &&
        auth.currentUser?.identities?.any(
              (identity) =>
                  identity.provider == 'apple' &&
                  identity.identityData?['sub'] == subject,
            ) ==
            true;
    bool sessionMatches() =>
        accountMatches() &&
        auth.currentSession?.accessToken == session.accessToken &&
        auth.currentSession?.refreshToken == session.refreshToken;
    bool newerSameAccount() =>
        auth.currentUser?.id == user.id && !sessionMatches();
    bool recheckAfterRefresh() {
      final current = auth.currentSession;
      if (current == null || !accountMatches() || sessionMatches()) {
        return false;
      }
      // Supabase session_id survives refresh-token rotation; a new sign-in
      // has a different session_id. This is local concurrency detection only.
      final previousId = _sessionId(session);
      final currentId = _sessionId(current);
      // Older tokens without session_id require fresh native state too.
      return previousId == null || currentId == null || previousId == currentId;
    }

    try {
      final state = await _channel.invokeMethod<String>('getCredentialState', {
        'userId': subject,
      });
      if (newerSameAccount()) return recheckAfterRefresh();
      if (state != 'revoked' && state != 'notFound') return false;
      final prefs = await _loadPreferences();
      if (newerSameAccount()) return recheckAfterRefresh();
      if (prefs != null) {
        // Cleanup is scoped to the captured account even if another account
        // became current while credential state or preferences were loading.
        await clearDesktopDeletedAccountPreferences(
          prefs: prefs,
          accountId: user.id,
          isCurrentAccount: accountMatches,
          isGuest: user.isAnonymous,
        );
      }
      if (!sessionMatches()) return recheckAfterRefresh();
      await auth.signOut(scope: SignOutScope.local);
    } on PlatformException {
      // No inferred revocation on a temporary AuthenticationServices error.
    } on MissingPluginException {
      // Direct-download editions do not attach this entitlement-gated bridge.
    } catch (_) {
      // Auth transport failure is retried on the next resume/auth event.
    }
    return false;
  }

  Future<void> dispose() async {
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    await _authSubscription?.cancel();
    _authSubscription = null;
  }
}
