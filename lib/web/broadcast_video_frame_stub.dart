import 'package:webview_all/webview_all.dart';

/// Native builds create their own WKWebView / WebView2 controller.
WebViewController? createBrowserBroadcastVideoController() => null;

/// Native players are not DOM elements inside a Flutter canvas, so an
/// overlay above them receives input normally. Nothing to do here.
void setBrowserBroadcastVideoFrameInteractive(
  WebViewController? controller, {
  required bool interactive,
}) {}
