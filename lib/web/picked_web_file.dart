import 'dart:typed_data';

/// A browser selection whose byte contents are read when it is copied.
final class PickedWebFile {
  const PickedWebFile({
    required this.relativePath,
    required this.readAsBytes,
    this.linkTo,
  });

  final String relativePath;
  final Future<Uint8List> Function() readAsBytes;

  /// Attaches write-back to a saved PGN when a file handle is available.
  final void Function(String storedPath)? linkTo;
}
