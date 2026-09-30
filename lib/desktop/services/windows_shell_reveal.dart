import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows-only shell launch used by "Show in folder".
///
/// Kept Flutter-free (and free of `Process.start`) so the exact production path
/// can be exercised on Windows during verification.
///
/// Why not `explorer.exe /select,"…"` through `Process.start`: Explorer
/// re-parses its own command line and only honors LITERAL quotes, while Dart's
/// argv escaping rewrites `"` as `\"` and wraps the whole argument. Both
/// `"/select,\"<path>\""` and `"/select,<path>"` were measured on Windows 11 to
/// be rejected — Explorer silently opens a Documents window instead. Passing the
/// parameter string through the shell's `open` verb keeps the quotes literal and
/// Explorer then opens the containing folder with the exact file selected.
bool executeWindowsShellOpen({
  required String executable,
  required String parameters,
}) {
  if (!Platform.isWindows) return false;
  final shellExecuteEx = _shellExecuteExW();
  if (shellExecuteEx == null) return false;

  final info = calloc<_ShellExecuteInfoW>();
  final verb = 'open'.toNativeUtf16();
  final file = executable.toNativeUtf16();
  final params = parameters.toNativeUtf16();
  try {
    info.ref
      ..cbSize = sizeOf<_ShellExecuteInfoW>()
      ..fMask = _seeMaskFlagNoUi
      ..lpVerb = verb
      ..lpFile = file
      ..lpParameters = params
      ..nShow = _swShowNormal;
    return shellExecuteEx(info) != 0;
  } on ArgumentError {
    return false;
  } on StateError {
    return false;
  } finally {
    calloc
      ..free(info)
      ..free(verb)
      ..free(file)
      ..free(params);
  }
}

const int _seeMaskFlagNoUi = 0x00000400;
const int _swShowNormal = 1;

_DartShellExecuteExW? _shellExecuteExCache;

_DartShellExecuteExW? _shellExecuteExW() {
  final cached = _shellExecuteExCache;
  if (cached != null) return cached;
  try {
    final resolved = DynamicLibrary.open(
      'shell32.dll',
    ).lookupFunction<_NativeShellExecuteExW, _DartShellExecuteExW>(
      'ShellExecuteExW',
    );
    _shellExecuteExCache = resolved;
    return resolved;
  } on ArgumentError {
    return null;
  }
}

typedef _NativeShellExecuteExW = Int32 Function(Pointer<_ShellExecuteInfoW>);
typedef _DartShellExecuteExW = int Function(Pointer<_ShellExecuteInfoW>);

/// `SHELLEXECUTEINFOW` — field order and native types mirror the platform
/// structure (112 bytes on x64, asserted during verification).
final class _ShellExecuteInfoW extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int fMask;
  @IntPtr()
  external int hwnd;
  external Pointer<Utf16> lpVerb;
  external Pointer<Utf16> lpFile;
  external Pointer<Utf16> lpParameters;
  external Pointer<Utf16> lpDirectory;
  @Int32()
  external int nShow;
  @IntPtr()
  external int hInstApp;
  external Pointer<Void> lpIDList;
  external Pointer<Utf16> lpClass;
  @IntPtr()
  external int hkeyClass;
  @Uint32()
  external int dwHotKey;
  @IntPtr()
  external int hIconOrMonitor;
  @IntPtr()
  external int hProcess;
}
