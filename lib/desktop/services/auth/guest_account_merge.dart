import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/repository/library/models/library_folder.dart';

/// Columns that are never copied from a guest row into the destination.
///
/// Identity and ownership are re-derived for the destination, timestamps are
/// the database's, and `share_token` is unique per shared folder so a copy
/// must never claim the guest's public link.
const Set<String> kGuestMergeNeverCopiedColumns = {
  'id',
  'user_id',
  'subscriber_id',
  'created_at',
  'updated_at',
  'share_token',
};

typedef GuestMergeRow = Map<String, dynamic>;

List<GuestMergeRow> _rowsFromJson(Object? value) {
  if (value is! List) return const [];
  return [
    for (final row in value)
      if (row is Map)
        {for (final entry in row.entries) entry.key.toString(): entry.value},
  ];
}

GuestMergeRow? _rowFromJson(Object? value) {
  if (value is! Map) return null;
  return {for (final entry in value.entries) entry.key.toString(): entry.value};
}

String _text(Object? value) => value?.toString().trim() ?? '';

/// The data carried across an account switch, for one account.
///
/// Rows are raw Supabase maps so columns the desktop models do not read yet
/// (for example `is_liked_games`) survive the round trip untouched.
/// Purchased entitlements are deliberately absent: subscriptions belong to the
/// identity that paid and are never moved by a data merge.
@immutable
class GuestAccountRows {
  const GuestAccountRows({
    this.favoritePlayers = const [],
    this.favoriteEvents = const [],
    this.folders = const [],
    this.savedAnalyses = const [],
    this.bookSubscriptions = const [],
    this.engineSettings,
    this.notificationPreferences,
  });

  factory GuestAccountRows.fromJson(Map<String, dynamic> json) {
    return GuestAccountRows(
      favoritePlayers: _rowsFromJson(json['favorite_players']),
      favoriteEvents: _rowsFromJson(json['favorite_events']),
      folders: _rowsFromJson(json['folders']),
      savedAnalyses: _rowsFromJson(json['saved_analyses']),
      bookSubscriptions: _rowsFromJson(json['book_subscriptions']),
      engineSettings: _rowFromJson(json['engine_settings']),
      notificationPreferences: _rowFromJson(json['notification_preferences']),
    );
  }

  final List<GuestMergeRow> favoritePlayers;
  final List<GuestMergeRow> favoriteEvents;
  final List<GuestMergeRow> folders;
  final List<GuestMergeRow> savedAnalyses;
  final List<GuestMergeRow> bookSubscriptions;
  final GuestMergeRow? engineSettings;
  final GuestMergeRow? notificationPreferences;

  bool get isEmpty =>
      favoritePlayers.isEmpty &&
      favoriteEvents.isEmpty &&
      folders.isEmpty &&
      savedAnalyses.isEmpty &&
      bookSubscriptions.isEmpty &&
      engineSettings == null &&
      notificationPreferences == null;

  Map<String, dynamic> toJson() => {
    'favorite_players': favoritePlayers,
    'favorite_events': favoriteEvents,
    'folders': folders,
    'saved_analyses': savedAnalyses,
    'book_subscriptions': bookSubscriptions,
    'engine_settings': engineSettings,
    'notification_preferences': notificationPreferences,
  };
}

/// Guest data captured BEFORE the auth switch. After the switch, row level
/// security hides the guest's rows, so this snapshot is the only way to carry
/// them. It is persisted until a replay is confirmed, and the guest's own rows
/// are never deleted by the client.
@immutable
class GuestAccountSnapshot {
  const GuestAccountSnapshot({
    required this.guestUserId,
    required this.capturedAt,
    required this.rows,
  });

