import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _startingFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class _AggregateCall {
  const _AggregateCall({
    required this.fen,
    required this.moves,
    this.playerId,
    this.timeControl,
    this.minRating,
    this.maxRating,
    this.color,
    this.result,
    this.yearFrom,
    this.yearTo,
    this.isOnline,
  });

  final String fen;
  final List<String> moves;
  final String? playerId;
  final TimeControl? timeControl;
  final int? minRating;
  final int? maxRating;
  final String? color;
  final String? result;
  final int? yearFrom;
  final int? yearTo;
  final bool? isOnline;
}

class _CapturingGamebaseRepository extends GamebaseRepository {
  _CapturingGamebaseRepository() : super(Dio(), baseUrl: 'http://localhost');

  final aggregateCalls = <_AggregateCall>[];

  @override
  Future<GamebaseResponse> getMoveAggregates({
    required String fen,
    List<String> moves = const [],
    String? playerId,
    TimeControl? timeControl,
    int? minRating,
    int? maxRating,
    String? color,
    String? result,
    int? yearFrom,
    int? yearTo,
    bool? isOnline,
  }) async {
    aggregateCalls.add(
      _AggregateCall(
        fen: fen,
        moves: List<String>.from(moves),
        playerId: playerId,
        timeControl: timeControl,
        minRating: minRating,
        maxRating: maxRating,
        color: color,
        result: result,
        yearFrom: yearFrom,
        yearTo: yearTo,
        isOnline: isOnline,
      ),
    );

    return const GamebaseResponse(
      status: 'success',
      data: GamebaseData(moves: []),
    );
  }
}

void main() {
  test(
    'player build-tree seed scopes aggregate query to player games',
    () async {
      final repository = _CapturingGamebaseRepository();
      final container = ProviderContainer(
        overrides: [gamebaseRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        gamebaseExplorerProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      const playerId = 'player-uuid';
      const player = GamebasePlayer(
        id: playerId,
        fideId: '1503014',
        name: 'Carlsen, Magnus',
        gender: PlayerGender.male,
        fed: 'NOR',
        title: 'GM',
        ratingClassical: 2830,
      );
      const scopedFilters = GamebaseFilters(
        playerIds: [playerId],
        selectedPlayers: [player],
        timeControls: [TimeControl.blitz],
        minRating: 2400,
        maxRating: 2900,
        playerColor: GamebasePlayerColor.white,
        gameResult: GamebaseGameResult.whiteWins,
        yearFrom: 2019,
        yearTo: 2025,
        isOnline: true,
      );

      final notifier = container.read(gamebaseExplorerProvider.notifier);
      notifier.updateFilters(scopedFilters);
      notifier.setPositionWithMoves(_startingFen, const <String>[]);
      await notifier.refresh();

      expect(repository.aggregateCalls, isNotEmpty);
      final call = repository.aggregateCalls.last;
      expect(call.fen, _startingFen);
      expect(call.moves, isEmpty);
      expect(call.playerId, player.id);
      expect(call.timeControl, TimeControl.blitz);
      expect(call.minRating, 2400);
      expect(call.maxRating, 2900);
      expect(call.color, 'white');
      expect(call.result, 'W');
      expect(call.yearFrom, 2019);
      expect(call.yearTo, 2025);
      expect(call.isOnline, isTrue);
    },
  );
}
