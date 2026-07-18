#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/third_party/desktop_updater/macos/desktop_updater/Sources/desktop_updater/DesktopUpdaterPlugin.swift"
PUBLISH_SOURCE="$REPO_ROOT/scripts/codemagic_publish_macos.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/chessever-framework-repair.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

CONTENTS="$WORKDIR/Chessever.app/Contents"
FRAMEWORK="$CONTENTS/Frameworks/resqlite.framework"
PRESERVED_FRAMEWORK="$CONTENTS/Frameworks/Preserved.framework"
AMBIGUOUS_FRAMEWORK="$CONTENTS/Frameworks/Ambiguous.framework"
BLOCKED_FRAMEWORK="$CONTENTS/Frameworks/Blocked.framework"
OUTSIDE_FRAMEWORK="$WORKDIR/Outside.framework"
mkdir -p \
  "$FRAMEWORK/Versions/A/Resources" \
  "$FRAMEWORK/Versions/C/Resources" \
  "$FRAMEWORK/Versions/Z/Resources" \
  "$PRESERVED_FRAMEWORK/Versions/A/Resources" \
  "$PRESERVED_FRAMEWORK/Versions/C/Resources" \
  "$AMBIGUOUS_FRAMEWORK/Versions/A/Resources" \
  "$AMBIGUOUS_FRAMEWORK/Versions/C/Resources" \
  "$OUTSIDE_FRAMEWORK/Versions/A/Resources" \
  "$BLOCKED_FRAMEWORK/Versions/A/Resources"

write_framework_plist() {
  local path="$1"
  local executable="$2"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$executable</string>
</dict>
</plist>
PLIST
}

write_framework_plist "$FRAMEWORK/Versions/A/Resources/Info.plist" resqlite
write_framework_plist "$FRAMEWORK/Versions/C/Resources/Info.plist" resqlite
write_framework_plist "$FRAMEWORK/Versions/Z/Resources/Info.plist" missing_launcher
write_framework_plist "$PRESERVED_FRAMEWORK/Versions/A/Resources/Info.plist" preserved
write_framework_plist "$PRESERVED_FRAMEWORK/Versions/C/Resources/Info.plist" preserved
write_framework_plist "$AMBIGUOUS_FRAMEWORK/Versions/A/Resources/Info.plist" ambiguous
write_framework_plist "$AMBIGUOUS_FRAMEWORK/Versions/C/Resources/Info.plist" ambiguous
write_framework_plist "$BLOCKED_FRAMEWORK/Versions/A/Resources/Info.plist" blocked

printf '#!/bin/sh\nexit 0\n' > "$FRAMEWORK/Versions/C/resqlite"
# A and Z do not contain the executable declared by their Info.plist, leaving C
# as the only unambiguous recovery candidate for the missing Current link.
printf '#!/bin/sh\nexit 0\n' > "$FRAMEWORK/Versions/Z/resqlite"
printf '#!/bin/sh\nexit 0\n' > "$PRESERVED_FRAMEWORK/Versions/A/preserved"
printf '#!/bin/sh\nexit 0\n' > "$PRESERVED_FRAMEWORK/Versions/C/preserved"
printf '#!/bin/sh\nexit 0\n' > "$AMBIGUOUS_FRAMEWORK/Versions/A/ambiguous"
printf '#!/bin/sh\nexit 0\n' > "$AMBIGUOUS_FRAMEWORK/Versions/C/ambiguous"
printf '#!/bin/sh\nexit 0\n' > "$BLOCKED_FRAMEWORK/Versions/A/blocked"
chmod +x \
  "$FRAMEWORK/Versions/C/resqlite" \
  "$FRAMEWORK/Versions/Z/resqlite" \
  "$PRESERVED_FRAMEWORK/Versions/A/preserved" \
  "$PRESERVED_FRAMEWORK/Versions/C/preserved" \
  "$AMBIGUOUS_FRAMEWORK/Versions/A/ambiguous" \
  "$AMBIGUOUS_FRAMEWORK/Versions/C/ambiguous" \
  "$BLOCKED_FRAMEWORK/Versions/A/blocked"

