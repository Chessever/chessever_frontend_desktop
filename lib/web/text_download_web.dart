import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Hands [text] to the browser as a download named [fileName].
void downloadTextFile(String fileName, String text) {
  final blob = web.Blob(
    [text.toJS].toJS,
    web.BlobPropertyBag(type: 'application/x-chess-pgn'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor =
      web.HTMLAnchorElement()
        ..href = url
        ..download = fileName;
  anchor.click();
  web.URL.revokeObjectURL(url);
}
