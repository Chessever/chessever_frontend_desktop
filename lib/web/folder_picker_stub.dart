import 'dart:typed_data';

/// A file from a folder the user picked, with its path inside that folder.
typedef PickedWebFile = ({String relativePath, Uint8List bytes});

Future<List<PickedWebFile>?> pickWebFolder({
  bool Function(String relativePath)? accept,
}) => throw UnsupportedError('Folder picking exists only in the web build.');
