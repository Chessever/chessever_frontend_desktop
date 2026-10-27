{{flutter_js}}
{{flutter_build_config}}

// Same as Flutter's generated bootstrap, plus removing the "Loading" text in
// index.html once the engine is ready to draw.
//
// Flutter enables the Wasm build only on Chromium by default and sends Firefox
// and Safari to the JavaScript build, which cannot run this app (dartchess
// needs 64-bit integers). Both run the Wasm build correctly, so allow them.
_flutter.loader.load({
  config: { wasmAllowList: { gecko: true, webkit: true } },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById("boot")?.remove();
    await appRunner.runApp();
  },
});
