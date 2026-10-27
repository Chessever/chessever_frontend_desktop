import 'dart:io' show Platform;

import 'package:chessever/web/hardware_concurrency.dart';
import 'package:flutter/foundation.dart';

// `dart:io`'s [Platform] throws on the web build (app.chessever.com), so
// shared code asks these instead. In the native builds `kIsWeb` is a constant
// false and each getter is exactly the `Platform` check it replaces.

bool get hostIsMacOS => !kIsWeb && Platform.isMacOS;
bool get hostIsWindows => !kIsWeb && Platform.isWindows;
bool get hostIsLinux => !kIsWeb && Platform.isLinux;
bool get hostIsAndroid => !kIsWeb && Platform.isAndroid;
bool get hostIsIOS => !kIsWeb && Platform.isIOS;

/// Whether shortcuts use ⌘ rather than Ctrl. On the web this follows the
/// visitor's OS, so a Mac browser still gets ⌘ labels and bindings.
bool get keyboardUsesMacModifiers =>
    kIsWeb ? defaultTargetPlatform == TargetPlatform.macOS : Platform.isMacOS;

/// `Platform.operatingSystem`, or `'web'` in the browser build.
String get hostOperatingSystem => kIsWeb ? 'web' : Platform.operatingSystem;

/// `Platform.pathSeparator`; `/` in the browser build's filesystem.
String get hostPathSeparator => kIsWeb ? '/' : Platform.pathSeparator;

/// `Platform.numberOfProcessors`, or what the browser reports (4 if hidden).
/// Each web engine runs in its own Worker, so these are real parallel cores.
int get hostProcessorCount =>
    kIsWeb ? browserHardwareConcurrency() ?? 4 : Platform.numberOfProcessors;

/// `Platform.environment`; empty in the browser build.
Map<String, String> get hostEnvironment =>
    kIsWeb ? const <String, String>{} : Platform.environment;
