import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The player's own fullscreen control only works because two plugin copies
/// under third_party/ are patched (see each CHESSEVER_PATCH.md). A pub
/// upgrade or a "cleanup" that drops the overrides silently returns the panel
/// to a hidden (YouTube) or inert (Twitch) fullscreen button on macOS and a
/// rail-sized "fullscreen" on Windows, with no error anywhere. These pins
/// make that loud.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('WKWebView element fullscreen patch', () {
    const channel =
        'com.abandoft.pigeon.webview_all_wkwebview.WKPreferences.setElementFullscreenEnabled';

    test('pubspec overrides both webview platform packages to third_party', () {
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
        overrides,
        contains(
          'webview_all_windows:\n    path: third_party/webview_all_windows',
        ),
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

  group('WebView2 fullscreen-element patch', () {
    test('the Windows controller exposes the native signal', () {
      final controller = read(
        'third_party/webview_all_windows/lib/src/windows_webview_controller.dart',
      );
      expect(
        controller,
        contains('Stream<bool> get containsFullScreenElementChanged =>'),
      );
      expect(
        controller,
        contains('_webviewController.containsFullScreenElementChanged;'),
      );
    });

    test(
      'the broadcast panel listens and lifts the player into an overlay',
      () {
        final panel = read('lib/desktop/widgets/broadcast_video_panel.dart');
        expect(panel, contains('platform.containsFullScreenElementChanged'));
        expect(panel, contains('Overlay.maybeOf(context, rootOverlay: true)'));
        expect(panel, contains('windowManager.setFullScreen(true)'));
        expect(panel, contains('windowManager.setFullScreen(false)'));
      },
    );
  });
}
