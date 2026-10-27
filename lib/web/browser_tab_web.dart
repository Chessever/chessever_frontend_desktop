import 'package:web/web.dart' as web;

/// Opens [path] (same origin) in a new browser tab.
void openInBrowserTab(String path) {
  web.window.open(path, '_blank', 'noopener');
}
