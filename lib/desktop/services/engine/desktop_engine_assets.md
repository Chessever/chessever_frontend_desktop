# Bundling Stockfish on desktop

The `stockfish` pub package only ships Android/iOS native libs. On desktop we drive a Stockfish binary directly via UCI over stdio (`UciEngine` + `DesktopStockfish`).

## Where the driver looks

`findStockfishBinary()` resolves in this order:

1. **Bundled asset** at `assets/engine/<os>/stockfish[.exe]` - copied to the app support directory at first launch and `chmod +x`ed on macOS.
2. **Homebrew paths** on macOS: `/opt/homebrew/bin/stockfish`, `/usr/local/bin/stockfish`.
3. **`PATH` lookup** via `which stockfish` (POSIX) / `where stockfish` (Windows).

If none exist, `DesktopStockfish.initialize()` logs a warning and stays in `isReady = false`. Callers should hide the engine UI in that state instead of crashing.

## Bundled binaries

Current bundled version: Stockfish 17.1.

Current SHA-256 values:

- macOS: `9345c44970093cabed9757be86a9ca86809a5b6ca1bdc654cf51a5eed7568858`
- Windows: `5f95eaea0d4eb697381989187ce6eb4d6ad59283c34421765ecc73cdb09ba766`

## Updating bundled binaries

1. Download official builds from <https://stockfishchess.org/download/>.
2. Or run `bash scripts/fetch_stockfish.sh` from the repo root.
3. Confirm the files are present:
   - macOS Apple Silicon: `assets/engine/macos/stockfish`
   - Windows AVX2: `assets/engine/windows/stockfish.exe`
4. Update the checksums above.

## Why subprocess instead of FFI

- Process isolation: a wedged search can be `kill`ed without taking the app down.
- No need to compile and ship per-CPU native libs - the official Stockfish binaries are already portable per OS/arch.
- Same UCI parsing code can later target user-installed engines (Komodo, Leela, etc.), turning Chessever into a real professional desktop chess database client rather than a Stockfish-only viewer.
