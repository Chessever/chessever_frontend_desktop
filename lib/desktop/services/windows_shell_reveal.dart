// ShellExecuteExW is reached through FFI, which the web build cannot import.
// The web variant reports that nothing was launched.
export 'windows_shell_reveal_io.dart'
    if (dart.library.js_interop) 'windows_shell_reveal_web.dart';
