import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _row({
  required String id,
  required String pgn,
  required String result,
  required String date,
  String? whitePlayerId,
  String? blackPlayerId,
  int? whiteElo,
  int? blackElo,
  String? timeControl,
  bool? isOnline,
}) {
  return <String, dynamic>{
    'id': id,
    'pgn': pgn,
    'result': result,
    'date': date,
    if (whitePlayerId != null) 'whitePlayerId': whitePlayerId,
    if (blackPlayerId != null) 'blackPlayerId': blackPlayerId,
    if (whiteElo != null) 'whiteElo': whiteElo,
    if (blackElo != null) 'blackElo': blackElo,
    if (timeControl != null) 'timeControl': timeControl,
    if (isOnline != null) 'isOnline': isOnline,
    'white': 'White $id',
    'black': 'Black $id',
    'event': 'Event $id',
  };
}

String _pgn({
  required String white,
  required String black,
  required String date,
  required String result,
  required String moves,
}) {
  return '''
[Event "Test"]
[Site "Local"]
[Date "$date"]
[White "$white"]
[Black "$black"]
[Result "$result"]

$moves $result
''';
}

Position _positionAfter(List<String> ucis) {
  Position position = Chess.initial;
  for (final uci in ucis) {
    final move = NormalMove.fromUci(uci);
    expect(position.isLegal(move), isTrue, reason: '$uci from ${position.fen}');
    position = position.play(move);
  }
  return position;
}

