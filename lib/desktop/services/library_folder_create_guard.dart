import 'package:collection/collection.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId;

/// Guards the two cloud containers the Library creates: folders and databases.
///
/// The server is the authority. `user_folders` carries
/// `UNIQUE (user_id, name)` (account-wide, case-sensitive) and the
/// `ensure_parent_node_is_folder()` BEFORE INSERT trigger
/// (`supabase/migrations/20260627095050_enforce_library_container_invariants.sql`):
///
/// * a child insert under a `folder` node is accepted;
/// * a child insert under a `database` node that holds no games is accepted and
///   the parent is silently promoted to `folder`;
/// * a child insert under a `database` node that already holds games raises
///   `23514 'Databases can only contain games; create child nodes under a
///   folder'`.
///
/// The Desktop must therefore never send a child insert for a node it only
/// *thinks* is a folder (`user_folders.node_type` is the authority, not `icon`),
/// and it must translate a rejection into an actionable message instead of the
/// generic failure toast.
///
/// See `docs/freemium_quota_contract.sql` §1 for the one-time repair that is
/// still required for legacy `icon = 'folder_container'` +
/// `node_type = 'database'` nodes.

/// Where a new folder/database created from inside a node must land.
class LibraryChildCreateTarget {
  const LibraryChildCreateTarget({
    required this.parent,
    required this.retargetedFromDatabase,
  });

  /// The cloud node the new item is created under, or `null` for the library
  /// top level.
  final LibraryFolder? parent;

  /// True when the node the user was inside is a database, so the create moved
  /// one level up into its parent folder. Databases contain games only, so
  /// there is no legal way to create a folder/database *inside* one.
  final bool retargetedFromDatabase;

  /// Display name of the create destination, for toasts and dialog titles.
  String get parentName => parent?.name ?? 'Library Home';
}

/// Resolve the container a new folder/database should be created under when the
/// user asks for one while standing inside [current].
///
/// [currentIsDatabase] is the caller's authoritative kind decision for
/// [current] (`libraryFolderIsDatabase`, which honours `user_folders.node_type`).
/// A database node is never used as the parent: the create is retargeted to its
/// parent folder, and to the top level when that parent is missing or is another
/// account's followed book.
LibraryChildCreateTarget libraryChildCreateTarget({
  required LibraryFolder current,
  required List<LibraryFolder> folders,
  required bool currentIsDatabase,
}) {
  if (!currentIsDatabase) {
    return LibraryChildCreateTarget(
      parent: current,
      retargetedFromDatabase: false,
    );
  }
  final parentId = current.parentId;
  final parent =
      parentId == null
          ? null
          : folders.firstWhereOrNull((folder) => folder.id == parentId);
  return LibraryChildCreateTarget(
    parent: parent == null || parent.isSubscribed ? null : parent,
    retargetedFromDatabase: true,
  );
}

/// The account's own cloud node that already uses [name], or `null`.
///
/// Mirrors `UNIQUE (user_id, name)`: the conflict is account-wide (not scoped to
/// the folder being browsed), case-sensitive, and ignores followed books, which
/// belong to another account and can never collide. The synthetic TWIC book is a
/// client-side id with no row, so it is ignored as well.
LibraryFolder? libraryCloudNodeNamed(
  String name,
  Iterable<LibraryFolder> folders,
) {
  final wanted = name.trim();
  if (wanted.isEmpty) return null;
  for (final folder in folders) {
    if (folder.isSubscribed) continue;
    if (folder.id == kTwicBookId) continue;
    if (folder.name.trim() == wanted) return folder;
  }
  return null;
}

/// A precise, actionable reason for a rejected `createFolder` insert, or `null`
/// when the failure is something else (network, auth, quota, unknown) and the
/// caller should keep its generic handling.
String? libraryCreateFolderRejectionMessage(
  Object error, {
  required String name,
  String? parentName,
}) {
  if (error is! PostgrestException) return null;
  final code = error.code ?? '';
  final text = '${error.message} ${error.details ?? ''}'.toLowerCase();
  if (code == '23505' || text.contains('duplicate key')) {
    return 'You already have a library item named "$name". '
        'Choose a different name.';
  }
  if (code == '23514' || text.contains('databases can only contain games')) {
    final where = parentName == null ? 'That item' : '"$parentName"';
    return '$where is a database. Folders and databases can only be created '
        'inside a folder.';
  }
  return null;
}
