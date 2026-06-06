import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:stockfish/stockfish.dart' as upstream;

import 'package:chessever/desktop/services/engine/uci_engine.dart';

// Re-export the upstream enum so call-sites can use `StockfishState.ready`
// regardless of which backend is active. The values match across mobile/desktop.
export 'package:stockfish/stockfish.dart' show StockfishState;

/// Drop-in replacement for `package:stockfish`'s `Stockfish` class.
///
/// On Android/iOS this delegates to the upstream FFI-based engine. On macOS,
/// Windows, and Linux the upstream package has no native libs, so we spawn a
/// Stockfish binary as a subprocess and drive it over UCI/stdio. The public
/// surface (`state`, `stdout`, `stdin`, `dispose`) matches the upstream
/// class exactly, which lets `StockfishSingleton` stay shared between
/// platforms unchanged.
class Stockfish {
  Stockfish._desktop();
  Stockfish._mobile(upstream.Stockfish backend) : _upstream = backend {
    backend.state.addListener(_forwardUpstreamState);
    _upstreamSub = backend.stdout.listen(
      _stdoutController.add,
      onError: _stdoutController.addError,
    );
  }

  static Stockfish? _instance;
  static bool _desktopEngineUnavailable = false;

  static bool get desktopEngineUnavailable => _desktopEngineUnavailable;

  static void resetDesktopEngineAvailabilityForRetry() {
    _desktopEngineUnavailable = false;
  }

  // --- desktop backend ---
  final _state = ValueNotifier<upstream.StockfishState>(
    upstream.StockfishState.starting,
  );
  final _stdoutController = StreamController<String>.broadcast();
  UciEngine? _engine;
  StreamSubscription<String>? _engineSub;

  // --- mobile backend ---
  upstream.Stockfish? _upstream;
  StreamSubscription<String>? _upstreamSub;

  bool _disposed = false;
  bool _isDesktop = false;

  /// Mirrors the upstream factory: only one live instance at a time.
  factory Stockfish() {
    if (_instance != null) {
      throw StateError('Multiple instances are not supported, yet.');
    }

    final useDesktopBackend =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;

    if (useDesktopBackend) {
      final s = Stockfish._desktop();
      s._isDesktop = true;
      _instance = s;
      // Fire-and-forget: state transitions to ready/error via the notifier.
      unawaited(s._initDesktop());
      return s;
    }

    final s = Stockfish._mobile(upstream.Stockfish());
    _instance = s;
    return s;
  }

  Future<void> _initDesktop() async {
    try {
      final binaryPath = await findStockfishBinary();
      if (binaryPath == null) {
        _desktopEngineUnavailable = true;
        if (kDebugMode) {
          debugPrint(
            '⚠️ Stockfish facade: no engine binary found. '
            'Bundle one under assets/engine/ or install via brew/PATH.',
          );
        }
        if (!_disposed) _state.value = upstream.StockfishState.error;
        return;
      }

      final engine = await UciEngine.spawn(binaryPath);
      if (_disposed) {
        await engine.dispose();
        return;
      }

      // Forward stdout to subscribers BEFORE the UCI handshake so the singleton
      // can attach a `readyok` listener at any time.
      _engineSub = engine.lines.listen(
        _stdoutController.add,
        onError: _stdoutController.addError,
      );
      _engine = engine;

      // Run the standard UCI handshake (`uci` → `uciok` → `isready` → `readyok`).
      // We do not pre-set MultiPV/Threads here because the singleton handles
      // those via setoption commands once it sees the engine is ready.
      final ok = await _doHandshake(engine);

      if (_disposed) {
        await engine.dispose();
        return;
      }

      _state.value =
          ok ? upstream.StockfishState.ready : upstream.StockfishState.error;
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('⚠️ Stockfish facade init failed: $e');
        debugPrint('$st');
      }
      if (!_disposed) _state.value = upstream.StockfishState.error;
    }
  }

  Future<bool> _doHandshake(UciEngine engine) async {
    final ready = Completer<bool>();
    final sub = engine.lines.listen((line) {
      if (line == 'uciok') {
        engine.send('isready');
      } else if (line == 'readyok') {
        if (!ready.isCompleted) ready.complete(true);
      }
    });
    engine.send('uci');
    final ok = await ready.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    await sub.cancel();
    return ok;
  }

  void _forwardUpstreamState() {
    if (_upstream != null) {
      _state.value = _upstream!.state.value;
    }
  }

  /// Same shape as upstream: a `ValueListenable` that flips through
  /// starting → ready → disposed/error.
  ValueListenable<upstream.StockfishState> get state => _state;

  /// Same shape as upstream: every line of engine stdout, broadcast.
  Stream<String> get stdout => _stdoutController.stream;

  /// Same shape as upstream: throws if the engine isn't ready.
  set stdin(String line) {
    final stateValue = _state.value;
    if (stateValue != upstream.StockfishState.ready) {
      throw StateError('Stockfish is not ready ($stateValue)');
    }
    if (_isDesktop) {
      _engine?.send(line);
    } else {
      _upstream!.stdin = line;
    }
  }

  /// Same shape as upstream: signals the engine to quit.
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    if (_isDesktop) {
      final engine = _engine;
      _engine = null;
      if (engine != null) {
        try {
          engine.send('stop');
        } catch (_) {}
        try {
          engine.send('quit');
        } catch (_) {}
        unawaited(engine.dispose());
      }
      unawaited(_engineSub?.cancel());
      _engineSub = null;
      if (!_stdoutController.isClosed) {
        unawaited(_stdoutController.close());
      }
      _state.value = upstream.StockfishState.disposed;
    } else {
      try {
        _upstream!.state.removeListener(_forwardUpstreamState);
      } catch (_) {}
      unawaited(_upstreamSub?.cancel());
      _upstreamSub = null;
      try {
        _upstream!.dispose();
      } catch (_) {}
      _state.value = upstream.StockfishState.disposed;
    }

    _instance = null;
  }
}
