<!-- Moved verbatim from AGENTS.md Part II (formerly AGENTS.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

## 5. Stockfish replacement (the hard one)

- Pub package `stockfish` is mobile-only because it bundles native libs for Android/iOS.
- Replacement: ship a Stockfish binary per OS and drive it via UCI over stdio.
  - Place binaries under `assets/engine/macos/stockfish` and `assets/engine/windows/stockfish.exe`.
  - At runtime, copy the asset to the app support dir (`getApplicationSupportDirectory()`), `chmod +x` on macOS, then `Process.start` it.
  - Use a `StreamController<String>` over stdout to parse UCI; reuse the existing `StockfishSingleton` API surface so callers don't change.
- Reference: official Stockfish builds at https://stockfishchess.org/download/.
- This is a multi-iteration task. First iteration: get the interface and binary copy in place; second iteration: parse UCI and surface evals; third: tune hash/threads to desktop defaults.
- **⚠️ Linux engine is bundled DIFFERENTLY.** `pubspec.yaml`'s `flutter: assets:` list is shared across platforms, so anything listed there ships in *every* desktop app. macOS/Windows engines are listed in pubspec normally. The Linux engine (`assets/engine/linux/stockfish`, ~78 MB) is **committed but deliberately NOT in pubspec** — listing it would add 78 MB to the mac/Windows downloads. The Linux CI build (`scripts/codemagic_build_linux_release.sh`) **injects** the `- assets/engine/linux/stockfish` line into pubspec at build time (idempotent awk insert after the Windows entry); only the Linux bundle carries it. `uci_engine.dart` keeps the `Platform.isLinux` branch (no-op on mac/Win). **Never add the Linux line back to pubspec** — it reintroduces the bloat for mac/Win.
