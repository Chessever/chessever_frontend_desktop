import 'package:url_launcher/url_launcher.dart';

/// Navigation only. The Premium website owns authentication, regional pricing,
/// trial disclosure and checkout. Never put account/session data in this URL.
Uri webPremiumPageUri(String interval) {
  if (interval != 'month' && interval != 'year') {
    throw ArgumentError.value(interval, 'interval', 'Expected month or year');
  }
  return Uri.https('chessever.com', '/premium', {'interval': interval});
}

typedef WebPremiumNavigator =
    Future<bool> Function(Uri uri, {required String windowName});

Future<bool> _navigate(Uri uri, {required String windowName}) =>
    launchUrl(uri, webOnlyWindowName: windowName);

/// Called directly from the user's click, without auth/network work first.
/// Same-tab navigation avoids asynchronous popup blocking and does not create
/// a Stripe session merely to open the pricing page.
Future<void> openWebPremiumPage({
  required String interval,
  WebPremiumNavigator? navigate,
}) async {
  final uri = webPremiumPageUri(interval);
  final opened = await (navigate ?? _navigate)(uri, windowName: '_self');
  if (!opened) {
    throw StateError('Could not open the Premium page.');
  }
}
