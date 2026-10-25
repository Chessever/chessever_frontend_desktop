import 'package:flutter/foundation.dart';

/// Web stand-in for `package:stockfish`, whose engine is an FFI library the
/// browser cannot load. Only the surface `StockfishFacade` touches is kept:
/// constructing one reports [StockfishState.error] and never emits output.
enum StockfishState { disposed, error, ready, starting }

class Stockfish {
  Stockfish();

  final ValueNotifier<StockfishState> _state = ValueNotifier(
    StockfishState.error,
  );

  ValueListenable<StockfishState> get state => _state;

  Stream<String> get stdout => const Stream<String>.empty();

  set stdin(String line) {}

  void dispose() {
    _state.value = StockfishState.disposed;
  }
}
