/// `dart:io`'s [Platform] on macOS, Windows, Linux, Android and iOS.
///
/// In the browser build every getter of the real `Platform` throws
/// `UnsupportedError`, so shared code imports `Platform` from here instead
/// (`import 'dart:io' hide Platform;`). Native builds get the `dart:io` class
/// itself, unchanged; the browser gets a stand-in that reports no native host
/// (every `isX` is false), which routes callers onto their non-native paths.
library;

export 'io_platform_native.dart'
    if (dart.library.js_interop) 'io_platform_web.dart';
