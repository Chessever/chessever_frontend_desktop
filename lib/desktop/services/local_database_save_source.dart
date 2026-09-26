import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/local_raw_pgn_catalog.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

/// Games handed to a bulk save, one bounded batch at a time.
///
/// A whole-database cloud save must not materialize a 78 000-game database in
/// memory, so the save dialog pulls batches instead of receiving one list.
/// Implementations hand over every game exactly once and keep peak memory at
/// roughly one batch of raw PGN plus one cloud request chunk.
abstract class LibrarySaveGameSource {
  /// Total games this source will hand over. Known before the first batch.
  int get totalCount;

  /// Next batch, or an empty list once every game has been handed over.
  ///
  /// Callers must not retain the returned list longer than the batch write.
  Future<List<ChessGame>> nextBatch();

  /// Releases whatever backs this source (for example a raw-PGN catalog
  /// handle). Idempotent; safe to call whether or not the save started.
  void release() {}
}

/// One page of a local database query. The same shape the workspace table's
/// page loader uses, so the table and the cloud save read identical rows.
typedef LocalDatabasePageLoad =
    Future<LocalChessGameQueryPage?> Function(int pageNumber);

/// Turns one page of lightweight local rows into full [ChessGame]s.
typedef LocalGamesHydration =
    Future<List<ChessGame>> Function(List<LocalChessGame> games);

/// Raised when a whole-database save cannot keep its own promise (the file
/// changed, a page vanished, the source shrank mid-save). The message is
/// user-facing, so it never leaks a `Bad state:` wrapper.
class LocalDatabaseSaveSourceException implements Exception {
  const LocalDatabaseSaveSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Rows per page when a whole local database is enumerated for a cloud save.
///
/// Matches the workspace table's page size and stays inside the raw-PGN
/// catalog's own clamp (it serves at most 200 rows per page), so pages tile
/// without gaps whichever source backs the query.
const int kLocalDatabaseSaveBatchSize = 200;

/// Enumerates every game a local database offers to "Save to cloud".
///
/// It walks the *same* paged query the workspace table reads — same search,
/// sort, filter and player scope — but through **all** pages, so the upload
/// covers the whole database instead of the loaded window (the table page
/// that happened to be on screen was the reported truncation). Each page is
/// hydrated from its raw PGN on a worker isolate.
///
/// With an active search or filter the save covers everything that filter
/// matches across every page, which is the only reading that keeps "Save to
/// cloud" honest: what you see filtered is what you upload, all of it.
class LocalDatabaseSaveEnumeration implements LibrarySaveGameSource {
  LocalDatabaseSaveEnumeration({
    required LocalDatabasePageLoad loadPage,
    required int totalCount,
    this.pageSize = kLocalDatabaseSaveBatchSize,
    LocalGamesHydration? hydrate,
    void Function()? onRelease,
    Map<int, LocalChessGameQueryPage> prefetchedPages =
        const <int, LocalChessGameQueryPage>{},
  }) : _loadPage = loadPage,
       _totalCount = totalCount < 0 ? 0 : totalCount,
       _hydrate = hydrate ?? _hydrateOnWorker,
       _onRelease = onRelease,
       _prefetched = Map<int, LocalChessGameQueryPage>.of(prefetchedPages) {
    if (_totalCount == 0) _done = true;
  }

  final LocalDatabasePageLoad _loadPage;
  final LocalGamesHydration _hydrate;
  final void Function()? _onRelease;
  final Map<int, LocalChessGameQueryPage> _prefetched;

  /// Rows requested per page. Never larger than the raw-PGN catalog serves.
  final int pageSize;

  final int _totalCount;
  int _nextPage = 0;
  int _handedOver = 0;
  bool _done = false;
  bool _released = false;

  @override
  int get totalCount => _totalCount;

  /// Games already handed to the save. Exposed for progress assertions.
  @visibleForTesting
  int get handedOverCount => _handedOver;

