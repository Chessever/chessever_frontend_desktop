import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(moves.first.gameId, 'sample-d4');
    expect(moves.first.lastPlayed, DateTime.parse('2026-05-21T00:00:00.000Z'));
  });

  test('filters backend buckets locally', () {
    final index = PlayerOpeningTreeIndex.fromSnapshot(
      PlayerOpeningTreeSnapshot.fromJson(_snapshotJson()),
    );

    final moves = index.movesForFen(
      Chess.initial.fen,
      filters: const PlayerOpeningTreeFilterCriteria(
        playerId: 'player-uuid',
        color: 'white',
        timeControl: TimeControl.blitz,
        result: 'W',
        isOnline: true,
        yearFrom: 2025,
        yearTo: 2026,
        minRating: 2500,
        maxRating: 2899,
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
}

Map<String, dynamic> _snapshotJson() {
  return {
    'treeId': 'v2:player-uuid:40',
    'playerId': 'player-uuid',
    'maxPly': 40,
    'rootNodeId': 0,
    'generatedAt': '2026-06-12T00:00:00.000Z',
    'nodes': [
      {
        'id': 0,
        'fenKey': 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -',
        'ply': 0,
        'moves': [
          {
            'uci': 'e2e4',
            'childNodeId': 1,
            'white': 6,
            'black': 2,
            'draws': 2,
            'total': 10,
            'lastPlayed': '2026-05-20T00:00:00.000Z',
            'sampleGameId': 'sample-e4',
            'filterBuckets': {
              'color=white|timeControl=BLITZ|isOnline=true|result=W|year=2025|rating=2800':
                  {'white': 2, 'black': 0, 'draws': 0, 'total': 2},
              'color=white|timeControl=BLITZ|isOnline=true|result=W|year=2026|rating=2500':
                  {'white': 1, 'black': 0, 'draws': 0, 'total': 1},
              'color=black|timeControl=RAPID|isOnline=false|result=B|year=2025|rating=2400':
                  {'white': 0, 'black': 2, 'draws': 0, 'total': 2},
            },
          },
          {
            'uci': 'd2d4',
            'childNodeId': 2,
            'white': 8,
            'black': 3,
            'draws': 4,
            'total': 15,
            'lastPlayed': '2026-05-21T00:00:00.000Z',
            'sampleGameId': 'sample-d4',
            'filterBuckets': {
              'color=white|timeControl=CLASSICAL|isOnline=false|result=D|year=2024|rating=2600':
                  {'white': 0, 'black': 0, 'draws': 4, 'total': 4},
            },
          },
        ],
      },
    ],
  };
}
