<!-- Moved verbatim from AGENTS.md Part II (formerly AGENTS.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

## 4. Package changes

When removing a mobile-only package:

1. Find every import: `grep -rn "package:<name>" lib/`.
2. For each callsite, either:
   - Replace with the desktop equivalent (preferred), **or**
   - Wrap in `if (!Platform.isMacOS && !Platform.isWindows) { ... }` if the call is mobile-only behavior we keep on mobile.
3. Remove the dependency from `pubspec.yaml`.
4. `flutter pub get` and confirm `flutter analyze` is clean.

When adding a desktop package:

1. Verify on pub.dev that it lists `macos` and `windows` (or both, if relevant).
2. Add to `pubspec.yaml` with a pinned `^x.y.z`.
3. Wire it minimally and verify it builds before broader use.
