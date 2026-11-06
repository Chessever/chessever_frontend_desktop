// The broadcast video panel's player in the web build: an <iframe> that is
// allowed to pass autoplay and fullscreen on to the provider player nested
// inside chessever.com's embed page.
export 'package:chessever/web/broadcast_video_frame_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/broadcast_video_frame_web.dart';
