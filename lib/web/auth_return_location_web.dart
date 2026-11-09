import 'dart:convert';

import 'package:web/web.dart' as web;
import 'package:chessever/desktop/auth/web_auth_return_destination.dart';

const _key = 'chessever.auth.return.v1';

void rememberWebAuthReturnLocation() {
  try {
    final current = Uri.base;
    final path = safeWebAuthReturnDestination(current);
    if (path == null) return;
    web.window.sessionStorage.setItem(
      _key,
      jsonEncode({
        'origin': current.origin,
        'path': path,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  } catch (_) {
    /* Storage being disabled must not prevent sign-in. */
  }
}

void clearWebAuthReturnLocation() {
  try {
    web.window.sessionStorage.removeItem(_key);
  } catch (_) {}
}

void restoreWebAuthReturnLocation() {
  try {
    final raw = web.window.sessionStorage.getItem(_key);
    if (raw == null) return;
    clearWebAuthReturnLocation();
    final current = Uri.base;
    final saved = jsonDecode(raw) as Map<String, dynamic>;
    final created = saved['createdAt'];
    if (saved['origin'] != current.origin || created is! int) return;
    final age = DateTime.now().millisecondsSinceEpoch - created;
    if (age < 0 || age > const Duration(hours: 1).inMilliseconds) return;
    // Do not hijack a different deliberate destination after authentication.
    if (current.path != '/' && current.path != '/auth/callback') return;
    final target = Uri.tryParse(saved['path']?.toString() ?? '');
    if (target == null) return;
    final path = safeWebAuthReturnDestination(target);
    if (path != null) web.window.history.replaceState(null, '', path);
  } catch (_) {
    /* A malformed or stale return hint is never an auth failure. */
  }
}
