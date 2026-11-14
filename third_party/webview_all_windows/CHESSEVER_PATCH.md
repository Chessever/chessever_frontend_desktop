# Chessever patch to webview_all_windows 1.4.1

Vendored from pub.dev `webview_all_windows` 1.4.1 and wired in through
`dependency_overrides` in the app's `pubspec.yaml`.

One change, Dart only, in `lib/src/windows_webview_controller.dart`:

- `WindowsWebViewController.containsFullScreenElementChanged` exposes the
  native controller's existing `ContainsFullScreenElementChanged` stream.
  Upstream subscribes to the WebView2 event but keeps the stream on a
  private field.

Why: WebView2 is composited into a Flutter texture, so an HTML element that
enters full screen (the YouTube / Twitch / Kick player's own fullscreen
button) is only sized to the WebView's widget box. The broadcast video panel
listens to this stream and grows that box to the window while it is set.

Also changed: `analysis_options.yaml` (excludes `pigeons/**`, which needs the
`pigeon` dev dependency the app does not carry). `test/`, `CHANGELOG*.md`
were not vendored. No native file differs from 1.4.1.

When upgrading: re-vendor the new release, re-apply the getter, and keep
`test/desktop/broadcast_video_fullscreen_test.dart` green.
