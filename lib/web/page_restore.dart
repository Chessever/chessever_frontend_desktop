// Waits out a same-tab navigation in the web build: a page that is leaving
// never resumes, so whatever is still waiting only wakes if it stayed.
export 'package:chessever/web/page_restore_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/page_restore_web.dart';
