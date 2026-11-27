# Bundling Stockfish on desktop

The `stockfish` pub package only ships Android/iOS native libs. On desktop we drive a Stockfish binary directly via UCI over stdio (`UciEngine` + `DesktopStockfish`).

## Where the driver looks

`findStockfishBinary()` resolves in this order:

1. **Bundled asset** at `assets/engine/<os>/stockfish[.exe]` - copied to `<app support>/engine/stockfish-<version>[.exe]` once per engine release and `chmod +x`ed on macOS and Linux.
2. **Homebrew paths** on macOS: `/opt/homebrew/bin/stockfish`, `/usr/local/bin/stockfish`.
3. **`PATH` lookup** via `which stockfish` (POSIX) / `where stockfish` (Windows).

If none exist, `DesktopStockfish.initialize()` logs a warning and stays in `isReady = false`. Callers should hide the engine UI in that state instead of crashing.

## Bundled binaries

Current bundled version: Stockfish 19 (official `sf_19` universal builds).

Current SHA-256 values of the committed or fetched engines:

- macOS (arm64 slice thinned from `stockfish-macos-universal`): `4e52e7f9df415cfbc5329931972ca791a63e15eff125d7f5a571acc6982224d0`
- Windows (`stockfish-windows-x86-64-universal.exe`): `45bc8e4969147db9c2eb533810637994619bff0eacc81ccfd9854394901bcbd0`
- Linux (`stockfish-linux-x86-64-universal`): `0f83d24cc46d2c66c60f16001af5444873bc112b7d028594513426894c12da19`

The Intel macOS package ships the whole universal file instead of a thinned
slice, because the x86_64 slice reads its network from the arm64 slice.

## Updating bundled binaries

1. Run `bash scripts/fetch_stockfish.sh` from the repo root (it verifies each
   archive against a pinned SHA-256; set `STOCKFISH_VERSION`, `MAC_SHA256`
   and `WIN_SHA256` for another release).
2. Replace `assets/engine/linux/stockfish` with the Linux x86-64 build.
3. Bump `kBundledStockfishVersion` in `uci_engine.dart`, so installed apps
   extract the new engine instead of reusing their old copy.
4. Update the Play catalog (`engine_catalog.dart`), the Mac App Store pin
   (`scripts/prepare_mac_app_store_engines.py`) and the checksums above.

## Why subprocess instead of FFI

- Process isolation: a wedged search can be `kill`ed without taking the app down.
- No need to compile and ship per-CPU native libs - the official Stockfish binaries are already portable per OS/arch.
- Same UCI parsing code can later target user-installed engines (Komodo, Leela, etc.), turning Chessever into a real professional desktop chess database client rather than a Stockfish-only viewer.
