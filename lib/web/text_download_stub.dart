import 'dart:typed_data';

void downloadTextFile(String fileName, String text) =>
    throw UnsupportedError('Downloads exist only in the browser build.');

void downloadBytesFile(String fileName, Uint8List bytes, String mimeType) =>
    throw UnsupportedError('Downloads exist only in the browser build.');

Future<void> copyPngToClipboard(Uint8List bytes) =>
    throw UnsupportedError('Browser clipboard exists only in the web build.');
