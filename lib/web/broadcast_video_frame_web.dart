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

/// The player is a real DOM `<iframe>`, and the browser always delivers a
/// pointer over it to the frame itself, even when Flutter has painted an
/// overlay (the stream / camera / pin menus) on a canvas above it. Flutter
/// content over an iframe is visible but not clickable: the tap reaches the
/// player underneath, which is why selecting a stream from the language
/// menu did nothing while the video paused instead.
///
/// While one of those menus is open the toolbar calls this with
/// `interactive: false` so the click reaches Flutter's overlay. The frame
/// itself keeps playing; only its own controls are paused for the moment
/// the menu is open.
void setBrowserBroadcastVideoFrameInteractive(
  WebViewController? controller, {
  required bool interactive,
}) {
  final platform = controller?.platform;
  if (platform is! WebWebViewController) return;
  final params = platform.params;
  if (params is! WebWebViewControllerCreationParams) return;
  // The controller exposes its iframe through the creation params (the
  // plugin has no style setter). Web-only, and the frame is ours.
  // ignore: invalid_use_of_visible_for_testing_member
  params.iFrame.style.pointerEvents = interactive ? 'auto' : 'none';
}
