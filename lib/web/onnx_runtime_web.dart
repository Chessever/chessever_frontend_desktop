import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<void>? _loading;

/// Adds onnxruntime-web (`web/onnx/`) to the page the first time Maia needs
/// it, so the 14 MB runtime costs nothing until then.
Future<void> ensureOnnxRuntimeLoaded() {
  return _loading ??= () async {
    final base = Uri.parse(web.document.baseURI).resolve('onnx/').toString();
    if (!globalContext.has('ort')) {
      final loaded = Completer<void>();
      final script =
          web.HTMLScriptElement()
            ..src = '${base}ort.wasm.min.js'
            ..async = true;
      script.onload = ((web.Event _) => loaded.complete()).toJS;
      script.onerror =
          ((web.Event _) => loaded.completeError(
            StateError('Could not load the Maia runtime'),
          )).toJS;
      web.document.head!.appendChild(script);
      await loaded.future;
    }
    final ort = globalContext['ort'] as JSObject;
    final wasm = (ort['env'] as JSObject)['wasm'] as JSObject;
    // Same-origin runtime files; one thread without cross-origin isolation.
    wasm['wasmPaths'] = base.toJS;
    wasm['numThreads'] = 1.toJS;
    // Model loading and inference run in onnxruntime's own worker, so a Maia
    // move (~90 ms of compute) never blocks a frame.
    wasm['proxy'] = true.toJS;
  }();
}

/// An onnxruntime-web inference session with float32 inputs and outputs.
///
/// flutter_onnxruntime's web plugin hands Dart values straight to JavaScript,
/// which only works when compiled to JavaScript; this app's web build is
/// Wasm, so Maia talks to onnxruntime-web through these typed bindings.
///
/// Handles for the same model URL share one underlying session (Maia's
/// rating is an input, so every Maia player in a tournament can use the same
/// 46 MB model), and runs on it go one at a time.
class WebOnnxSession {
  WebOnnxSession._(this._url, this._shared, this._session);

  final String _url;
  final _SharedSession _shared;
  final JSObject _session;
  bool _released = false;

  static final Map<String, _SharedSession> _byUrl = {};

  static Future<WebOnnxSession> create(String modelUrl) async {
    final shared = _byUrl[modelUrl] ??= _SharedSession(_open(modelUrl));
    shared.users++;
    try {
      return WebOnnxSession._(modelUrl, shared, await shared.session);
    } catch (_) {
      // A failed load is not cached, so the next game can try again.
      shared.users--;
      if (identical(_byUrl[modelUrl], shared)) _byUrl.remove(modelUrl);
      rethrow;
    }
  }

  static Future<JSObject> _open(String modelUrl) async {
    await ensureOnnxRuntimeLoaded();
    final factory = _ort['InferenceSession'] as JSObject;
    final options = JSObject()..['executionProviders'] = ['wasm'.toJS].toJS;
    return factory
        .callMethod<JSPromise<JSObject>>('create'.toJS, modelUrl.toJS, options)
        .toDart;
  }

  /// Runs the model on [inputs] (name to data and shape) and returns a copy
  /// of the [output] tensor's values.
  Future<Float32List> run(
    Map<String, (Float32List, List<int>)> inputs,
    String output,
  ) {
    final result = _shared.queue.then((_) => _run(inputs, output));
    _shared.queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Float32List> _run(
    Map<String, (Float32List, List<int>)> inputs,
    String output,
  ) async {
    final tensor = _ort['Tensor'] as JSFunction;
    final feeds = JSObject();
    final created = <JSObject>[];
    for (final MapEntry(key: name, value: (data, shape)) in inputs.entries) {
      final value = tensor.callAsConstructor<JSObject>(
        'float32'.toJS,
        data.toJS,
        [for (final dim in shape) dim.toJS].toJS,
      );
      created.add(value);
      feeds[name] = value;
    }
    try {
      final results =
          await _session
              .callMethod<JSPromise<JSObject>>('run'.toJS, feeds)
              .toDart;
      try {
        final values = results[output] as JSObject;
        return Float32List.fromList((values['data'] as JSFloat32Array).toDart);
      } finally {
        _disposeAll(results);
      }
    } finally {
      for (final value in created) {
        value.callMethod<JSAny?>('dispose'.toJS);
      }
    }
  }

  /// Drops this handle; the session itself is released with its last user.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    if (--_shared.users > 0) return;
    if (identical(_byUrl[_url], _shared)) _byUrl.remove(_url);
    await _shared.queue;
    await _session.callMethod<JSPromise<JSAny?>>('release'.toJS).toDart;
  }

  static JSObject get _ort => globalContext['ort'] as JSObject;

  static void _disposeAll(JSObject results) {
    final keys = (globalContext['Object'] as JSObject)
        .callMethod<JSArray<JSString>>('keys'.toJS, results);
    for (final key in keys.toDart) {
      (results[key.toDart] as JSObject?)?.callMethod<JSAny?>('dispose'.toJS);
    }
  }
}

class _SharedSession {
  _SharedSession(this.session);

  final Future<JSObject> session;
  int users = 0;
  Future<void> queue = Future<void>.value();
}
