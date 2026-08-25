import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('filters Blitz, Bullet, and Ultrabullet as distinct tree buckets', () {
    const blitz = PlayerOpeningTreeFilterCriteria(
      timeControl: TimeControl.blitz,
    );
    const bullet = PlayerOpeningTreeFilterCriteria(
      timeControl: TimeControl.bullet,
    );
    const ultrabullet = PlayerOpeningTreeFilterCriteria(
      timeControl: TimeControl.ultrabullet,
    );

    expect(blitz.matches(<String, dynamic>{'timeControl': 'blitz'}), isTrue);
    expect(blitz.matches(<String, dynamic>{'timeControl': 'bullet'}), isFalse);
    expect(
      blitz.matches(<String, dynamic>{'timeControl': 'ultrabullet'}),
      isFalse,
    );
    expect(bullet.matches(<String, dynamic>{'timeControl': 'bullet'}), isTrue);
    expect(bullet.matches(<String, dynamic>{'timeControl': 'blitz'}), isFalse);
    expect(
      ultrabullet.matches(<String, dynamic>{'timeControl': 'ultra-bullet'}),
      isTrue,
    );
    expect(
      ultrabullet.matches(<String, dynamic>{'timeControl': 'bullet'}),
      isFalse,
    );
    expect(blitz.matches(<String, dynamic>{'timeControl': 'rapid'}), isFalse);
  });

  test('opponent filter matches only the studied player head-to-head', () {
    const filters = PlayerOpeningTreeFilterCriteria(
      playerNames: <String>['Rosen, Eric'],
      opponentNames: <String>['Carlsen, Magnus'],
    );

    expect(
      filters.matches(<String, dynamic>{
        'white': 'Rosen, Eric',
        'black': 'Carlsen, Magnus',
      }),
      isTrue,
    );
    expect(
      filters.matches(<String, dynamic>{
        'white': 'Carlsen, Magnus',
        'black': 'Rosen, Eric',
      }),
      isTrue,
    );
    expect(
      filters.matches(<String, dynamic>{
        'white': 'Rosen, Eric',
        'black': 'Nakamura, Hikaru',
      }),
      isFalse,
    );
  });

  test('opponent AND-combines with every opening-tree filter axis', () {
    const filters = PlayerOpeningTreeFilterCriteria(
      playerNames: <String>['Rosen, Eric'],
      opponentNames: <String>['Carlsen, Magnus'],
      timeControl: TimeControl.rapid,
      minRating: 2500,
      maxRating: 2700,
      color: 'white',
      result: 'W',
      isOnline: true,
      yearFrom: 2024,
      yearTo: 2025,
    );
    final matching = <String, dynamic>{
      'white': 'Rosen, Eric',
      'black': 'Carlsen, Magnus',
      'whiteElo': 2600,
      'blackElo': 2800,
      'timeControl': 'rapid',
      'result': '1-0',
      'isOnline': true,
      'date': '2025-03-18',
    };

    expect(filters.matches(matching), isTrue);

    for (final mismatch in <Map<String, dynamic>>[
      <String, dynamic>{...matching, 'black': 'Nakamura, Hikaru'},
      <String, dynamic>{...matching, 'timeControl': 'blitz'},
      <String, dynamic>{...matching, 'whiteElo': 2400},
      <String, dynamic>{...matching, 'whiteElo': 2800},
      <String, dynamic>{
        ...matching,
        'white': 'Carlsen, Magnus',
        'black': 'Rosen, Eric',
      },
      <String, dynamic>{...matching, 'result': '0-1'},
      <String, dynamic>{...matching, 'isOnline': false},
      <String, dynamic>{...matching, 'date': '2023-03-18'},
      <String, dynamic>{...matching, 'date': '2026-03-18'},
    ]) {
      expect(filters.matches(mismatch), isFalse, reason: mismatch.toString());
    }
  });

  test('maps backend tree snapshot moves by FEN key', () {
    final index = PlayerOpeningTreeIndex.fromSnapshot(
      PlayerOpeningTreeSnapshot.fromJson(_snapshotJson()),
    );

    final moves = index.movesForFen(Chess.initial.fen);

    expect(index.positionCount, 1);
    expect(moves, hasLength(2));
    expect(moves.first.uci, 'd2d4');
    expect(moves.first.white, 8);
    expect(moves.first.black, 3);
    expect(moves.first.draws, 4);
    expect(moves.first.total, 15);
    expect(moves.first.gameId, isNull);
    expect(moves.first.lastPlayed, DateTime.parse('2026-05-21'));
  });

  test('falls back to old compact two-field snapshot keys', () {
    final snapshot = _snapshotJson();
    snapshot['fk'] = <String>[
      Chess.initial.fen.split(RegExp(r'\s+')).take(2).join(' '),
    ];
    final index = PlayerOpeningTreeIndex.fromSnapshot(
      PlayerOpeningTreeSnapshot.fromJson(snapshot),
    );

    final canonicalKey = playerOpeningTreeFenKey(Chess.initial.fen);
    final moves = index.movesForFen(Chess.initial.fen);

    expect(canonicalKey.split(' '), hasLength(4));
    expect(canonicalKey, endsWith('KQkq -'));
    expect(index.nodesByFenKey.keys.single.split(' '), hasLength(2));
    expect(moves, hasLength(2));
    expect(moves.first.uci, 'd2d4');
  });

  test('filters supported compact backend buckets locally', () {
    final index = PlayerOpeningTreeIndex.fromSnapshot(
      PlayerOpeningTreeSnapshot.fromJson(_snapshotJson()),
    );

    final moves = index.movesForFen(
      Chess.initial.fen,
      filters: const PlayerOpeningTreeFilterCriteria(
        playerId: 'player-uuid',
        color: 'white',
        timeControl: TimeControl.blitz,
        result: 'B',
        isOnline: true,
        yearFrom: 1800,
        yearTo: 1801,
        minRating: 3500,
      ),
    );

    expect(moves, hasLength(1));
    expect(moves.single.uci, 'e2e4');
    expect(moves.single.white, 3);
    expect(moves.single.black, 0);
    expect(moves.single.draws, 0);
    expect(moves.single.total, 3);
  });

  test('returns no moves for positions missing from backend snapshot', () {
    final index = PlayerOpeningTreeIndex.fromSnapshot(
      PlayerOpeningTreeSnapshot.fromJson(_snapshotJson()),
    );

    expect(index.movesForFen('8/8/8/8/8/8/8/8 w - - 0 1'), isEmpty);
  });

  test(
    'serves games for current position from downloaded games index',
    () async {
      final treeIndex = PlayerOpeningTreeIndex.fromSnapshot(
        PlayerOpeningTreeSnapshot.fromJson(_snapshotJson()),
      );
      final gamesIndex = await buildPlayerOpeningGamesIndexBatchAsync([
        {
          'id': 'game-1',
          'date': '2024-01-01',
          'result': '1-0',
          'whitePlayerId': 'player-uuid',
          'blackPlayerId': 'other',
          'white': 'White',
          'black': 'Black',
          'pgn': '''
[Event "Test"]
[Site "Local"]
[Date "2024.01.01"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 1-0
''',
        },
      ]);
      final index = treeIndex.copyWithGames(gamesIndex);

      final response = localPlayerTreeGamesResponse(
        index: index,
        fen: Chess.initial.fen,
        uci: 'e2e4',
        filters: const PlayerOpeningTreeFilterCriteria(playerId: 'player-uuid'),
        sortBy: GamebaseSortField.date,
        sortDirection: GamebaseSortDirection.desc,
        pageNumber: 0,
        pageSize: 10,
      );

      expect(response.metadata.totalCount, 1);
      expect(response.data.single['id'], 'game-1');
      expect(response.data.single['continuation'], ['e2e4', 'e7e5']);
    },
  );

  test('normalizes legacy tree rows for year and notation columns', () {
    final treeIndex = PlayerOpeningTreeIndex.fromSnapshot(
      PlayerOpeningTreeSnapshot.fromJson(_snapshotJson()),
    );
    final index = treeIndex.copyWithGames(
      PlayerOpeningTreeGamesIndex(
        gamesByFen: <String, List<PlayerOpeningTreeGameRef>>{
          playerOpeningTreeFenKey(Chess.initial.fen): const [
            PlayerOpeningTreeGameRef(
              gameId: 'legacy-game',
              fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
              ply: 0,
            ),
          ],
        },
        gameRowsById: const <String, Map<String, dynamic>>{
          'legacy-game': <String, dynamic>{
            'id': 'legacy-game',
            'white': 'Legacy White',
            'black': 'Legacy Black',
            'headers': <String, dynamic>{'Date': '2026.06.28'},
            'pgn': '''
[Event "Legacy cache"]
[Date "2026.06.28"]
[White "Legacy White"]
[Black "Legacy Black"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''',
          },
        },
      ),
    );

    final response = localPlayerTreeGamesResponse(
      index: index,
      fen: Chess.initial.fen,
      uci: null,
      sortBy: GamebaseSortField.date,
      sortDirection: GamebaseSortDirection.desc,
      pageNumber: 0,
      pageSize: 10,
    );

    expect(response.data.single['date'], '2026-06-28T00:00:00.000');
    expect(response.data.single['continuation'], [
      'e2e4',
      'e7e5',
      'g1f3',
      'b8c6',
    ]);
  });

  test('builds and merges local v1 tree batches', () async {
    final first = await buildPlayerOpeningTreeBatchAsync([
      {
        'id': 'local-1',
        'whitePlayerId': 'player-uuid',
        'blackPlayerId': 'other-1',
        'timeControl': 'blitz',
        'result': '1-0',
        'pgn': '''
[Event "Local one"]
[Date "2025.01.01"]
[White "Player"]
[Black "Other"]
[Result "1-0"]

1. e4 e5 1-0
''',
      },
    ]);
    final second = await buildPlayerOpeningTreeBatchAsync([
      {
        'id': 'local-2',
        'whitePlayerId': 'other-2',
        'blackPlayerId': 'player-uuid',
        'timeControl': 'rapid',
        'result': '0-1',
        'pgn': '''
[Event "Local two"]
[Date "2025.01.02"]
[White "Other"]
[Black "Player"]
[Result "0-1"]

1. d4 d5 0-1
''',
      },
    ]);

    final index = mergePlayerOpeningTreeIndexes(
      first,
      second,
    ).copyWithIdentity(treeId: 'local-v1:player-uuid', playerId: 'player-uuid');
    final moves = index.movesForFen(Chess.initial.fen);
    final whiteBlitzMoves = index.movesForFen(
      Chess.initial.fen,
      filters: const PlayerOpeningTreeFilterCriteria(
        playerId: 'player-uuid',
        color: 'white',
        timeControl: TimeControl.blitz,
      ),
    );

    expect(index.isUsable, isTrue);
    expect(index.downloadedGameCount, 2);
    expect(
      moves.map((move) => move.uci),
      containsAll(<String>['e2e4', 'd2d4']),
    );
    expect(whiteBlitzMoves, hasLength(1));
    expect(whiteBlitzMoves.single.uci, 'e2e4');
    expect(whiteBlitzMoves.single.white, 1);
  });

  test(
    'prep side includes every configured source name for one player',
    () async {
      final index = await buildPlayerOpeningTreeBatchAsync([
        {
          'id': 'chesscom-hikaru-black',
          'result': '0-1',
          'pgn': '''
[Event "Chess.com"]
[White "Opponent"]
[Black "Hikaru"]
[Result "0-1"]

1. e4 c5 0-1
''',
        },
        {
          'id': 'chessever-hikaru-black',
          'result': '1-0',
          'pgn': '''
[Event "ChessEver"]
[White "Opponent"]
[Black "Hikaru Nakamura"]
[Result "1-0"]

1. d4 d5 1-0
''',
        },
      ]);

      final blackPrepMoves = index.movesForFen(
        Chess.initial.fen,
        filters: const PlayerOpeningTreeFilterCriteria(
          playerNames: ['Hikaru', 'Hikaru Nakamura'],
          color: 'black',
        ),
      );

      expect(
        blackPrepMoves.map((move) => move.uci),
        containsAll(<String>['e2e4', 'd2d4']),
      );
      expect(blackPrepMoves.every((move) => move.total == 1), isTrue);
    },
  );
}

Map<String, dynamic> _snapshotJson() {
  return {
    'tid': 'v4:player-uuid:24',
    'pid': 'player-uuid',
    'mp': 24,
    'r': 0,
    'bd': ['color', 'timeControl', 'isOnline'],
    'g': '2026-06-12T00:00:00.000Z',
    'fk': ['rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -'],
    'n': [
      {
        'id': 0,
        'f': 0,
        'p': 0,
        'm': [
          {
            'u': 'e2e4',
            'c': 1,
            'w': 6,
            'b': 2,
            'd': 2,
            't': 10,
            'lp': '2026-05-20',
            'fb': [
              ['w', 'b', 1, 2, 2, 0, 0],
              ['w', 'b', 1, 1, 1, 0, 0],
              ['b', 'r', 0, 2, 0, 2, 0],
            ],
          },
          {
            'u': 'd2d4',
            'c': 2,
            'w': 8,
            'b': 3,
            'd': 4,
            't': 15,
            'lp': '2026-05-21',
            'fb': [
              ['w', 'c', 0, 4, 0, 0, 4],
            ],
          },
        ],
      },
    ],
  };
}
