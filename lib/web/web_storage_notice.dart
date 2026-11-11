import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'package:chessever/web/web_file_system.dart';

/// Tells the visitor when this tab is not saving local databases, which the
/// app would otherwise only show by losing them on the next visit.
///
/// Plain HTML over the Flutter view rather than a widget: it has to be able
/// to appear before sign-in and from a save that fails in the background,
/// where no pane owns the message.
void watchWebFileStorage() {
  final fs = WebFileSystem.instance;
  _show(fs.storage);
  fs.onStorageChanged = _show;
}

const String _elementId = 'storage-notice';

String? _messageFor(WebFileStorage storage) => switch (storage) {
  // A second tab keeps its changes in memory (see WebFileSystem.mount);
  // that is expected, not something to interrupt the visitor about.
  WebFileStorage.saved || WebFileStorage.otherTab => null,
  WebFileStorage.unavailable =>
    'This browser window does not keep site data (a private window, '
        'usually). Local databases and prep last until the tab is closed.',
  WebFileStorage.full =>
    'Browser storage for ChessEver is full. Recent changes to local '
        'databases are not saved yet. Remove a database you no longer need '
        'to free space.',
};

void _show(WebFileStorage storage) {
  web.document.getElementById(_elementId)?.remove();
  final message = _messageFor(storage);
  if (message == null) return;

  final bar =
      web.HTMLDivElement()
        ..id = _elementId
        ..setAttribute('role', 'status');
  bar.style
    ..position = 'fixed'
    ..left = '50%'
    ..bottom = '16px'
    ..transform = 'translateX(-50%)'
    ..maxWidth = 'min(680px, calc(100vw - 32px))'
    ..boxSizing = 'border-box'
    ..padding = '10px 12px 10px 16px'
    ..display = 'flex'
    ..alignItems = 'center'
    ..gap = '14px'
    ..background = '#1f1d1a'
    ..color = '#f1ede6'
    ..border = '1px solid #3a3631'
    ..borderRadius = '8px'
    ..font = '500 13px/1.45 system-ui, sans-serif'
    ..zIndex = '2147483000';

  final text = web.HTMLSpanElement()..textContent = message;

  final dismiss =
      web.HTMLButtonElement()
        ..type = 'button'
        ..textContent = 'Dismiss';
  dismiss.style
    ..flex = 'none'
    ..padding = '6px 10px'
    ..background = 'transparent'
    ..color = '#f1ede6'
    ..border = '1px solid #4a453f'
    ..borderRadius = '6px'
    ..font = '600 13px/1 system-ui, sans-serif'
    ..cursor = 'pointer';
  dismiss.addEventListener(
    'click',
    ((web.Event _) => bar.remove()).toJS,
  );

  bar
    ..append(text)
    ..append(dismiss);
  web.document.body?.append(bar);
}
