// Reloads the page in the web build, where reloading is how a new deploy of
// app.chessever.com reaches an open tab.
export 'package:chessever/web/page_reload_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/page_reload_web.dart';
