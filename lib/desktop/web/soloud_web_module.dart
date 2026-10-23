import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

@JS('document.createElement')
external _ScriptElement _createScript(String tagName);

@JS('document.head.appendChild')
external void _appendToHead(_ScriptElement element);

@JS('Module_soloud')
external JSFunction get _moduleFactory;

@JS('Module_soloud')
external set _module(JSObject module);

extension type _ScriptElement(JSObject _) implements JSObject {
  external set src(String value);
  external set onload(JSFunction? handler);
  external set onerror(JSFunction? handler);
}

Future<void>? _loading;

/// Loads flutter_soloud's WebAssembly audio engine.
///
/// The plugin expects two `<script>` tags in index.html: its Emscripten
/// module and a small compiled Dart file that instantiates it. This does the
/// same from Dart, after startup, so the module stays off the critical path
/// of the first frame. The script resolves its .wasm next to itself, so it
/// is loaded from the versioned asset directory like every other asset.
Future<void> loadSoloudWebModule() => _loading ??= _load();

Future<void> _load() async {
  final loaded = Completer<void>();
  void onLoad() => loaded.complete();
  void onError() => loaded.completeError(
    StateError('flutter_soloud web module failed to load'),
  );
  final script = _createScript('script');
  script.src = ui_web.assetManager.getAssetUrl(
    'packages/flutter_soloud/web/libflutter_soloud_plugin.js',
  );
  script.onload = onLoad.toJS;
  script.onerror = onError.toJS;
  _appendToHead(script);
  await loaded.future;

  // What the plugin's init_module.dart.js does: run the Emscripten factory
  // and publish the instance under the same global name.
  final instance = _moduleFactory.callAsFunction() as JSPromise<JSObject>;
  _module = await instance.toDart;
}
