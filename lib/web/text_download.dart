// Saves text as a browser download in the web build. Native builds write
// files through the save dialog instead and never call this.
export 'package:chessever/web/text_download_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/text_download_web.dart';
