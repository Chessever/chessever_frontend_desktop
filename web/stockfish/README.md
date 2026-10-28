# Stockfish for the web build

`stockfish-19-lite-single.js` and `.wasm` are Stockfish 19 compiled to
WebAssembly by the stockfish.js project, unmodified, from the npm package
`stockfish@19.0.1` (tarball sha256
`c3695e2a3afbc61c6439c689cb8b95cec4627bcda407193f6b7c3a5702fac839`).

- Source: https://github.com/nmrugg/stockfish.js (tag v19.0.1) and
  https://github.com/official-stockfish/Stockfish
- License: GNU GPL v3, see `COPYING.txt`.

The app runs it as a separate program in a Web Worker and talks to it over
UCI text messages (`lib/web/shims/stockfish_upstream_web.dart`). This is the
lite, single-threaded build: it needs no cross-origin isolation, and the full
network (99 MB) exceeds the hosting limit.
