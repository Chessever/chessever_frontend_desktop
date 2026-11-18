import 'dart:convert';

/// Decode in bounded slices: the Wasm SDK's single-call UTF-8 fast path can
/// overrun its fixed scratch array for long, non-Latin text. The streaming
/// decoder carries partial characters across slices and still rejects errors.
String decodeCbhUtf8(List<int> bytes) {
  final output = StringBuffer();
  final sink = const Utf8Decoder().startChunkedConversion(
    StringConversionSink.fromStringSink(output),
  );
  const chunkSize = 512;
  for (var start = 0; start < bytes.length; start += chunkSize) {
    final end = (start + chunkSize).clamp(0, bytes.length);
    sink.addSlice(bytes, start, end, false);
  }
  sink.close();
  return output.toString();
}
