import 'dart:math' as math;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_database_save_source.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Save to cloud" must offer the WHOLE local database to the save dialog.
///
/// Reported defect: a 1 436-game local database (a ChessBase conversion) landed
/// in the cloud as exactly 200 games. The save was handed
/// `databaseRows.loadedGames` — the table page that happened to be loaded, at
/// `_kLocalDatabaseGameQueryPageSize == 200` — instead of the database.
///
/// These tests pin the replacement: a paged enumeration of the same query that
/// walks every page in bounded batches, so the dialog is offered 1 436 rows
/// while a single loaded page is still only 200.
void main() {
  const pageSize = kLocalDatabaseSaveBatchSize;

  group('whole-database save enumeration', () {
    test('offers every game of a database larger than one page', () async {
      final database = _syntheticDatabase(1436);
      final requests = <int>[];
      final source = LocalDatabaseSaveEnumeration(
        loadPage: _pagedLoader(database, requests),
        totalCount: database.length,
        hydrate: _identityHydration,
      );

      expect(source.totalCount, 1436);
      expect(
        source.handedOverCount,
        0,
        reason: 'nothing is offered before the first batch is pulled',
      );

      final batches = await _drain(source);

      // 1 436 = 7 x 200 + 36, so eight bounded pages and a 36-game tail. The
      // dialog's progress bar and its cloud quota request both read this total.
      expect(
        batches.map((batch) => batch.length).toList(growable: false),
        const <int>[200, 200, 200, 200, 200, 200, 200, 36],
      );
      expect(
        batches.fold<int>(0, (sum, batch) => sum + batch.length),
        1436,
      );
      expect(
        requests,
        const <int>[0, 1, 2, 3, 4, 5, 6, 7],
        reason: 'every page is read once, in order',
      );
      expect(source.handedOverCount, 1436);
      expect(
        await source.nextBatch(),
        isEmpty,
        reason: 'an exhausted source never restarts',
      );
    });

    test('a single loaded page is 200 of 1436 — the pre-fix payload', () async {
      final database = _syntheticDatabase(1436);
      var pageReads = 0;
      final source = LocalDatabaseSaveEnumeration(
        loadPage: (page) {
          pageReads++;
          return Future<LocalChessGameQueryPage?>.value(
            _pageOf(database, page, pageSize),
          );
        },
        totalCount: database.length,
        hydrate: _identityHydration,
      );

      final firstBatch = await source.nextBatch();

      // The old save stopped here: `filtered` was the loaded page, so exactly
      // one page of 200 games was uploaded out of 1 436.
      expect(firstBatch.length, 200);
      expect(pageReads, 1);
      expect(
        source.totalCount,
        1436,
        reason: 'the save must be told the database total, not the page total',
      );
      expect(
        firstBatch.length,
        isNot(source.totalCount),
        reason: 'the loaded window is not the whole database',
      );
    });

    test('bounds every batch for a very large database', () async {
      const total = 78829;
      final database = _syntheticDatabase(total);
      final requests = <int>[];
      final source = LocalDatabaseSaveEnumeration(
        loadPage: _pagedLoader(database, requests),
        totalCount: total,
        hydrate: _identityHydration,
      );

      var seen = 0;
      var largestBatch = 0;
      while (true) {
        final batch = await source.nextBatch();
        if (batch.isEmpty) break;
        largestBatch = math.max(largestBatch, batch.length);
        seen += batch.length;
      }

      // 78 829 = 394 x 200 + 29 over 395 pages: the whole database is offered,
      // and at no point is more than one page of games resident, which is what
      // keeps a huge database savable.
      expect(seen, total);
      expect(largestBatch, pageSize);
      expect(requests.length, 395);
    });

    test('an active filter saves every match, not the file total', () async {
      // The page source is the filtered query: 137 matches across 1 436 games.
      final matches = _syntheticDatabase(137);
      final source = LocalDatabaseSaveEnumeration(
        loadPage: (page) => Future<LocalChessGameQueryPage?>.value(
          _pageOf(matches, page, pageSize),
        ),
        totalCount: matches.length,
        hydrate: _identityHydration,
      );

      expect(source.totalCount, 137);
      expect(
        (await _drain(source)).fold<int>(0, (sum, batch) => sum + batch.length),
        137,
      );
    });

    test('an empty database offers nothing', () async {
      final source = LocalDatabaseSaveEnumeration(
        loadPage: _pagedLoader(const <LocalChessGame>[], <int>[]),
        totalCount: 0,
        hydrate: _identityHydration,
      );

      expect(source.totalCount, 0);
      expect(await source.nextBatch(), isEmpty);
    });

    test('an unavailable page fails instead of uploading less', () async {
      final database = _syntheticDatabase(1436);
      final source = LocalDatabaseSaveEnumeration(
        loadPage: (page) => Future<LocalChessGameQueryPage?>.value(
          page == 0 ? _pageOf(database, 0, pageSize) : null,
        ),
        totalCount: database.length,
        hydrate: _identityHydration,
      );

      await source.nextBatch();

      await expectLater(
        source.nextBatch(),
        throwsA(
          isA<LocalDatabaseSaveSourceException>().having(
            (error) => error.message,
            'message',
            contains('could not be read'),
          ),
        ),
      );
    });

    test('a source that shrinks mid-save fails instead of uploading less', () async {
      final database = _syntheticDatabase(1436);
      final source = LocalDatabaseSaveEnumeration(
        loadPage: (page) => Future<LocalChessGameQueryPage?>.value(
          page == 0 ? _pageOf(database, 0, pageSize) : _emptyPage(page, 1436),
        ),
        totalCount: database.length,
        hydrate: _identityHydration,
      );

      await source.nextBatch();

      await expectLater(
        source.nextBatch(),
        throwsA(isA<LocalDatabaseSaveSourceException>()),
      );
    });

    test('a query total that changes mid-save fails instead of skewing', () async {
      final database = _syntheticDatabase(1436);
      final source = LocalDatabaseSaveEnumeration(
        loadPage: (page) => Future<LocalChessGameQueryPage?>.value(
          page == 0
              ? _pageOf(database, 0, pageSize)
              : _pageOf(database, page, pageSize, totalCount: 1200),
        ),
        totalCount: database.length,
        hydrate: _identityHydration,
      );

      await source.nextBatch();

      await expectLater(
        source.nextBatch(),
        throwsA(
          isA<LocalDatabaseSaveSourceException>().having(
            (error) => error.message,
            'message',
            contains('changed while it was being saved'),
          ),
        ),
      );
    });

    test('a prefetched first page is handed over without a second read', () async {
      final database = _syntheticDatabase(1436);
      final requests = <int>[];
      final firstPage = _pageOf(database, 0, pageSize)!;
      final source = LocalDatabaseSaveEnumeration(
        loadPage: _pagedLoader(database, requests),
        totalCount: database.length,
        hydrate: _identityHydration,
        prefetchedPages: <int, LocalChessGameQueryPage>{0: firstPage},
      );

      final firstBatch = await source.nextBatch();

      expect(firstBatch.length, 200);
      expect(
        requests,
        isEmpty,
        reason: 'the page read while preparing the source is reused',
      );
      expect(await source.nextBatch(), hasLength(200));
      expect(requests, const <int>[1]);
    });

    test('release is forwarded once and is idempotent', () {
      var releases = 0;
      final source = LocalDatabaseSaveEnumeration(
        loadPage: _pagedLoader(const <LocalChessGame>[], <int>[]),
        totalCount: 0,
        hydrate: _identityHydration,
        onRelease: () => releases++,
      );

      source.release();
      source.release();

      expect(releases, 1);
    });
  });

  group('save-batch hydration', () {
    test('re-parses raw PGN and keeps backfilled stored headers', () {
      final row = LocalChessGame(
        id: 'game-7',
        game: ChessGame(
          gameId: 'stale-row',
          startingFen: '',
          metadata: const <String, dynamic>{
            'White': 'Stored White',
            'WhiteTitle': 'GM',
          },
          mainline: const <ChessMove>[],
        ),
        rawPgn: '[Event "Prep"]\n'
            '[White "Parsed White"]\n'
            '[Black "Parsed Black"]\n'
            '[Result "1-0"]\n'
            '\n'
            '1. e4 e5 2. Nf3 1-0\n',
        sourcePath: r'C:\Games\Son tehlil.pgn',
        sourceRelativePath: 'Son tehlil.pgn',
        fileName: 'Son tehlil.pgn',
        indexInFile: 7,
        fileGameCount: 1436,
        hasMoves: true,
      );

      final hydrated = hydrateLocalGamesForSave(<LocalChessGame>[row]).single;

      expect(hydrated.gameId, 'game-7');
      expect(hydrated.mainline, isNotEmpty);
      expect(hydrated.metadata['White'], 'Parsed White');
      expect(
        hydrated.metadata['WhiteTitle'],
        'GM',
        reason: 'a backfilled FIDE title from the local row must survive',
      );
    });
  });
}

