import 'package:web/web.dart' as web;

/// Reloads the page. The browser revalidates every file against the server,
/// so the reloaded page runs whatever build is live.
void reloadPage() {
  web.window.location.reload();
}
