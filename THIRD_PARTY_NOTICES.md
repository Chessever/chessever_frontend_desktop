# Third-Party Notices

Chessever Desktop is licensed under GPL-3.0 (see `LICENSE`). It bundles,
vendors, and depends on third-party software covered by their own licenses.
This file records the notices required for redistribution. It is not
exhaustive of every transitive dependency; the authoritative dependency list
is `pubspec.lock`, and each package's license travels with it on pub.dev.

## Bundled binaries

### Stockfish 17.1

Chessever Desktop ships prebuilt Stockfish chess engine binaries:

- `assets/engine/macos/stockfish`
- `assets/engine/windows/stockfish.exe`

- **Project:** Stockfish — https://stockfishchess.org/
- **Source:** https://github.com/official-stockfish/Stockfish
- **Version:** 17.1
- **License:** GNU General Public License v3.0 (GPL-3.0)
- **Provenance:** Official release builds downloaded from
  https://stockfishchess.org/download/ (macOS Apple Silicon, Windows AVX2).
  Refresh with `bash scripts/fetch_stockfish.sh`.
- **Bundled SHA-256 (also recorded in
  `lib/desktop/services/engine/desktop_engine_assets.md`):**
  - macOS: `9345c44970093cabed9757be86a9ca86809a5b6ca1bdc654cf51a5eed7568858`
  - Windows: `5f95eaea0d4eb697381989187ce6eb4d6ad59283c34421765ecc73cdb09ba766`

**Written offer / source availability.** Stockfish is free software released
under GPL-3.0. The complete corresponding source for the bundled binaries is
the official tagged release matching the version above, available at
https://github.com/official-stockfish/Stockfish. A full copy of the GPL-3.0
license text is in this repository's `LICENSE` file, which applies to both
Chessever Desktop and the bundled Stockfish binaries.

### Mac App Store engine resources

The dedicated Mac App Store package seals its executable engines inside
`Contents/Helpers` and model data inside `Contents/Resources/Engines`:

- **Stockfish 18:** official `sf_18` release, combined from the unmodified
  Apple Silicon and Intel AVX2 executables. GPL-3.0; source and build files:
  https://github.com/official-stockfish/Stockfish/tree/sf_18.
- **Leela Chess Zero 0.32.0:** official universal macOS executable,
  GPL-3.0-or-later. Source and build files:
  https://github.com/LeelaChessZero/lc0/tree/v0.32.0.
- **Leela network `t1-256x10-distilled-swa-2432500.pb.gz`:** created by
  `masterkni6`, distributed unchanged from the official network host. The
  creator permits anyone to use it however they want:
  https://github.com/orgs/LeelaChessZero/discussions/2430.
- **Maia-3:** the unmodified `maia3_simplified.onnx` model published at
  https://www.maiachess.com/maia3/maia3_simplified.onnx. Maia-3 is released by
  the University of Toronto CSSLab under AGPL-3.0. Source and model links:
  https://github.com/CSSLab/maia3. Citation: Daniel Monroe, George Eilender,
  Philip Chalmers, Zhenwei Tang and Ashton Anderson, *Chessformer: A Unified
  Architecture for Chess Modeling*, ICLR 2026.

`scripts/prepare_mac_app_store_engines.py` pins download URLs and SHA-256
checksums. The package includes the GPL text, the Maia-3 AGPL text, and these
notices in its engine resource directory. The Maia-3 license copy comes from
upstream commit `1e13597c42d4858b7cfd7cfdae01e297263364b2`.

## Vendored source

### desktop_updater

A copy of the `desktop_updater` Flutter plugin is vendored under
`third_party/desktop_updater/`.

- **License:** MIT — see `third_party/desktop_updater/LICENSE`
- **Copyright:** © 2022 Burak Karahan
- **Upstream:** https://pub.dev/packages/desktop_updater

## Dart / Flutter package dependencies

All pub package dependencies are pinned in `pubspec.lock`. Each package is
distributed under its own license (predominantly BSD-3-Clause, MIT, and
Apache-2.0). To enumerate the licenses of the resolved dependency set, run:

```bash
flutter pub deps --style=compact
# or, for a license report, use a tool such as:
dart pub global activate cider && cider ...   # (optional)
```

## Country flags and assets

Flag, font, and image assets retained from the upstream Chessever app remain
under their original licenses. Where an asset's license requires attribution,
the attribution travels with the asset directory.
