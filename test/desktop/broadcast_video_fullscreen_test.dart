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

  // WebView2 is drawn into a Flutter texture, so a full-screen element only
  // fills the WebView's widget box (the rail slot). The panel hears the
  // native signal through the patched Windows package and moves the same
  // player into a window-filling overlay. The move must go through a
  // GlobalKey: an unkeyed remount builds a new player State, which is what
  // restarted streams in later Board tabs.
  group('WebView2 fullscreen element on Windows', () {
    test('pubspec overrides the Windows package to third_party', () {
      final pubspec = read('pubspec.yaml');
      final overrides = pubspec.substring(
        pubspec.indexOf('dependency_overrides:'),
      );
      expect(
        overrides,
        contains(
          'webview_all_windows:\n    path: third_party/webview_all_windows',
        ),
      );
      expect(
        File('third_party/webview_all_windows/CHESSEVER_PATCH.md').existsSync(),
        isTrue,
      );
    });

    test('the controller exposes the native fullscreen-element stream', () {
      expect(
        read(
          'third_party/webview_all_windows/lib/src/windows_webview_controller.dart',
        ),
        contains(
          'Stream<bool> get containsFullScreenElementChanged =>\n'
          '      _webviewController.containsFullScreenElementChanged;',
        ),
      );
    });

    test('the panel listens and moves the player only by its GlobalKey', () {
      final panel = read('lib/desktop/widgets/broadcast_video_panel.dart');
      expect(panel, contains('platform.containsFullScreenElementChanged'));
      expect(panel, contains('rootOverlay: true'));
      expect(panel, contains('KeyedSubtree(key: _playerKey, child: view)'));
      // Both mounts build the player through the keyed helper, never a
      // bare WebViewWidget that would remount it.
      expect(
        RegExp(r'WebViewWidget\(').allMatches(panel).length,
        1,
        reason: 'only _playerView may build the WebViewWidget',
      );
      expect(panel, contains('child: _playerView(controller),'));
      expect(panel, contains(': _playerView(_ensureController()),'));
    });
  });
}
