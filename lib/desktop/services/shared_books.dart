import 'package:chessever/repository/api_utils/api_exceptions.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId;

/// Canonical public link for a shared book.
String sharedBookUrl(String shareToken) =>
    'https://chessever.com/books/${Uri.encodeComponent(shareToken)}';

/// Only a root database the user owns can be published.
///
/// Mirrors the phone rule (`folder.parentId != null || folder.isFolder` is
/// not shareable). Desktop folders carry no node type, so the caller passes
/// the database classification it already uses for the Library.
/// `isSubscribed` is a client-side flag set only by `getSubscribedBooks()`.
bool libraryFolderIsShareable(
  LibraryFolder folder, {
  required bool isDatabase,
}) {
  return !folder.isSubscribed &&
      folder.id != kTwicBookId &&
      folder.parentId == null &&
      isDatabase;
}

/// True when subscribing failed because the row already exists.
bool isDuplicateSubscriptionError(Object error) {
  if (error is GenericApiException) return error.message == 'Duplicate entry';
  final raw = error.toString().toLowerCase();
  return raw.contains('duplicate') || raw.contains('23505');
}

enum SharedBookAddOutcome { added, alreadyInLibrary, ownBook }

/// Adds a shared book to the signed-in user's library.
///
/// [findOwnedFolder] resolves only folders the current user owns (the
/// repository's `getFolder` filters on `user_id`). A duplicate subscription is
/// not an error: the book is already in the library.
Future<SharedBookAddOutcome> addSharedBookToLibrary({
  required String folderId,
  required Future<LibraryFolder?> Function(String folderId) findOwnedFolder,
  required Future<void> Function(String folderId) subscribe,
}) async {
  LibraryFolder? owned;
  try {
    owned = await findOwnedFolder(folderId);
  } catch (_) {
    owned = null;
  }
  if (owned != null) return SharedBookAddOutcome.ownBook;
  try {
    await subscribe(folderId);
    return SharedBookAddOutcome.added;
  } catch (error) {
    if (isDuplicateSubscriptionError(error)) {
      return SharedBookAddOutcome.alreadyInLibrary;
    }
    rethrow;
  }
}

/// [addSharedBookToLibrary] against the real repository.
Future<SharedBookAddOutcome> addSharedBookToLibraryWith(
  LibraryRepository repository,
  String folderId,
) {
  return addSharedBookToLibrary(
    folderId: folderId,
    findOwnedFolder: repository.getFolder,
    subscribe: repository.subscribeToBook,
  );
}
