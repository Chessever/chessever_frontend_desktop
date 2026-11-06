import 'package:webview_all/webview_all.dart';
import 'package:webview_all_web/webview_all_web.dart';

/// Permissions policy is delegated frame by frame: the provider player sits
/// inside chessever.com's embed page, which sits inside this iframe, so each
/// feature the player needs must be allowed here too. Without it the browser
/// blocks autoplay and the player's fullscreen control. Matches the `allow`
/// list the embed page gives the provider frame.
const String broadcastVideoFrameAllow =
    'autoplay; fullscreen; picture-in-picture; encrypted-media';

WebViewController? createBrowserBroadcastVideoController() {
  return WebViewController.fromPlatformCreationParams(
    WebWebViewControllerCreationParams(
      iFrameAllow: broadcastVideoFrameAllow,
      // YouTube's embed consent needs an origin referrer on the way in.
      iFrameReferrerPolicy: 'strict-origin-when-cross-origin',
      iFrameAttributes: const <String, String?>{'allowfullscreen': ''},
    ),
  );
}
