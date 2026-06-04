#!/usr/bin/env bash
# Builds the Linux desktop release bundle via desktop_updater:release, mirroring
# the macOS build step. Installs the GTK / Flutter-Linux toolchain on the
# Codemagic linux_x2 image, injects the same dart-defines as macOS/Windows, and
# stages the bundle under dist/<build>/<name>-<version>+<build>-linux/ where
# codemagic_publish_linux.sh picks it up.
#
# Additive: this script is Linux-only and shares no state with the macOS/Windows
# pipelines. Removing it has no effect on those workflows.
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# The Linux Stockfish engine asset is intentionally NOT listed in pubspec.yaml
# (assets are shared across platforms — listing it would bundle the 78 MB
# binary into the macOS/Windows apps too). Inject it here so only the Linux
# build carries it. Idempotent; the binary is committed at the path below.
LINUX_ENGINE_ASSET='    - assets/engine/linux/stockfish'
[ -f assets/engine/linux/stockfish ] || die "assets/engine/linux/stockfish missing — Linux engine binary not committed"
if ! grep -qF "$LINUX_ENGINE_ASSET" pubspec.yaml; then
  # Insert right after the bundled Windows engine asset line (awk: portable,
  # no GNU/BSD sed newline differences).
  awk -v ins="$LINUX_ENGINE_ASSET" \
    '{print} /^    - assets\/engine\/windows\/stockfish\.exe$/{print ins}' \
    pubspec.yaml > pubspec.yaml.tmp && mv pubspec.yaml.tmp pubspec.yaml
  grep -qF "$LINUX_ENGINE_ASSET" pubspec.yaml || die "failed to inject Linux engine asset into pubspec.yaml"
  echo "Injected Linux engine asset into pubspec.yaml for this build."
fi

# Same dart-define contract as scripts/codemagic_publish_macos.sh so the three
# desktop platforms ship with an identical configuration surface.
# Matches the keys the desktop app actually compiles (lib/desktop/services/
# desktop_env.dart). The gamebase proxy is GAMEBASE_PROXY_BASE and optional —
# the app falls back when it's absent; there is no GAMEBASE_API_KEY define.
REQUIRED_DART_DEFINE_KEYS=(
  SUPABASE_URL
  SUPABASE_ANON_KEY
  GOOGLE_DESKTOP_CLIENT_ID
  GOOGLE_DESKTOP_CLIENT_SECRET
  SENTRY_FLUTTER
)
OPTIONAL_DART_DEFINE_KEYS=(
  GOOGLE_WEB_CLIENT_ID
  BILLING_API_BASE
  GAMEBASE_PROXY_BASE
)

DART_DEFINES=()
for name in "${REQUIRED_DART_DEFINE_KEYS[@]}"; do
  [ -n "${!name:-}" ] || die "$name is required"
  DART_DEFINES+=(--dart-define="$name=${!name}")
done
for name in "${OPTIONAL_DART_DEFINE_KEYS[@]}"; do
  if [ -n "${!name:-}" ]; then
    DART_DEFINES+=(--dart-define="$name=${!name}")
  fi
done

# Flutter Linux desktop build dependencies. The Codemagic linux_x2 image ships
# Flutter + a C/C++ toolchain, but the GTK dev headers and ninja are not
# guaranteed. apt is idempotent, so re-running skips anything already installed.
if command -v apt-get >/dev/null 2>&1; then
  # Codemagic's Ubuntu image runs unattended-upgrades at boot, which holds the
  # dpkg/apt lock and makes a naive `apt-get install` fail with "Could not get
  # lock /var/lib/dpkg/lock-frontend". Stop the auto-upgrader, wait for the
  # lock to clear, then install with one retry.
  sudo systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  for _ in $(seq 1 60); do
    if sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then
      echo "waiting for apt/dpkg lock (unattended-upgrades)…"
      sleep 5
    else
      break
    fi
  done
  PKGS=(
    clang cmake ninja-build pkg-config file
    build-essential libgtk-3-dev liblzma-dev
    desktop-file-utils
    libkeybinder-3.0-dev libnotify-dev
    libcurl4-openssl-dev zlib1g-dev
    libasound2-dev
  )
  apt_install() {
    sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
  }
  apt_install || { echo "apt failed (likely lock race); retrying once…"; sleep 15; apt_install; }
fi
# Plugin-specific native deps (CMake config aborts at the first missing one;
# flutter_soloud's ALSA backend needs the header at compile time):
#   libkeybinder-3.0-dev -> hotkey_manager   libnotify-dev -> local_notifier
#   libcurl4-openssl-dev + zlib1g-dev -> sentry-native (sentry_flutter)
#   libasound2-dev (alsa/asoundlib.h) -> flutter_soloud ALSA backend
# window_manager / screen_retriever / desktop_drop / url_launcher use GTK3
# (libgtk-3-dev, above).

flutter config --enable-linux-desktop
export FLUTTER_ROOT="${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}"
rm -rf dist
dart run desktop_updater:release linux --release "${DART_DEFINES[@]}"

echo "Linux release bundle staged under dist/"
