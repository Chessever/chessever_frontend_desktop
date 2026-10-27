import 'dart:typed_data';

Future<void> ensureOnnxRuntimeLoaded() async {}

/// Browser-only; native builds run Maia through flutter_onnxruntime.
class WebOnnxSession {
  WebOnnxSession._();

  static Future<WebOnnxSession> create(String modelUrl) =>
      throw UnsupportedError('WebOnnxSession is only available on the web');

  Future<Float32List> run(
    Map<String, (Float32List, List<int>)> inputs,
    String output,
  ) => throw UnsupportedError('WebOnnxSession is only available on the web');

  Future<void> release() async {}
}
