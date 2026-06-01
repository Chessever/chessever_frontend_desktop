import 'package:flutter/foundation.dart';

/// Payload used when dragging a database-like source from the Library rail
/// onto the My Databases board.
@immutable
class LibraryDatabaseDragPayload {
  const LibraryDatabaseDragPayload.cloud({
    required this.folderId,
    required this.title,
  }) : localPath = null;

  const LibraryDatabaseDragPayload.local({
    required this.localPath,
    required this.title,
  }) : folderId = null;

  final String? folderId;
  final String? localPath;
  final String title;

  bool get isCloud => folderId != null;
  bool get isLocal => localPath != null;
}