void main() {
  test('aggregates shared moves with WDL counts and latest date', () async {
    final index = await buildPlayerOpeningTreeBatchAsync([
      _row(
        id: 'g1',
        date: '2024-01-01',
        result: '1-0',
        pgn: _pgn(
          white: 'A',
          black: 'B',
          date: '2024.01.01',
          result: '1-0',
          moves: '1. e4 e5 2. Nf3',
        ),
      ),
      _row(
        id: 'g2',
        date: '2025-02-03',
        result: '0-1',
        pgn: _pgn(
          white: 'C',
          black: 'D',
          date: '2025.02.03',
          result: '0-1',
          moves: '1. e4 c5',
        ),
      ),
    ]);

    final moves = index.movesForFen(Chess.initial.fen);
    expect(moves, hasLength(1));
    expect(moves.single.uci, 'e2e4');
    expect(moves.single.white, 1);
    expect(moves.single.black, 1);
    expect(moves.single.draws, 0);
    expect(moves.single.total, 2);
    expect(moves.single.lastPlayed, DateTime(2025, 2, 3));
  });

  test('indexes games by transposed FEN, independent of move order', () async {
    final index = await buildPlayerOpeningTreeBatchAsync([
      _row(
        id: 'nf3-first',
        date: '2024-01-01',
        result: '1/2-1/2',
        pgn: _pgn(
          white: 'A',
          black: 'B',
          date: '2024.01.01',
          result: '1/2-1/2',
          moves: '1. Nf3 Nf6 2. d4 d5',
        ),
      ),
      _row(
        id: 'd4-first',
        date: '2024-01-02',
        result: '1-0',
        pgn: _pgn(
          white: 'C',
          black: 'D',
          date: '2024.01.02',
          result: '1-0',
          moves: '1. d4 d5 2. Nf3 Nf6',
        ),
      ),
    ]);

    final transposed = _positionAfter(['g1f3', 'g8f6', 'd2d4', 'd7d5']);
    final games = index.gamesForFen(
      transposed.fen,
      sortBy: GamebaseSortField.date,
      sortDirection: GamebaseSortDirection.asc,
      pageNumber: 0,
      pageSize: 10,
    );

    expect(games.map((row) => row['id']), ['nf3-first', 'd4-first']);
    expect(index.gamesCountForFen(transposed.fen), 2);
  });

  test(
    'filters local move aggregates from indexed transposition rows',
    () async {
      final index = await buildPlayerOpeningTreeBatchAsync([
        _row(
          id: 'rapid-white',
          date: '2024-01-01',
          result: '1-0',
          whitePlayerId: 'player-1',
          blackPlayerId: 'other-1',
          whiteElo: 2600,
          blackElo: 2500,
          timeControl: 'RAPID',
          isOnline: true,
          pgn: _pgn(
            white: 'A',
            black: 'B',
            date: '2024.01.01',
            result: '1-0',
            moves: '1. e4 e5',
          ),
        ),
        _row(
          id: 'blitz-black',
          date: '2024-01-02',
          result: '0-1',
          whitePlayerId: 'other-2',
          blackPlayerId: 'player-1',
          whiteElo: 2550,
          blackElo: 2650,
          timeControl: 'BLITZ',
          isOnline: false,
          pgn: _pgn(
            white: 'C',
            black: 'D',
            date: '2024.01.02',
            result: '0-1',
            moves: '1. d4 d5',
          ),
        ),
      ]);

      final rapidWhiteMoves = index.movesForFen(
        Chess.initial.fen,
        filters: const PlayerOpeningTreeFilterCriteria(
          playerId: 'player-1',
          color: 'white',
          timeControl: TimeControl.rapid,
          isOnline: true,
          minRating: 2500,
        ),
      );

      expect(rapidWhiteMoves, hasLength(1));
      expect(rapidWhiteMoves.single.uci, 'e2e4');
      expect(rapidWhiteMoves.single.white, 1);
    },
  );

  test('filters local transposition games before pagination', () async {
    final index = await buildPlayerOpeningTreeBatchAsync([
      _row(
        id: 'nf3-rapid',
        date: '2024-01-01',
        result: '1/2-1/2',
        whitePlayerId: 'player-1',
        blackPlayerId: 'other-1',
        whiteElo: 2600,
        blackElo: 2500,
        timeControl: 'RAPID',
        pgn: _pgn(
          white: 'A',
          black: 'B',
          date: '2024.01.01',
          result: '1/2-1/2',
          moves: '1. Nf3 Nf6 2. d4 d5',
        ),
      ),
      _row(
        id: 'd4-blitz',
        date: '2024-01-02',
        result: '1-0',
        whitePlayerId: 'player-1',
        blackPlayerId: 'other-2',
        whiteElo: 2600,
        blackElo: 2500,
        timeControl: 'BLITZ',
        pgn: _pgn(
          white: 'C',
          black: 'D',
          date: '2024.01.02',
          result: '1-0',
          moves: '1. d4 d5 2. Nf3 Nf6',
        ),
      ),
    ]);

    final transposed = _positionAfter(['g1f3', 'g8f6', 'd2d4', 'd7d5']);
    final response = localPlayerTreeGamesResponse(
      index: index,
      fen: transposed.fen,
      uci: null,
      filters: const PlayerOpeningTreeFilterCriteria(
        playerId: 'player-1',
        timeControl: TimeControl.rapid,
      ),
      sortBy: GamebaseSortField.date,
      sortDirection: GamebaseSortDirection.asc,
      pageNumber: 0,
      pageSize: 10,
    );

    expect(response.metadata.totalCount, 1);
    expect(response.data.single['id'], 'nf3-rapid');
  });

  test(
    'skips invalid or move-less PGNs without dropping valid games',
    () async {
      final index = await buildPlayerOpeningTreeBatchAsync([
        _row(id: 'bad', date: '2024-01-01', result: '*', pgn: 'not a pgn'),
        _row(
          id: 'headers-only',
          date: '2024-01-01',
          result: '*',
          pgn: '[Event "Headers"]\n[Result "*"]\n\n*',
        ),
        _row(
          id: 'good',
          date: '2024-01-02',
          result: '1-0',
          pgn: _pgn(
            white: 'A',
            black: 'B',
            date: '2024.01.02',
            result: '1-0',
            moves: '1. e4',
          ),
        ),
      ]);

      expect(index.movesForFen(Chess.initial.fen), hasLength(1));
      expect(index.gamesCountForFen(Chess.initial.fen), 1);
    },
  );

  test(
    'merged partial indexes remain queryable while later batches arrive',
    () async {
      final first = await buildPlayerOpeningTreeBatchAsync([
        _row(
          id: 'first',
          date: '2024-01-01',
          result: '1-0',
          pgn: _pgn(
            white: 'A',
            black: 'B',
            date: '2024.01.01',
            result: '1-0',
            moves: '1. e4',
          ),
        ),
      ]);
      expect(first.movesForFen(Chess.initial.fen).single.total, 1);

      final second = await buildPlayerOpeningTreeBatchAsync([
        _row(
          id: 'second',
          date: '2024-01-02',
          result: '0-1',
          pgn: _pgn(
            white: 'C',
            black: 'D',
            date: '2024.01.02',
            result: '0-1',
            moves: '1. e4',
          ),
        ),
      ]);

      final merged = mergePlayerOpeningTreeIndexes(first, second);
      expect(merged.movesForFen(Chess.initial.fen).single.total, 2);
    },
  );
}
