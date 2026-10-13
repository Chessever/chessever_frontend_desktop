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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
  });

  test(
    'SQL tree move counts and position games retain all six source games',
    () async {
      final dir = await Directory.systemTemp.createTemp('player-six-sql-');
      final db = await resqlite.Database.open('${dir.path}/isolated.db');
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      await createLocalChessResqliteDatabaseSchema(db);
      final file = File('${dir.path}/unique-source.pgn');
      await file.writeAsString(_fixture());
      final source = await scanLocalChessPaths([file.path]);
      final repo = LocalChessDatabaseRepository(database: () async => db);
      await repo.persistFileNode(
        source.root.singlePlayableDatabaseInSubtree!,
        sourceLabel: 'Player source',
      );
      const filters = PlayerOpeningTreeFilterCriteria(
        playerFideIds: ['39935140'],
        playerNames: ['Aarav Karthik'],
      );
      final moves = await repo.localMoveAggregatesForFen(
        databasePath: file.path,
        fen: Chess.initial.fen,
        filters: filters,
      );
      expect(moves.fold<int>(0, (sum, move) => sum + move.total), 6);
      final games = await repo.localPositionGamesResponse(
        databasePath: file.path,
        fen: Chess.initial.fen,
        filters: filters,
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.desc,
        pageNumber: 0,
        pageSize: 20,
      );
      expect(games?.metadata.totalCount, 6);
      expect(games?.data, hasLength(6));
    },
  );

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
        'Aarav Karthik',
        'Karthik, Aarav',
        ' KARTHIK , AARAV ',
        'Karthik,\tAarav',
        'Aarav\nKarthik',
        'Karthik,\u000bAarav',
        'Karthik,\u000cAarav',
        'Karthik,',
        ',Aarav',
        'Karthik, Aarav, Junior',
        'Karthik Aarav',
        'Aarav_Karthik',
        'Aarav.Karthik',
        'Aarav-Karthik',
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
        playerIdentityNameKey('Karthik Aarav'),
        isNot(playerIdentityNameKey('Aarav Karthik')),
      );
    },
  );

  test('tree name fallback never overrides a conflicting positive FIDE ID', () {
    const filters = PlayerOpeningTreeFilterCriteria(
      playerFideIds: ['39935140'],
      playerNames: ['Aarav Karthik'],
    );
    expect(
      filters.matches({
        'white': 'Karthik, Aarav',
        'black': 'Other Player',
        'whiteFideId': '88887777',
      }),
      isFalse,
    );
  });
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
        ? 'Karthik,Aarav'
        : 'Karthik, Aarav'}"]
[Black "${i == 3 ? 'Karthik, Aarav' : 'Other Player'}"]
${i < 2
        ? '[WhiteFideId "39935140"]'
        : i == 6
        ? '[WhiteFideId "88887777"]'
        : ''}
[Result "${i < 2 || i == 3 ? '0-1' : '1/2-1/2'}"]

1. d4 d5 ${i < 2 || i == 3 ? '0-1' : '1/2-1/2'}
''',
].join('\n');
