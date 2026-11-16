import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/knockout/match_play.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/match_play_color_mark.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_grouped_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_tournament_state_provider.dart';
import 'package:chessever/utils/date_time_provider.dart';

import 'support/current_broadcast_games.dart';
import 'support/real_tab_fixture.dart';

/// Speed Chess Championship XI, Round of 16 (tour fqCjSUpE, round 60IswAYI)
/// as production held it: all eight matches in ONE round, game 1 and game 2
/// of every match pre-created, only Nakamura vs Erdogmus under way.
const _tour = 'fqCjSUpE';
const _round = '60IswAYI';
const _playedFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
final _game1End = DateTime.utc(2026, 11, 16, 17, 14, 54);
final _game2Move = DateTime.utc(2026, 11, 16, 17, 25, 59);
final _now = DateTime.utc(2026, 11, 16, 17, 26, 30);

const _players = <String, int>{
  'Nakamura, Hikaru': 2016192,
  'Erdogmus, Yagiz Kaan': 44599790,
  'Carlsen, Magnus': 1503014,
  'Movahed, Sina': 42520835,
  'Abdusattorov, Nodirbek': 14204118,
  'Keymer, Vincent': 12940690,
  'Nihal Sarin': 25092340,
  'Niemann, Hans Moke': 2093596,
  'Firouzja, Alireza': 12573981,
  'Artemiev, Vladislav': 24101605,
  'Caruana, Fabiano': 2020009,
  'Sindarov, Javokhir': 14205483,
  'Lazavik, Denis': 13515110,
  'Andreikin, Dmitry': 4158814,
  'So, Wesley': 5202213,
  'Praggnanandhaa R': 25059530,
};

TournamentGameSummary _row(
  String id,
  int board,
  String white,
  String black, {
  String? tag,
  GameStatus status = GameStatus.ongoing,
  DateTime? movedAt,
  String roundId = _round,
  String roundName = 'Round of 16',
  int? whiteFideId,
  int? blackFideId,
}) {
  final moved = movedAt != null;
  return TournamentGameSummary(
    id: id.contains(':') ? id : '$_round-$id',
    name: '$white - $black',
    whitePlayer: white,
    blackPlayer: black,
    whiteFideId: whiteFideId ?? _players[white],
    blackFideId: blackFideId ?? _players[black],
    hasPgn: tag != null,
    pgn:
        tag == null
            ? null
            : '[Event "Speed Chess Championship"]\n[Round "$tag"]\n'
                '[Board "7"]\n[White "$white"]\n[Black "$black"]\n\n*',
    tourId: _tour,
    roundId: roundId,
    roundSlug: 'round-of-16',
    roundName: roundName,
    boardNumber: board,
    status: status,
    hasStarted: moved,
    lastMoveTime: movedAt,
    fen: moved ? _playedFen : null,
  );
}

/// The production fixture. [tags] adds the PGN `[Round]` tag that the board
/// rail's lean rows never carry.
List<TournamentGameSummary> _fixture({bool tags = false}) {
  String? t(String value) => tags ? value : null;
  return [
    _row(
      'pq36vc',
      1,
      'Nakamura, Hikaru',
      'Erdogmus, Yagiz Kaan',
      tag: t('01.01'),
      status: GameStatus.draw,
      movedAt: _game1End,
    ),
    _row('src7cv', 2, 'Carlsen, Magnus', 'Movahed, Sina', tag: t('01.01')),
    _row(
      '1iw36s7',
      3,
      'Abdusattorov, Nodirbek',
      'Keymer, Vincent',
      tag: t('01.01'),
    ),
    _row('ck9pdy', 4, 'Nihal Sarin', 'Niemann, Hans Moke', tag: t('01.01')),
    _row(
      '78pcxs',
      5,
      'Firouzja, Alireza',
      'Artemiev, Vladislav',
      tag: t('01.01'),
    ),
    _row(
      'um9vyy',
      6,
      'Caruana, Fabiano',
      'Sindarov, Javokhir',
      tag: t('01.01'),
    ),
    _row('1lcthoy', 7, 'Lazavik, Denis', 'Andreikin, Dmitry', tag: t('01.01')),
    _row('1siueax', 8, 'So, Wesley', 'Praggnanandhaa R', tag: t('01.01')),
    _row('67v3yr', 9, 'Niemann, Hans Moke', 'Nihal Sarin', tag: t('01.02')),
    _row('1fw7jih', 10, 'Andreikin, Dmitry', 'Lazavik, Denis', tag: t('01.02')),
    _row('1a45jh4', 11, 'Movahed, Sina', 'Carlsen, Magnus', tag: t('01.02')),
    _row(
      '1md2dlh',
      12,
      'Erdogmus, Yagiz Kaan',
      'Nakamura, Hikaru',
      tag: t('01.02'),
      movedAt: _game2Move,
    ),
    _row(
      '1i7jwd7',
      13,
      'Artemiev, Vladislav',
      'Firouzja, Alireza',
      tag: t('01.02'),
    ),
    _row('1igry3e', 14, 'Praggnanandhaa R', 'So, Wesley', tag: t('01.02')),
    _row(
      'w84g18',
      15,
      'Keymer, Vincent',
      'Abdusattorov, Nodirbek',
      tag: t('01.02'),
    ),
    _row(
      '166s5u7',
      16,
      'Sindarov, Javokhir',
      'Caruana, Fabiano',
      tag: t('01.02'),
    ),
  ];
}

