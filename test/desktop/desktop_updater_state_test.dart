import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/desktop_updater_state.dart';

void main() {
  group('DesktopUpdateState version comparison', () {
    test('treats a build-number-only bump as newer', () {
      expect(
        DesktopUpdateState.isStrictlyNewer('3.0.0+18', '3.0.0+19'),
        isTrue,
      );
      expect(
        DesktopUpdateState.classify('3.0.0+18', '3.0.0+19'),
        DesktopUpdateTier.patch,
      );
    });

    test('does not treat the same semver and build as newer', () {
      expect(
        DesktopUpdateState.isStrictlyNewer('3.0.0+18', '3.0.0+18'),
        isFalse,
      );
    });

    test('treats skipped minor versions as one latest-version upgrade', () {
      expect(
        DesktopUpdateState.isStrictlyNewer('3.1.9+44', '3.4.0+71'),
        isTrue,
      );
      expect(
        DesktopUpdateState.classify('3.1.9+44', '3.4.0+71'),
        DesktopUpdateTier.minor,
      );
    });

    test('treats skipped major versions as a forced major upgrade', () {
      expect(
        DesktopUpdateState.isStrictlyNewer('3.9.9+99', '5.0.1+140'),
        isTrue,
      );
      expect(
        DesktopUpdateState.classify('3.9.9+99', '5.0.1+140'),
        DesktopUpdateTier.major,
      );
    });

    test('recognizes recovered installs that already reached target', () {
      expect(DesktopUpdateState.isAtLeast('4.0.0+80', '4.0.0+80'), isTrue);
      expect(DesktopUpdateState.isAtLeast('4.0.1+81', '4.0.0+80'), isTrue);
      expect(DesktopUpdateState.isAtLeast('3.9.9+79', '4.0.0+80'), isFalse);
    });

    test('composes desktop_updater version and numeric shortVersion', () {
      expect(
        DesktopUpdateState.composeReleaseVersion(
          shortVersion: '3.0.0',
          buildNumber: '19',
        ),
        '3.0.0+19',
      );
    });

    test('manual download state keeps the target version and fallback URL', () {
      final state = const DesktopUpdateState(
        status: DesktopUpdateStatus.downloaded,
        version: '4.0.0+80',
        tier: DesktopUpdateTier.major,
      ).copyManualDownloadRequired(
        message: 'Automatic update failed',
        manualDownloadUrl: 'https://example.com/#download',
      );

      expect(state.status, DesktopUpdateStatus.manualDownloadRequired);
      expect(state.requiresManualDownload, isTrue);
      expect(state.version, '4.0.0+80');
      expect(state.tier, DesktopUpdateTier.major);
      expect(state.manualDownloadUrl, 'https://example.com/#download');
    });
  });
}