  factory GuestAccountSnapshot.fromJson(Map<String, dynamic> json) {
    return GuestAccountSnapshot(
      guestUserId: _text(json['guest_user_id']),
      capturedAt:
          DateTime.tryParse(_text(json['captured_at'])) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      rows: GuestAccountRows.fromJson(
        (json['rows'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }

  final String guestUserId;
  final DateTime capturedAt;
  final GuestAccountRows rows;

  Map<String, dynamic> toJson() => {
    'guest_user_id': guestUserId,
    'captured_at': capturedAt.toUtc().toIso8601String(),
    'rows': rows.toJson(),
  };

  String encode() => jsonEncode(toJson());

  static GuestAccountSnapshot? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final snapshot = GuestAccountSnapshot.fromJson(
        decoded.cast<String, dynamic>(),
      );
      return snapshot.guestUserId.isEmpty ? null : snapshot;
    } catch (_) {
      return null;
    }
  }
}

/// Writes needed to bring a destination up to date with a guest snapshot.
@immutable
class GuestMergePlan {
  const GuestMergePlan({
    this.favoritePlayers = const [],
    this.favoriteEvents = const [],
    this.folders = const [],
    this.savedAnalyses = const [],
    this.bookSubscriptions = const [],
    this.engineSettings,
    this.notificationPreferences,
  });

  /// Upserted with `onConflict: user_id,player_name, ignoreDuplicates`.
  final List<GuestMergeRow> favoritePlayers;

  /// Upserted with `onConflict: user_id,event_id, ignoreDuplicates`.
  final List<GuestMergeRow> favoriteEvents;

  /// Parents always precede children. Upserted on `id`, ignoring duplicates.
  final List<GuestMergeRow> folders;

  /// Upserted on `id`, ignoring duplicates.
  final List<GuestMergeRow> savedAnalyses;
  final List<GuestMergeRow> bookSubscriptions;

  /// Only present when the destination has no settings row of its own.
  final GuestMergeRow? engineSettings;
  final GuestMergeRow? notificationPreferences;

  int get writeCount =>
      favoritePlayers.length +
      favoriteEvents.length +
      folders.length +
      savedAnalyses.length +
      bookSubscriptions.length +
      (engineSettings == null ? 0 : 1) +
      (notificationPreferences == null ? 0 : 1);

  bool get isEmpty => writeCount == 0;
}

/// Deterministic, RFC 4122 shaped (name-based, v5 style) id for the copy of a
/// guest row in [targetUserId]'s account. The same guest row always maps to
/// the same destination id, so a retried merge collides with its own earlier
/// write instead of creating a second copy, and distinct guest rows stay
/// distinct documents.
String deriveGuestMergeRowId({
  required String targetUserId,
  required String guestRowId,
}) {
  final digest = sha1.convert(
    utf8.encode('chessever-guest-merge:$targetUserId:$guestRowId'),
  );
  final bytes = digest.bytes.sublist(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _isLikedGamesFolder(GuestMergeRow row) => row['is_liked_games'] == true;

GuestMergeRow _copyColumns(GuestMergeRow row) => {
  for (final entry in row.entries)
    if (!kGuestMergeNeverCopiedColumns.contains(entry.key))
      entry.key: entry.value,
};

/// Plans an idempotent merge of [snapshot] into the destination account.
///
/// * Relationship records (favourites, shared-book subscriptions, likes) are
///   merged: when the destination already holds the same relationship, the
///   destination record is kept and the guest copy is not written twice.
/// * Documents (folders, saved analyses) are copied under deterministic ids,
///   so a retry is a no-op and two guest documents never collapse into one.
/// * The Likes collection is matched by its `is_liked_games` flag, never by
///   its display name. The permanent "My Folder" / "My Database" pair is
///   matched to the destination's own so a merge never creates a second one.
/// * Settings rows are written only when the destination has none: destination
///   preferences always win.
/// * There is no quota here. A merge that leaves the account over a free limit
///   keeps every record; trimming to fit would be data loss.
GuestMergePlan planGuestAccountMerge({
  required GuestAccountSnapshot snapshot,
  required GuestAccountRows destination,
  required String targetUserId,
}) {
  final target = targetUserId.trim();
  if (target.isEmpty || target == snapshot.guestUserId) {
    return const GuestMergePlan();
  }
  final rows = snapshot.rows;

  // Favourite players: fide_id first, exact player_name as the fallback key
  // (the same key the table's upsert conflict target uses).
  final destFideIds = {
    for (final row in destination.favoritePlayers)
      if (_text(row['fide_id']).isNotEmpty) _text(row['fide_id']),
  };
  final destPlayerNames = {
    for (final row in destination.favoritePlayers) _text(row['player_name']),
  };
  final favoritePlayers = <GuestMergeRow>[];
  for (final row in rows.favoritePlayers) {
    final fideId = _text(row['fide_id']);
    final name = _text(row['player_name']);
    if (name.isEmpty) continue;
    if (fideId.isNotEmpty && !destFideIds.add(fideId)) continue;
    if (!destPlayerNames.add(name)) continue;
    favoritePlayers.add({
      'user_id': target,
      'fide_id': fideId.isEmpty ? null : fideId,
      'player_name': name,
      'metadata': row['metadata'],
    });
  }

  final destEventIds = {
    for (final row in destination.favoriteEvents) _text(row['event_id']),
  };
  final favoriteEvents = <GuestMergeRow>[];
  for (final row in rows.favoriteEvents) {
    final eventId = _text(row['event_id']);
    if (eventId.isEmpty || !destEventIds.add(eventId)) continue;
    favoriteEvents.add({
      'user_id': target,
      'event_id': eventId,
      'event_name': row['event_name'],
      'metadata': row['metadata'],
    });
  }

  // Folders, parents before children.
  final destFolderIds = {
    for (final row in destination.folders) _text(row['id']),
  };
  final destLiked = destination.folders.where(_isLikedGamesFolder).firstOrNull;
  final guestFoldersById = {
    for (final row in rows.folders)
      if (_text(row['id']).isNotEmpty) _text(row['id']): row,
  };
  final folderIdMap = <String, String>{};
  final likedFolderIds = <String>{};
  final folders = <GuestMergeRow>[];
  final visiting = <String>{};

  String? mapFolder(String guestId) {
    final known = folderIdMap[guestId];
    if (known != null) return known;
    final row = guestFoldersById[guestId];
    if (row == null || !visiting.add(guestId)) return null; // missing or cycle
    try {
      final guestParent = _text(row['parent_id']);
      final parentId = guestParent.isEmpty ? null : mapFolder(guestParent);
      final name = _text(row['name']);
      final liked = _isLikedGamesFolder(row);
      if (liked) likedFolderIds.add(guestId);

      String? existing;
      if (liked && destLiked != null) {
        existing = _text(destLiked['id']);
      } else if (!liked && isPermanentLibraryFolderName(name)) {
        existing =
            destination.folders
                .where(
                  (dest) =>
                      !_isLikedGamesFolder(dest) &&
                      _text(dest['name']).toLowerCase() == name.toLowerCase() &&
                      (_text(dest['parent_id']).isEmpty
                          ? parentId == null
                          : _text(dest['parent_id']) == parentId),
                )
                .map((dest) => _text(dest['id']))
                .firstOrNull;
      }
      if (existing != null && existing.isNotEmpty) {
        return folderIdMap[guestId] = existing;
      }

      final derived = deriveGuestMergeRowId(
        targetUserId: target,
        guestRowId: guestId,
      );
      folderIdMap[guestId] = derived;
      if (destFolderIds.add(derived)) {
        folders.add({
          ..._copyColumns(row),
          'id': derived,
          'user_id': target,
          'parent_id': parentId,
        });
      }
      return derived;
    } finally {
      visiting.remove(guestId);
    }
  }

  for (final guestId in guestFoldersById.keys) {
    mapFolder(guestId);
  }

  // Saved analyses. A like the destination already has (same source game in
  // its Likes collection) is the same relationship, so it is merged.
  final destAnalysisIds = {
    for (final row in destination.savedAnalyses) _text(row['id']),
  };
  final destLikedId = destLiked == null ? null : _text(destLiked['id']);
  final destLikedGameIds = {
    for (final row in destination.savedAnalyses)
      if (destLikedId != null &&
          _text(row['folder_id']) == destLikedId &&
          _text(row['source_game_id']).isNotEmpty)
        _text(row['source_game_id']),
  };
  final savedAnalyses = <GuestMergeRow>[];
  for (final row in rows.savedAnalyses) {
    final guestId = _text(row['id']);
    if (guestId.isEmpty) continue;
    final guestFolder = _text(row['folder_id']);
    final isLike = likedFolderIds.contains(guestFolder);
    final sourceGameId = _text(row['source_game_id']);
    if (isLike && sourceGameId.isNotEmpty) {
      final mappedToDestLikes = folderIdMap[guestFolder] == destLikedId;
      if (mappedToDestLikes && !destLikedGameIds.add(sourceGameId)) continue;
    }
    final derived = deriveGuestMergeRowId(
      targetUserId: target,
      guestRowId: guestId,
    );
    if (!destAnalysisIds.add(derived)) continue;
    savedAnalyses.add({
      ..._copyColumns(row),
      'id': derived,
      'user_id': target,
      'folder_id': guestFolder.isEmpty ? null : folderIdMap[guestFolder],
    });
  }

  final destBookIds = {
    for (final row in destination.bookSubscriptions) _text(row['folder_id']),
  };
  final bookSubscriptions = <GuestMergeRow>[];
  for (final row in rows.bookSubscriptions) {
    final folderId = _text(row['folder_id']);
    if (folderId.isEmpty || !destBookIds.add(folderId)) continue;
    bookSubscriptions.add({'folder_id': folderId, 'subscriber_id': target});
  }

  GuestMergeRow? settingsRow(GuestMergeRow? guest, GuestMergeRow? dest) {
    if (guest == null || dest != null) return null;
    return {..._copyColumns(guest), 'user_id': target};
  }

  return GuestMergePlan(
    favoritePlayers: favoritePlayers,
    favoriteEvents: favoriteEvents,
    folders: folders,
    savedAnalyses: savedAnalyses,
    bookSubscriptions: bookSubscriptions,
    engineSettings: settingsRow(
      rows.engineSettings,
      destination.engineSettings,
    ),
    notificationPreferences: settingsRow(
      rows.notificationPreferences,
      destination.notificationPreferences,
    ),
  );
}