Future<List<ChessGame>> _identityHydration(List<LocalChessGame> games) async =>
    games.map((game) => game.game).toList(growable: false);

Future<List<List<ChessGame>>> _drain(LibrarySaveGameSource source) async {
  final batches = <List<ChessGame>>[];
  while (true) {
    final batch = await source.nextBatch();
    if (batch.isEmpty) return batches;
    batches.add(batch);
  }
}

LocalDatabasePageLoad _pagedLoader(
  List<LocalChessGame> database,
  List<int> requests, {
  int pageSize = kLocalDatabaseSaveBatchSize,
}) {
  return (int page) {
    requests.add(page);
    return Future<LocalChessGameQueryPage?>.value(
      _pageOf(database, page, pageSize),
    );
  };
}

LocalChessGameQueryPage? _pageOf(
  List<LocalChessGame> database,
  int page,
  int pageSize, {
  int? totalCount,
}) {
  final total = totalCount ?? database.length;
  final start = page * pageSize;
  if (start >= database.length) {
    return _emptyPage(page, total, pageSize: pageSize);
  }
  final end = math.min(start + pageSize, database.length);
  return LocalChessGameQueryPage(
    games: database.sublist(start, end),
    totalCount: total,
    pageNumber: page,
    pageSize: pageSize,
  );
}

LocalChessGameQueryPage _emptyPage(
  int page,
  int totalCount, {
  int pageSize = kLocalDatabaseSaveBatchSize,
}) {
  return LocalChessGameQueryPage(
    games: const <LocalChessGame>[],
    totalCount: totalCount,
    pageNumber: page,
    pageSize: pageSize,
  );
}

List<LocalChessGame> _syntheticDatabase(int count) {
  return <LocalChessGame>[
    for (var index = 0; index < count; index++)
      LocalChessGame(
        id: 'game-$index',
        game: ChessGame(
          gameId: 'game-$index',
          startingFen: '',
          metadata: <String, dynamic>{
            'White': 'White $index',
            'Black': 'Black $index',
            'Result': '1-0',
          },
          mainline: const <ChessMove>[],
        ),
        rawPgn: '',
        sourcePath: r'C:\Games\Son tehlil.pgn',
        sourceRelativePath: 'Son tehlil.pgn',
        fileName: 'Son tehlil.pgn',
        indexInFile: index,
        fileGameCount: count,
        hasMoves: false,
      ),
  ];
}
