import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const nextMoveRibbonHeight = 82.0;
const _busyRetriesMs = [250, 500, 750];
const _colors = [Color(0xFF83C7C4), Color(0xFF9AADD1), Color(0xFFD5B487)];

class NextMoveCandidate {
  const NextMoveCandidate(this.uci, this.san, this.probability, this.color);

  final String? uci;
  final String san;
  final double probability;
  final Color color;

  String get percentage =>
      probability > 0 && probability < .001
          ? '<0.1%'
          : '${(probability * 100).toStringAsFixed(1)}%';
}

final nextMovePredictionProvider = FutureProvider.autoDispose
    .family<List<NextMoveCandidate>, String>((ref, request) async {
      final cancellation = CancelToken();
      ref.onDispose(() => cancellation.cancel());
      final repo = ref.read(gamebaseRepositoryProvider);
      final payload = jsonDecode(request) as Map<String, dynamic>;
      final deadline = Timer(const Duration(seconds: 4), cancellation.cancel);
      ref.onDispose(deadline.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      for (
        var attempt = 0;
        attempt <= _busyRetriesMs.length && !cancellation.isCancelled;
        attempt++
      ) {
        final reply = await repo.getNextMove(payload, cancellation);
        if (!reply.pending || cancellation.isCancelled) {
          deadline.cancel();
          final json = reply.data;
          final raw = json?['moves'];
          final other = json?['otherProbability'];
          if (raw is! List ||
              raw.isEmpty ||
              raw.length > 3 ||
              other is! num ||
              !other.isFinite ||
              other < 0 ||
              other > 1) {
            return const [];
          }
          final result = <NextMoveCandidate>[];
          for (final (rank, row) in raw.indexed) {
            if (row is! Map) return const [];
            final uci = row['uci'];
            final san = row['san'];
            final chance = row['probability'];
            if (uci is! String ||
                !_uci.hasMatch(uci) ||
                san is! String ||
                chance is! num ||
                !chance.isFinite ||
                chance < 0 ||
                chance > 1) {
              return const [];
            }
            result.add(
              NextMoveCandidate(uci, san, chance.toDouble(), _colors[rank]),
            );
          }
          if (other > 0) {
            result.add(
              NextMoveCandidate(
                null,
                'Other',
                other.toDouble(),
                const Color(0xFF93969B),
              ),
            );
          }
          final lease = ref.keepAlive();
          final timer = Timer(const Duration(minutes: 2), lease.close);
          ref.onDispose(timer.cancel);
          return result;
        }
        if (attempt < _busyRetriesMs.length) {
          await Future<void>.delayed(
            Duration(milliseconds: _busyRetriesMs[attempt]),
          );
        }
      }
      deadline.cancel();
      return const [];
    });

final _uci = RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$');

String nextMoveCadence(String? category, String? timeControl) {
  final speed = category?.toLowerCase() ?? '';
  if (speed.contains('bullet')) return 'blitz';
  if (speed.contains('blitz') || speed.contains('rapid')) {
    return speed.contains('blitz') ? 'blitz' : 'rapid';
  }
  if (speed.contains('classical') || speed.contains('standard')) {
    return 'classical';
  }
  final tag = RegExp(
    r'^(\d+)(?:\s*\+\s*(\d+))?$',
  ).firstMatch(timeControl ?? '');
  if (tag == null) return 'classical';
  final seconds = int.parse(tag[1]!) + 40 * (int.tryParse(tag[2] ?? '') ?? 0);
  if (seconds <= 600) return 'blitz';
  return seconds < 3600 ? 'rapid' : 'classical';
}

class DesktopNextMoveRibbon extends StatelessWidget {
  const DesktopNextMoveRibbon({
    super.key,
    required this.moves,
    required this.selectedUci,
    required this.onSelect,
  });

  final List<NextMoveCandidate> moves;
  final String? selectedUci;
  final ValueChanged<NextMoveCandidate?> onSelect;

  Widget _move(NextMoveCandidate move, {required bool inside}) {
    final color = inside ? const Color(0xFF141819) : kWhiteColor;
    final active = move.uci != null && selectedUci == move.uci;
    final label = [
      Text(
        move.san,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
      Text(move.percentage, style: TextStyle(fontSize: 11, color: color)),
    ];
    final content =
        inside
            ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: label,
            )
            : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 6,
                  child: ColoredBox(color: move.color),
                ),
                const SizedBox(width: 4),
                label.first,
                const SizedBox(width: 4),
                label.last,
              ],
            );
    if (move.uci == null) return Center(child: content);
    return Semantics(
      selected: active,
      child: TextButton(
        onPressed: () => onSelect(active ? null : move),
        style: TextButton.styleFrom(
          foregroundColor: color,
          backgroundColor: active ? color.withValues(alpha: .12) : null,
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const RoundedRectangleBorder(),
        ),
        child: content,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBlack2Color,
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 3),
      child: LayoutBuilder(
        builder: (context, constraints) {
          bool fits(NextMoveCandidate move) =>
              move.probability * constraints.maxWidth >=
              (move.san.length > 5 ? 54 : 39);
          final omitted = moves.where(
            (move) => move.probability > 0 && !fits(move),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Next move',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: kWhiteColor,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 34,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final move in moves.where(
                      (move) => move.probability > 0,
                    ))
                      Expanded(
                        flex: math.max(1, (move.probability * 100000).round()),
                        child: ColoredBox(
                          color: move.color,
                          child:
                              fits(move)
                                  ? _move(move, inside: true)
                                  : const SizedBox(),
                        ),
                      ),
                  ],
                ),
              ),
              if (omitted.isNotEmpty)
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 8,
                      children: [
                        for (final move in omitted) _move(move, inside: false),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