const _expectedSideA = <String>[
  'Nakamura, Hikaru',
  'Carlsen, Magnus',
  'Abdusattorov, Nodirbek',
  'Nihal Sarin',
  'Firouzja, Alireza',
  'Caruana, Fabiano',
  'Lazavik, Denis',
  'So, Wesley',
];

MatchPlayRound<TournamentGameSummary> _build(
  List<TournamentGameSummary> rows,
) =>
    buildMatchPlayRound<TournamentGameSummary>(
      rows,
      (game) => matchPlayFactsOfSummary(game, now: _now),
    )!;

List<String> _sideA(MatchPlayRound<TournamentGameSummary> round) => [
  for (final match in round.matches) match.firstFacts.whiteName,
];

List<String> _ids(Iterable<TournamentGameSummary> games) => [
  for (final game in games) game.id.replaceFirst('$_round-', ''),
];

/// A plain Swiss-style round: eight boards, every pair once.
List<TournamentGameSummary> _plainRound() => [
  for (var board = 1; board <= 8; board++)
    _row(
      'plain-$board',
      board,
      'White $board',
      'Black $board',
      roundId: 'swiss-r5',
      roundName: 'Round 5',
      whiteFideId: 100 + board,
      blackFideId: 200 + board,
      status: board.isEven ? GameStatus.whiteWins : GameStatus.draw,
      movedAt: _game1End.add(Duration(minutes: board)),
    ),
];

/// A World Cup style knockout: game 1 and game 2 of every match in separate
/// source rounds that share a stage name. No pair repeats inside a round.
List<TournamentGameSummary> _legsInSeparateRounds() => [
  for (var match = 1; match <= 4; match++) ...[
    _row(
      'wc-g1-$match',
      match,
      'Seed $match',
      'Challenger $match',
      roundId: 'wc-r1-game-1',
      roundName: 'Round 1',
      whiteFideId: 300 + match,
      blackFideId: 400 + match,
      status: GameStatus.draw,
      movedAt: _game1End.add(Duration(minutes: match)),
    ),
    _row(
      'wc-g2-$match',
      match,
      'Challenger $match',
      'Seed $match',
      roundId: 'wc-r1-game-2',
      roundName: 'Round 1',
      whiteFideId: 400 + match,
      blackFideId: 300 + match,
      status: GameStatus.blackWins,
      movedAt: _game2Move.add(Duration(minutes: match)),
    ),
  ],
];

