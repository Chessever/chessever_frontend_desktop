import 'package:collection/collection.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/repository/api_utils/api_exceptions.dart';

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

/// True when [folder] must be treated as a games-only database rather than a
/// container that may hold folders and databases.
///
/// The server's container guard acts on `user_folders.node_type`, so a row that
/// carries it is classified by it and never by presentation. This is what keeps
/// the Desktop from calling a legacy node a folder when the server will refuse
/// child inserts under it (icon 'folder_container' + column default
/// 'database').
///
/// [gameCount] is only known to callers that also read the saved-game counts;
/// it upgrades an untyped legacy node to a database once it is known to hold
/// games.
bool libraryCloudNodeIsDatabase(
  LibraryFolder folder,
  Iterable<LibraryFolder> folders, {
  int? gameCount,
}) {
  final nodeType = folder.nodeType;
  if (nodeType == kLibraryNodeTypeFolder) return false;
  if (nodeType == kLibraryNodeTypeDatabase) {
    // A database node holds games only. A *mixed* legacy node (children created
    // before the container guard shipped) stays navigable so those children
    // remain reachable, and the server's invariant repair promotes it to a
    // folder.
    if (libraryCloudNodeHasChildren(folders, folder.id)) return false;
    // A node the client itself typed as a database is exact.
    if (folder.icon == 'database' || folder.icon == 'twic') return true;
    // Once it is known to hold games it is a database whatever its icon says,
    // and the create guard retargets away from it.
    if (gameCount != null && gameCount > 0) return true;
    // Otherwise this is a legacy container: builds up to 20.32.16 wrote the
    // folder icon without ever writing `node_type`, so the column default
    // ('database') is all that makes it look like one. The server accepts — and
    // promotes — a child under such a node while it holds no games, so leave it
    // presented as the folder the user created and let the first child repair
    // the row. Demoting it here would lock an empty folder into a kind it never
    // chose and block the very insert that heals it; if the live guard does
    // reject the insert anyway, [libraryCreateFolderRejectionMessage] says so in
    // words instead of failing generically.
    return false;
  }
  if (folder.icon == 'database' || folder.icon == 'twic') return true;
  if (_isKnownRootDatabase(folder) &&
      !libraryCloudNodeHasChildren(folders, folder.id)) {
    return true;
  }
  if (folder.icon != 'folder') return false;
  if (libraryCloudNodeHasChildren(folders, folder.id)) return false;
  if (folder.parentId != null) return true;
  return gameCount != null && gameCount > 0;
}

bool libraryCloudNodeHasChildren(
  Iterable<LibraryFolder> folders,
  String folderId,
) => folders.any((folder) => folder.parentId == folderId);

bool _isKnownRootDatabase(LibraryFolder folder) =>
    folder.name.trim().toLowerCase() == 'liked games';

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

/// The node a *new* cloud database name would clash with, or `null`.
///
/// Same account-wide `UNIQUE (user_id, name)` rule as [libraryCloudNodeNamed],
/// but the nodes the caller's own save created are excluded. A local-database
/// save inserts its destination database *before* the first game row, and
/// `user_folders` is streamed over realtime, so the node this very save is
/// filling arrives in the folder list while its rows are still streaming.
/// Matching the name against that list would report the save as an existing
/// clash against itself.
///
/// [createdIds] / [createdNames] are the nodes this save created (both are
/// matched, so a realtime payload and a create response name the same node
/// even if only one identity is known), and [saveInFlight] suppresses the
/// hint for the whole write. Neither can hide a real conflict: a name that
/// already existed when Save was pressed is refused by the pre-save guard
/// (with [libraryDuplicateCloudNodeMessage]) before any database is created,
/// and the server's unique constraint rejects a concurrent insert.
LibraryFolder? libraryNewCloudDatabaseNameConflict(
  String name,
  Iterable<LibraryFolder> folders, {
  Iterable<String> createdIds = const <String>[],
  Iterable<String> createdNames = const <String>[],
  bool saveInFlight = false,
}) {
  if (saveInFlight) return null;
  final createdIdSet = createdIds.toSet();
  final createdNameSet = <String>{
    for (final created in createdNames) created.trim(),
  };
  return libraryCloudNodeNamed(
    name,
    folders.where(
      (folder) =>
          !createdIdSet.contains(folder.id) &&
          !createdNameSet.contains(folder.name.trim()),
    ),
  );
}

/// A precise, actionable reason for a rejected `createFolder` insert, or `null`
/// when the failure is something else (network, auth, quota, unknown) and the
/// caller should keep its generic handling.
String? libraryCreateFolderRejectionMessage(
  Object error, {
  required String name,
  String? parentName,
}) {
  // `LibraryRepository.createFolder` runs through `handleApiCall`, which maps
  // `23505` to `GenericApiException('Duplicate entry')` before the caller can see
  // it, so the mapped text is matched here as well as the raw code. Both the
  // mapped and the raw rejection are an expected server-side guard, not a crash.
  final code = error is PostgrestException ? (error.code ?? '') : '';
  final text =
      switch (error) {
        PostgrestException e => '${e.message} ${e.details ?? ''}',
        GenericApiException e => e.message,
        _ => error.toString(),
      }.toLowerCase();
  if (code == '23505' ||
      text.contains('duplicate entry') ||
      text.contains('duplicate key')) {
    return libraryDuplicateCloudNodeMessage(name);
  }
  if (code == '23514' || text.contains('databases can only contain games')) {
    final where = parentName == null ? 'That item' : '"$parentName"';
    return '$where is a database. Folders and databases can only be created '
        'inside a folder.';
  }
  return null;
}

/// The account-wide duplicate-name message every cloud create surface shows.
///
/// `user_folders` is `UNIQUE (user_id, name)` for the whole account and
/// case-sensitive, so the conflict is never scoped to the folder being browsed.
String libraryDuplicateCloudNodeMessage(String name) =>
    'You already have a library item named "${name.trim()}". '
    'Choose a different name.';

/// True when a save may go on even though a node named [name] already exists.
///
/// Only nodes this same dialog created for its own saves are tolerated
/// ([ownNodeIds]): a destination database whose save failed before a single row
/// landed and whose removal did not happen (or whose removal the live folder
/// list has not caught up with). Those are not a pre-existing clash the user
/// has to rename for — the retry fills that same database. Every node the
/// dialog did not create stays a real clash, refused exactly as before.
bool librarySaveToleratesOwnCloudName({
  required LibraryFolder? clash,
  required Set<String> ownNodeIds,
}) => clash == null || ownNodeIds.contains(clash.id);
