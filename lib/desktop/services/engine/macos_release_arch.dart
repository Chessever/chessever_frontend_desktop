import 'dart:io';

/// Which macOS package flavor this build was produced as.
///
/// Each release embeds only one Stockfish slice so install size stays lean.
/// The flavor is baked in via `--dart-define=MACOS_RELEASE_ARCH=arm64|x64`.
enum MacOsReleaseArch {
  arm64('arm64'),
  x64('x64');

  const MacOsReleaseArch(this.wireName);
  final String wireName;

  /// Platform key stored in `app-archive.json` / archive directory names.
  String get updatePlatformKey => 'macos-$wireName';

  /// Stable website DMG alias for this flavor.
  String get stableDmgFileName => switch (this) {
    MacOsReleaseArch.arm64 => 'Chessever-arm64.dmg',
    MacOsReleaseArch.x64 => 'Chessever-intel.dmg',
  };

  Uri get downloadUri => Uri.parse(
    'https://chessever.com/updates/desktop/downloads/$stableDmgFileName',
  );

  String get humanLabel => switch (this) {
    MacOsReleaseArch.arm64 => 'Apple Silicon',
    MacOsReleaseArch.x64 => 'Intel',
  };

  static MacOsReleaseArch? tryParse(String? raw) {
    final key = (raw ?? '').trim().toLowerCase();
    return switch (key) {
      'arm64' || 'aarch64' || 'apple-silicon' || 'silicon' =>
        MacOsReleaseArch.arm64,
      'x64' || 'x86_64' || 'amd64' || 'intel' => MacOsReleaseArch.x64,
      _ => null,
    };
  }
}

/// Compile-time flavor for this binary. Defaults to Apple Silicon so existing
/// single-arch builds keep working until dual packaging is fully rolled out.
const String kMacOsReleaseArchDefine = String.fromEnvironment(
  'MACOS_RELEASE_ARCH',
  defaultValue: 'arm64',
);

MacOsReleaseArch macosReleaseArchFromDefine([String? raw]) {
  return MacOsReleaseArch.tryParse(raw ?? kMacOsReleaseArchDefine) ??
      MacOsReleaseArch.arm64;
}

/// Map `uname -m` / ProcessInfo-style machine strings to a release arch.
MacOsReleaseArch? hostMacOsArchFromMachine(String machine) {
  final key = machine.trim().toLowerCase();
  if (key.contains('arm64') || key.contains('aarch64')) {
    return MacOsReleaseArch.arm64;
  }
  if (key.contains('x86_64') ||
      key.contains('amd64') ||
      key == 'i386' ||
      key == 'x86') {
    return MacOsReleaseArch.x64;
  }
  return null;
}

/// True when this package's embedded engine arch cannot run natively on [host].
bool isWrongMacOsChip({
  required MacOsReleaseArch buildFlavor,
  required MacOsReleaseArch? hostArch,
}) {
  if (hostArch == null) return false;
  return buildFlavor != hostArch;
}

/// Platform key used when filtering `app-archive.json` items.
///
/// Non-macOS hosts keep the bare OS name so Windows/Linux are unchanged.
String desktopUpdatePlatformKey({
  String? operatingSystem,
  MacOsReleaseArch? macOsFlavor,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  if (os != 'macos') return os;
  return (macOsFlavor ?? macosReleaseArchFromDefine()).updatePlatformKey;
}

/// Human recovery copy for the wrong-chip dialog.
String wrongMacOsChipMessage({
  required MacOsReleaseArch buildFlavor,
  required MacOsReleaseArch hostArch,
}) {
  return 'This ChessEver package is built for ${buildFlavor.humanLabel} Macs, '
      'but this computer is ${hostArch.humanLabel}. '
      'Download the ${hostArch.humanLabel} build so the engine works.';
}
