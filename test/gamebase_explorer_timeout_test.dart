import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _FailingGamebaseRepository extends GamebaseRepository {
  _FailingGamebaseRepository() : super(Dio(), baseUrl: 'http://localhost');

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
    throw Exception('scripted aggregate failure');
  }
}

void main() {
  test(
    'aggregate failures update state without leaking cleanup errors',
    () async {
      final container = ProviderContainer(
        overrides: [
          gamebaseRepositoryProvider.overrideWithValue(
            _FailingGamebaseRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        gamebaseExplorerProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await container.read(gamebaseExplorerProvider.notifier).refresh();
      await Future<void>.delayed(Duration.zero);

      final state = container.read(gamebaseExplorerProvider);
      expect(state.isLoading, isFalse);
      expect(state.error, contains('scripted aggregate failure'));
    },
  );
}
