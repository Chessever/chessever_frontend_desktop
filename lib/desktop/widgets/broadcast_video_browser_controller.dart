// webview_all_web imports dart:ui_web, which native builds cannot compile.
// The native variant is never called; the panel checks kIsWeb first.
export 'broadcast_video_browser_controller_io.dart'
    if (dart.library.js_interop) 'broadcast_video_browser_controller_web.dart';
