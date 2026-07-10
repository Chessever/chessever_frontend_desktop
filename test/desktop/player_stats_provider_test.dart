import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_stats.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_stats_repository.dart';
import 'package:chessever/desktop/state/player_stats_provider.dart';

void main() {
  const request = PlayerStatsRequest(
    databasePath: '/tmp/player-source.pgn',
    aliases: <String>['Player'],
  );

  test('switching source cancels an unfinished stats request', () async {
    final repository = _TestPlayerStatsRepository(blockUntilCanceled: true);
    final container = ProviderContainer(
      overrides: <Override>[
        playerStatsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    final subscription = container.listen(
      playerStatsProvider(request),
      (_, _) {},
      fireImmediately: true,
    );
    await repository.started.future;
    subscription.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(repository.tokens, hasLength(1));
    expect(repository.tokens.single.isCanceled, isTrue);
  });

  test('a completed source snapshot is reused when switching back', () async {
    final repository = _TestPlayerStatsRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        playerStatsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final provider = playerStatsProvider(request);

    final first = container.listen(provider, (_, _) {}, fireImmediately: true);
    await container.read(provider.future);
    first.close();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final second = container.listen(provider, (_, _) {}, fireImmediately: true);
    await container.read(provider.future);
    second.close();

    expect(repository.calls, 1);
  });
}

class _TestPlayerStatsRepository extends PlayerStatsRepository {
  _TestPlayerStatsRepository({this.blockUntilCanceled = false})
    : super(database: () async => throw UnimplementedError());

  final bool blockUntilCanceled;
  final Completer<void> started = Completer<void>();
  final List<OperationCancellationToken> tokens =
      <OperationCancellationToken>[];
  int calls = 0;

  @override
  Future<PlayerStatsSnapshot> computePlayerStats({
    required String databasePath,
    required Iterable<String> aliases,
    String? playerFideId,
    int? windowDays,
    String? timeControlCategory,
    String? preferredRatingTimeControl,
    String? unclassifiedTimeControlCategory,
    PlayerStatsOutcomeFilter playerOutcome = PlayerStatsOutcomeFilter.all,
    String? playerColor,
    OperationCancellationToken? cancellationToken,
  }) async {
    calls++;
    final token = cancellationToken!;
    tokens.add(token);
    if (!started.isCompleted) started.complete();
    if (blockUntilCanceled) {
      await token.whenCanceled;
      token.throwIfCanceled();
    }
    return PlayerStatsSnapshot.empty;
  }
}
