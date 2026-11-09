// The browser build is served at two addresses from the same deploy:
//
//   https://app.chessever.com/<path>         mount '/'
//   https://chessever.com/webapp/<path>      mount '/webapp/'
//
// On chessever.com the Next.js site forwards /webapp/* to this app's Worker,
// which strips the prefix and rewrites index.html's <base href> to '/webapp/'
// (web_worker/index.js). Everything the app does with its own address (the
// address bar, OAuth return, the release check, same-origin relays) works in
// mount-free "app paths" and converts at the edge with these helpers, so both
// addresses show the same page for the same app path.
//
// Not /app: chessever.com/app/... is the phone app's link format
// (chessever-frontend docs/mobile-app-routes.md) and stays exactly as it is.
// Keep [chesseverComWebAppMount] in sync with WEB_APP_MOUNT in
// chessever_web_frontend's src/lib/web-app-mount.ts.
import 'package:chessever/web/web_document_base.dart';

/// Host that serves the browser build under [chesseverComWebAppMount].
const String chesseverComHost = 'chessever.com';

/// Path prefix of the browser build on [chesseverComHost].
const String chesseverComWebAppMount = '/webapp/';

/// The directory [documentBase] points at: `'/'` or `'/webapp/'`. Always starts
/// and ends with `/`. Non-http(s) bases (native builds, tests) mount at `/`.
String webMountPathOf(Uri documentBase) {
  if (documentBase.scheme != 'http' && documentBase.scheme != 'https') {
    return '/';
  }
  final path = documentBase.path;
  final slash = path.lastIndexOf('/');
  if (slash <= 0) return '/';
  return path.substring(0, slash + 1);
}

/// Mount of the running page (from `document.baseURI` in the browser).
String get webMountPath => webMountPathOf(webDocumentBase());

/// Strips [mount] from a browser path (optionally with `?query`), giving the
/// app path. Paths outside the mount are returned unchanged.
String webAppPath(String browserPath, String mount) {
  if (mount == '/') return browserPath;
  final bare = mount.substring(0, mount.length - 1);
  if (browserPath == bare) return '/';
  if (browserPath.startsWith('$bare?')) {
    return '/${browserPath.substring(bare.length)}';
  }
  if (browserPath.startsWith(mount)) {
    return browserPath.substring(bare.length);
  }
  return browserPath;
}

/// Adds [mount] to an app path (optionally with `?query`).
String webBrowserPath(String appPath, String mount) {
  if (mount == '/') return appPath;
  final bare = mount.substring(0, mount.length - 1);
  return appPath.startsWith('/') ? '$bare$appPath' : '$mount$appPath';
}

/// [browserUri] with its path converted to the app path.
Uri webAppUri(Uri browserUri, String mount) {
  if (mount == '/') return browserUri;
  return browserUri.replace(path: webAppPath(browserUri.path, mount));
}

/// Absolute URL of [appPath] on [page]'s origin, under [mount].
Uri webOwnUrl(Uri page, String appPath, String mount) =>
    Uri.parse('${page.origin}${webBrowserPath(appPath, mount)}');

/// Maps a chessever.com/webapp/... link to the address app.chessever.com
/// uses for the same page, so link parsers only know one shape. Every other
/// address, including the phone app's chessever.com/app/... links, is
/// returned unchanged.
Uri normalizeChesseverComWebAppUri(Uri uri) {
  if ((uri.scheme != 'https' && uri.scheme != 'http') ||
      (uri.host != chesseverComHost && uri.host != 'www.$chesseverComHost')) {
    return uri;
  }
  final segments = uri.pathSegments;
  if (segments.isEmpty || segments.first != 'webapp') return uri;
  return uri.replace(
    host: 'app.$chesseverComHost',
    path: webAppPath(uri.path, chesseverComWebAppMount),
  );
}
