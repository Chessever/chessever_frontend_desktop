{{flutter_js}}
{{flutter_build_config}}

// Same as Flutter's generated bootstrap, plus removing the "Loading" text in
// index.html once the engine is ready to draw.
//
// Flutter enables the Wasm build only on Chromium by default and sends Firefox
// and Safari to the JavaScript build, which cannot run this app (dartchess
// needs 64-bit integers). Both run the Wasm build correctly, so allow them.
//
// The JavaScript build is dropped from the candidates: all it could do is
// draw the unsupported-browser notice (lib/web/web_unsupported_browser.dart),
// and reaching that cost ~9 MB (main.dart.js plus canvaskit.wasm). A browser
// the Wasm build cannot run now gets the same notice as plain HTML.
_flutter.buildConfig.builds = _flutter.buildConfig.builds.filter(
  function (build) { return build.compileTarget === "dart2wasm"; },
);

function showBootMessage(title, body) {
  var boot = document.getElementById("boot");
  if (!boot) return;
  boot.className = "message";
  boot.innerHTML = "<div><h1>" + title + "</h1><p>" + body + "</p></div>";
}

_flutter.loader.load({
  config: { wasmAllowList: { gecko: true, webkit: true } },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById("boot")?.remove();
    await appRunner.runApp();
  },
}).catch(function (error) {
  console.error(error);
  // flutter.js throws this when no candidate build suits the browser.
  if (/could not find a build compatible/.test(String(error && error.message))) {
    showBootMessage(
      "This browser cannot run ChessEver.",
      "Open app.chessever.com in a current version of Chrome, Edge, Firefox " +
        "or Safari, or download the desktop app from " +
        '<a href="https://chessever.com">chessever.com</a>.',
    );
  } else {
    // A failed download or engine start would otherwise leave "Loading…"
    // on screen forever. Once the app runs, #boot is gone and this is a no-op.
    showBootMessage(
      "ChessEver could not load.",
      "Check your connection and reload the page.",
    );
  }
});
