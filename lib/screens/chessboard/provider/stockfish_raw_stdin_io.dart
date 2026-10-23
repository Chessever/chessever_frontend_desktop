import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:ffi/ffi.dart';

// Cache for native FFI pointers to avoid expensive lookups during teardown/hot-restart
DynamicLibrary? _nativeStockfishLib;
int Function(Pointer<Utf8>)? _nativeWriteFn;

/// Write a UCI command directly to the native Stockfish stdin buffer via FFI,
/// bypassing the Dart [Stockfish] wrapper's state check that throws when the
/// engine isn't in [StockfishState.ready].
///
/// PERFORMANCE: Uses [Isolate.run] to avoid blocking the main thread. This is
/// critical during hot-restart teardown where the native engine might be busy
/// and holding the stdin mutex, which would otherwise hang the entire app.
Future<void> rawStockfishStdin(String command) async {
  // On macOS/Windows there is no in-process stockfish native library to look
  // up — the engine runs as a subprocess, owned by the façade. The desktop
  // façade's dispose() already sends 'stop'/'quit' to the subprocess, so
  // there's nothing to do here.
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    return;
  }
  try {
    await Isolate.run(() {
      _nativeStockfishLib ??=
          Platform.isAndroid
              ? DynamicLibrary.open('libstockfish.so')
              : DynamicLibrary.process();

      _nativeWriteFn ??=
          _nativeStockfishLib!
              .lookup<NativeFunction<IntPtr Function(Pointer<Utf8>)>>(
                'stockfish_stdin_write',
              )
              .asFunction<int Function(Pointer<Utf8>)>();

      final ptr = '$command\n'.toNativeUtf8();
      try {
        _nativeWriteFn!(ptr);
      } finally {
        calloc.free(ptr);
      }
    });
  } catch (_) {
    // Silently ignore FFI errors during teardown
  }
}
