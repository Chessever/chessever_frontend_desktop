# Desktop distribution through GitHub Actions

The production branch is `main`. Both release workflows are manually dispatched
and use the protected `release` environment. Only jobs running from `main` receive
signing or publishing credentials. The environment has no required reviewer, so a
dispatched run starts at once: dispatching it is the approval. Setup uses native background steps followed by
`wait-all`; no signing or publishing step runs in the background.

## Website downloads

Run **Desktop release** (`desktop-release.yml`) for any combination of:

| Target | Website installer | Updater platform |
| --- | --- | --- |
| macOS Apple Silicon | `Chessever.dmg` | `macos` |
| macOS Intel | `Chessever-intel.dmg` | `macos-x64` |
| Windows | `Chessever-Setup.exe` | `windows` |
| Linux | `Chessever.deb` | `linux` |

These editions retain Stripe billing and the existing updater. The GitHub jobs
reuse the Codemagic build, signing, notarization and R2 publishing scripts.
`ruby scripts/ci/check_codemagic_parity.rb` verifies all five historical recipes,
including the separate unsigned Flutter master build. `codemagic.yaml` remains a
behavior reference, rather than the service used to run releases.

Leave **Publish to R2** unchecked to build signed installers as seven-day GitHub
artifacts without changing website downloads or installed clients. Checking it is
the explicit manual action that publishes the direct-download release. macOS uses
Developer ID signing and Apple notarization, rather than App Review.

## Mac App Store

Run **Mac App Store review** (`desktop-app-store.yml`). It produces a universal
Apple Silicon + Intel `.pkg` for App Store Connect app `6824524785`, bundle
`com.chessever.desktop`. The dedicated build script sets both
`MAC_APP_STORE=true` and `CHESSEVER_APP_STORE=YES`, uses sandbox entitlements,
bundles signed universal engines, and uses Apple purchases. It does not invoke
the website updater or R2 publishing scripts.

App Review rejected 22.15.1 (481) on two points that the store edition must keep
honoring. Guideline 5.2.5: no Apple trademark ("Mac", "for Mac", "macOS") in
the app name, subtitle or screenshot captions. Guideline 4: sign-in never leaves
the app. The edition shows the native Sign in with Apple sheet, which requires
`com.apple.developer.applesignin` in `macos/Runner/AppStore.entitlements` and in
the store profile. Google opens in an `ASWebAuthenticationSession` sheet
(`DesktopWebAuthBridge.swift`) instead of the default browser.

**Submit review** defaults to checked. The workflow uploads the package, waits for
processing, and submits for App Review with `--platform MAC_OS --release-type
MANUAL`. Approval holds the app for a human to release in App Store Connect.
There is no publish-now command or automatic release option.

Uncheck **Submit review** only when an upload without changing the current review
is intended, for example while a previous version is already waiting for review.
The new build appears in App Store Connect/TestFlight after Apple processes it.
**Replace pending review** defaults to unchecked and must be explicitly selected
to cancel an earlier submission and submit its replacement. It still enforces
manual release. Never treat a successful upload-only run as a review submission.

The production store provisioning profile is `WR4MCF5FY6`. Renew it when needed;
do not substitute the direct-download profile. Store certificates are separate
from Developer ID certificates. The protected environment contains:

- `MAC_APP_STORE_APPLICATION_P12_B64`
- `MAC_APP_STORE_INSTALLER_P12_B64`
- `MAC_APP_STORE_P12_PASSWORD`
- `APP_STORE_CONNECT_KEY_IDENTIFIER`, `APP_STORE_CONNECT_ISSUER_ID`,
  `APP_STORE_CONNECT_PRIVATE_KEY`

Only client-safe settings are written to the allowlisted temporary Dart config.
Signing material lives in an ephemeral runner keychain, is removed in `always()`
cleanup, and is never included in the installer artifact. Actions use full commit
pins, checkout does not persist credentials, and the GitHub token is read-only.
No pull-request or push event can invoke either production release workflow.

The Codemagic CLI tools are pinned open-source utilities running on GitHub
runners. Their use does not invoke the hosted Codemagic build service.

Every job has a time limit, so a stalled build fails instead of running for
three hours. The limits sit above the slowest successful release (23 October
2026), where macOS Intel took 63 minutes and the R2 publish steps took 23-30
minutes:

| Job | Job limit | Build step limit |
|---|---|---|
| macOS (Apple Silicon, Intel) | 90 min | 75 min (build, notarize and publish) |
| Windows | 75 min | 30 min |
| Linux | 60 min | 20 min |
| Mac App Store | 75 min | 45 min, then 30 min for upload and review |
| macOS on Flutter master | 60 min | 40 min |

Revisit the limits when release durations change. The review script waits at
most 10 minutes for Apple to process a build. Apple processing is external: a
timeout is a failed run, not proof of submission. A retry reuses a build that
was already uploaded.
