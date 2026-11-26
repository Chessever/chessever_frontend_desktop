import 'dart:async';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report_store.dart';
import 'package:chessever/desktop/services/engine/server_game_report.dart';
import 'package:chessever/desktop/services/toby/toby_access.dart';
import 'package:chessever/desktop/services/toby/toby_performance.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart'
    show GameReportView, tobyRatingCells, tobyRatingSemanticsLabel;
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _afterE4 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
const _afterE5 = 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
const _afterNf3 =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

GameReportLine _cp(int cp, [List<String> moves = const []]) =>
    GameReportLine(moves: moves, depth: 20, centipawns: cp);

GameReportLine _mate(int mate) =>
    GameReportLine(moves: const [], depth: 20, mate: mate);

GameReportPosition _at(String fen, List<GameReportLine> lines) =>
    GameReportPosition(fen: fen, lines: lines);

GameAnalysisReport _report(List<GameReportPosition> positions) =>
    GameAnalysisReport(
      fingerprint: 'fp-1',
      positions: positions,
      moves: const [],
      whiteAccuracy: 90,
      blackAccuracy: 80,
      generatedAt: DateTime.utc(2026),
    );

Map<String, dynamic> _side(
  int rating,
  String display, {
  String method = 'moves',
}) => {
  'rating': rating,
  'display': display,
  'method': method,
  'moves': 24,
  'sd': 180.5,
};

Map<String, dynamic> _body() => {
  'model': 'toby2-level-v1',
  'cadence': 'classical',
  'white': _side(2480, '2480', method: 'rated'),
  'black': _side(2550, '2500+'),
};

GamebaseTobyReply _reply(
  int? status, [
  Map<String, dynamic>? data,
  Duration? retryAfter,
]) => (statusCode: status, data: data, retryAfter: retryAfter);

typedef _Call = ({Map<String, Object?> body, bool recheckAccess});

class _FakeGamebase extends GamebaseRepository {
  _FakeGamebase(this._answer) : super(Dio(), baseUrl: 'http://example.test');

  final FutureOr<GamebaseTobyReply> Function(int index) _answer;
  final calls = <_Call>[];

  @override
  Future<GamebaseTobyReply> getTobyPerformance(
    Map<String, Object?> body,
    CancelToken cancelToken, {
    bool recheckAccess = false,
  }) async {
    calls.add((body: body, recheckAccess: recheckAccess));
    return _answer(calls.length - 1);
  }
}

TobyPerformanceRequest _request({
  int? whiteRating = 2500,
  String? timeControl = '5400+30',
  List<TobyMoveValues?>? values = const [(best: 30, played: 25), null],
}) => TobyPerformanceRequest(
  moves: const ['e2e4', 'e7e5'],
  values: values,
  whiteRating: whiteRating,
  timeControl: timeControl,
);

TobyPerformanceQuery _query({
  String? accountId = 'acct',
  TobyPerformanceRequest? request,
}) => TobyPerformanceQuery(
  fingerprint: 'fp-1',
  accountId: accountId,
  request: request ?? _request(),
);

