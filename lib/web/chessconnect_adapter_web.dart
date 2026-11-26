// Release-mode console output is the only signal when the install fails.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'package:chessever/desktop/services/chessconnect/chessconnect_bridge.dart';

const String _adapterGlobal = 'chessconnectAdapter';
const String _changeEvent = 'chessconnectadapter:change';
const String _rootElementId = 'chessconnect-root';
const String _rootViewType = 'chessever-chessconnect-root';

const bool chessconnectRootSupported = !kChessconnectAdapterDisabled;

/// True once Chessconnect has put its connect button into the root element.
final ValueNotifier<bool> chessconnectRootHasContent = ValueNotifier<bool>(
  false,
);

bool _installed = false;
bool _changePending = false;

/// Exposes `window.chessconnectAdapter` (Adapter API v1) once per page.
///
/// The object is frozen and defined read-only on the window, so no other
/// script on the page can swap `move` or `getState` for its own. It is only
/// installed in the top-level window: when another site frames the app, the
/// framed copy offers nothing. Every member goes through
/// [ChessconnectBridge], which never throws and refuses anything that is not
/// a plain, legal board move.
void installChessconnectAdapter() {
  if (_installed || kChessconnectAdapterDisabled) return;
  _installed = true;
  try {
    if (!globalContext['self'].strictEquals(globalContext['top']).toDart) {
      return;
    }
    if (globalContext.has(_adapterGlobal)) return;

    final bridge = ChessconnectBridge.instance;
    final adapter =
        JSObject()
          ..['version'] = 1.toJS
          ..['changeEvents'] = true.toJS
          ..['getState'] = _getState.toJS
          ..['move'] = _move.toJS
          ..['onConnectionChange'] = _onConnectionChange.toJS;

    final objectCtor = globalContext['Object']! as JSObject;
    objectCtor.callMethod<JSAny?>('freeze'.toJS, adapter);
    final descriptor =
        JSObject()
          ..['value'] = adapter
          ..['writable'] = false.toJS
          ..['configurable'] = false.toJS
          ..['enumerable'] = false.toJS;
    objectCtor.callMethod<JSAny?>(
      'defineProperty'.toJS,
      globalContext,
      _adapterGlobal.toJS,
      descriptor,
    );

    bridge.addChangeListener(_scheduleChangeEvent);
    ui_web.platformViewRegistry.registerViewFactory(
      _rootViewType,
      _createRootElement,
    );
    print('[web] chessconnect adapter ready');
  } catch (e) {
    print('[web] chessconnect adapter unavailable: $e');
  }
}

JSAny? _getState() => ChessconnectBridge.instance.state()?.jsify();

JSAny? _move(JSAny? uci) {
  final String? raw = uci.isA<JSString>() ? (uci! as JSString).toDart : null;
  final result = ChessconnectBridge.instance.move(raw);
  return <String, Object?>{
    'ok': result.ok,
    if (result.message != null) 'message': result.message,
  }.jsify();
}

void _onConnectionChange(JSAny? info) {
  try {
    if (!info.isA<JSObject>()) return;
    final object = info! as JSObject;
    final connected = object['connected'];
    final board = object['board'];
    ChessconnectBridge.instance.connectionChanged(
      connected:
          connected.isA<JSBoolean>() ? (connected! as JSBoolean).toDart : null,
      board: board.isA<JSString>() ? (board! as JSString).toDart : null,
    );
  } catch (_) {
    // Chessconnect ignores our return value and exceptions; so do we.
  }
}

/// One event per burst of changes, dispatched after the last of them.
void _scheduleChangeEvent() {
  if (_changePending) return;
  _changePending = true;
  scheduleMicrotask(() {
    _changePending = false;
    try {
      web.window.dispatchEvent(web.Event(_changeEvent));
    } catch (_) {}
  });
}

/// The empty element Chessconnect draws its connect button into. We never
/// read or write its contents; we only watch whether it has any, to give it
/// room only while Chessconnect uses it (its phone apps do not).
web.HTMLElement _createRootElement(int viewId) {
  final element = web.document.createElement('div') as web.HTMLDivElement;
  element.id = _rootElementId;
  element.style
    ..width = '100%'
    ..height = '100%';
  // The factory can run while Flutter builds; notify the slot afterwards.
  scheduleMicrotask(() => chessconnectRootHasContent.value = false);
  web.MutationObserver(
    ((JSArray<web.MutationRecord> _, web.MutationObserver _) {
      chessconnectRootHasContent.value = element.childElementCount > 0;
    }).toJS,
  ).observe(element, web.MutationObserverInit(childList: true));
  return element;
}

Widget buildChessconnectRootView() =>
    const HtmlElementView(viewType: _rootViewType);
