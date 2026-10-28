// Opens an app path in a new browser tab in the web build, where a new
// browser tab stands in for the desktop app's extra windows.
export 'package:chessever/web/browser_tab_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/browser_tab_web.dart';
