import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Web stand-in for `package:stockfish`: Stockfish 19 (lite, single-threaded
/// WebAssembly build in `web/stockfish/`) running in a Web Worker, spoken to
/// over UCI text messages. Same surface the facade uses on mobile: [state],
/// [stdout], [stdin] and [dispose].
enum StockfishState { disposed, error, ready, starting }

class Stockfish {
  Stockfish() {
    try {
      final worker = web.Worker(_workerUrl.toJS);
      _worker = worker;
      worker.onmessage =
          ((web.MessageEvent event) {
            final data = event.data;
            if (data == null || !data.isA<JSString>()) return;
            _onLine((data as JSString).toDart);
          }).toJS;
      worker.onerror =
          ((web.Event _) {
            if (_state.value == StockfishState.starting) {
              _state.value = StockfishState.error;
            }
          }).toJS;
      // The worker answers `uciok` once the Wasm engine has loaded.
      worker.postMessage('uci'.toJS);
    } catch (_) {
      _state.value = StockfishState.error;
    }
  }

  static const String _workerUrl = 'stockfish/stockfish-19-lite-single.js';

  web.Worker? _worker;
  final ValueNotifier<StockfishState> _state = ValueNotifier(
    StockfishState.starting,
  );
  final StreamController<String> _stdout = StreamController.broadcast();

  ValueListenable<StockfishState> get state => _state;

  Stream<String> get stdout => _stdout.stream;

  set stdin(String line) {
    if (_state.value != StockfishState.ready) {
      throw StateError('Stockfish is not ready (${_state.value})');
    }
    _worker?.postMessage(line.toJS);
  }

  void _onLine(String text) {
    // Messages can carry several lines.
    for (final line in text.split('\n')) {
      if (line.isEmpty) continue;
      if (_state.value == StockfishState.starting && line == 'uciok') {
        _state.value = StockfishState.ready;
      }
      if (!_stdout.isClosed) _stdout.add(line);
    }
  }

  void dispose() {
    final worker = _worker;
    _worker = null;
    if (worker != null) {
      try {
        worker.postMessage('quit'.toJS);
      } catch (_) {}
      worker.terminate();
    }
    if (!_stdout.isClosed) unawaited(_stdout.close());
    _state.value = StockfishState.disposed;
  }
}
