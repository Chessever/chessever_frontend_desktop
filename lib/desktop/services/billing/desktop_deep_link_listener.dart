import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Listens for desktop deep links and dispatches them to a callback.
///
/// Used by the billing flow (`chessever://billing/success?...`) and by
/// website links such as `https://chessever.com/broadcast/<slug>/<id>` when
/// the OS delivers them to the desktop app.
///
/// Lifecycle: [start] once on app boot, [dispose] never (the app exits with
/// the stream).
class DesktopDeepLinkListener {
  DesktopDeepLinkListener._();
  static final DesktopDeepLinkListener instance = DesktopDeepLinkListener._();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  void Function(Uri uri)? _handler;

  /// Initial link can arrive before any listener is attached (cold-launch via
  /// custom scheme). We buffer it here so [start] can replay it.
  Uri? _pendingInitial;
  bool _initialFetched = false;

  Future<void> start({required void Function(Uri uri) onLink}) async {
    _handler = onLink;

    if (!_initialFetched) {
      _initialFetched = true;
      try {
        final initial = await _appLinks.getInitialLink();
        if (initial != null) {
          _pendingInitial = initial;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[deeplink] initial link error: $e');
      }
    }
    if (_pendingInitial != null) {
      _dispatch(_pendingInitial!);
      _pendingInitial = null;
    }

    _sub ??= _appLinks.uriLinkStream.listen(
      _dispatch,
      onError: (Object e) {
        if (kDebugMode) debugPrint('[deeplink] stream error: $e');
      },
    );
  }

  void _dispatch(Uri uri) {
    final isChesseverScheme = uri.scheme == 'chessever';
    final isChesseverWebLink =
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        (uri.host == 'chessever.com' || uri.host == 'www.chessever.com');
    if (!isChesseverScheme && !isChesseverWebLink) return;
    if (kDebugMode) debugPrint('[deeplink] received $uri');
    _handler?.call(uri);
  }
}
