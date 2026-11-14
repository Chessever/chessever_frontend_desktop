import 'package:chessever/web/shared_auth_session.dart';

/// Native builds keep their session in their own storage only.
SharedAuthCookieJar? sharedAuthCookieJar() => null;

/// Native builds have no page visibility to follow.
void onPageShown(void Function() callback) {}
