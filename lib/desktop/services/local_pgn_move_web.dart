import 'dart:io';

/// The browser build's files live in the app's in-page filesystem, where
/// nothing else can create [destination] between the check and the move.
void moveLocalPgnWithoutReplacing(String source, String destination) {
  if (FileSystemEntity.typeSync(destination, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw FileSystemException(
      'Cannot rename database; destination already exists.',
      destination,
    );
  }
  File(source).renameSync(destination);
}
