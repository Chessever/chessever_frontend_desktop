import 'dart:convert';
import 'dart:io';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opening Explorer filter axes sent on aggregates + position-games requests.
///
/// Defaults (`timeControls=[]`, rating/year null, isOnline/result/color null)
/// are omitted. Listed UI values:
/// timeControl: classical, rapid, blitz, bullet, ultrabullet
/// rating: default vs 2400-2800
/// year: default vs 2018-2024
/// isOnline: all, online, otb
/// result: all, whiteWins, blackWins, draw
/// color: all, white, black
const _startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const _deepMoves = <String>['e2e4'];

const _filterKeys = <String>{
  'playerId',
  'timeControl',
  'minRating',
  'maxRating',
  'yearFrom',
  'yearTo',
  'isOnline',
  'result',
  'color',
};

class _AxisValue {
  const _AxisValue({
    required this.axis,
    required this.label,
    this.timeControl,
    this.minRating,
    this.maxRating,
    this.yearFrom,
    this.yearTo,
    this.isOnline,
    this.result,
    this.color,
    this.playerId,
  });

  final String axis;
  final String label;
  final TimeControl? timeControl;
  final int? minRating;
  final int? maxRating;
  final int? yearFrom;
  final int? yearTo;
  final bool? isOnline;
  final GamebaseGameResult? result;
  final GamebasePlayerColor? color;
  final String? playerId;

  GamebaseFilters apply(GamebaseFilters filters) {
    return filters.copyWith(
      timeControls:
          timeControl != null
              ? <TimeControl>[timeControl!]
              : filters.timeControls,
      minRating: minRating ?? filters.minRating,
      maxRating: maxRating ?? filters.maxRating,
      yearFrom: yearFrom ?? filters.yearFrom,
      yearTo: yearTo ?? filters.yearTo,
      isOnline: isOnline ?? filters.isOnline,
      gameResult: result ?? filters.gameResult,
      playerColor: color ?? filters.playerColor,
      playerIds: playerId != null ? <String>[playerId!] : filters.playerIds,
    );
  }

  Map<String, dynamic> expectedFields() {
    return <String, dynamic>{
      if (timeControl != null) 'timeControl': timeControl!.name.toUpperCase(),
      if (minRating != null) 'minRating': minRating,
      if (maxRating != null) 'maxRating': maxRating,
      if (yearFrom != null) 'yearFrom': yearFrom,
      if (yearTo != null) 'yearTo': yearTo,
      if (isOnline != null) 'isOnline': isOnline,
      if (result != null) 'result': result!.apiValue,
      if (color != null) 'color': color!.name,
      if (playerId != null) 'playerId': playerId,
    };
  }
}

class _Case {
  _Case({
    required this.kind,
    required this.parts,
    required this.filters,
    required this.expected,
  });

  final String kind;
  final List<String> parts;
  final GamebaseFilters filters;
  final Map<String, dynamic> expected;

  String get name => '$kind ${parts.join(' + ')}';
}

const _timeControlValues = <_AxisValue>[
  _AxisValue(
    axis: 'timeControl',
    label: 'timeControl=CLASSICAL',
    timeControl: TimeControl.classical,
  ),
  _AxisValue(
    axis: 'timeControl',
    label: 'timeControl=RAPID',
    timeControl: TimeControl.rapid,
  ),
  _AxisValue(
    axis: 'timeControl',
    label: 'timeControl=BLITZ',
    timeControl: TimeControl.blitz,
  ),
  _AxisValue(
    axis: 'timeControl',
    label: 'timeControl=BULLET',
    timeControl: TimeControl.bullet,
  ),
  _AxisValue(
    axis: 'timeControl',
    label: 'timeControl=ULTRABULLET',
    timeControl: TimeControl.ultrabullet,
  ),
];

const _ratingValues = <_AxisValue>[
  _AxisValue(
    axis: 'rating',
    label: 'rating=2400-2800',
    minRating: 2400,
    maxRating: 2800,
  ),
];

const _yearValues = <_AxisValue>[
  _AxisValue(
    axis: 'year',
    label: 'year=2018-2024',
    yearFrom: 2018,
    yearTo: 2024,
  ),
];

const _isOnlineValues = <_AxisValue>[
  _AxisValue(axis: 'isOnline', label: 'isOnline=true', isOnline: true),
  _AxisValue(axis: 'isOnline', label: 'isOnline=false', isOnline: false),
];

