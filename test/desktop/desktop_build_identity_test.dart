import 'package:chessever/desktop/services/desktop_build_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production identity keeps the public ChessEver app contract', () {
    const identity = DesktopBuildIdentity(isRelease: true);

    expect(identity.displayName, 'ChessEver');
    expect(identity.urlScheme, 'chessever');
    expect(identity.updatesEnabled, isTrue);
    expect(identity.isDevelopment, isFalse);
  });

  test('development identity is visibly and operationally isolated', () {
    const identity = DesktopBuildIdentity(isRelease: false);

    expect(identity.displayName, 'ChessEver Development');
    expect(identity.urlScheme, 'chessever-development');
    expect(identity.updatesEnabled, isFalse);
    expect(identity.isDevelopment, isTrue);
  });
}
