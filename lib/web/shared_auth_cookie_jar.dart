// The cookie jar behind lib/web/shared_auth_session.dart: document.cookie on
// the chessever.com hosts in the browser build, none anywhere else.
export 'package:chessever/web/shared_auth_cookie_jar_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/shared_auth_cookie_jar_web.dart';
