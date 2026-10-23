import 'dart:js_interop';

@JS('navigator.hardwareConcurrency')
external JSNumber? get _hardwareConcurrency;

@JS('navigator.language')
external JSString? get _navigatorLanguage;

/// Browser stand-in for `dart:io`'s `Platform`. A browser tab is none of the
/// native hosts, so every `isX` getter is false. Where code needs the
/// visitor's operating system (shortcut labels), it asks
/// `defaultTargetPlatform`, which Flutter derives from the user agent.
abstract final class Platform {
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isLinux => false;
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isFuchsia => false;

  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => '';
  static String get pathSeparator => '/';
  static String get localHostname => 'localhost';
  static String get version => '';
  static String get resolvedExecutable => '';
  static String get executable => '';
  static String get script => '';
  static List<String> get executableArguments => const [];
  static Map<String, String> get environment => const {};

  static int get numberOfProcessors {
    final cores = _hardwareConcurrency?.toDartInt;
    return cores == null || cores < 1 ? 1 : cores;
  }

  static String get localeName =>
      (_navigatorLanguage?.toDart ?? 'en-US').replaceAll('-', '_');
}
