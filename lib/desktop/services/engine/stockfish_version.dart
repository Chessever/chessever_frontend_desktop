/// Stockfish release every ChessEver build analyses with: the binary bundled
/// under `assets/engine/`, the Mac App Store helper and the browser worker in
/// `web/stockfish/`. Bump it with `scripts/fetch_stockfish.sh`.
const String kBundledStockfishVersion = '19';

/// Short engine label shown where the analysis engine is named, as Lichess
/// writes it ("SF 19").
const String kStockfishShortLabel = 'SF $kBundledStockfishVersion';

/// `SF <version>` for a UCI `id name` reply, e.g. `Stockfish 19` -> `SF 19`,
/// `Stockfish 17.1` -> `SF 17.1`, `Stockfish dev-20261127-5bdfd3e1` ->
/// `SF dev`. Anything else falls back to [kStockfishShortLabel].
String stockfishShortLabelFromUciName(String? idName) {
  final match = RegExp(
    r'^\s*Stockfish\s+(dev\b|[0-9]+(?:\.[0-9]+)*)',
    caseSensitive: false,
  ).firstMatch(idName ?? '');
  if (match == null) return kStockfishShortLabel;
  final version = match.group(1)!;
  return 'SF ${version.toLowerCase() == 'dev' ? 'dev' : version}';
}
