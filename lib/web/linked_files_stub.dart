bool get linkedFilesSupported => false;

Future<List<String>?> pickLinkedChessFiles(String folder) =>
    throw UnsupportedError('Linked files exist only in the web build.');
