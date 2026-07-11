import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/utils/pgn_multi_parser.dart';

const _fullTagPgn = '''
[Event "FIDE World Championship 2024"]
[Site "Singapore SGP"]
[Date "2024.11.25"]
[Round "1.1"]
[White "Ding, Liren"]
[Black "Gukesh, D"]
[Result "1/2-1/2"]
[WhiteElo "2728"]
[BlackElo "2783"]
[WhiteTitle "GM"]
[BlackTitle "GM"]
[WhiteFideId "8603677"]
[BlackFideId "46616543"]
[ECO "C42"]
[Opening "Russian Game"]
[Variation "Nimzowitsch Attack"]
[WhiteTeam "China"]
[BlackTeam "India"]
[WhiteFed "CHN"]
[BlackFed "IND"]
[EventDate "2024.11.25"]
[EventType "match"]
[Annotator "Test Annotator"]
[PlyCount "6"]
[TimeControl "40/7200:20/3600:900+30"]
[SourceTitle "Mega Database"]
[UTCDate "2024.11.25"]
[UTCTime "09:00:00"]

1. e4 e5 2. Nf3 Nf6 3. Nxe5 d6 1/2-1/2
''';

const _expectedTags = <String, String>{
  'Event': 'FIDE World Championship 2024',
  'Site': 'Singapore SGP',
  'Date': '2024.11.25',
  'Round': '1.1',
  'White': 'Ding, Liren',
  'Black': 'Gukesh, D',
  'Result': '1/2-1/2',
  'WhiteElo': '2728',
  'BlackElo': '2783',
  'WhiteTitle': 'GM',
  'BlackTitle': 'GM',
  'WhiteFideId': '8603677',
  'BlackFideId': '46616543',
  'ECO': 'C42',
  'Opening': 'Russian Game',
  'Variation': 'Nimzowitsch Attack',
  'WhiteTeam': 'China',
  'BlackTeam': 'India',
  'WhiteFed': 'CHN',
  'BlackFed': 'IND',
  'EventDate': '2024.11.25',
  'EventType': 'match',
  'Annotator': 'Test Annotator',
  'PlyCount': '6',
  'TimeControl': '40/7200:20/3600:900+30',
  'SourceTitle': 'Mega Database',
  'UTCDate': '2024.11.25',
  'UTCTime': '09:00:00',
};

const _lichessSpeedPgn = '''
[Event "Hourly UltraBullet Arena"]
[Site "https://lichess.org/ultra123"]
[Date "2025.09.13"]
[White "Fast One"]
[Black "Fast Two"]
[Result "1-0"]
[TimeControl "15+0"]

1. e4 e5 2. Nf3 Nc6 1-0

[Event "rated rapid game"]
[Site "https://lichess.org/rapid123"]
[Date "2025.09.14"]
[White "Fast Two"]
[Black "Fast One"]
[Result "0-1"]
[TimeControl "300+5"]

1. d4 d5 2. c4 e6 0-1
''';

const _chessComSpeedPgn = '''
[Event "Live Chess"]
[Site "Chess.com"]
[Date "2025.09.13"]
[Round "1"]
[White "Fast One"]
[Black "Fast Two"]
[Result "1-0"]
[TimeControl "30"]

1. e4 e5 2. Nf3 Nc6 1-0

[Event "Live Chess"]
[Site "Chess.com"]
[Date "2025.09.14"]
[Round "2"]
[White "Fast Two"]
[Black "Fast One"]
[Result "0-1"]
[TimeControl "60"]

1. d4 d5 2. c4 e6 0-1

[Event "Live Chess"]
[Site "Chess.com"]
[Date "2025.09.15"]
[Round "3"]
[White "Fast One"]
[Black "Fast Two"]
[Result "1-0"]
[TimeControl "180"]

1. c4 e5 2. Nc3 Nf6 1-0

[Event "Live Chess"]
[Site "Chess.com"]
[Date "2025.09.16"]
[Round "4"]
[White "Fast Two"]
[Black "Fast One"]
[Result "0-1"]
[TimeControl "600"]

1. Nf3 d5 2. g3 c5 0-1
''';

