import 'package:flutter/foundation.dart';

/// Mirrors `package:stockfish`'s state enum. The values and their order match
/// upstream so `StockfishState.ready` reads the same on every platform.
enum StockfishState { disposed, error, ready, starting }

/// Web build stand-in for `package:stockfish`'s FFI engine. The browser has no
/// in-process native engine, so constructing one fails; the facade never does.
class Stockfish {
  factory Stockfish() =>
      throw UnsupportedError(
        'The in-process Stockfish engine is not available on the web.',
      );

  ValueListenable<StockfishState> get state => throw UnimplementedError();

  Stream<String> get stdout => throw UnimplementedError();

  set stdin(String line) => throw UnimplementedError();

  void dispose() {}
}
