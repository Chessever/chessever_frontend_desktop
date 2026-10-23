import 'package:webview_all/webview_all.dart';

/// Native builds: the browser iframe controller does not exist here.
WebViewController createBrowserVideoController() {
  throw UnsupportedError('The browser video controller is web-only.');
}