void main() {
  setUp(tobyPerformanceMemory.clear);

  group('values from the report', () {
    test('mover terms: White as is, Black negated, played from the next '
        'position', () {
      final report = _report([
        _at(_start, [_cp(30)]),
        _at(_afterE4, [_cp(25)]),
        _at(_afterE5, [_cp(40)]),
      ]);
      expect(tobyPerformanceValues(report, const ['e2e4', 'e7e5']), [
        (best: 30, played: 25),
        (best: -25, played: -40),
      ]);
    });

    test(
      'prefers the played move\'s own MultiPV line, castling either way',
      () {
        final report = _report([
          _at(_start, [
            _cp(35, const ['d2d4']),
            _cp(20, const ['e2e4']),
          ]),
          _at(_afterE4, [_cp(-500)]),
        ]);
        expect(tobyPerformanceValues(report, const ['e2e4']), [
          (best: 35, played: 20),
        ]);

        const castled = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';
        final castle = _report([
          _at(castled, [
            _cp(10, const ['a1a8']),
            _cp(5, const ['e1g1']),
          ]),
          _at(castled.replaceFirst(' w ', ' b '), [_cp(-90)]),
        ]);
        expect(tobyPerformanceValues(castle, const ['e1h1']), [
          (best: 10, played: 5),
        ]);
      },
    );

    test('mates are ±10000 in the mover\'s terms; scores are clamped', () {
      final report = _report([
        _at(_afterE5, [_mate(3)]),
        _at(_afterNf3, [_mate(0)]),
        _at(_start, [_cp(-20000)]),
      ]);
      // Move 1 (White): best mate for White; played reaches a position where
      // the side to move (Black) is mated.
      // Move 2 (Black): best = -(+10000); played = -(-10000), clamped.
      expect(tobyPerformanceValues(report, const ['g1f3', 'b8c6']), [
        (best: 10000, played: 10000),
        (best: -10000, played: 10000),
      ]);
    });

    test('a missing evaluation is null, and so is a move past the report', () {
      final report = _report([
        _at(_start, [_cp(30)]),
        _at(_afterE4, [const GameReportLine(moves: [], depth: 0)]),
      ]);
      expect(tobyPerformanceValues(report, const ['e2e4', 'e7e5']), [
        null,
        null,
      ]);
    });
  });

  group('request', () {
    test('version 1 body with values and the raw game facts', () {
      final request = TobyPerformanceRequest(
        startFen: _start,
        moves: const ['e2e4', 'e7e5'],
        values: const [(best: 30, played: 25), null],
        whiteRating: 2500,
        blackRating: 0,
        timeControl: ' 5400+30 ',
        site: 'Wijk aan Zee',
      );
      expect(request.toBody(), {
        'version': 1,
        'moves': ['e2e4', 'e7e5'],
        'values': [
          {'best': 30, 'played': 25},
          null,
        ],
        'game': {
          'whiteRating': 2500,
          'blackRating': null,
          'timeControl': '5400+30',
          'category': null,
          'site': 'Wijk aan Zee',
          'event': null,
        },
      });
      expect(request.isSupported, isTrue);
    });

    test('values are left out when none is known or the lengths differ', () {
      expect(
        TobyPerformanceRequest(
          moves: const ['e2e4'],
          values: const [null],
        ).toBody().containsKey('values'),
        isFalse,
      );
      expect(
        TobyPerformanceRequest(
          moves: const ['e2e4', 'e7e5'],
          values: const [(best: 1, played: 1)],
        ).toBody().containsKey('values'),
        isFalse,
      );
    });

    test('forReport skips values when the report is not this game', () {
      final report = _report([
        _at(_start, [_cp(30)]),
      ]);
      final request = TobyPerformanceRequest.forReport(
        report,
        moves: const ['e2e4', 'e7e5'],
      );
      expect(request.values, isNull);
    });

    test('an empty or over-long game is not supported', () {
      expect(TobyPerformanceRequest(moves: const []).isSupported, isFalse);
      expect(
        TobyPerformanceRequest(
          moves: List.filled(tobyMaxMoves + 1, 'g1f3'),
        ).isSupported,
        isFalse,
      );
    });
  });

  group('parsing', () {
    test('reads the Gamebase body and round-trips it', () {
      final performance = TobyPerformance.fromJson(_body())!;
      expect(performance.model, 'toby2-level-v1');
      expect(performance.cadence, TobyCadence.classical);
      expect(performance.white!.display, '2480');
      expect(performance.white!.method, TobyPerformanceMethod.rated);
      expect(performance.black!.rating, 2550);
      expect(performance.black!.sd, 180.5);
      expect(TobyPerformance.fromJson(performance.toJson()), performance);
    });

    test(
      'a null or malformed side has no estimate; a bad envelope is null',
      () {
        final performance =
            TobyPerformance.fromJson({
              ..._body(),
              'white': null,
              'black': {..._side(2100, '2100'), 'method': 'guess'},
            })!;
        expect(performance.white, isNull);
        expect(performance.black, isNull);
        expect(performance.hasEstimate, isFalse);
        expect(
          TobyPerformance.fromJson({..._body(), 'cadence': 'bullet'}),
          isNull,
        );
        expect(TobyPerformance.fromJson({..._body(), 'model': 3}), isNull);
        expect(TobyPerformance.fromJson('nope'), isNull);
      },
    );

    test('the report JSON field is optional', () {
      expect(tobyPerformanceFromServerJson(const {}), isNull);
      expect(
        tobyPerformanceFromServerJson({
          'tobyPerformance': _body(),
        })!.white!.rating,
        2480,
      );
    });
  });

  group('replies', () {
    test('200, 202, refusals and failures', () {
      expect(
        interpretTobyPerformanceReply(_reply(200, _body())),
        isA<TobyPerformanceReady>(),
      );
      expect(
        interpretTobyPerformanceReply(_reply(200, {'model': 'x'})),
        isA<TobyPerformanceFailed>().having((r) => r.retryable, 'retry', false),
      );
      final pending = interpretTobyPerformanceReply(
        _reply(202, {
          'status': 'pending',
          'progress': {'done': 8, 'total': 40},
        }, const Duration(seconds: 3)),
      );
      expect(
        pending,
        isA<TobyPerformancePending>()
            .having((r) => r.wait, 'wait', const Duration(seconds: 3))
            .having((r) => r.done, 'done', 8)
            .having((r) => r.total, 'total', 40),
      );
      expect(
        (interpretTobyPerformanceReply(
                  _reply(202, null, const Duration(minutes: 5)),
                )
                as TobyPerformancePending)
            .wait,
        const Duration(seconds: 30),
      );
      expect(
        interpretTobyPerformanceReply(_reply(401)),
        isA<TobyPerformanceDenied>().having((r) => r.signIn, 'signIn', true),
      );
      expect(
        interpretTobyPerformanceReply(
          _reply(403, {'error': 'premium_required'}),
        ),
        isA<TobyPerformanceDenied>().having((r) => r.signIn, 'signIn', false),
      );
      for (final status in [null, 429, 503]) {
        expect(
          interpretTobyPerformanceReply(_reply(status)),
          isA<TobyPerformanceFailed>().having((r) => r.retryable, 'r', true),
        );
      }
      expect(
        interpretTobyPerformanceReply(_reply(400)),
        isA<TobyPerformanceFailed>().having((r) => r.retryable, 'r', false),
      );
    });
  });

  group('row cells', () {
    test('hidden, loading, ready and a side without an estimate', () {
      expect(tobyRatingCells(null), isNull);
      expect(tobyRatingCells(TobyPerformanceState.unavailable), isNull);
      expect(tobyRatingCells(TobyPerformanceState.loading), (
        white: '—',
        black: '—',
        loading: true,
      ));
      final ready = TobyPerformance.fromJson({..._body(), 'white': null})!;
      expect(tobyRatingCells(TobyPerformanceState.ready(ready)), (
        white: '—',
        black: '2500+',
        loading: false,
      ));
      final empty =
          TobyPerformance.fromJson({..._body(), 'white': null, 'black': null})!;
      expect(tobyRatingCells(TobyPerformanceState.ready(empty)), isNull);
      // Asked and nothing came: the row keeps its placeholder.
      expect(tobyRatingCells(TobyPerformanceState.failed), (
        white: '—',
        black: '—',
        loading: false,
      ));
    });

    test('the screen-reader label says the state, never the glyph', () {
      String label(TobyPerformanceState? state) =>
          tobyRatingSemanticsLabel(state, white: 'Ada', black: 'Grace');
      expect(
        label(TobyPerformanceState.loading),
        startsWith('Toby rating: Ada loading, Grace loading.'),
      );
      expect(
        label(TobyPerformanceState.failed),
        startsWith('Toby rating: Ada not available, Grace not available.'),
      );
      final oneSide = TobyPerformance.fromJson({..._body(), 'white': null})!;
      expect(
        label(TobyPerformanceState.ready(oneSide)),
        startsWith('Toby rating: Ada not available, Grace 2500+.'),
      );
      expect(label(TobyPerformanceState.loading), isNot(contains('—')));
    });
  });

  group('basis', () {
    test('the game facts and the values are part of it', () {
      final base = _request();
      expect(_request().basis, base.basis);
      expect(_request(whiteRating: 2300).basis, isNot(base.basis));
      expect(_request(timeControl: '180+2').basis, isNot(base.basis));
      expect(
        _request(values: const [(best: 30, played: 0), null]).basis,
        isNot(base.basis),
      );
    });
  });

  group('memory', () {
    final performance = TobyPerformance.fromJson(_body())!;

    test('same moves, other ratings: no cross-hit', () {
      tobyPerformanceMemory.store(_query(), performance);
      expect(tobyPerformanceMemory.lookup(_query()), performance);
      expect(
        tobyPerformanceMemory.lookup(
          _query(request: _request(whiteRating: 2300)),
        ),
        isNull,
      );
      expect(
        tobyPerformanceMemory.lookup(
          _query(request: _request(timeControl: '180+2')),
        ),
        isNull,
      );
    });

    test('scoped by account', () {
      tobyPerformanceMemory.store(_query(), performance);
      expect(tobyPerformanceMemory.lookup(_query(accountId: 'other')), isNull);
      expect(tobyPerformanceMemory.lookup(_query(accountId: null)), isNull);
    });

    test('the Worker\'s estimate serves only the ratings it was sent', () {
      tobyPerformanceMemory.storeFromReport(
        'fp-1',
        performance,
        whiteRating: 2500,
      );
      expect(tobyPerformanceMemory.lookup(_query()), performance);
      expect(
        tobyPerformanceMemory.lookup(_query(accountId: 'other')),
        isNotNull,
      );
      expect(
        tobyPerformanceMemory.lookup(
          _query(request: _request(whiteRating: 2300)),
        ),
        isNull,
      );
    });
  });

  group('store', () {
    final basis = _request().basis;

    test('the estimate is kept beside the report, across a cold start and '
        'a second save in the session', () async {
      final store = GameAnalysisReportStore.memory();
      final report = _report([
        _at(_start, [_cp(30)]),
      ]);
      final performance = TobyPerformance.fromJson(_body())!;
      await store.save('acct', report);
      await store.saveTobyPerformance(
        'acct',
        'fp-1',
        performance,
        basis: basis,
      );
      await store.flush();

      store.clearHotCacheForTest();
      expect(
        await store.loadTobyPerformance('acct', 'fp-1', basis: basis),
        performance,
      );
      expect(
        await store.loadTobyPerformance('other', 'fp-1', basis: basis),
        isNull,
      );

      await store.save('acct', report);
      await store.flush();
      store.clearHotCacheForTest();
      expect((await store.load('acct', 'fp-1'))?.fingerprint, 'fp-1');
      expect(
        await store.loadTobyPerformance('acct', 'fp-1', basis: basis),
        performance,
      );
    });

    test('another basis (facts, values) never reads it', () async {
      final store = GameAnalysisReportStore.memory();
      final performance = TobyPerformance.fromJson(_body())!;
      await store.save(
        'acct',
        _report([
          _at(_start, [_cp(30)]),
        ]),
      );
      await store.saveTobyPerformance(
        'acct',
        'fp-1',
        performance,
        basis: basis,
      );
      await store.flush();
      final other = _request(whiteRating: 2300).basis;
      expect(
        await store.loadTobyPerformance('acct', 'fp-1', basis: other),
        isNull,
      );
      store.clearHotCacheForTest();
      expect(
        await store.loadTobyPerformance('acct', 'fp-1', basis: other),
        isNull,
      );
    });

    test('an estimate from another model is read again', () {
      final stored = desktopGameReportTobyPerformanceFromJson({
        'tobyPerformance': {..._body(), 'model': 'toby2-level-v0'},
        'tobyPerformanceBasis': basis,
      });
      expect(stored, isNull);
      expect(
        desktopGameReportTobyPerformanceFromJson({'tobyPerformance': _body()}),
        isNull,
      );
    });

    test('an estimate that arrives before its report joins it', () async {
      final store = GameAnalysisReportStore.memory();
      final performance = TobyPerformance.fromJson(_body())!;
      await store.saveTobyPerformance(
        'acct',
        'fp-1',
        performance,
        basis: basis,
      );
      await store.save(
        'acct',
        _report([
          _at(_start, [_cp(30)]),
        ]),
      );
      await store.flush();
      store.clearHotCacheForTest();
      expect(
        await store.loadTobyPerformance('acct', 'fp-1', basis: basis),
        performance,
      );
    });

    test('the session tier is capped', () async {
      final store = GameAnalysisReportStore.memory(hotEntries: 2);
      final performance = TobyPerformance.fromJson(_body())!;
      for (var i = 0; i < 5; i++) {
        await store.saveTobyPerformance(
          'acct',
          'fp-$i',
          performance,
          basis: basis,
        );
      }
      // No report rows exist, so only the session tier could answer.
      expect(
        await store.loadTobyPerformance('acct', 'fp-0', basis: basis),
        isNull,
      );
      expect(
        await store.loadTobyPerformance('acct', 'fp-4', basis: basis),
        performance,
      );
    });
  });

  group('loop', () {
    ProviderContainer container(
      _FakeGamebase repo,
      GameAnalysisReportStore store, {
      bool premium = false,
    }) {
      final container = ProviderContainer(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(repo),
          tobyPerformanceStoreProvider.overrideWithValue(store),
          tobyReaderHasPremiumProvider.overrideWithValue(premium),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    testWidgets('polls through 202 honoring Retry-After, then saves', (
      tester,
    ) async {
      final store = GameAnalysisReportStore.memory();
      final repo = _FakeGamebase(
        (index) =>
            index == 0
                ? _reply(202, {'status': 'pending'}, const Duration(seconds: 2))
                : _reply(200, _body()),
      );
      final c = container(repo, store);
      final provider = tobyPerformanceProvider(_query());
      c.listen(provider, (_, _) {});
      expect(c.read(provider).status, TobyPerformanceStatus.loading);
      await tester.pump();
      expect(repo.calls, hasLength(1));
      expect(repo.calls.single.body['version'], 1);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(repo.calls, hasLength(1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.calls, hasLength(2));
      expect(c.read(provider).status, TobyPerformanceStatus.ready);
      expect(c.read(provider).performance!.black!.display, '2500+');
      expect(tobyPerformanceMemory.lookup(_query()), isNotNull);
    });

    testWidgets('an estimate from the report JSON asks nothing', (
      tester,
    ) async {
      tobyPerformanceMemory.storeFromReport(
        'fp-1',
        TobyPerformance.fromJson(_body())!,
        whiteRating: 2500,
      );
      final repo = _FakeGamebase((_) => _reply(500));
      final c = container(repo, GameAnalysisReportStore.memory());
      final provider = tobyPerformanceProvider(_query());
      c.listen(provider, (_, _) {});
      await tester.pump(const Duration(seconds: 1));
      expect(repo.calls, isEmpty);
      expect(c.read(provider).status, TobyPerformanceStatus.ready);
    });

    testWidgets('a refusal settles the row; a Premium reader re-checks once', (
      tester,
    ) async {
      final repo = _FakeGamebase(
        (_) => _reply(403, {'error': 'premium_required'}),
      );
      final c = container(
        repo,
        GameAnalysisReportStore.memory(),
        premium: true,
      );
      final provider = tobyPerformanceProvider(_query(accountId: null));
      c.listen(provider, (_, _) {});
      await tester.pump(const Duration(seconds: 1));
      expect(repo.calls.map((call) => call.recheckAccess), [false, true]);
      expect(c.read(provider).status, TobyPerformanceStatus.failed);
    });

    testWidgets('gives up after the budget', (tester) async {
      final repo = _FakeGamebase((_) => _reply(503));
      final c = container(repo, GameAnalysisReportStore.memory());
      final provider = tobyPerformanceProvider(_query(accountId: null));
      c.listen(provider, (_, _) {});
      await tester.pump(tobyPerformanceBudget - const Duration(seconds: 1));
      expect(c.read(provider).status, TobyPerformanceStatus.loading);
      await tester.pump(const Duration(seconds: 2));
      expect(c.read(provider).status, TobyPerformanceStatus.failed);
      final count = repo.calls.length;
      await tester.pump(const Duration(seconds: 10));
      expect(repo.calls.length, count);
    });
  });

  group('report view', () {
    final game = ChessGame.fromPgn(
      'toby-row',
      '[White "Ada"]\n[Black "Grace"]\n\n1. e4 e5 *',
    );
    final report = GameAnalysisReport(
      fingerprint: gameReportFingerprint(game),
      positions: [
        _at(game.startingFen, [_cp(30)]),
        _at(game.mainline[0].fen, [_cp(25)]),
        _at(game.mainline[1].fen, [_cp(40)]),
      ],
      moves: [
        GameReportMove(
          ply: 1,
          san: 'e4',
          uci: 'e2e4',
          isWhite: true,
          classification: null,
          evaluation: _cp(25),
        ),
        GameReportMove(
          ply: 2,
          san: 'e5',
          uci: 'e7e5',
          isWhite: false,
          classification: null,
          evaluation: _cp(40),
        ),
      ],
      whiteAccuracy: 90,
      blackAccuracy: 80,
      whiteEstimatedRating: 2050,
      blackEstimatedRating: 1910,
      generatedAt: DateTime.utc(2026),
    );

    Future<void> pump(WidgetTester tester, TobyPerformanceState? toby) =>
        tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 520,
              height: 700,
              child: GameReportView(
                state: GameReportState(
                  status: GameReportStatus.completed,
                  progress: 1,
                  report: report,
                ),
                tobyPerformance: toby,
                game: game,
                headers: const {'White': 'Ada', 'Black': 'Grace'},
                activePly: 0,
                onAnalyze: () async {},
                onCancel: () async {},
                onJumpToPly: null,
              ),
            ),
          ),
        );

    testWidgets('Toby rating sits under Game rating', (tester) async {
      await pump(
        tester,
        TobyPerformanceState.ready(TobyPerformance.fromJson(_body())!),
      );
      expect(find.text('Toby rating'), findsOneWidget);
      expect(find.text('2480'), findsOneWidget);
      expect(find.text('2500+'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Toby rating')).dy,
        greaterThan(tester.getTopLeft(find.text('Game rating')).dy),
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Toby rating: Ada 2480, Grace 2500\+')),
        findsOneWidget,
      );
    });

    testWidgets('placeholder while loading, kept when nothing came, hidden '
        'when unavailable', (tester) async {
      await pump(tester, TobyPerformanceState.loading);
      expect(find.text('Toby rating'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(2));
      await pump(tester, TobyPerformanceState.failed);
      expect(find.text('Toby rating'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(2));
      await pump(tester, TobyPerformanceState.unavailable);
      expect(find.text('Toby rating'), findsNothing);
      await pump(tester, null);
      expect(find.text('Toby rating'), findsNothing);
    });

    testWidgets('the explanation opens on a tap, not only on hover', (
      tester,
    ) async {
      await pump(
        tester,
        TobyPerformanceState.ready(TobyPerformance.fromJson(_body())!),
      );
      expect(find.textContaining('how human the moves were'), findsNothing);
      await tester.tap(find.text('Toby rating'));
      await tester.pumpAndSettle();
      expect(find.textContaining('how human the moves were'), findsOneWidget);
    });
  });
}