# Exercise repair of a broken link and of valid links with incorrect targets.
ln -s Missing "$FRAMEWORK/Versions/Current"
ln -s Versions/A/resqlite "$FRAMEWORK/resqlite"
ln -s Versions/Missing/Resources "$FRAMEWORK/Resources"

# A valid Current target is authoritative even when another valid version is
# present. Repair the root links without guessing a different version.
ln -s A "$PRESERVED_FRAMEWORK/Versions/Current"
ln -s Versions/C/preserved "$PRESERVED_FRAMEWORK/preserved"
ln -s Versions/C/Resources "$PRESERVED_FRAMEWORK/Resources"

# With multiple valid versions and no Current hint, repair must refuse to guess.

# A framework-root symlink must never make repair traverse outside Frameworks.
printf 'outside-must-not-change\n' > "$OUTSIDE_FRAMEWORK/marker"
ln -s "$OUTSIDE_FRAMEWORK" "$CONTENTS/Frameworks/Linked.framework"

# A real node at a canonical link path must never be deleted by repair.
printf 'do-not-delete\n' > "$BLOCKED_FRAMEWORK/blocked"

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
test "$(readlink "$FRAMEWORK/Versions/Current")" = "C"
test -L "$FRAMEWORK/resqlite"
test "$(readlink "$FRAMEWORK/resqlite")" = "Versions/Current/resqlite"
test -x "$FRAMEWORK/resqlite"
test -L "$FRAMEWORK/Resources"
test "$(readlink "$FRAMEWORK/Resources")" = "Versions/Current/Resources"
test "$(readlink "$PRESERVED_FRAMEWORK/Versions/Current")" = "A"
test "$(readlink "$PRESERVED_FRAMEWORK/preserved")" = "Versions/Current/preserved"
test "$(readlink "$PRESERVED_FRAMEWORK/Resources")" = "Versions/Current/Resources"
test ! -e "$AMBIGUOUS_FRAMEWORK/Versions/Current"
test ! -e "$AMBIGUOUS_FRAMEWORK/ambiguous"
test "$(cat "$BLOCKED_FRAMEWORK/blocked")" = "do-not-delete"
test "$(cat "$OUTSIDE_FRAMEWORK/marker")" = "outside-must-not-change"

# A second pass must leave every already-correct link node untouched.
current_inode="$(stat -f '%i' "$FRAMEWORK/Versions/Current")"
executable_inode="$(stat -f '%i' "$FRAMEWORK/resqlite")"
resources_inode="$(stat -f '%i' "$FRAMEWORK/Resources")"
"$REPAIR" "$CONTENTS"
test "$(stat -f '%i' "$FRAMEWORK/Versions/Current")" = "$current_inode"
test "$(stat -f '%i' "$FRAMEWORK/resqlite")" = "$executable_inode"
test "$(stat -f '%i' "$FRAMEWORK/Resources")" = "$resources_inode"
test "$(cat "$BLOCKED_FRAMEWORK/blocked")" = "do-not-delete"
test "$(cat "$OUTSIDE_FRAMEWORK/marker")" = "outside-must-not-change"

STRIPPER="$WORKDIR/strip-framework-links.sh"
python3 - "$PUBLISH_SOURCE" "$STRIPPER" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
output = pathlib.Path(sys.argv[2])
start = next(i for i, line in enumerate(source) if line == "validate_versioned_frameworks() {")
end = next(i for i, line in enumerate(source[start:], start) if line.startswith("VERSION_RAW="))
block = "\n".join(source[start:end])
output.write_text(
    "#!/usr/bin/env bash\nset -euo pipefail\n"
    "die() { echo \"error: $*\" >&2; exit 1; }\n" +
    block + "\nremove_transport_only_framework_links \"$1\"\n",
    encoding="utf-8",
)
PY
chmod +x "$STRIPPER"
bash -n "$STRIPPER"

