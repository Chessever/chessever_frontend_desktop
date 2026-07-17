import 'dart:io';

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/compact_local_tree_index.dart';
import 'package:chessever/desktop/services/local_opening_tree_builder.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever-ceti-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('compact index finds games that transpose into the same position', () {
    final indexPath = '${temp.path}/transpositions.pgn.ceti';
    final builder = CompactLocalTreeIndexBuilder(
      targetPath: indexPath,
      maxPly: 50,
    );
    builder.addGame(
      _input(
        index: 0,
        moves: const <String>[
          'g1f3',
          'd7d5',
          'g2g3',
          'g8f6',
          'f1g2',
        ],
      ),
    );
    builder.addGame(
      _input(
        index: 1,
        moves: const <String>[
          'g2g3',
          'd7d5',
          'g1f3',
          'g8f6',
          'f1g2',
        ],
      ),
    );
    final result = builder.finish();

    final transposed = _positionAfter(const <String>[
      'g1f3',
      'd7d5',
      'g2g3',
      'g8f6',
    ]);
    final matches = readCompactLocalTreePositionMatchesSync(
      indexPath: indexPath,
      fen: transposed.fen,
    );

    expect(result.metadata.gameCount, 2);
    expect(matches.map((match) => match.indexInFile), <int>[0, 1]);
    expect(matches.map((match) => match.nextUci), everyElement('f1g2'));
  });

  test('compact index publishes the boundary position without another move', () {
    final indexPath = '${temp.path}/boundary.pgn.ceti';
    final builder = CompactLocalTreeIndexBuilder(
      targetPath: indexPath,
      maxPly: 4,
    );
    const line = <String>['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5'];
    builder.addGame(_input(index: 0, moves: line));
    builder.finish();

    final boundaryMatches = readCompactLocalTreePositionMatchesSync(
      indexPath: indexPath,
      fen: _positionAfter(line.take(4)).fen,
    );
    final beyondBoundaryMatches = readCompactLocalTreePositionMatchesSync(
      indexPath: indexPath,
      fen: _positionAfter(line).fen,
    );

    expect(boundaryMatches, hasLength(1));
    expect(boundaryMatches.single.ply, 4);
    expect(boundaryMatches.single.nextUci, isNull);
    expect(beyondBoundaryMatches, isEmpty);
    expect(localOpeningTreeDefaultMaxPly, 50);
  });
}

LocalOpeningTreeGameInput _input({
  required int index,
  required List<String> moves,
}) {
  return LocalOpeningTreeGameInput(
    id: 'game-$index',
    uciLine: moves,
    metadata: const <String, String>{
      'Result': '1-0',
      'Date': '2026.07.16',
    },
    sourcePath: 'test.pgn',
    sourceRelativePath: 'test.pgn',
    fileName: 'test.pgn',
    indexInFile: index,
    fileGameCount: 2,
  );
}

Position _positionAfter(Iterable<String> moves) {
  Position position = Chess.initial;
  for (final uci in moves) {
    position = position.play(NormalMove.fromUci(uci));
  }
  return position;
}
