import 'dart:io';

import 'package:dartchess/dartchess.dart' show Chess;
import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/services/player_identity_name.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';

const _filters = PlayerOpeningTreeFilterCriteria(
  playerFideIds: ['99999901'],
  playerNames: ['Elise Moreau'],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
  });

  test(
    'SQL tree move counts and position games retain all six source games',
    () async {
      final counts = await _sqlCounts(_fixture());
      expect(counts.moves, 6);
      expect(counts.games, 6);
    },
  );

  test('SQL FIDE match reads the FideID header spelling too', () async {
    final counts = await _sqlCounts('''
[Event "Alternate FIDE tag"]
[White "Moreau, Elise"]
[Black "Other Player"]
[WhiteFideID "99999901"]
[Result "1-0"]

1. e4 e5 1-0
''');
    expect(counts.moves, 1);
    expect(counts.games, 1);
  });

  test(
    'SQL and Dart keys agree on explicit name conventions and whitespace',
    () async {
      final dir = await Directory.systemTemp.createTemp('player-name-parity-');
      final db = await resqlite.Database.open('${dir.path}/names.db');
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      for (final value in <String?>[
        null,
        '',
        '?',
        ' \t? \n',
        '\u00a0?\u00a0',
        '?,',
        'Elise Moreau',
        'Moreau, Elise',
        ' MOREAU , ELISE ',
        'Moreau,\tElise',
        'Elise\nMoreau',
        'Moreau,\u000bElise',
        'Moreau,\u000cElise',
        'Moreau,\u00a0Elise',
        'Moreau,',
        ',Elise',
        'Moreau, Elise, Junior',
        'Moreau Elise',
        'Elise_Moreau',
        'Elise.Moreau',
        'Elise-Moreau',
      ]) {
        final rows = await db.select(
          'SELECT ${playerIdentityNameSql('name_value')} AS name_key '
          'FROM (SELECT ? AS name_value)',
          [value],
        );
        expect(
          rows.single['name_key'],
          playerIdentityNameKey(value),
          reason: '$value',
        );
      }
      expect(
        playerIdentityNameKey('Moreau Elise'),
        isNot(playerIdentityNameKey('Elise Moreau')),
      );
    },
  );

  test('tree name fallback never overrides a conflicting positive FIDE ID', () {
    expect(
      _filters.matches({
        'white': 'Moreau, Elise',
        'black': 'Other Player',
        'whiteFideId': '88887777',
      }),
      isFalse,
    );
  });
}

Future<({int moves, int games})> _sqlCounts(String pgn) async {
  final dir = await Directory.systemTemp.createTemp('player-source-sql-');
  final db = await resqlite.Database.open('${dir.path}/isolated.db');
  addTearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  await createLocalChessResqliteDatabaseSchema(db);
  final file = File('${dir.path}/unique-source.pgn');
  await file.writeAsString(pgn);
  final source = await scanLocalChessPaths([file.path]);
  final repo = LocalChessDatabaseRepository(database: () async => db);
  await repo.persistFileNode(
    source.root.singlePlayableDatabaseInSubtree!,
    sourceLabel: 'Player source',
  );
  final moves = await repo.localMoveAggregatesForFen(
    databasePath: file.path,
    fen: Chess.initial.fen,
    filters: _filters,
  );
  final games = await repo.localPositionGamesResponse(
    databasePath: file.path,
    fen: Chess.initial.fen,
    filters: _filters,
    sortBy: GamebaseSortField.date,
    sortDirection: GamebaseSortDirection.desc,
    pageNumber: 0,
    pageSize: 20,
  );
  expect(games?.data, hasLength(games?.metadata.totalCount ?? -1));
  return (
    moves: moves.fold<int>(0, (sum, move) => sum + move.total),
    games: games?.metadata.totalCount ?? 0,
  );
}

// Six intended games plus a same-name, different-FIDE-ID control row.
String _fixture() => [
  for (var i = 0; i < 7; i++)
    '''
[Event "Player source identity"]
[Date "2026.08.${(i + 1).toString().padLeft(2, '0')}"]
[White "${i == 3
        ? 'Other Player'
        : i < 2
        ? 'Moreau,Elise'
        : 'Moreau, Elise'}"]
[Black "${i == 3 ? 'Moreau, Elise' : 'Other Player'}"]
${i < 2
        ? '[WhiteFideId "99999901"]'
        : i == 6
        ? '[WhiteFideId "88887777"]'
        : ''}
[Result "${i < 2 || i == 3 ? '0-1' : '1/2-1/2'}"]

1. d4 d5 ${i < 2 || i == 3 ? '0-1' : '1/2-1/2'}
''',
].join('\n');
