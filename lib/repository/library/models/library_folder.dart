import 'package:dart_mappable/dart_mappable.dart';

part 'library_folder.mapper.dart';

const kPermanentLibraryFolderNames = <String>{
  'Liked Games',
  'My Database',
  'My Folder',
};

const _kPermanentLibraryFolderKeys = <String>{
  'liked games',
  'my database',
  'my folder',
};

bool isPermanentLibraryFolderName(String name) {
  return _kPermanentLibraryFolderKeys.contains(name.trim().toLowerCase());
}

/// Authoritative library node kinds stored in `user_folders.node_type`.
///
/// A `folder` organises (it may contain folders and databases, never games);
/// a `database` holds games. The column is `NOT NULL DEFAULT 'database'` on the
/// server, so it is the authority for how a node must behave — unlike `icon`,
/// which is client-chosen presentation.
const String kLibraryNodeTypeFolder = 'folder';
const String kLibraryNodeTypeDatabase = 'database';

/// Normalizes a `user_folders.node_type` value.
///
/// Returns [kLibraryNodeTypeFolder] / [kLibraryNodeTypeDatabase], or `null` when
/// the value is missing or unknown (synthetic client rows such as the TWIC book,
/// test fixtures, and any row read before the column existed). Callers must fall
/// back to the icon/metadata heuristics on `null` instead of guessing.
String? libraryNodeTypeFromRow(Object? value) {
  final raw = value?.toString().trim().toLowerCase();
  if (raw == kLibraryNodeTypeFolder) return kLibraryNodeTypeFolder;
  if (raw == kLibraryNodeTypeDatabase) return kLibraryNodeTypeDatabase;
  return null;
}

@MappableClass()
class LibraryFolder with LibraryFolderMappable {
  final String id;
  final String userId;
  final String name;
  final String color;
  final String icon;
  final int orderIndex;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? shareToken;
  final String? ownerDisplayName;
  final String? parentId;

  /// Authoritative node kind from `user_folders.node_type`
  /// ([kLibraryNodeTypeFolder] / [kLibraryNodeTypeDatabase]), normalized by
  /// [libraryNodeTypeFromRow]. `null` when the row did not carry the column —
  /// synthetic rows (TWIC) and older/cached fixtures — in which case callers use
  /// the icon/metadata heuristics.
  ///
  /// This is what the server's container guard acts on, so the Desktop must
  /// classify with it: a legacy node can look like a folder (`icon ==
  /// 'folder_container'`) while `node_type` is still the column default
  /// `'database'`. Creating a child under such a node is rejected by the server
  /// once it holds games.
  final String? nodeType;

  /// Client-side only — true when this folder was fetched via subscription.
  /// Not stored in DB; set by the provider layer.
  final bool isSubscribed;

  /// True for the per-user Likes collection. Persisted as `is_liked_games`.
  /// This flag, never the display name, is how the Likes collection is
  /// identified: likes do not spend the saved-game or database quotas and are
  /// governed by the seven-day Likes window instead of generic folder access.
  final bool isLikedGames;

  const LibraryFolder({
    required this.id,
    required this.userId,
    required this.name,
    required this.color,
    required this.icon,
    required this.orderIndex,
    required this.createdAt,
    required this.updatedAt,
    this.shareToken,
    this.ownerDisplayName,
    this.parentId,
    this.nodeType,
    this.isSubscribed = false,
    this.isLikedGames = false,
  });

  bool get isPermanentLibraryFolder =>
      isLikedGames || isPermanentLibraryFolderName(name);

  /// User-facing label. The Likes collection is branded "My Likes" whatever
  /// its stored row name is (legacy rows were created as "Liked Games").
  String get displayName => isLikedGames ? 'My Likes' : name;

  /// Convert Supabase JSON to LibraryFolder
  factory LibraryFolder.fromSupabase(Map<String, dynamic> json) {
    return LibraryFolder(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      color: json['color'] as String? ?? '#0FB4E5',
      icon: json['icon'] as String? ?? 'folder',
      orderIndex: json['order_index'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      shareToken: json['share_token'] as String?,
      parentId: json['parent_id'] as String?,
      nodeType: libraryNodeTypeFromRow(json['node_type']),
      isLikedGames: (json['is_liked_games'] as bool?) ?? false,
    );
  }

  /// Convert to Supabase format for insert (without id, timestamps auto-generated)
  Map<String, dynamic> toSupabaseInsert() {
    return {
      'user_id': userId,
      'name': name,
      'color': color,
      'icon': icon,
      'order_index': orderIndex,
      'parent_id': parentId,
    };
  }

  /// Convert to regular map for other uses
  Map<String, dynamic> toSupabaseMap() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'color': color,
      'icon': icon,
      'order_index': orderIndex,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'parent_id': parentId,
    };
  }
}
