// Chess files opened in the web build that stay linked to the user's file
// on disk (Chromium's File System Access API). Native builds edit files in
// place and never call this.
export 'package:chessever/web/linked_files_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/linked_files_web.dart';
