import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// On macOS the player's own fullscreen control only works because the
/// WKWebView plugin copy under third_party/ is patched (see its
/// CHESSEVER_PATCH.md). A pub upgrade or a "cleanup" that drops the override
/// silently returns the panel to a hidden (YouTube) or inert (Twitch)
/// fullscreen button, with no error anywhere. These pins make that loud.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('WKWebView element fullscreen patch', () {
    const channel =
        'com.abandoft.pigeon.webview_all_wkwebview.WKPreferences.setElementFullscreenEnabled';

    test('pubspec overrides the WKWebView package to third_party', () {
      final pubspec = read('pubspec.yaml');
      final overrides = pubspec.substring(
        pubspec.indexOf('dependency_overrides:'),
      );
      expect(
        overrides,
        contains(
          'webview_all_wkwebview:\n    path: third_party/webview_all_wkwebview',
        ),
      );
      expect(
        File('third_party/webview_all_wkwebview/CHESSEVER_PATCH.md').existsSync(),
        isTrue,
      );
    });

    test('pigeon source, generated Dart and Swift agree on the channel', () {
      expect(
        read('third_party/webview_all_wkwebview/pigeons/webkit.dart'),
        contains('void setElementFullscreenEnabled(bool enabled);'),
      );
      expect(
        read('third_party/webview_all_wkwebview/lib/src/common/web_kit.g.dart'),
        contains("'$channel'"),
      );
      expect(
        read(
          'third_party/webview_all_wkwebview/darwin/webview_all_wkwebview/'
          'Sources/webview_all_wkwebview/WebKitLibrary.g.swift',
        ),
        contains('"$channel"'),
      );
    });

    test(
      'the Swift delegate flips WKPreferences.isElementFullscreenEnabled',
      () {
        final delegate = read(
          'third_party/webview_all_wkwebview/darwin/webview_all_wkwebview/'
          'Sources/webview_all_wkwebview/PreferencesProxyAPIDelegate.swift',
        );
        expect(delegate, contains('func setElementFullscreenEnabled('));
        expect(
          delegate,
          contains('pigeonInstance.isElementFullscreenEnabled = enabled'),
        );
        expect(delegate, contains('#available(iOS 15.4, macOS 12.3, *)'));
      },
    );

    test('creation params carry the flag and the controller applies it', () {
      final controller = read(
        'third_party/webview_all_wkwebview/lib/src/webkit_webview_controller.dart',
      );
      expect(controller, contains('this.elementFullscreenEnabled = false,'));
      expect(controller, contains('final bool elementFullscreenEnabled;'));
      expect(
        controller,
        contains('await preferences.setElementFullscreenEnabled(true);'),
      );
    });

    test('the broadcast panel opts in on macOS', () {
      final panel = read('lib/desktop/widgets/broadcast_video_panel.dart');
      final webKitParams = panel.substring(
        panel.indexOf('WebKitWebViewControllerCreationParams('),
      );
      expect(webKitParams, contains('elementFullscreenEnabled: true,'));
    });
  });

  // WebView2 already has the Fullscreen API on, but sizes a full-screen
  // element to the WebView's own bounds, so on Windows the player fills its
  // rail slot. Enlarging it would mean moving the player into an overlay,
  // and moving or remounting the host restarts the stream in later Board
  // tabs (see "Keep broadcast video mounted across Board tabs").
  test('the player is never lifted out of its stable mount', () {
    final panel = read('lib/desktop/widgets/broadcast_video_panel.dart');
    expect(panel, isNot(contains('rootOverlay: true')));
    expect(panel, isNot(contains('OverlayEntry(')));
  });
}