void _expectAllTags(Map<String, dynamic> metadata, String label) {
  final missing = <String>[];
  final wrong = <String>[];
  for (final entry in _expectedTags.entries) {
    final value = metadata[entry.key]?.toString();
    if (value == null) {
      missing.add(entry.key);
    } else if (value != entry.value) {
      wrong.add('${entry.key}: "$value" != "${entry.value}"');
    }
  }
  expect(
    missing,
    isEmpty,
    reason: '$label dropped tags: $missing (kept: ${metadata.keys.toList()})',
  );
  expect(wrong, isEmpty, reason: '$label mangled tags: $wrong');
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever_meta_repro_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<LocalChessGame> scanSingle(String name, List<int> bytes) async {
    final file = File('${temp.path}/$name');
    await file.writeAsBytes(bytes);
    final source = await scanLocalChessPaths(<String>[file.path]);
    final games = source.games;
    expect(games, hasLength(1), reason: 'expected 1 game in $name');
    return games.single;
  }

  group('local PGN import metadata fidelity', () {
    test('scanner keeps every header tag (LF)', () async {
      final game = await scanSingle('lf.pgn', utf8.encode(_fullTagPgn));
      _expectAllTags(game.game.metadata, 'scanner LF');
    });

    test('scanner keeps every header tag (CRLF)', () async {
      final crlf = _fullTagPgn.replaceAll('\n', '\r\n');
      final game = await scanSingle('crlf.pgn', utf8.encode(crlf));
      _expectAllTags(game.game.metadata, 'scanner CRLF');
    });

    test('scanner keeps every header tag (BOM)', () async {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(_fullTagPgn)];
      final game = await scanSingle('bom.pgn', bytes);
      _expectAllTags(game.game.metadata, 'scanner BOM');
    });

    test('multi-parser keeps every header tag', () {
      final entries = parsePgnsToChessGames(_fullTagPgn);
      expect(entries, hasLength(1));
      _expectAllTags(entries.single.chessGame.metadata, 'multi-parser');
    });

    test('repository import + page query keep every header tag', () async {
      final db = await resqlite.Database.open('${temp.path}/local_chess.db');
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      await createLocalChessResqliteDatabaseSchema(db);

      final pgnFile = File('${temp.path}/full_tags.pgn');
      await pgnFile.writeAsString(_fullTagPgn);
      final repo = LocalChessDatabaseRepository(database: () async => db);
      final source = await repo.importSingleFileSource(path: pgnFile.path);
      expect(source, isNotNull);

      final stored =
          (await db.select(
            'SELECT headers_json FROM local_chess_games WHERE database_id = ?',
            <Object?>[pgnFile.path],
          )).single;
      _expectAllTags(
        jsonDecode(stored['headers_json'] as String) as Map<String, dynamic>,
        'headers_json',
      );

      final page = await repo.localDatabaseGamesPage(
        databasePath: pgnFile.path,
        pageNumber: 0,
        pageSize: 10,
      );
      expect(page, isNotNull);
      expect(page!.games, hasLength(1));
      _expectAllTags(page.games.single.game.metadata, 'games page');
    });

    test('repository persists Lichess source-specific speed buckets', () async {
      final db = await resqlite.Database.open('${temp.path}/lichess.db');
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      await createLocalChessResqliteDatabaseSchema(db);

      final pgnFile = File('${temp.path}/lichess-speeds.pgn');
      await pgnFile.writeAsString(_lichessSpeedPgn);
      final repo = LocalChessDatabaseRepository(database: () async => db);
      final source = await repo.importSingleFileSource(path: pgnFile.path);
      expect(source, isNotNull);

      final rows = await db.select(
        '''
        SELECT time_control, time_control_category
        FROM local_chess_games
        WHERE database_id = ?
        ''',
        <Object?>[pgnFile.path],
      );
      expect(
        <String, String>{
          for (final row in rows)
            row['time_control']! as String:
                row['time_control_category']! as String,
        },
        <String, String>{'15+0': 'ultrabullet', '300+5': 'rapid'},
      );
    });

    test(
      'repository persists Chess.com Bullet and UltraBullet buckets',
      () async {
        final db = await resqlite.Database.open('${temp.path}/chesscom.db');
        addTearDown(db.close);
        await db.execute('PRAGMA foreign_keys=ON');
        await createLocalChessResqliteDatabaseSchema(db);

        final pgnFile = File('${temp.path}/chesscom-speeds.pgn');
        await pgnFile.writeAsString(_chessComSpeedPgn);
        final repo = LocalChessDatabaseRepository(database: () async => db);
        final source = await repo.importSingleFileSource(path: pgnFile.path);
        expect(source, isNotNull);

        final rows = await db.select(
          '''
          SELECT time_control, time_control_category
          FROM local_chess_games
          WHERE database_id = ?
          ''',
          <Object?>[pgnFile.path],
        );
        expect(
          <String, String>{
            for (final row in rows)
              row['time_control']! as String:
                  row['time_control_category']! as String,
          },
          <String, String>{
            '30': 'ultrabullet',
            '60': 'bullet',
            '180': 'blitz',
            '600': 'rapid',
          },
        );
      },
    );
  });
}
