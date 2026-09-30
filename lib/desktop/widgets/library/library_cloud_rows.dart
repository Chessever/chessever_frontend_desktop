import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import 'package:chessever/repository/library/models/saved_analysis.dart';

/// Scope key for a cloud folder database.
///
/// A subscribed (shared) book and an owned folder can share an id namespace
/// while being different row sources, so the sharing flag is part of the key.
/// Every surface that shows the same database must derive the same key.
String libraryCloudDatabaseScope(
  String folderId, {
  required bool isSubscribed,
}) => '${isSubscribed ? 'shared' : 'owned'}:$folderId';

/// Stable widget key for one saved-game row.
///
/// Row identity must be the analysis id, not the list index: a quiet refresh
/// republishes the same rows as new objects, and index-keyed elements would
/// churn whenever a row is inserted or removed.
ValueKey<String> libraryDatabaseSavedRowKey(String analysisId) =>
    ValueKey<String>('database-saved-row:$analysisId');

/// One atomic publication of a cloud database's saved-game rows.
///
/// [scope] identifies the database the rows belong to and [rows] holds the
/// last successfully loaded rows *for that scope* (null when nothing has
/// loaded for it yet). Scope and rows travel together so a consumer can never
/// pair one database's rows with another database's name.
///
/// [isRefreshing] and [isInitialLoading] split the two meanings that a single
/// "connectionState != done" check used to conflate:
///
/// * [isInitialLoading] — nothing to show yet for this scope. Only this state
///   may replace the surface with a loading placeholder.
/// * [isRefreshing] — real rows are on screen while a background fetch runs
///   (the periodic catch-up, a realtime notification, a post-write nonce).
///   A refresh must never empty or blank the list.
@immutable
class LibraryCloudRowsSnapshot {
  const LibraryCloudRowsSnapshot({
    required this.scope,
    required this.rows,
    required this.isInitialLoading,
    required this.isRefreshing,
    this.error,
  });

  final String scope;
  final List<SavedAnalysis>? rows;
  final bool isInitialLoading;
  final bool isRefreshing;

  /// Failure of the most recent fetch, surfaced only when it left nothing to
  /// show. A background failure must never replace rows that are on screen.
  final Object? error;
}

class _ScopedCloudRows {
  const _ScopedCloudRows(this.scope, this.rows);

  final String scope;
  final List<SavedAnalysis> rows;
}

/// Fetches a cloud database's rows with scope-tagged, refresh-quiet
/// semantics.
///
/// [refreshKeys] are the signals that ask for a fresh fetch: a local
/// post-write nonce, the cloud Library refresh nonce, and the realtime
/// revision. Any of them (or [scope]) starts a fetch while the previous
/// publication stays on screen.
///
/// A completed fetch is only published when it belongs to the scope being
/// rendered; a stale or out-of-order completion cannot leak rows across
/// databases. A failed refresh keeps the last good rows for the same scope
/// instead of clearing the table.
LibraryCloudRowsSnapshot useLibraryCloudRows({
  required String scope,
  required List<Object?> refreshKeys,
  required Future<List<SavedAnalysis>> Function() fetch,
}) {
  final future = useMemoized<Future<_ScopedCloudRows>>(
    () => fetch().then((rows) => _ScopedCloudRows(scope, rows)),
    <Object?>[scope, ...refreshKeys],
  );
  // preserveState keeps the previous publication across a key change, which is
  // what lets a background refresh leave the visible rows untouched.
  final snapshot = useFuture(future, preserveState: true);
  final lastGood = useRef<_ScopedCloudRows?>(null);

  // An error settles with a null-data snapshot, so remember the last success
  // separately rather than letting a transient failure blank a loaded table.
  final settled = snapshot.hasError ? null : snapshot.data;
  if (settled != null) lastGood.value = settled;

  final published = lastGood.value;
  final current =
      published != null && published.scope == scope ? published : null;
  final inFlight = snapshot.connectionState != ConnectionState.done;
  return LibraryCloudRowsSnapshot(
    scope: scope,
    rows: current?.rows,
    isInitialLoading: current == null && inFlight,
    isRefreshing: current != null && inFlight,
    error: current == null ? snapshot.error : null,
  );
}