const _resultValues = <_AxisValue>[
  _AxisValue(
    axis: 'result',
    label: 'result=W',
    result: GamebaseGameResult.whiteWins,
  ),
  _AxisValue(
    axis: 'result',
    label: 'result=B',
    result: GamebaseGameResult.blackWins,
  ),
  _AxisValue(
    axis: 'result',
    label: 'result=D',
    result: GamebaseGameResult.draw,
  ),
];

const _colorValues = <_AxisValue>[
  _AxisValue(
    axis: 'color',
    label: 'color=white',
    color: GamebasePlayerColor.white,
  ),
  _AxisValue(
    axis: 'color',
    label: 'color=black',
    color: GamebasePlayerColor.black,
  ),
];

const _playerValues = <_AxisValue>[
  _AxisValue(
    axis: 'playerId',
    label: 'playerId=bluebaum',
    playerId: 'bluebaum',
  ),
];

const _allAxes = <List<_AxisValue>>[
  _timeControlValues,
  _ratingValues,
  _yearValues,
  _isOnlineValues,
  _resultValues,
  _colorValues,
  _playerValues,
];

_Case _caseFrom(String kind, List<_AxisValue> values) {
  var filters = const GamebaseFilters();
  final expected = <String, dynamic>{};
  final parts = <String>[];
  for (final value in values) {
    filters = value.apply(filters);
    expected.addAll(value.expectedFields());
    parts.add(value.label);
  }
  return _Case(kind: kind, parts: parts, filters: filters, expected: expected);
}

List<_Case> _generateExplorerFilterMatrix() {
  final cases = <_Case>[];

  for (final axis in _allAxes) {
    for (final value in axis) {
      cases.add(_caseFrom('single', [value]));
    }
  }

  for (var i = 0; i < _allAxes.length; i++) {
    for (var j = i + 1; j < _allAxes.length; j++) {
      for (final left in _allAxes[i]) {
        for (final right in _allAxes[j]) {
          cases.add(_caseFrom('pair', [left, right]));
        }
      }
    }
  }

  return cases;
}

Map<String, dynamic> _filterSlice(Map<String, dynamic> request) {
  return <String, dynamic>{
    for (final key in _filterKeys)
      if (request.containsKey(key)) key: request[key],
  };
}

Map<String, dynamic> _aggregatesBody(GamebaseFilters filters) {
  return buildMoveAggregatesQueryBody(
    fen: _startFen,
    moves: const [],
    timeControl: filters.requestTimeControl,
    playerId: filters.requestPlayerId,
    minRating: filters.minRating,
    maxRating: filters.maxRating,
    color: filters.requestColor,
    result: filters.requestResult,
    yearFrom: filters.yearFrom,
    yearTo: filters.yearTo,
    isOnline: filters.isOnline,
  );
}

Map<String, dynamic> _gamesBody(GamebaseFilters filters) {
  return buildPositionGamesQueryBody(
    fen: _startFen,
    moves: _deepMoves,
    timeControl: filters.requestTimeControl,
    playerId: filters.requestPlayerId,
    minRating: filters.minRating,
    maxRating: filters.maxRating,
    color: filters.requestColor,
    result: filters.requestResult,
    yearFrom: filters.yearFrom,
    yearTo: filters.yearTo,
    isOnline: filters.isOnline,
    sortBy: filters.sortBy,
    sortDirection: filters.sortDirection,
  );
}

Map<String, dynamic> _gamesParams(GamebaseFilters filters) {
  return buildPositionGamesQueryParameters(
    fen: _startFen,
    timeControl: filters.requestTimeControl,
    playerId: filters.requestPlayerId,
    minRating: filters.minRating,
    maxRating: filters.maxRating,
    color: filters.requestColor,
    result: filters.requestResult,
    yearFrom: filters.yearFrom,
    yearTo: filters.yearTo,
    isOnline: filters.isOnline,
    sortBy: filters.sortBy,
    sortDirection: filters.sortDirection,
  );
}

void _assertAndCombined(_Case c, Map<String, dynamic> request, String shape) {
  final reason = '${c.name} $shape';
  expect(request.containsKey('or'), isFalse, reason: reason);
  expect(request.containsKey('and'), isFalse, reason: reason);
  expect(_filterSlice(request), c.expected, reason: reason);

  for (final key in c.expected.keys) {
    expect(request.containsKey(key), isTrue, reason: '$reason missing $key');
    expect(request[key], c.expected[key], reason: '$reason $key');
  }

  for (final key in _filterKeys.difference(c.expected.keys.toSet())) {
    expect(request.containsKey(key), isFalse, reason: '$reason extra $key');
  }
}

