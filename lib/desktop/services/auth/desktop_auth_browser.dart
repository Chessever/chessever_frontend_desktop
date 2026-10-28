import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chessever/desktop/services/mac_app_store.dart';

/// The user closed the sign-in sheet before finishing.
class DesktopSignInCancelled implements Exception {
  const DesktopSignInCancelled();

  @override
  String toString() => 'Sign-in was canceled.';
}

/// Where the loopback OAuth flows open their authorization page.
///
/// Website editions open the user's default browser. The Mac App Store
/// edition must keep sign-in inside the app (App Review guideline 4), so it
/// shows the page in an ASWebAuthenticationSession sheet
/// (`macos/Runner/DesktopWebAuthBridge.swift`). The loopback listener still
/// receives the authorization code, then redirects the sheet to
/// [completionUri] so it closes itself.
abstract final class DesktopAuthBrowser {
  static const MethodChannel _channel = MethodChannel(
    'chessever.desktop/web_auth',
  );

  /// Not registered in Info.plist: only the sheet watches for it.
  static const String callbackScheme = 'chessever-auth';
  static final Uri completionUri = Uri(
    scheme: callbackScheme,
    host: 'complete',
  );

  @visibleForTesting
  static bool? debugInAppOverride;

  static bool get inApp => debugInAppOverride ?? isMacAppStore;

  /// Opens [url]. Returns false if the website editions could not launch a
  /// browser. In the in-app sheet, [onClosedEarly] receives
  /// [DesktopSignInCancelled] when the user closes it, or the error that kept
  /// it from opening. It is never called once the sheet reached
  /// [completionUri].
  static Future<bool> open(
    Uri url, {
    required void Function(Object error) onClosedEarly,
  }) async {
    if (!inApp) {
      return launchUrl(url, mode: LaunchMode.externalApplication);
    }
    unawaited(
      _channel
          .invokeMethod<String>('start', <String, String>{
            'url': url.toString(),
            'callbackScheme': callbackScheme,
          })
          .then<void>(
            (_) {},
            onError: (Object error) {
              onClosedEarly(
                error is PlatformException && error.code == 'canceled'
                    ? const DesktopSignInCancelled()
                    : error,
              );
            },
          ),
    );
    return true;
  }

  /// Ends the loopback request that carried the result. The sheet closes on
  /// [completionUri] and the app shows the outcome itself.
  static Future<void> finishInSheet(HttpResponse response) {
    response
      ..statusCode = HttpStatus.found
      ..headers.set(HttpHeaders.locationHeader, completionUri.toString());
    return response.close();
  }

  /// Dismisses the sheet if it is still showing (time-out, failure).
  static Future<void> close() async {
    if (!inApp) return;
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // Already closed.
    } on MissingPluginException {
      // Website build or a test without the bridge.
    }
  }
}
