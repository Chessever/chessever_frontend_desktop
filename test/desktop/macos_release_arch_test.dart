import 'package:chessever/desktop/services/engine/macos_chip_guard.dart';
import 'package:chessever/desktop/services/engine/macos_release_arch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MacOsReleaseArch', () {
    // Renaming any Silicon identifier strands every installed Silicon client:
    // desktop_updater filters app-archive.json on an exact platform string, so
    // a client asking for a key the server no longer publishes matches zero
    // items, gets a null version check, and silently never offers an update
    // again. That is exactly what builds 264/265 shipped with `macos-arm64`.
    // These are frozen values, not preferences — see CLAUDE.md §2.10.
    test('Silicon identifiers stay frozen; Intel is additive', () {
      expect(MacOsReleaseArch.arm64.updatePlatformKey, 'macos');
      expect(MacOsReleaseArch.arm64.stableDmgFileName, 'Chessever.dmg');
      expect(MacOsReleaseArch.x64.updatePlatformKey, 'macos-x64');
      expect(MacOsReleaseArch.x64.stableDmgFileName, 'Chessever-intel.dmg');
      expect(
        MacOsReleaseArch.arm64.stableDmgFileName,
        isNot(MacOsReleaseArch.x64.stableDmgFileName),
      );
      expect(
        MacOsReleaseArch.arm64.downloadUri.toString(),
        contains('Chessever.dmg'),
      );
      expect(
        MacOsReleaseArch.x64.downloadUri.toString(),
        contains('Chessever-intel.dmg'),
      );
    });

    test('tryParse accepts common wire names', () {
      expect(MacOsReleaseArch.tryParse('arm64'), MacOsReleaseArch.arm64);
      expect(MacOsReleaseArch.tryParse('x86_64'), MacOsReleaseArch.x64);
      expect(MacOsReleaseArch.tryParse('intel'), MacOsReleaseArch.x64);
      expect(MacOsReleaseArch.tryParse('nope'), isNull);
    });
  });

  group('hostMacOsArchFromMachine', () {
    test('maps uname-style machines', () {
      expect(hostMacOsArchFromMachine('arm64'), MacOsReleaseArch.arm64);
      expect(hostMacOsArchFromMachine('x86_64'), MacOsReleaseArch.x64);
      expect(hostMacOsArchFromMachine('unknown'), isNull);
    });
  });

  group('isWrongMacOsChip / evaluateMacOsChipMismatch', () {
    test('Silicon package on Intel is a mismatch', () {
      expect(
        isWrongMacOsChip(
          buildFlavor: MacOsReleaseArch.arm64,
          hostArch: MacOsReleaseArch.x64,
        ),
        isTrue,
      );
      final mismatch = evaluateMacOsChipMismatch(
        buildFlavor: MacOsReleaseArch.arm64,
        hostMachine: 'x86_64',
      );
      expect(mismatch, isNotNull);
      expect(mismatch!.hostArch, MacOsReleaseArch.x64);
      expect(mismatch.recoveryDownloadUri.toString(), contains('intel'));
      expect(mismatch.message, contains('Intel'));
    });

    test('Intel package on Silicon is a mismatch', () {
      final mismatch = evaluateMacOsChipMismatch(
        buildFlavor: MacOsReleaseArch.x64,
        hostMachine: 'arm64',
      );
      expect(mismatch, isNotNull);
      expect(mismatch!.hostArch, MacOsReleaseArch.arm64);
      // Silicon recovery uses the continuous Chessever.dmg alias.
      expect(
        mismatch.recoveryDownloadUri.toString(),
        endsWith('/Chessever.dmg'),
      );
    });

    test('matching flavors are fine', () {
      expect(
        evaluateMacOsChipMismatch(
          buildFlavor: MacOsReleaseArch.arm64,
          hostMachine: 'arm64',
        ),
        isNull,
      );
      expect(
        evaluateMacOsChipMismatch(
          buildFlavor: MacOsReleaseArch.x64,
          hostMachine: 'x86_64',
        ),
        isNull,
      );
    });

    test('non-macOS skips guard', () {
      expect(
        evaluateMacOsChipMismatch(
          buildFlavor: MacOsReleaseArch.arm64,
          hostMachine: 'x86_64',
          isMacOS: false,
        ),
        isNull,
      );
    });
  });

  group('desktopUpdatePlatformKey', () {
    test('uses dual keys on macOS and bare os elsewhere', () {
      expect(
        desktopUpdatePlatformKey(
          operatingSystem: 'macos',
          macOsFlavor: MacOsReleaseArch.arm64,
        ),
        'macos',
      );
      expect(
        desktopUpdatePlatformKey(
          operatingSystem: 'macos',
          macOsFlavor: MacOsReleaseArch.x64,
        ),
        'macos-x64',
      );
      expect(
        desktopUpdatePlatformKey(operatingSystem: 'windows'),
        'windows',
      );
      expect(desktopUpdatePlatformKey(operatingSystem: 'linux'), 'linux');
    });
  });
}
