import 'package:sentry_flutter/sentry_flutter.dart';

/// Expected, non-actionable failures, dropped in `beforeSend` so the
/// dashboard only shows what the app can do something about. The phone app
/// keeps the same list in `main.dart`; desktop had none, so a dead socket or
/// an abandoned browser sign-in was filed like a crash.
const List<String> _dropContains = <String>[
  // This machine is offline or its socket died.
  'failed host lookup',
  'socketexception',
  'authretryablefetchexception', // GoTrue retrying while offline (CHESSEVER-DG)
  'connection closed while receiving data',
  'connection closed before full header',
  'connection reset by peer',
  'network is unreachable',
  'handshakeexception',
  'software caused connection abort',
  'clientexception: bad file descriptor',
  'clientexception: read failed',
  'no internet connection', // NetworkException (CHESSEVER-1PN/1XJ/23D/23G)
  // Sentry Cocoa's native failed-request capture on macOS. Our own traffic is
  // Dart sockets, so these are third-party SDKs' 5xx (CHESSEVER-XM).
  'httpclienterror',
  // The realtime socket reconnects on its own.
  'realtimesubscribeexception', // CHESSEVER-16N
  // The session was revoked elsewhere; the auth gate signs the user out.
  'invalid refresh token', // CHESSEVER-E4
  // The user closed the browser tab without finishing sign-in.
  'oauth flow timed out', // CHESSEVER-238/1FM
  'sign-in timed out', // CHESSEVER-1ZG
  // ...or closed the Mac App Store edition's in-app sign-in sheet.
  'sign-in was canceled',
  // flutter_cache_manager racing itself on one image key; the image loads.
  'unique constraint failed: cacheobject.key', // CHESSEVER-22B
];

bool shouldDropDesktopSentryEvent(SentryEvent event) {
  final haystack = StringBuffer();
  final throwable = event.throwable;
  if (throwable != null) haystack.write(throwable.toString());
  for (final exception in event.exceptions ?? const <SentryException>[]) {
    haystack
      ..write(' ')
      ..write(exception.type ?? '')
      ..write(' ')
      ..write(exception.value ?? '');
  }
  final hay = haystack.toString().toLowerCase();
  if (hay.isEmpty) return false;
  return _dropContains.any(hay.contains);
}