  @override
  Future<List<ChessGame>> nextBatch() async {
    if (_done) return const <ChessGame>[];
    final pageNumber = _nextPage;
    final prefetched = _prefetched.remove(pageNumber);
    final page = prefetched ?? await _loadPage(pageNumber);
    if (page == null) {
      throw const LocalDatabaseSaveSourceException(
        'The local database could not be read while saving. Refresh the '
        'database and try again.',
      );
    }
    if (page.pageNumber != pageNumber || page.pageSize != pageSize) {
      throw const LocalDatabaseSaveSourceException(
        'The local database returned an unexpected page while saving. Refresh '
        'the database and try again.',
      );
    }
    // A page total that moved means the underlying query changed under the
    // save (an import, a delete, an external edit). Stopping is the honest
    // outcome: continuing would upload a silently skewed copy.
    if (page.totalCount != _totalCount) {
      throw const LocalDatabaseSaveSourceException(
        'The local database changed while it was being saved. Refresh the '
        'database and try again.',
      );
    }
    final games = page.games;
    if (games.isEmpty) {
      if (_handedOver < _totalCount) {
        throw const LocalDatabaseSaveSourceException(
          'The local database changed while it was being saved. Refresh the '
          'database and try again.',
        );
      }
      _done = true;
      return const <ChessGame>[];
    }
    _nextPage = pageNumber + 1;
    _handedOver += games.length;
    if (_handedOver >= _totalCount) _done = true;
    // Hydrate off the UI isolate: `rawPgn` reads the record's byte range from
    // disk, and parsing a page's worth of PGN on the UI thread would stall the
    // dialog on every batch of a large database.
    return _hydrate(games);
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    _prefetched.clear();
    _onRelease?.call();
  }
}

Future<List<ChessGame>> _hydrateOnWorker(List<LocalChessGame> games) =>
    compute(hydrateLocalGamesForSave, games);

/// Re-parses raw PGN for a batch of local rows so saved cloud entries carry
/// full move data.
///
/// The scanner builds light [ChessGame]s with empty mainlines, so what the
/// repository/table returns is not what the cloud should store. Runs inside a
/// worker isolate (see [LocalDatabaseSaveEnumeration.nextBatch]).
List<ChessGame> hydrateLocalGamesForSave(List<LocalChessGame> games) {
  final out = <ChessGame>[];
  for (final game in games) {
    try {
      final parsed = ChessGame.fromPgn(game.id, game.rawPgn);
      // The stored header bag may carry backfilled tags (WhiteTitle/WhiteFed)
      // the raw PGN never had; keep them when saving to the library.
      out.add(
        parsed.copyWith(
          metadata: <String, dynamic>{
            ...game.game.metadata,
            ...parsed.metadata,
          },
        ),
      );
    } catch (_) {
      out.add(game.game);
    }
  }
  return out;
}

/// Enumerates the whole of a `.pgn` file straight from disk.
///
/// The workspace table normally pages through the repository index or through
/// an already-open raw-PGN catalog. A workspace that still holds only the
/// session-only preview (its first [previewMaxGames] records) has neither, so
/// this walks the real file with [openLocalRawPgnCatalog] and enumerates every
/// record — the preview window is never what gets uploaded.
///
/// The returned source owns the catalog handle and releases it from
/// [LibrarySaveGameSource.release].
Future<LocalDatabaseSaveEnumeration> openLocalDatabaseSaveEnumerationFromPgn({
  required String path,
  String? sourceLabel,
  String search = '',
  LocalChessGameSortField sortBy = LocalChessGameSortField.originalOrder,
  LocalChessGameSortDirection sortDirection = LocalChessGameSortDirection.asc,
  LocalChessGameFilter? filter,
  String? playerFideId,
  List<String> playerAliases = const <String>[],
  int pageSize = kLocalDatabaseSaveBatchSize,
  void Function(LocalChessScanProgress progress)? onProgress,
  OperationCancellationToken? cancellationToken,
}) async {
  final handle = await openLocalRawPgnCatalog(
    path,
    sourceLabel: sourceLabel,
    onProgress: onProgress,
    cancellationToken: cancellationToken,
  );
  var keepHandle = false;
  try {
    final descriptor = handle.descriptor;
    Future<LocalChessGameQueryPage?> load(int pageNumber) =>
        localRawPgnCatalogPage(
          LocalRawPgnCatalogPageQuery(
            descriptor: descriptor,
            search: search,
            sortBy: sortBy,
            sortDirection: sortDirection,
            filter: filter,
            playerFideId: playerFideId,
            playerAliases: playerAliases,
            pageNumber: pageNumber,
            pageSize: pageSize,
          ),
        );
    // Read the first page before handing the source over: with an active
    // search or filter the file's own game count is not the save's total, and
    // the dialog needs the exact figure for its progress and header. The page
    // is kept, so it is never fetched twice.
    final firstPage = await load(0);
    if (firstPage == null) {
      throw const LocalDatabaseSaveSourceException(
        'The local PGN could not be read. Refresh the database and try again.',
      );
    }
    final enumeration = LocalDatabaseSaveEnumeration(
      loadPage: load,
      totalCount: firstPage.totalCount,
      pageSize: pageSize,
      onRelease: handle.release,
      prefetchedPages: <int, LocalChessGameQueryPage>{0: firstPage},
    );
    keepHandle = true;
    return enumeration;
  } finally {
    if (!keepHandle) handle.release();
  }
}
