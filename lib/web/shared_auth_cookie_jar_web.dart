import 'dart:js_interop';

import 'package:chessever/web/shared_auth_session.dart';
import 'package:chessever/web/web_mount.dart';
import 'package:web/web.dart' as web;

/// Hosts that serve the browser build and share [chesseverComHost]'s cookies:
/// app.chessever.com, and chessever.com (or www.) under /webapp.
const _sharedHosts = {
  'app.$chesseverComHost',
  chesseverComHost,
  'www.$chesseverComHost',
};

/// The shared jar on the chessever.com hosts. Elsewhere (localhost, previews)
/// the page keeps its sign-in in its own localStorage, as before.
SharedAuthCookieJar? sharedAuthCookieJar() {
  final location = web.window.location;
  if (location.protocol != 'https:') return null;
  if (!_sharedHosts.contains(location.hostname)) return null;
  return const _DocumentCookieJar();
}

/// Runs [callback] whenever the page becomes visible or focused again. The
/// listeners are added in the capture phase on window, ahead of the Flutter
/// engine's, so the session is caught up before the resumed auto refresh.
void onPageShown(void Function() callback) {
  void handler(web.Event _) {
    if (web.document.visibilityState == 'visible') callback();
  }

  final listener = handler.toJS;
  web.window.addEventListener(
    'visibilitychange',
    listener,
    web.AddEventListenerOptions(capture: true),
  );
  web.window.addEventListener(
    'focus',
    listener,
    web.AddEventListenerOptions(capture: true),
  );
  web.window.addEventListener(
    'pageshow',
    listener,
    web.AddEventListenerOptions(capture: true),
  );
}

class _DocumentCookieJar implements SharedAuthCookieJar {
  const _DocumentCookieJar();

  // Chrome caps cookie lifetimes at 400 days.
  static const _maxAgeSeconds = 400 * 24 * 60 * 60;
  static const _attributes =
      '; Domain=$chesseverComHost; Path=/; Secure; SameSite=Lax';

  @override
  String? read(String name) {
    for (final pair in web.document.cookie.split(';')) {
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      if (pair.substring(0, eq).trim() == name) {
        return pair.substring(eq + 1).trim();
      }
    }
    return null;
  }

  @override
  void write(String name, String value) {
    web.document.cookie = '$name=$value; Max-Age=$_maxAgeSeconds$_attributes';
  }

  @override
  void delete(String name) {
    web.document.cookie = '$name=; Max-Age=0$_attributes';
  }
}
