import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps Bullet and UltraBullet inside the legacy Blitz tree bucket', () {
    const blitz = PlayerOpeningTreeFilterCriteria(
      timeControl: TimeControl.blitz,
    );

    expect(blitz.matches(<String, dynamic>{'timeControl': 'blitz'}), isTrue);
    expect(blitz.matches(<String, dynamic>{'timeControl': 'bullet'}), isTrue);
    expect(
      blitz.matches(<String, dynamic>{'timeControl': 'ultrabullet'}),
      isTrue,
    );
    expect(blitz.matches(<String, dynamic>{'timeControl': 'rapid'}), isFalse);
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