void main() {
  group('PGN game index', () {
    test('reads S.NN and S.SET.G round tags', () {
      expect(matchPlayGameIndexFromPgn('[Round "01.02"]\n\n*'), (
        set: 0,
        game: 2,
      ));
      expect(
        matchPlayGameIndexFromPgn('[Event "x"]\n[Round "03.02.03"]\n\n*'),
        (set: 2, game: 3),
      );
    });

    test('ignores missing, plain and non-numeric tags', () {
      expect(matchPlayGameIndexFromPgn(null), isNull);
      expect(matchPlayGameIndexFromPgn(''), isNull);
      expect(matchPlayGameIndexFromPgn('[Round "5"]\n\n*'), isNull);
      expect(matchPlayGameIndexFromPgn('[Round "1.a"]\n\n*'), isNull);
      expect(matchPlayGameIndexFromPgn('[Round "1.2.3.4"]\n\n*'), isNull);
    });
  });

  group('the match-play gate', () {
    test('the SCC round is match-play', () {
      expect(
        isMatchPlayRound(_fixture(), (game) => matchPlayFactsOfSummary(game)),
        isTrue,
      );
      expect(eventRailMayHoldMatchPlay(_fixture()), isTrue);
    });

    test('a round where every pair meets once is not', () {
      expect(
        isMatchPlayRound(_plainRound(), (g) => matchPlayFactsOfSummary(g)),
        isFalse,
      );
      expect(eventRailMayHoldMatchPlay(_plainRound()), isFalse);
      expect(buildMatchPlayRound(_plainRound(), matchPlayFactsOfSummary), null);
    });

    test('legs in separate source rounds are not match-play', () {
      final rows = _legsInSeparateRounds();
      expect(isMatchPlayRound(rows, matchPlayFactsOfSummary), isFalse);
      expect(eventRailMayHoldMatchPlay(rows), isFalse);
    });

    test('FIDE ids join two spellings of the same pair', () {
      final rows = [
        _row('a', 1, 'Nihal Sarin', 'Niemann, Hans Moke'),
        _row(
          'b',
          2,
          'Niemann, Hans',
          'Sarin, Nihal',
          whiteFideId: 2093596,
          blackFideId: 25092340,
        ),
      ];
      expect(isMatchPlayRound(rows, matchPlayFactsOfSummary), isTrue);
      expect(eventRailMayHoldMatchPlay(rows), isTrue);
      expect(_build(rows).matches, hasLength(1));
    });
  });

  group('the SCC fixture', () {
    for (final tags in [false, true]) {
      final label = tags ? 'with PGN round tags' : 'from lean rail rows';
      test('folds into eight matches, side A = White of game 1 ($label)', () {
        final round = _build(_fixture(tags: tags));
        expect(round.matches, hasLength(8));
        expect(round.looseGames, isEmpty);
        expect(_sideA(round), _expectedSideA);
      });

      test('Nakamura match: live game 2 above game 1, ½–½ ($label)', () {
        final match = _build(_fixture(tags: tags)).matches.first;
        expect(match.state, MatchPlayState.live);
        expect(_ids(match.displayGames), ['1md2dlh', 'pq36vc']);
        expect(_ids(match.chronologicalGames), ['pq36vc', '1md2dlh']);
        // Nakamura is side A: White in game 1, Black in game 2.
        expect(match.anchorIsWhite('$_round-pq36vc'), isTrue);
        expect(match.anchorIsWhite('$_round-1md2dlh'), isFalse);
        expect(match.aPoints, 0.5);
        expect(match.bPoints, 0.5);
        expect(match.finishedGames, 1);
      });

      test('matches not started stay in bracket order ($label)', () {
        final matches = _build(_fixture(tags: tags)).matches;
        for (final match in matches.skip(1)) {
          expect(match.state, MatchPlayState.notStarted);
          expect(match.hasReportedScore, isFalse);
          expect(match.lastActivity, isNull);
          // Game 1 (A White) is the shell to play next, game 2 after it.
          expect([
            for (final id in match.anchorIsWhiteById.keys) id,
          ], hasLength(2));
          expect(match.anchorIsWhite(_idOf(match.displayGames.first)), isTrue);
          expect(match.anchorIsWhite(_idOf(match.displayGames.last)), isFalse);
        }
        expect(_ids(matches[1].displayGames), ['src7cv', '1a45jh4']);
      });
    }

    test('a 0-move shell is never live', () {
      final shell = matchPlayFactsOfSummary(_fixture()[1], now: _now);
      expect(shell.hasMoves, isFalse);
      expect(shell.isLive, isFalse);
      final live = matchPlayFactsOfSummary(_fixture()[11], now: _now);
      expect(live.isLive, isTrue);
    });
  });

  group('renumbering robustness', () {
    test('a later game inserted on a low board keeps side A (lean rows)', () {
      // Game 2 finished, game 3 under way; chess.com inserted game 3 at the
      // top of the file and the ingest renumbered every board after it.
      final rows = [
        _row(
          'chess.com:3',
          1,
          'Nakamura, Hikaru',
          'Erdogmus, Yagiz Kaan',
          movedAt: _now,
        ),
        for (final game in _fixture())
          game.id == '$_round-1md2dlh'
              ? _row(
                '1md2dlh',
                game.boardNumber! + 1,
                'Erdogmus, Yagiz Kaan',
                'Nakamura, Hikaru',
                status: GameStatus.blackWins,
                movedAt: _game2Move,
              )
              : _renumbered(game, game.boardNumber! + 1),
      ];
      final round = _build(rows);
      expect(_sideA(round), _expectedSideA);
      final match = round.matches.first;
      expect(_ids(match.displayGames), ['chess.com:3', '1md2dlh', 'pq36vc']);
      expect(match.anchorIsWhite('chess.com:3'), isTrue);
      expect(match.aPoints, 1.5);
      expect(match.bPoints, 0.5);
    });

    test('Black-of-game-1 on a lower board keeps side A (round tags)', () {
      // Game 4 (Movahed White) inserted above game 1 of Carlsen's match.
      final rows = [
        _row(
          'chess.com:4',
          0,
          'Movahed, Sina',
          'Carlsen, Magnus',
          tag: '01.04',
        ),
        ..._fixture(tags: true),
      ];
      final round = _build(rows);
      expect(_sideA(round), _expectedSideA);
      final carlsen = round.matches[1];
      expect(_ids(carlsen.chronologicalGames), [
        'src7cv',
        '1a45jh4',
        'chess.com:4',
      ]);
      expect(carlsen.anchorIsWhite('chess.com:4'), isFalse);
      // Bracket order is game 1's board, never a later game's.
      expect(carlsen.bracketBoard, 2);
    });
  });

  group('match and game order', () {
    test('live, then played newest first, then not started by bracket', () {
      final rows = [
        // Bracket 1: finished long ago.
        _row(
          'm1g1',
          1,
          'A1',
          'B1',
          status: GameStatus.whiteWins,
          movedAt: _now.subtract(const Duration(days: 3)),
        ),
        _row(
          'm1g2',
          5,
          'B1',
          'A1',
          status: GameStatus.draw,
          movedAt: _now.subtract(const Duration(days: 3)),
        ),
        // Bracket 2: not started.
        _row('m2g1', 2, 'A2', 'B2'),
        _row('m2g2', 6, 'B2', 'A2'),
        // Bracket 3: finished yesterday.
        _row(
          'm3g1',
          3,
          'A3',
          'B3',
          status: GameStatus.blackWins,
          movedAt: _now.subtract(const Duration(days: 1)),
        ),
        _row(
          'm3g2',
          7,
          'B3',
          'A3',
          status: GameStatus.whiteWins,
          movedAt: _now.subtract(const Duration(days: 1)),
        ),
        // Bracket 4: live.
        _row(
          'm4g1',
          4,
          'A4',
          'B4',
          status: GameStatus.draw,
          movedAt: _now.subtract(const Duration(minutes: 9)),
        ),
        _row('m4g2', 8, 'B4', 'A4', movedAt: _now),
      ];
      final round = _build(rows);
      expect(_sideA(round), ['A4', 'A3', 'A1', 'A2']);
      expect(round.matches.map((match) => match.state), [
        MatchPlayState.live,
        MatchPlayState.played,
        MatchPlayState.played,
        MatchPlayState.notStarted,
      ]);
      // A3 lost game 1 with White and lost game 2 with Black.
      expect(round.matches[1].aPoints, 0);
      expect(round.matches[1].bPoints, 2);
    });

    test('two live matches keep bracket order', () {
      final rows = [
        _row('x1', 1, 'X', 'Y', status: GameStatus.draw, movedAt: _game1End),
        _row(
          'x2',
          3,
          'Y',
          'X',
          movedAt: _now.subtract(const Duration(minutes: 5)),
        ),
        _row('z1', 2, 'Z', 'W', status: GameStatus.draw, movedAt: _game1End),
        _row('z2', 4, 'W', 'Z', movedAt: _now),
      ];
      expect(_sideA(_build(rows)), ['X', 'Z']);
    });

    test('game in play, then finished newest first, then shells', () {
      final rows = [
        _row('g5', 1, 'A', 'B', tag: '01.05'),
        _row(
          'g1',
          2,
          'A',
          'B',
          tag: '01.01',
          status: GameStatus.draw,
          movedAt: _game1End,
        ),
        _row('g3', 3, 'A', 'B', tag: '01.03', movedAt: _now),
        _row(
          'g2',
          4,
          'B',
          'A',
          tag: '01.02',
          status: GameStatus.whiteWins,
          movedAt: _game2Move,
        ),
        _row('g4', 5, 'B', 'A', tag: '01.04'),
      ];
      final match = _build(rows).matches.single;
      expect(_ids(match.displayGames), ['g3', 'g2', 'g1', 'g4', 'g5']);
      expect(_ids(match.chronologicalGames), ['g1', 'g2', 'g3', 'g4', 'g5']);
      expect(match.aPoints, 0.5);
      expect(match.bPoints, 1.5);
    });

    test('boards without a named player stay loose rows', () {
      final rows = [..._fixture(), _row('tbd', 17, 'TBD', '?')];
      final round = _build(rows);
      expect(round.matches, hasLength(8));
      expect(_ids(round.looseGames), ['tbd']);
      expect(_ids(round.orderedGames).last, 'tbd');
    });
  });

  group('event rail', () {
    test('a header per match, side A on top, match order kept', () {
      final segments = eventRailMatchPlaySegmentsForTesting(
        _fixture(),
        now: _now,
      );
      expect(segments, hasLength(8));
      expect(segments.first.title, 'Nakamura,H vs Erdogmus,Y');
      expect(segments.first.score, '½–½');
      expect(_strip(segments.first.gameIds), ['1md2dlh', 'pq36vc']);
      expect(segments.first.topIsWhite, [false, true]);
      expect(segments[1].title, 'Carlsen,M vs Movahed,S');
      expect(segments[1].score, '');
      expect(_strip(segments[1].gameIds), ['src7cv', '1a45jh4']);
      expect(segments[1].topIsWhite, [true, false]);
      expect(
        [for (final s in segments) s.title!.split(' vs ').first],
        [
          'Nakamura,H',
          'Carlsen,M',
          'Abdusattorov,N',
          'Nihal Sarin',
          'Firouzja,A',
          'Caruana,F',
          'Lazavik,D',
          'So,W',
        ],
      );
    });

    test('the live-first toggle never re-sorts a match', () {
      final plain = eventRailMatchPlaySegmentsForTesting(_fixture(), now: _now);
      final liveFirst = eventRailMatchPlaySegmentsForTesting(
        _fixture(),
        now: _now,
        liveFirst: true,
      );
      expect(
        [for (final s in liveFirst) s.gameIds],
        [for (final s in plain) s.gameIds],
      );
    });

    test('a render window keeps the full round\'s sides and score', () {
      final rows = _fixture();
      final window = [
        for (final game in rows)
          if (game.id != '$_round-pq36vc' &&
              !game.whitePlayer.startsWith('Carlsen') &&
              !game.blackPlayer.startsWith('Carlsen'))
            game,
      ];
      final segments = eventRailMatchPlaySegmentsForTesting(
        rows,
        now: _now,
        window: window,
      );
      expect(segments, hasLength(7));
      expect(_strip(segments.first.gameIds), ['1md2dlh']);
      expect(segments.first.topIsWhite, [false]);
      expect(segments.first.score, '½–½');
      expect(segments.any((s) => s.title!.startsWith('Carlsen')), isFalse);
    });

    test('without the knockout opt-in the round renders as today', () {
      final today = eventRailRoundSegmentsForTesting(_fixture());
      expect(
        _flat(
          eventRailRoundSegmentsForTesting(_fixture(), knockoutEvent: false),
        ),
        _flat(today),
      );
      expect(today, hasLength(1));
      expect(today.single.title, isNull);
      expect(_strip(today.single.gameIds), ['pq36vc', '1md2dlh']);
    });

    for (final (name, rows) in [
      ('a plain round', _plainRound()),
      ('a knockout with legs in separate rounds', _legsInSeparateRounds()),
    ]) {
      test('$name is unchanged by the knockout opt-in', () {
        expect(
          _flat(eventRailRoundSegmentsForTesting(rows, knockoutEvent: true)),
          _flat(eventRailRoundSegmentsForTesting(rows)),
        );
        expect(
          eventRailOrderedIdsForTesting(rows, knockoutEvent: true),
          eventRailOrderedIdsForTesting(rows),
        );
        expect(
          [
            for (final group in eventRailRoundGroupsForTesting(
              rows,
              knockoutEvent: true,
            ))
              [group.id, group.status, group.pairingOnly, ...group.gameIds],
          ],
          [
            for (final group in eventRailRoundGroupsForTesting(rows))
              [group.id, group.status, group.pairingOnly, ...group.gameIds],
          ],
        );
        expect(
          eventRailMatchPlaySegmentsForTesting(
            rows,
          ).every((segment) => segment.topIsWhite == null),
          isTrue,
        );
      });
    }
  });

  group('tournament Games tab sections', () {
    List<GamesTourModel> models({bool tags = false}) => [
      for (final row in _fixture(tags: tags))
        gamesTourModelFromTournamentSummary(row),
    ];

    test('match-play sections: A left, display order, A–B score', () {
      final sections = desktopKnockoutMatchSections(models(tags: true));
      expect(sections, hasLength(8));
      expect([for (final s in sections) s.header.player1], _expectedSideA);
      final nakamura = sections.first;
      expect(nakamura.isMatchPlay, isTrue);
      expect(nakamura.header.player2, 'Erdogmus, Yagiz Kaan');
      expect(
        [for (final game in nakamura.header.games) game.gameId],
        ['$_round-1md2dlh', '$_round-pq36vc'],
      );
      expect(nakamura.header.player1ScoreLabel, '0.5');
      expect(nakamura.header.player2ScoreLabel, '0.5');
      expect(nakamura.anchorIsWhiteById, {
        '$_round-pq36vc': true,
        '$_round-1md2dlh': false,
      });
    });

    test('other knockout rounds keep the detector sections', () {
      final legs = [
        for (final row in _legsInSeparateRounds())
          gamesTourModelFromTournamentSummary(row),
      ];
      final sections = desktopKnockoutMatchSections(legs);
      final expected = orderedKnockoutMatchEntriesForDisplay(legs);
      expect(
        [for (final s in sections) s.key],
        [for (final e in expected) e.key],
      );
      expect(
        [
          for (final s in sections) [for (final g in s.header.games) g.gameId],
        ],
        [
          for (final e in expected) [for (final g in e.value) g.gameId],
        ],
      );
      expect(sections.every((s) => !s.isMatchPlay), isTrue);
    });

    test('the stage gate merges shells only into match-play stages', () {
      expect(hasMatchPlayPairing(models()), isTrue);
      expect(
        hasMatchPlayPairing([
          for (final row in _legsInSeparateRounds())
            gamesTourModelFromTournamentSummary(row),
        ]),
        isFalse,
      );
    });
  });

  group('focus follow', () {
    MatchPlayGameFacts g(String id, {bool moves = false, bool done = false}) =>
        MatchPlayGameFacts(
          id: id,
          roundId: _round,
          whiteName: 'A',
          blackName: 'B',
          isFinished: done,
          hasMoves: moves || done,
        );

    MatchPlayFollowDecision step(
      MatchPlayFollowState? previous,
      List<MatchPlayGameFacts> games, {
      String focus = 'g1',
      bool analysing = false,
    }) => decideMatchPlayFocusFollow(
      previous: previous,
      focusedGameId: focus,
      matchGames: games,
      isUserAnalysing: () => analysing,
    );

    test('follows once when the next game starts while watching', () {
      final first = step(null, [g('g1', done: true), g('g2')]);
      expect(first.followGameId, isNull);
      expect(first.state!.suppressed, isFalse);
      final started = step(first.state, [
        g('g1', done: true),
        g('g2', moves: true),
      ]);
      expect(started.followGameId, 'g2');
      final again = step(started.state, [
        g('g1', done: true),
        g('g2', moves: true),
      ]);
      expect(again.followGameId, isNull);
    });

    test('never jumps on the first look at a historical game', () {
      final first = step(null, [
        g('g1', done: true),
        g('g2', done: true),
        g('g3', moves: true),
      ]);
      expect(first.followGameId, isNull);
      expect(first.state!.suppressed, isTrue);
      // The reader chose game 1 after game 3 was live: game 4 must not pull.
      final next = step(first.state, [
        g('g1', done: true),
        g('g2', done: true),
        g('g3', done: true),
        g('g4', moves: true),
      ]);
      expect(next.followGameId, isNull);
    });

    test('analysing on the board consumes the start', () {
      final first = step(null, [g('g1', done: true), g('g2')]);
      final busy = step(first.state, [
        g('g1', done: true),
        g('g2', moves: true),
      ], analysing: true);
      expect(busy.followGameId, isNull);
      final later = step(busy.state, [
        g('g1', done: true),
        g('g2', moves: true),
      ]);
      expect(later.followGameId, isNull);
    });

    test('waits for the watched game\'s own result', () {
      final first = step(null, [g('g1', moves: true), g('g2')]);
      final early = step(first.state, [
        g('g1', moves: true),
        g('g2', moves: true),
      ]);
      expect(early.followGameId, isNull);
      final settled = step(early.state, [
        g('g1', done: true),
        g('g2', moves: true),
      ]);
      expect(settled.followGameId, 'g2');
    });

    test('asks about analysis only when a later game starts', () {
      var asked = 0;
      final first = decideMatchPlayFocusFollow(
        previous: null,
        focusedGameId: 'g1',
        matchGames: [g('g1', done: true), g('g2')],
        isUserAnalysing: () {
          asked++;
          return false;
        },
      );
      decideMatchPlayFocusFollow(
        previous: first.state,
        focusedGameId: 'g1',
        matchGames: [g('g1', done: true), g('g2')],
        isUserAnalysing: () {
          asked++;
          return false;
        },
      );
      expect(asked, 0);
    });

    test('a game outside match play has no follow state', () {
      final decision = decideMatchPlayFocusFollow(
        previous: null,
        focusedGameId: 'other',
        matchGames: null,
        isUserAnalysing: () => false,
      );
      expect(decision.state, isNull);
      expect(decision.followGameId, isNull);
    });
  });

  group('widgets', () {
    testWidgets('colour mark: same size both colours, labelled', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              MatchPlayColorMark(isWhite: true),
              MatchPlayColorMark(isWhite: false),
            ],
          ),
        ),
      );
      final white = tester.getSize(
        find.byKey(const ValueKey('match-play-mark-white')),
      );
      final black = tester.getSize(
        find.byKey(const ValueKey('match-play-mark-black')),
      );
      expect(white, const Size(9, 9));
      expect(black, white);
      expect(find.bySemanticsLabel('White'), findsOneWidget);
      expect(find.bySemanticsLabel('Black'), findsOneWidget);
    });

    testWidgets('rail rows keep side A on top with colour marks', (
      tester,
    ) async {
      await tester.pumpWidget(_railHarness(knockout: true));
      await tester.pump();

      expect(find.text('Nakamura,H vs Erdogmus,Y'), findsOneWidget);
      expect(find.text('½–½'), findsOneWidget);
      // Game 2: Nakamura (Black) on the top line, Erdogmus (White) below.
      final top = tester.getTopLeft(
        find.byKey(const Key('event-game-$_round-1md2dlh-black-line')),
      );
      final bottom = tester.getTopLeft(
        find.byKey(const Key('event-game-$_round-1md2dlh-white-line')),
      );
      expect(top.dy, lessThan(bottom.dy));
      // Game 1 keeps Nakamura (White) on top.
      expect(
        tester
            .getTopLeft(
              find.byKey(const Key('event-game-$_round-pq36vc-white-line')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const Key('event-game-$_round-pq36vc-black-line')),
              )
              .dy,
        ),
      );
      expect(find.byKey(const ValueKey('match-play-mark-black')), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a non-knockout event keeps White on top and no marks', (
      tester,
    ) async {
      await tester.pumpWidget(_railHarness(knockout: false));
      await tester.pump();

      expect(find.text('Nakamura,H vs Erdogmus,Y'), findsNothing);
      expect(find.byType(MatchPlayColorMark), findsNothing);
      expect(
        tester
            .getTopLeft(
              find.byKey(const Key('event-game-$_round-1md2dlh-white-line')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const Key('event-game-$_round-1md2dlh-black-line')),
              )
              .dy,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    for (final layout in DesktopCardLayout.values) {
      testWidgets('${layout.name} card puts side A first when A is Black', (
        tester,
      ) async {
        await _pumpCard(
          tester,
          layout: layout,
          data: _cardData.copyWith(matchPlayAnchorIsWhite: false),
        );
        final a = tester.getTopLeft(find.textContaining('Naka'));
        final b = tester.getTopLeft(find.textContaining('Erdo'));
        if (layout == DesktopCardLayout.compact) {
          expect(a.dx, lessThan(b.dx));
        } else {
          expect(a.dy, lessThan(b.dy));
        }
        expect(find.byType(MatchPlayColorMark), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      });

      testWidgets('${layout.name} card is unchanged outside match play', (
        tester,
      ) async {
        await _pumpCard(tester, layout: layout, data: _cardData);
        final white = tester.getTopLeft(find.textContaining('Erdo'));
        final black = tester.getTopLeft(find.textContaining('Naka'));
        switch (layout) {
          case DesktopCardLayout.compact:
            expect(white.dx, lessThan(black.dx));
          case DesktopCardLayout.list:
            expect(white.dy, lessThan(black.dy));
          case DesktopCardLayout.grid:
            expect(black.dy, lessThan(white.dy));
        }
        expect(find.byType(MatchPlayColorMark), findsNothing);
      });
    }
  });
}

String _idOf(TournamentGameSummary game) => game.id;

List<List<Object?>> _flat(
  List<({String? title, String? score, List<String> gameIds})> segments,
) => [
  for (final segment in segments)
    [segment.title, segment.score, ...segment.gameIds],
];

class _IdleGames extends StateNotifier<AsyncValue<List<Games>>>
    implements GamesTourNotifier {
  _IdleGames() : super(const AsyncValue.data(<Games>[]));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _strip(List<String> ids) => [
  for (final id in ids) id.replaceFirst('$_round-', ''),
];

TournamentGameSummary _renumbered(TournamentGameSummary game, int board) =>
    TournamentGameSummary(
      id: game.id,
      name: game.name,
      whitePlayer: game.whitePlayer,
      blackPlayer: game.blackPlayer,
      whiteFideId: game.whiteFideId,
      blackFideId: game.blackFideId,
      hasPgn: game.hasPgn,
      pgn: game.pgn,
      tourId: game.tourId,
      roundId: game.roundId,
      roundSlug: game.roundSlug,
      roundName: game.roundName,
      boardNumber: board,
      status: game.status,
      hasStarted: game.hasStarted,
      lastMoveTime: game.lastMoveTime,
      fen: game.fen,
    );

Widget _railHarness({required bool knockout}) {
  final games = _fixture();
  return ProviderScope(
    overrides: [
      currentBroadcastGames,
      gamesTourProvider.overrideWith((ref, tourId) => _IdleGames()),
      isTeamEventProvider.overrideWith((ref, id) => false),
      knockoutTournamentStateProvider.overrideWith(
        (ref, id) => KnockoutTournamentState(
          isKnockout: knockout,
          isTeamEvent: false,
          stageName: null,
          allGames: const <GamesTourModel>[],
        ),
      ),
      desktopTabsProvider.overrideWith((ref) => realTabFixture()),
      boardTabGameArgsByTabIdProvider.overrideWith(
        (ref) => {
          'fixture-board': BoardTabGameArgs(
            gameId: '$_round-1md2dlh',
            pgn: '1. e4 e5 *',
            label: 'Speed Chess Championship',
            whiteName: 'Erdogmus, Yagiz Kaan',
            blackName: 'Nakamura, Hikaru',
            tournamentTitle: 'Speed Chess Championship',
            eventGames: games,
            gameListSelectedId: '$_round-1md2dlh',
          ),
        },
      ),
      gameUpdatesStreamProvider.overrideWith(
        (ref, gameId) => const Stream<Map<String, dynamic>?>.empty(),
      ),
      gameUpdatesBatchStreamProvider.overrideWith(
        (ref, key) => const Stream<Map<String, LiveGameUpdate>>.empty(),
      ),
      dateTimeProvider.overrideWith((ref) => Stream.value(DateTime.now())),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: EventGamesTable.width,
          child: EventGamesTable(tabId: 'fixture-board'),
        ),
      ),
    ),
  );
}

const _cardData = GameCardData(
  id: 'card-1',
  title: 'Erdogmus vs Nakamura',
  whiteName: 'Erdogmus, Yagiz Kaan',
  blackName: 'Nakamura, Hikaru',
  whiteFederation: 'TUR',
  blackFederation: 'USA',
  whiteTitle: 'GM',
  blackTitle: 'GM',
  whiteRating: 2650,
  blackRating: 2800,
  fen: null,
  status: GameStatus.blackWins,
  hasStarted: true,
);

Future<void> _pumpCard(
  WidgetTester tester, {
  required DesktopCardLayout layout,
  required GameCardData data,
}) async {
  final grid = layout == DesktopCardLayout.grid;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        engineSettingsProviderNew.overrideWith(_TestEngineSettingsNotifier.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: grid ? 250 : 420,
              height: grid ? 263 : 112,
              child: DesktopGameCard(
                data: data,
                layout: layout,
                onTap: () {},
                allowStockfishFallback: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew();
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _TestEngineSettingsNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings();
    state = const AsyncValue.data(settings);
    return settings;
  }
}
