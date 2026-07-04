import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

// Guards the local database mini-preview search (the surface shown when a
// user single-clicks an imported PGN in My Databases). The full workspace
// table has its own SQL search; this covers the in-memory fallback the
// preview uses for folder-subtree games, with the same multi-term semantics.
const _pgn = '''
[Event "Speed Chess Championship"]
[Site "chess.com"]
[White "Carlsen, Magnus"]
[Black "Le, Tuan Minh"]
[Result "1-0"]
[ECO "C42"]

1. e4 e5 1-0

[Event "Bundesliga"]
[Site "Berlin GER"]
[White "Keymer, Vincent"]
[Black "Bluebaum, Matthias"]
[Result "1/2-1/2"]
[ECO "D37"]

1. d4 d5 1/2-1/2
''';

void main() {
  late Directory temp;
  late List<LocalChessGame> games;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chessever_mini_search_');
    final file = File('${temp.path}/games.pgn');
    await file.writeAsString(_pgn);
    final source = await scanLocalChessPaths(<String>[file.path]);
    games = source.games;
    expect(games, hasLength(2));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  List<String> whiteNames(List<LocalChessGame> list) => list
      .map((game) => game.game.metadata['White'].toString())
      .toList(growable: false);

  test('empty query returns every game', () {
    expect(debugFilterLocalMiniPreviewGames(games, ''), games);
    expect(debugFilterLocalMiniPreviewGames(games, '   '), games);
  });

  test('single term matches any header value', () {
    expect(
      whiteNames(debugFilterLocalMiniPreviewGames(games, 'berlin')),
      ['Keymer, Vincent'],
    );
    expect(
      whiteNames(debugFilterLocalMiniPreviewGames(games, 'carlsen')),
      ['Carlsen, Magnus'],
    );
  });

  test('every whitespace term must match (AND)', () {
    expect(
      whiteNames(debugFilterLocalMiniPreviewGames(games, 'magnus carlsen')),
      ['Carlsen, Magnus'],
    );
    expect(
      whiteNames(debugFilterLocalMiniPreviewGames(games, 'keymer bundesliga')),
      ['Keymer, Vincent'],
    );
    expect(debugFilterLocalMiniPreviewGames(games, 'carlsen bundesliga'), isEmpty);
    expect(debugFilterLocalMiniPreviewGames(games, 'carlsen zzz'), isEmpty);
  });

  test('matches ECO and result tags too', () {
    expect(
      whiteNames(debugFilterLocalMiniPreviewGames(games, 'c42')),
      ['Carlsen, Magnus'],
    );
    expect(
      whiteNames(debugFilterLocalMiniPreviewGames(games, '1/2-1/2')),
      ['Keymer, Vincent'],
    );
  });
}
