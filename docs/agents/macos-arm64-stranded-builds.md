<!-- Moved verbatim from AGENTS.md (Part I §2.10, formerly CLAUDE.md §2.10) on 2026-10-12 so it is
     read on demand, not loaded into every agent session. Still binding; edit it here. -->

# Part I §2.10 — the 264/265 stranded macOS builds

**This already happened once, and the cleanup is still running.** Commit `f6bb4b60` (Jul 29) set Silicon's key to `macos-arm64`; `62da658a` (Jul 30) put it back. Builds **264 and 265** shipped in between. `versionCheckFunction` filters `app-archive.json` on an exact platform string, so those installs match zero items, get a `null` version check, and the update chip silently never appears again — no error, no retry, no log line. They cannot be fixed by any later release, because they will never see one.

Two compensations exist for them and **must not be "cleaned up"** until 264/265 installs have drained:
- The release service mirrors every bare-`macos` ingest to an additive `macos-arm64` item (hard-linked, ~0 disk). See `_mirror_macos_arm64` in `/usr/local/lib/chessever-release-service/release_service/desktop_release_service.py`; disable with `CHESSEVER_UPDATES_MACOS_ARM64_MIRROR=0`. A stranded client takes one update through it and lands on code that asks for `macos` again, which heals it permanently.
- `downloads/Chessever-arm64.dmg` serves the current Silicon installer, because the 264/265 binaries hardcode that URL as their manual-download fallback. On the legacy release server it was a symlink to `Chessever.dmg`; in R2 `scripts/r2_publish_release.py` writes it beside the stable alias on every `macos` publish. (It was missing from R2, a 404, from the R2 migration until 22.0.1.)
