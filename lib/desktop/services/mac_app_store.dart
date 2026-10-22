import 'dart:io' show File, Platform;

/// Opt-in distribution channel. Website and Windows builds keep their existing
/// update, billing, and engine behavior.
const bool macAppStoreBuild = bool.fromEnvironment('MAC_APP_STORE');

bool get isMacAppStore => Platform.isMacOS && macAppStoreBuild;

/// Sealed files installed by the Mac App Store release lane.
String macAppStoreBundledPath(String directory, String filename) =>
    '${File(Platform.resolvedExecutable).parent.parent.path}/$directory/$filename';
