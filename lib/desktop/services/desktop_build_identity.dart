import 'package:flutter/foundation.dart' show kReleaseMode;

import 'mac_app_store.dart';

/// Build-specific identity for keeping development and production installs
/// visibly and operationally separate.
class DesktopBuildIdentity {
  const DesktopBuildIdentity({required this.isRelease});

  static const DesktopBuildIdentity current = DesktopBuildIdentity(
    isRelease: kReleaseMode,
  );

  final bool isRelease;

  bool get isDevelopment => !isRelease;
  bool get updatesEnabled => isRelease && !macAppStoreBuild;

  String get displayName => isRelease ? 'ChessEver' : 'ChessEver Development';

  String get urlScheme => isRelease ? 'chessever' : 'chessever-development';
}