make_archive_framework() {
  local archive="$1"
  local framework="$archive/Frameworks/Archive.framework"
  mkdir -p "$framework/Versions/A/Resources"
  write_framework_plist "$framework/Versions/A/Resources/Info.plist" Archive
  printf '#!/bin/sh\nexit 0\n' > "$framework/Versions/A/Archive"
  # Framework bundle binaries may be dyld-loaded Mach-O libraries rather than
  # process launchers. Flutter's App.framework/App is valid at mode 0644.
  chmod 0644 "$framework/Versions/A/Archive"
  ln -s A "$framework/Versions/Current"
  ln -s Versions/Current/Archive "$framework/Archive"
  ln -s Versions/Current/Resources "$framework/Resources"
}

CLEAN_ARCHIVE="$WORKDIR/clean-archive"
make_archive_framework "$CLEAN_ARCHIVE"
test ! -x "$CLEAN_ARCHIVE/Frameworks/Archive.framework/Archive"
"$STRIPPER" "$CLEAN_ARCHIVE"
test -f "$CLEAN_ARCHIVE/Frameworks/Archive.framework/Versions/A/Archive"
test ! -x "$CLEAN_ARCHIVE/Frameworks/Archive.framework/Versions/A/Archive"
test -z "$(find "$CLEAN_ARCHIVE" -type l -print -quit)"

UNSUPPORTED_ARCHIVE="$WORKDIR/unsupported-archive"
make_archive_framework "$UNSUPPORTED_ARCHIVE"
ln -s Frameworks "$UNSUPPORTED_ARCHIVE/unsupported-link"
if "$STRIPPER" "$UNSUPPORTED_ARCHIVE" >"$WORKDIR/unsupported.log" 2>&1; then
  echo "framework link stripper accepted an unsupported symbolic link" >&2
  exit 1
fi
grep -q 'unsupported symbolic links' "$WORKDIR/unsupported.log"
test -L "$UNSUPPORTED_ARCHIVE/unsupported-link"

MULTIVERSION_ARCHIVE="$WORKDIR/multiversion-archive"
make_archive_framework "$MULTIVERSION_ARCHIVE"
MULTIVERSION_FRAMEWORK="$MULTIVERSION_ARCHIVE/Frameworks/Archive.framework"
mkdir -p "$MULTIVERSION_FRAMEWORK/Versions/B/Resources"
write_framework_plist "$MULTIVERSION_FRAMEWORK/Versions/B/Resources/Info.plist" Archive
printf '#!/bin/sh\nexit 0\n' > "$MULTIVERSION_FRAMEWORK/Versions/B/Archive"
chmod +x "$MULTIVERSION_FRAMEWORK/Versions/B/Archive"
if "$STRIPPER" "$MULTIVERSION_ARCHIVE" >"$WORKDIR/multiversion.log" 2>&1; then
  echo "framework link stripper accepted ambiguous concrete versions" >&2
  exit 1
fi
grep -q 'requires exactly one valid concrete version' "$WORKDIR/multiversion.log"
test -L "$MULTIVERSION_FRAMEWORK/Versions/Current"

SYMLINK_ROOT_ARCHIVE="$WORKDIR/symlink-root-archive"
mkdir -p "$SYMLINK_ROOT_ARCHIVE/Frameworks"
ln -s "$OUTSIDE_FRAMEWORK" "$SYMLINK_ROOT_ARCHIVE/Frameworks/Linked.framework"
if "$STRIPPER" "$SYMLINK_ROOT_ARCHIVE" >"$WORKDIR/symlink-root.log" 2>&1; then
  echo "framework link stripper accepted a symlink framework root" >&2
  exit 1
fi
grep -q 'framework root must not be a symlink' "$WORKDIR/symlink-root.log"
test "$(cat "$OUTSIDE_FRAMEWORK/marker")" = "outside-must-not-change"

echo "Verified updater repair uses only an unambiguous or existing framework version"
echo "Verified publisher strips only reconstructible framework links and rejects unknown links"
echo "Verified publisher accepts valid mode-0644 framework bundle binaries"
