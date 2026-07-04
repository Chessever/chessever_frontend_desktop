import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

// Game 1: TWIC-shaped — FIDE IDs present, no titles, no country tags.
// Game 2: fully tagged both sides — enrichment must not touch it.
// Game 3: no FIDE IDs at all — enrichment must skip it entirely.
const _mixedPgn = '''
[Event "Speed Chess Championship"]
[Site "chess.com"]
[Date "2025.10.13"]
[Round "1.1"]
[White "Carlsen, Magnus"]
[Black "Le, Tuan Minh"]
[Result "1-0"]
[WhiteFideId "1503014"]
[BlackFideId "12401153"]

1. e4 e5 1-0

[Event "Bundesliga"]
[Site "Berlin GER"]
[Date "2024.03.01"]
[Round "5"]
[White "Keymer, Vincent"]
[Black "Bluebaum, Matthias"]
[Result "1/2-1/2"]
[WhiteFideId "12940690"]
[BlackFideId "24651516"]
[WhiteTitle "IM"]
[BlackTitle "IM"]
[WhiteFed "GER"]
[BlackFed "SUI"]

1. d4 d5 1/2-1/2

[Event "Club Night"]
[Site "Local"]
[Date "2020.01.01"]
[Round "1"]
[White "Smith, John"]
[Black "Doe, Jane"]
[Result "0-1"]

1. c4 c5 0-1
''';

const _resolvable = <int, LocalPlayerEnrichment>{
  1503014: LocalPlayerEnrichment(title: 'GM', federation: 'NOR'),
  12401153: LocalPlayerEnrichment(title: 'GM', federation: 'VIE'),
  12940690: LocalPlayerEnrichment(title: 'GM', federation: 'GER'),
  24651516: LocalPlayerEnrichment(title: 'GM', federation: 'GER'),
};

void main() {
  late Directory temp;
  late resqlite.Database db;
  late LocalChessDatabaseRepository repo;
  late File pgnFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever_enrich_');
    db = await resqlite.Database.open('${temp.path}/local_chess.db');
    await db.execute('PRAGMA foreign_keys=ON');
    await createLocalChessResqliteDatabaseSchema(db);
    repo = LocalChessDatabaseRepository(database: () async => db);
    pgnFile = File('${temp.path}/mixed.pgn');
    await pgnFile.writeAsString(_mixedPgn);
    final source = await repo.importSingleFileSource(path: pgnFile.path);
    expect(source, isNotNull);
  });

  tearDown(() async {
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<Map<String, Map<String, dynamic>>> loadHeadersByWhite() async {
    final page = await repo.localDatabaseGamesPage(
      databasePath: pgnFile.path,
      pageNumber: 0,
      pageSize: 50,
    );
    expect(page, isNotNull);
    return <String, Map<String, dynamic>>{
      for (final game in page!.games)
        game.game.metadata['White'].toString(): game.game.metadata,
    };
  }

  group('enrichLocalDatabasePlayers', () {
    test('backfills missing titles and federations by FIDE ID', () async {
      final requested = <int>{};
      final updated = await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: (ids) async {
          requested.addAll(ids);
          return _resolvable;
        },
      );
      expect(updated, 1);
      // Only the TWIC-shaped game needs work; the fully-tagged and
      // FIDE-less games contribute no lookups.
      expect(requested, <int>{1503014, 12401153});

      final headers = await loadHeadersByWhite();
      final twic = headers['Carlsen, Magnus']!;
      expect(twic['WhiteTitle'], 'GM');
      expect(twic['WhiteFed'], 'NOR');
      expect(twic['BlackTitle'], 'GM');
      expect(twic['BlackFed'], 'VIE');
    });

    test('never overwrites tags the source PGN carried', () async {
      await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: (_) async => _resolvable,
      );
      final headers = await loadHeadersByWhite();
      final tagged = headers['Keymer, Vincent']!;
      expect(tagged['WhiteTitle'], 'IM');
      expect(tagged['WhiteFed'], 'GER');
      expect(tagged['BlackTitle'], 'IM');
      expect(tagged['BlackFed'], 'SUI');
    });

    test('leaves FIDE-less games untouched', () async {
      await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: (_) async => _resolvable,
      );
      final headers = await loadHeadersByWhite();
      final plain = headers['Smith, John']!;
      expect(plain.containsKey('WhiteTitle'), isFalse);
      expect(plain.containsKey('WhiteFed'), isFalse);
    });

    test('is a one-shot pass until new games arrive', () async {
      var calls = 0;
      Future<Map<int, LocalPlayerEnrichment>> counting(Set<int> ids) async {
        calls++;
        return _resolvable;
      }

      await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: counting,
      );
      expect(calls, 1);

      final again = await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: counting,
      );
      expect(again, 0);
      expect(calls, 1, reason: 'marker must short-circuit the second pass');

      // Re-persisting the file inserts game rows, which resets the marker.
      final source = await scanLocalChessPaths(<String>[pgnFile.path]);
      final node = source.nodeForPath(pgnFile.path);
      await repo.persistFileNode(
        node as LocalChessFileNode,
        sourceLabel: 'test',
      );
      await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: counting,
      );
      expect(calls, 2, reason: 'new inserts must re-arm the enrichment pass');
    });

    test('failed resolver leaves the pass retryable', () async {
      await expectLater(
        repo.enrichLocalDatabasePlayers(
          databasePath: pgnFile.path,
          resolve: (_) async => throw StateError('offline'),
        ),
        throwsStateError,
      );
      var calls = 0;
      await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: (ids) async {
          calls++;
          return _resolvable;
        },
      );
      expect(calls, 1, reason: 'marker must stay unset after a failure');
    });
  });

  group('local database search', () {
    Future<List<String>> search(String query) async {
      final page = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        search: query,
        pageNumber: 0,
        pageSize: 50,
      );
      return page!.games
          .map((game) => game.game.metadata['White'].toString())
          .toList();
    }

    test('multi-term queries AND across header fields', () async {
      expect(await search('carlsen 1-0'), ['Carlsen, Magnus']);
      expect(await search('magnus carlsen'), ['Carlsen, Magnus']);
      expect(await search('keymer bundesliga'), ['Keymer, Vincent']);
      expect(await search('carlsen bundesliga'), isEmpty);
      expect(await search('carlsen xyzzy'), isEmpty);
    });

    test('single-term search still matches any header value', () async {
      expect(await search('berlin'), ['Keymer, Vincent']);
      expect(await search('doe'), ['Smith, John']);
    });

    test('finds backfilled titles after enrichment', () async {
      expect(await search('GM'), isEmpty);
      await repo.enrichLocalDatabasePlayers(
        databasePath: pgnFile.path,
        resolve: (_) async => _resolvable,
      );
      expect(await search('gm carlsen'), ['Carlsen, Magnus']);
      expect(await search('nor carlsen'), ['Carlsen, Magnus']);
    });
  });
}
