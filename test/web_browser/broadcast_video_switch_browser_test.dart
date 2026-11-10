@TestOn('browser')
library;

import 'package:chessever/web/broadcast_video_frame_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_web/webview_all_web.dart';

void main() {
  setUpAll(() {
    // `flutter test` does not run the app's web plugin registrant.
    WebViewPlatform.instance = WebWebViewPlatform();
  });

  test('a stream menu takes the player iframe out of hit testing', () {
    final controller = createBrowserBroadcastVideoController();
    expect(controller, isNotNull);

    final platform = controller!.platform as WebWebViewController;
    final params = platform.params as WebWebViewControllerCreationParams;
    final iframe = params.iFrame;

    expect(iframe.style.pointerEvents, isNot('none'));

    // The menu is painted over the iframe; leaving the frame interactive
    // sends its rows' clicks to the video instead of Flutter.
    setBrowserBroadcastVideoFrameInteractive(controller, interactive: false);
    expect(iframe.style.pointerEvents, 'none');

    setBrowserBroadcastVideoFrameInteractive(controller, interactive: true);
    expect(iframe.style.pointerEvents, 'auto');
  });

  test('a missing controller is a no-op', () {
    expect(
      () => setBrowserBroadcastVideoFrameInteractive(null, interactive: false),
      returnsNormally,
    );
  });
}
