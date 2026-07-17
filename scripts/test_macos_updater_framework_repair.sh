#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/third_party/desktop_updater/macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/chessever-framework-repair.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

CONTENTS="$WORKDIR/Chessever.app/Contents"
FRAMEWORK="$CONTENTS/Frameworks/resqlite.framework"
mkdir -p "$FRAMEWORK/Versions/A/Resources"

cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>resqlite</string>
</dict>
</plist>
PLIST

printf '#!/bin/sh\nexit 0\n' > "$FRAMEWORK/Versions/A/resqlite"
chmod +x "$FRAMEWORK/Versions/A/resqlite"

REPAIR="$WORKDIR/repair.sh"
python3 - "$SOURCE" "$REPAIR" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
output = pathlib.Path(sys.argv[2])
start_marker = "# BEGIN DESKTOP_UPDATER_FRAMEWORK_REPAIR"
end_marker = "# END DESKTOP_UPDATER_FRAMEWORK_REPAIR"

start = next(i for i, line in enumerate(source) if start_marker in line) + 1
end = next(i for i, line in enumerate(source[start:], start) if end_marker in line)
block = []
for line in source[start:end]:
    block.append(line[8:] if line.startswith("        ") else line)

output.write_text(
    "#!/bin/sh\nset -eu\nTARGET=\"$1\"\n" + "\n".join(block) +
    "\nrepair_versioned_frameworks\n",
    encoding="utf-8",
)
PY

chmod +x "$REPAIR"
sh -n "$REPAIR"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Embedded updater repair syntax verified; symlink runtime test requires macOS"
  exit 0
fi

"$REPAIR" "$CONTENTS"

test -L "$FRAMEWORK/Versions/Current"
test "$(readlink "$FRAMEWORK/Versions/Current")" = "A"
test -L "$FRAMEWORK/resqlite"
test "$(readlink "$FRAMEWORK/resqlite")" = "Versions/Current/resqlite"
test -x "$FRAMEWORK/resqlite"
test -L "$FRAMEWORK/Resources"
test "$(readlink "$FRAMEWORK/Resources")" = "Versions/Current/Resources"

echo "Verified updater repair for a versioned resqlite.framework"
