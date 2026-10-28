# onnxruntime-web for Maia in the web build

Unmodified files from the npm package `onnxruntime-web@1.30.0` (tarball
sha256 `d2228df7e4616bc3348bf504ee888f3bec43789a273f0a63f3e68d203ce3bf71`),
MIT licensed (see package.json; https://github.com/microsoft/onnxruntime).

`lib/web/onnx_runtime_web.dart` loads `ort.wasm.min.js` only when a Maia game
starts and talks to it through typed `dart:js_interop` bindings
(flutter_onnxruntime's web plugin only works when compiled to JavaScript, and
this build is Wasm). `env.wasm.proxy` runs model loading and inference in
onnxruntime's own worker, single-threaded without cross-origin isolation.
