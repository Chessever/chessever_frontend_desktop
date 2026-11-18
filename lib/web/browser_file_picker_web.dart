import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'package:chessever/web/picked_web_file.dart';

Future<List<PickedWebFile>?> pickWebFiles({
  required List<String> allowedExtensions,
  required bool allowMultiple,
  required String label,
}) => _pick(
  web.HTMLInputElement()
    ..multiple = allowMultiple
    ..accept = allowedExtensions.map((extension) => '.$extension').join(',')
    ..setAttribute('aria-label', label),
);

/// Opens the browser's folder picker (`webkitdirectory`, in Chrome, Firefox
/// and Safari) and reads the files [accept] keeps. Null when cancelled.
Future<List<PickedWebFile>?> pickWebFolder({
  bool Function(String relativePath)? accept,
}) => _pick(
  web.HTMLInputElement()
    ..multiple = true
    ..setAttribute('webkitdirectory', ''),
  accept: accept,
);

Future<List<PickedWebFile>?> _pick(
  web.HTMLInputElement input, {
  bool Function(String relativePath)? accept,
}) async {
  input.type = 'file';
  input.style.display = 'none';
  final picked = Completer<web.FileList?>();
  input.onchange =
      ((web.Event _) {
        if (!picked.isCompleted) picked.complete(input.files);
      }).toJS;
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!picked.isCompleted) picked.complete(null);
    }).toJS,
  );
  web.document.body!.append(input);
  final web.FileList? files;
  try {
    input.click();
    files = await picked.future;
  } finally {
    input.remove();
  }
  if (files == null || files.length == 0) return null;
  final result = <PickedWebFile>[];
  for (var i = 0; i < files.length; i++) {
    final file = files.item(i)!;
    final relativePath =
        file.webkitRelativePath.isEmpty ? file.name : file.webkitRelativePath;
    if (accept != null && !accept(relativePath)) continue;
    result.add(
      PickedWebFile(
        relativePath: relativePath,
        readAsBytes:
            () async => (await file.arrayBuffer().toDart).toDart.asUint8List(),
      ),
    );
  }
  return result;
}
