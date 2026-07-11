# Windows terminal shutdown and native symbols design

## Problem

The Windows runner now keeps the Flutter host alive only while COM is
initialized, but Sentry still records access violations during native window
teardown. The app's terminal close path calls `windowManager.destroy()`. In
`window_manager` 0.5.1 that method posts `WM_QUIT` directly; it does not close
and destroy the HWND first. The message loop can therefore end while Flutter
and plugin-owned window state is still attached, leaving runner destruction to
unwind the native window late.

The uploaded release also lacks native Windows debug symbols, so Sentry cannot
name runner, plugin, or Flutter engine frames precisely enough to distinguish
future shutdown defects.

## Goals

- A terminal Windows close follows `WM_CLOSE` / `WM_DESTROY` before the runner
  message loop exits.
- Shutdown remains single-flight through provider disposal and the terminal
  native action.
- macOS and Linux retain their current force-destroy behavior.
- A failed graceful Windows close falls back to the existing terminal action.
- Windows release builds upload all available PDBs, including the exact
  `flutter_windows.dll.pdb`, to Sentry without blocking artifact publication
  when symbol upload itself is unavailable.

## Approach

After player operations and the tournament server have drained, the shutdown
coordinator removes its window listener and disables close interception. On
Windows it then invokes `windowManager.close()`, which posts a native close
request and lets the runner destroy its HWND normally. macOS and Linux continue
using `windowManager.destroy()`. The coordinator stays terminally
single-flight; lifecycle callbacks or the close event emitted by the native
request cannot begin a second disposal sequence. If the Windows close request
throws, the coordinator records a non-fatal diagnostic and falls back to
`destroy()` and, only if that also fails, process exit.

The Windows workflow installs `sentry-cli` only when needed and uploads PDBs
from the release bundle plus the Flutter SDK cache. Symbol upload uses the
existing Sentry project configuration and auth environment, runs after the
release build but before publication, and is non-fatal so a telemetry outage
does not withhold a working updater release.

## Verification

- Unit or source-contract tests require Windows terminal shutdown to use
  `close()` after close interception is disabled, with `destroy()` retained as
  fallback only.
- Concurrent close/lifecycle callbacks cannot dispose providers twice.
- Workflow tests require a PDB collection/upload step and inclusion of the
  Flutter engine PDB when present.
- Flutter analysis and the focused desktop test suites remain clean. Native
  compilation and close smoke tests run in the Codemagic Windows workflow, in
  accordance with the repository's no-local-build rule.