class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;
  Map<String, dynamic>? lastBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    if (options.data is Map<String, dynamic>) {
      lastBody = Map<String, dynamic>.from(options.data as Map);
    }
    final isAggregates = options.path.contains('aggregates');
    final payload =
        isAggregates
            ? '{"status":"success","data":{"moves":[]}}'
            : '{"status":"success","data":[],"metadata":{"pageNumber":0,"pageSize":20,"hasMore":false}}';
    return ResponseBody.fromString(
      payload,
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  final cases = _generateExplorerFilterMatrix();

  test('explorer matrix enumerates every axis and every pair', () {
    expect(cases.where((c) => c.kind == 'single').length, 15);
    expect(cases.where((c) => c.kind == 'pair').length, 90);
    expect(cases.length, 105);
    expect(_allAxes.map((axis) => axis.first.axis).toList(), [
      'timeControl',
      'rating',
      'year',
      'isOnline',
      'result',
      'color',
      'playerId',
    ]);
  });

  test('empty GamebaseFilters omits every filter axis', () {
    const filters = GamebaseFilters();
    for (final request in [
      _aggregatesBody(filters),
      _gamesBody(filters),
      _gamesParams(filters),
    ]) {
      expect(_filterSlice(request), isEmpty);
      expect(request.containsKey('or'), isFalse);
      expect(request.containsKey('and'), isFalse);
    }
  });

  test('all seven axes AND-combine on aggregates and position games', () {
    const filters = GamebaseFilters(
      playerIds: <String>['bluebaum'],
      timeControls: [TimeControl.classical],
      minRating: 2400,
      maxRating: 2800,
      yearFrom: 2018,
      yearTo: 2024,
      isOnline: false,
      gameResult: GamebaseGameResult.draw,
      playerColor: GamebasePlayerColor.white,
    );
    final expected = <String, dynamic>{
      'playerId': 'bluebaum',
      'timeControl': 'CLASSICAL',
      'minRating': 2400,
      'maxRating': 2800,
      'yearFrom': 2018,
      'yearTo': 2024,
      'isOnline': false,
      'result': 'D',
      'color': 'white',
    };
    for (final request in [
      _aggregatesBody(filters),
      _gamesBody(filters),
      _gamesParams(filters),
    ]) {
      expect(_filterSlice(request), expected);
      expect(request.containsKey('or'), isFalse);
      expect(request.containsKey('and'), isFalse);
    }
  });

  test('shipped explorer sources still AND-combine every filter axis', () {
    final repository =
        File(
          'lib/repository/gamebase/gamebase_repository.dart',
        ).readAsStringSync();
    final providers =
        File(
          'lib/screens/gamebase/providers/gamebase_providers.dart',
        ).readAsStringSync();
    final sheet =
        File(
          'lib/screens/gamebase/widgets/position_games_sheet.dart',
        ).readAsStringSync();

    expect(repository, contains('buildMoveAggregatesQueryBody'));
    expect(repository, contains('buildPositionGamesQueryBody'));
    expect(repository, contains('buildPositionGamesQueryParameters'));
    expect(repository, contains('buildGamebaseExplorerFilterFields'));
    expect(providers, contains('filters.requestTimeControl'));
    expect(providers, contains('filters.requestPlayerId'));
    expect(providers, contains('filters.requestColor'));
    expect(providers, contains('filters.requestResult'));
    expect(providers, contains('filters.minRating'));
    expect(providers, contains('filters.maxRating'));
    expect(providers, contains('filters.yearFrom'));
    expect(providers, contains('filters.yearTo'));
    expect(providers, contains('filters.isOnline'));
    expect(sheet, contains('widget.filters.requestTimeControl'));
    expect(sheet, contains('widget.filters.requestColor'));
    expect(sheet, contains('widget.filters.requestResult'));
    expect(sheet, contains('widget.filters.minRating'));
    expect(sheet, contains('widget.filters.yearFrom'));
    expect(sheet, contains('widget.filters.isOnline'));
  });

  test('getMoveAggregates posts the shipped aggregates body', () async {
    final adapter = _CapturingAdapter();
    final repo = GamebaseRepository(
      Dio()..httpClientAdapter = adapter,
      baseUrl: 'http://test',
    );
    const filters = GamebaseFilters(
      timeControls: [TimeControl.rapid],
      minRating: 2400,
      maxRating: 2800,
      yearFrom: 2018,
      yearTo: 2024,
      isOnline: true,
      gameResult: GamebaseGameResult.whiteWins,
      playerColor: GamebasePlayerColor.black,
    );

    await repo.getMoveAggregates(
      fen: _startFen,
      timeControl: filters.requestTimeControl,
      minRating: filters.minRating,
      maxRating: filters.maxRating,
      color: filters.requestColor,
      result: filters.requestResult,
      yearFrom: filters.yearFrom,
      yearTo: filters.yearTo,
      isOnline: filters.isOnline,
    );

    expect(adapter.lastRequest?.method, 'POST');
    expect(
      adapter.lastRequest?.path,
      contains('/api/game-position/aggregates/query'),
    );
    expect(adapter.lastBody, _aggregatesBody(filters));
  });

  test('getPositionGames posts the shipped games query body', () async {
    final adapter = _CapturingAdapter();
    final repo = GamebaseRepository(
      Dio()..httpClientAdapter = adapter,
      baseUrl: 'http://test',
    );
    final afterE2e4Fen = Chess.initial.play(NormalMove.fromUci('e2e4')).fen;
    const filters = GamebaseFilters(
      timeControls: [TimeControl.blitz],
      minRating: 2400,
      yearTo: 2024,
      isOnline: false,
      gameResult: GamebaseGameResult.blackWins,
      playerColor: GamebasePlayerColor.white,
    );
    final expectedBody = buildPositionGamesQueryBody(
      fen: afterE2e4Fen,
      moves: _deepMoves,
      timeControl: filters.requestTimeControl,
      playerId: filters.requestPlayerId,
      minRating: filters.minRating,
      maxRating: filters.maxRating,
      color: filters.requestColor,
      result: filters.requestResult,
      yearFrom: filters.yearFrom,
      yearTo: filters.yearTo,
      isOnline: filters.isOnline,
      sortBy: filters.sortBy,
      sortDirection: filters.sortDirection,
    );

    await repo.getPositionGames(
      fen: afterE2e4Fen,
      moves: _deepMoves,
      timeControl: filters.requestTimeControl,
      minRating: filters.minRating,
      maxRating: filters.maxRating,
      color: filters.requestColor,
      result: filters.requestResult,
      yearFrom: filters.yearFrom,
      yearTo: filters.yearTo,
      isOnline: filters.isOnline,
      sortBy: filters.sortBy,
      sortDirection: filters.sortDirection,
    );

    expect(adapter.lastRequest?.method, 'POST');
    expect(
      adapter.lastRequest?.path,
      contains('/api/game-position/games/query'),
    );
    expect(adapter.lastBody, expectedBody);
    expect(_filterSlice(adapter.lastBody!), {
      'timeControl': 'BLITZ',
      'minRating': 2400,
      'yearTo': 2024,
      'isOnline': false,
      'result': 'B',
      'color': 'white',
    });
  });

  test(
    'getPositionGames GET query params AND-combine the same filters',
    () async {
      final adapter = _CapturingAdapter();
      final repo = GamebaseRepository(
        Dio()..httpClientAdapter = adapter,
        baseUrl: 'http://test',
      );
      const filters = GamebaseFilters(
        timeControls: [TimeControl.classical],
        maxRating: 2800,
        yearFrom: 2018,
        isOnline: true,
        gameResult: GamebaseGameResult.draw,
        playerColor: GamebasePlayerColor.black,
      );

      await repo.getPositionGames(
        fen: _startFen,
        timeControl: filters.requestTimeControl,
        minRating: filters.minRating,
        maxRating: filters.maxRating,
        color: filters.requestColor,
        result: filters.requestResult,
        yearFrom: filters.yearFrom,
        yearTo: filters.yearTo,
        isOnline: filters.isOnline,
        sortBy: filters.sortBy,
        sortDirection: filters.sortDirection,
      );

      expect(adapter.lastRequest?.method, 'GET');
      expect(adapter.lastRequest?.path, contains('/api/game-position/games'));
      expect(
        Map<String, dynamic>.from(adapter.lastRequest!.queryParameters),
        _gamesParams(filters),
      );
    },
  );

  for (final c in cases) {
    test(c.name, () {
      final aggregates = _aggregatesBody(c.filters);
      final gamesBody = _gamesBody(c.filters);
      final gamesParams = _gamesParams(c.filters);

      _assertAndCombined(c, aggregates, 'aggregates');
      _assertAndCombined(c, gamesBody, 'games/query');
      _assertAndCombined(c, gamesParams, 'games GET');

      expect(_filterSlice(aggregates), _filterSlice(gamesBody), reason: c.name);
      expect(
        _filterSlice(gamesBody),
        _filterSlice(gamesParams),
        reason: c.name,
      );

      final encoded = jsonEncode({
        'aggregates': aggregates,
        'gamesBody': gamesBody,
        'gamesParams': gamesParams,
      });
      expect(encoded.contains('"or"'), isFalse, reason: c.name);
      expect(encoded, isNot(contains('ilike')), reason: c.name);
    });
  }
}
