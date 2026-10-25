/// The web build has no in-process native Stockfish, so there is no stdin
/// buffer to write to.
Future<void> rawStockfishStdin(String command) async {}
