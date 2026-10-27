// Lets the user pick a whole folder in the web build. Native builds pick
// folders through FilePicker.getDirectoryPath and never call this.
export 'package:chessever/web/folder_picker_stub.dart'
    if (dart.library.js_interop) 'package:chessever/web/folder_picker_web.dart';
