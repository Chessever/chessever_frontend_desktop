import 'dart:async';
import 'dart:io' as io;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:path/path.dart' as p;
import 'package:web/web.dart' as web;

import 'package:chessever/web/web_file_system.dart';

/// Whether the browser can hand back a file the app may write to again
/// (Chrome, Edge, Opera). Firefox and Safari import a copy instead.
bool get linkedFilesSupported => web.window.has('showOpenFilePicker');

/// App-storage path to the user's file it mirrors.
final Map<String, web.FileSystemFileHandle> _links = {};
final Map<String, Timer> _pendingWrites = {};
bool _listening = false;

/// Lets the user pick PGN files, copies each into [folder] in app storage
/// and keeps it linked: saving changes in the app writes them back to the
/// user's file. Null when the user cancels.
Future<List<String>?> pickLinkedChessFiles(String folder) async {
  final options =
      {
        'multiple': true,
        'types': [
          {
            'description': 'Chess games',
            'accept': {
              'application/x-chess-pgn': ['.pgn'],
            },
          },
        ],
      }.jsify();
  final JSArray<web.FileSystemFileHandle> picked;
  try {
    picked =
        await web.window
            .callMethod<JSPromise<JSArray<web.FileSystemFileHandle>>>(
              'showOpenFilePicker'.toJS,
              options,
            )
            .toDart;
  } catch (_) {
    return null; // Cancelled (AbortError) or refused.
  }
  _listen();
  await io.Directory(folder).create(recursive: true);
  final paths = <String>[];
  for (final handle in picked.toDart) {
    // Asked while the picker's user gesture still counts, so later saves
    // can write without a prompt. Declining keeps the file as a copy.
    try {
      await handle
          .callMethod<JSPromise<JSString>>(
            'requestPermission'.toJS,
            {'mode': 'readwrite'}.jsify(),
          )
          .toDart;
    } catch (_) {}
    final file = await handle.getFile().toDart;
    final buffer = await file.arrayBuffer().toDart;
    final path = p.join(folder, p.basename(file.name));
    await io.File(path).writeAsBytes(buffer.toDart.asUint8List(), flush: true);
    _links[path] = handle;
    paths.add(path);
  }
  return paths.isEmpty ? null : paths;
}

void _listen() {
  if (_listening) return;
  _listening = true;
  WebFileSystem.instance.onFileChanged = (path) {
    if (!_links.containsKey(path)) return;
    // A save arrives as many small writes; send the settled file once.
    _pendingWrites[path]?.cancel();
    _pendingWrites[path] = Timer(
      const Duration(milliseconds: 800),
      () => unawaited(_writeBack(path)),
    );
  };
}

Future<void> _writeBack(String path) async {
  _pendingWrites.remove(path);
  final handle = _links[path];
  if (handle == null) return;
  final file = io.File(path);
  if (!file.existsSync()) {
    _links.remove(path); // Renamed or deleted in the app: no longer linked.
    return;
  }
  try {
    final bytes = file.readAsBytesSync();
    final stream = await handle.createWritable().toDart;
    await stream.write(bytes.toJS).toDart;
    await stream.close().toDart;
  } catch (e) {
    // No write permission (declined, or revoked): the app copy still holds
    // the change, and Export saves it.
    // ignore: avoid_print
    print('[web] could not write back $path: $e');
  }
}
