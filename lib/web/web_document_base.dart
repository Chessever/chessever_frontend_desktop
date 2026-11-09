// The page's base URL: `document.baseURI` in the browser, which the
// <base href> in index.html sets ('/' on app.chessever.com, '/webapp/' on
// chessever.com). See web_mount.dart.
export 'package:chessever/web/web_document_base_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/web_document_base_web.dart';
