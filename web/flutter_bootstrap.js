{{flutter_js}}
{{flutter_build_config}}

// Same as Flutter's generated bootstrap, plus removing the "Loading" text in
// index.html once the engine is ready to draw.
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById("boot")?.remove();
    await appRunner.runApp();
  },
});
