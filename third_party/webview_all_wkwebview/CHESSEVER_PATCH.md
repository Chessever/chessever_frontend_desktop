# Chessever patch to webview_all_wkwebview 1.4.1

Vendored from pub.dev `webview_all_wkwebview` 1.4.1 and wired in through
`dependency_overrides` in the app's `pubspec.yaml`.

One change: a `WKPreferences.setElementFullscreenEnabled` pigeon method and
an `elementFullscreenEnabled` creation param, in five files:

- `pigeons/webkit.dart` (pigeon source)
- `lib/src/common/web_kit.g.dart` (generated Dart, hand-mirrored)
- `darwin/.../WebKitLibrary.g.swift` (generated Swift, hand-mirrored)
- `darwin/.../PreferencesProxyAPIDelegate.swift` (sets
  `isElementFullscreenEnabled`, macOS 12.3+)
- `lib/src/webkit_webview_controller.dart` (creation param, applied after
  construction)

Why: WKWebView ships with the HTML Fullscreen API off, so YouTube hides its
fullscreen button and Twitch's does nothing. With it on, WebKit shows the
player in a full-screen window of its own.

When upgrading: re-vendor the new release, re-apply the method, and keep
`test/desktop/broadcast_video_fullscreen_test.dart` green.
