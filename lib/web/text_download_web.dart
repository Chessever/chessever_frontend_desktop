import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Hands [text] to the browser as a download named [fileName].
void downloadTextFile(String fileName, String text) {
  _download(
    fileName,
    web.Blob(
      [text.toJS].toJS,
      web.BlobPropertyBag(type: 'application/x-chess-pgn'),
    ),
  );
}

/// Hands [bytes] (of [mimeType]) to the browser as a download.
void downloadBytesFile(String fileName, Uint8List bytes, String mimeType) {
  _download(
    fileName,
    web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType)),
  );
}

/// Puts a PNG image on the clipboard.
Future<void> copyPngToClipboard(Uint8List bytes) async {
  final png = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'image/png'),
  );
  final item = web.ClipboardItem({'image/png': png}.jsify()! as JSObject);
  await web.window.navigator.clipboard.write([item].toJS).toDart;
}

void _download(String fileName, web.Blob blob) {
  final url = web.URL.createObjectURL(blob);
  final anchor =
      web.HTMLAnchorElement()
        ..href = url
        ..download = fileName;
  anchor.click();
  web.URL.revokeObjectURL(url);
}
