# SQLite for local databases in the web build

`sqlite3-3.8.0.wasm` is the `sqlite3.wasm` release asset of the Dart
`sqlite3` package, tag `sqlite3-3.8.0`
(https://github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-3.8.0,
sha256 `efd308be92a34f3aa15f289a37f213b0230fd80888a1364326ee29579d892d37`).
Its imports must match the Dart package version in pubspec.lock; update both
together (`test/web/local_sqlite_wasm_version_test.dart` checks this).
SQLite is public domain; the package is MIT licensed.

`lib/web/shims/local_sqlite_web.dart` loads it for the local chess library.
The `web/sqlite3.wasm` beside `sqflite_sw.js` belongs to sqflite's own worker.

`sqlite3-3.3.3.wasm` is the previous module. It stays for one deploy so tabs
opened before the 3.8.0 deploy can still load the engine they were built
against; delete it in the next web release.
