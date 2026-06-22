import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:url_launcher/url_launcher.dart';

const Set<String> _chesseverWebHosts = {'chessever.com', 'www.chessever.com'};

bool isChesseverWebUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return (scheme == 'https' || scheme == 'http') &&
      _chesseverWebHosts.contains(uri.host.toLowerCase());
}

@visibleForTesting
Uri desktopBrowserSafeUri(Uri uri) {
  if (uri.scheme.toLowerCase() == 'https' && isChesseverWebUri(uri)) {
    return uri.replace(scheme: 'http');
  }
  return uri;
}

/// Opens a web URL in the user's browser without letting macOS universal-link
/// resolution steal chessever.com account and billing pages back into the app.
Future<bool> launchDesktopWebUrl(Uri uri) async {
  final browserSafeUri = desktopBrowserSafeUri(uri);
  final opened = await launchUrl(
    browserSafeUri,
    mode: LaunchMode.externalApplication,
  );
  if (opened) return true;
  if (browserSafeUri == uri) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

Uri desktopAccountWebUri({
  String source = 'desktop_app',
  String action = 'manage_subscription',
}) {
  return Uri.https('chessever.com', '/account', {
    'source': source,
    'action': action,
  });
}

Uri desktopPricingWebUri({
  required String interval,
  String source = 'desktop_app',
  String returnTo = 'desktop',
  String action = 'checkout',
}) {
  return Uri.https('chessever.com', '/pricing', {
    'source': source,
    'return_to': returnTo,
    'action': action,
    'interval': interval,
  });
}
