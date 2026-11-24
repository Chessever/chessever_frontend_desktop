import 'dart:async';

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:dio/dio.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

typedef EnginePlayedPosition = ({String fen, String line});

class EnginePlayed {
  const EnginePlayed(this.counts, this.total);

  final Map<String, int> counts;
  final int total;

  String? labelFor(String? uci, {bool isCastling = false}) {
    if (uci == null || total <= 0) return null;
    final alternate =
        isCastling ? GamebaseRepository.alternateCastlingUci(uci) : null;
    final percent = (counts[uci] ?? counts[alternate] ?? 0) / total * 100;
    return percent > 0 && percent < 0.1
        ? '<0.1%'
        : '${percent.toStringAsFixed(1)}%';
  }
}

final enginePlayedProvider = FutureProvider.autoDispose
    .family<EnginePlayed?, EnginePlayedPosition>((ref, position) async {
      final repository = ref.watch(gamebaseRepositoryProvider);
      if (!repository.isConfigured) return null;
      final cancellation = CancelToken();
      ref.onDispose(cancellation.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (cancellation.isCancelled) return null;

      final response = await repository.getEngineMoveAggregates(
        fen: position.fen,
        moves: position.line.isEmpty ? const [] : position.line.split(' '),
        cancelToken: cancellation,
      );
      if (cancellation.isCancelled) return null;
      final counts = {
        for (final move in response.data.moves) move.uci: move.total,
      };
      final total = counts.values.fold(0, (sum, count) => sum + count);
      final lease = ref.keepAlive();
      final timer = Timer(const Duration(minutes: 2), lease.close);
      ref.onDispose(timer.cancel);
      return total > 0 ? EnginePlayed(Map.unmodifiable(counts), total) : null;
    });
