import 'package:webview_all/webview_all.dart';
import 'package:webview_all_web/webview_all_web.dart'
    show WebWebViewControllerCreationParams;

/// Web build: the player is an iframe in a cross-origin isolated page.
///
/// The page sends COEP credentialless so the renderer can use threads. A
/// credentialless iframe may still embed the chessever.com player page,
/// which does not opt in to isolation itself.
WebViewController createBrowserVideoController() {
  return WebViewController.fromPlatformCreationParams(
    WebWebViewControllerCreationParams(
      iFrameAllow: 'autoplay; fullscreen; picture-in-picture; encrypted-media',
      iFrameAttributes: const <String, String?>{'credentialless': ''},
    ),
  );
}
