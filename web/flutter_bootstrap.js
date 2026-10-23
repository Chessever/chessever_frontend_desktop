{{flutter_js}}
{{flutter_build_config}}

// Loader for app.chessever.com, inlined into index.html at build time.
//
// The app is compiled to WebAssembly only (dart2wasm + the skwasm renderer):
// its chess library relies on 64-bit integers, which the JavaScript compiler
// cannot represent. A browser without WasmGC never downloads the app; it
// gets a short HTML notice instead of a blank page.
//
// scripts/build_web.sh moves the compiled app into an immutable, content
// hashed directory and replaces __CHESSEVER_ASSET_BASE__ with its path
// (`/v/<hash>/`). Under `flutter run` the placeholder is left alone and the
// files are served from the root, as Flutter lays them out.
(function () {
  const assetBase = "__CHESSEVER_ASSET_BASE__";
  // Absolute: package_info_plus builds version.json's URL from the asset
  // base and cannot resolve a path that has no origin.
  const root =
    assetBase.charAt(0) === "/" ? window.location.origin + assetBase : "";

  const loading = document.getElementById("ce-loading");

  // Flutter only selects the Wasm build on Chromium browsers by default.
  // `?wasm=all` lets Firefox and Safari try it, for testing.
  const tryEveryEngine =
    new URLSearchParams(window.location.search).get("wasm") === "all";
  const supportsWasmGC = WebAssembly.validate(
    new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 95, 1, 120, 0]),
  );
  const isChromium =
    navigator.vendor === "Google Inc." || navigator.userAgent.includes("Edg/");

  if (!supportsWasmGC || !(isChromium || tryEveryEngine)) {
    if (loading) loading.hidden = true;
    const notice = document.getElementById("ce-unsupported");
    if (notice) notice.hidden = false;
    return;
  }

  // Start both large downloads now. Flutter's loader requests each .wasm
  // only after it has imported that file's JS glue, a round trip later.
  const preload = (href, isModule) => {
    const link = document.createElement("link");
    if (isModule) {
      link.rel = "modulepreload";
    } else {
      link.rel = "preload";
      link.as = "fetch";
      link.type = "application/wasm";
      link.crossOrigin = "anonymous";
    }
    link.href = href;
    document.head.appendChild(link);
  };
  // The same choice flutter.js makes between its two skwasm builds.
  const needsHeavySkwasm =
    !(isChromium && typeof ImageDecoder !== "undefined") ||
    typeof Intl.v8BreakIterator === "undefined" ||
    typeof Intl.Segmenter === "undefined";
  const skwasm = root + "canvaskit/" +
    (needsHeavySkwasm ? "skwasm_heavy" : "skwasm");
  preload(root + "main.dart.mjs", true);
  preload(root + "main.dart.wasm", false);
  preload(skwasm + ".js", true);
  preload(skwasm + ".wasm", false);

  window.addEventListener(
    "flutter-first-frame",
    () => {
      if (loading) loading.remove();
    },
    { once: true },
  );

  _flutter.loader.load({
    config: {
      renderer: "skwasm",
      entrypointBaseUrl: root,
      assetBase: root,
      canvasKitBaseUrl: root + "canvaskit/",
      wasmAllowList: tryEveryEngine
        ? { blink: true, gecko: true, webkit: true, unknown: true }
        : undefined,
    },
  }).catch((error) => {
    console.error(error);
    if (loading) loading.hidden = true;
    const failed = document.getElementById("ce-failed");
    if (failed) failed.hidden = false;
  });
})();
