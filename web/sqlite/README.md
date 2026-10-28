# SQLite for local databases in the web build

`sqlite3-3.3.3.wasm` is the `sqlite3.wasm` release asset of the Dart
`sqlite3` package, tag `sqlite3-3.3.3`
(https://github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-3.3.3,
sha256 `cfab48c6bbb718552ec19bc4f1365e19185311b72e4739cc19ef7333758304d3`).
Its imports must match the Dart package version in pubspec.lock; update both
together. SQLite is public domain; the package is MIT licensed.

`lib/web/shims/resqlite_web.dart` loads it for the local chess library. The
`web/sqlite3.wasm` beside `sqflite_sw.js` belongs to sqflite's own worker.
