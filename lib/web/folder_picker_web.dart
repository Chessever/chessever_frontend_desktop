import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// A file from a folder the user picked, with its path inside that folder.
typedef PickedWebFile = ({String relativePath, Uint8List bytes});

/// Opens the browser's folder picker (`webkitdirectory`, in Chrome, Firefox
/// and Safari) and reads the files [accept] keeps. Null when cancelled.
Future<List<PickedWebFile>?> pickWebFolder({
  bool Function(String relativePath)? accept,
}) async {
  final input =
      web.HTMLInputElement()
        ..type = 'file'
        ..multiple = true
        ..setAttribute('webkitdirectory', '');
  final picked = Completer<web.FileList?>();
  input.onchange = ((web.Event _) => picked.complete(input.files)).toJS;
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!picked.isCompleted) picked.complete(null);
    }).toJS,
  );
  input.click();
  final files = await picked.future;
  if (files == null || files.length == 0) return null;
  final result = <PickedWebFile>[];
  for (var i = 0; i < files.length; i++) {
    final file = files.item(i)!;
    final relativePath =
        file.webkitRelativePath.isEmpty ? file.name : file.webkitRelativePath;
    if (accept != null && !accept(relativePath)) continue;
    final buffer = await file.arrayBuffer().toDart;
    result.add((
      relativePath: relativePath,
      bytes: buffer.toDart.asUint8List(),
    ));
  }
  return result;
}
