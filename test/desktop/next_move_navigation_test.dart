import 'dart:convert';

import 'package:chessever/desktop/widgets/next_move_ribbon.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _BusyGamebase extends GamebaseRepository {
  _BusyGamebase() : super(Dio(), baseUrl: 'http://example.test');

  final requestedPositions = <int>[];

  @override
  Future<({bool pending, Map<String, dynamic>? data})> getNextMove(
    Map<String, dynamic> input,
    CancelToken cancelToken,
  ) async {
    requestedPositions.add(input['ply'] as int);
    if (requestedPositions.length < 6) return (pending: true, data: null);
    return (
      pending: false,
      data: {
        'moves': [
          {'uci': 'e2e4', 'san': 'e4', 'probability': 0.5},
        ],
        'otherProbability': 0.5,
      },
    );
  }
}

void main() {
  testWidgets('rapid moves settle and the final position retries when busy', (
    tester,
  ) async {
    final repo = _BusyGamebase();
    final container = ProviderContainer(
      overrides: [gamebaseRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    for (var ply = 0; ply < 12; ply++) {
      final provider = nextMovePredictionProvider(jsonEncode({'ply': ply}));
      final visit = container.listen(provider, (_, _) {});
      await tester.pump(const Duration(milliseconds: 35));
      visit.close();
    }
    expect(repo.requestedPositions, isEmpty);

    final settled = nextMovePredictionProvider(jsonEncode({'ply': 12}));
    final visit = container.listen(settled, (_, _) {});
    addTearDown(visit.close);
    for (var i = 0; i < 20 && container.read(settled).isLoading; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(repo.requestedPositions, List.filled(6, 12));
    expect(container.read(settled).valueOrNull?.first.san, 'e4');
    container.dispose();
  });

  testWidgets('closing a board cancels a pending prediction retry', (
    tester,
  ) async {
    final repo = _BusyGamebase();
    final container = ProviderContainer(
      overrides: [gamebaseRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final provider = nextMovePredictionProvider(jsonEncode({'ply': 42}));
    container.listen(provider, (_, _) {});
    await tester.pump(const Duration(milliseconds: 180));
    expect(repo.requestedPositions, [42]);

    container.dispose();
    await tester.pump();
    expect(repo.requestedPositions, [42]);
  });
}
