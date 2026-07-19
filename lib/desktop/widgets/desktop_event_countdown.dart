import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/event_card/event_next_round_provider.dart';

/// One shared clock drives every visible desktop event countdown.
final _desktopEventCountdownTickProvider = StreamProvider.autoDispose<DateTime>(
  (ref) => Stream<DateTime>.periodic(
    const Duration(seconds: 1),
    (_) => DateTime.now(),
  ),
);

class DesktopEventCountdownLine extends ConsumerWidget {
  const DesktopEventCountdownLine({required this.event, super.key});

  final GroupEventCardModel event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (event.eventSource != EventSource.lichessBroadcast ||
        event.tourEventCategory == TourEventCategory.completed ||
        event.tourEventCategory == TourEventCategory.live) {
      return const SizedBox.shrink();
    }

    final nextRound = ref.watch(eventNextRoundProvider(event.id)).valueOrNull;
    if (nextRound == null) return const SizedBox.shrink();

    var now = DateTime.now();
    var remaining = nextRound.startsAt.difference(now);
    if (remaining <= Duration.zero) return const SizedBox.shrink();

    if (remaining < const Duration(hours: 24)) {
      now = ref.watch(_desktopEventCountdownTickProvider).valueOrNull ?? now;
      remaining = nextRound.startsAt.difference(now);
      if (remaining <= Duration.zero) return const SizedBox.shrink();
    }

    final label = desktopRoundStartLabel(
      roundName: nextRound.name,
      startsAt: nextRound.startsAt,
      now: now,
    );
    if (label.isEmpty) return const SizedBox.shrink();

    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kPrimaryColor,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        fontFeatures: [FontFeature.tabularFigures()],
        height: 1.2,
      ),
    );
  }
}

@visibleForTesting
String desktopRoundStartLabel({
  required String roundName,
  required DateTime startsAt,
  required DateTime now,
}) {
  final remaining = startsAt.difference(now);
  if (remaining <= Duration.zero) return '';

  final cleanRoundName = roundName.trim();
  final prefix = cleanRoundName.isEmpty ? '' : '$cleanRoundName · ';
  if (remaining < const Duration(hours: 24)) {
    return '${prefix}starts in ${desktopEventCountdownText(remaining)}';
  }
  return '${prefix}starts ${_desktopEventAbsoluteTime(startsAt, now)}';
}

@visibleForTesting
String desktopEventCountdownText(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 24 * 3600);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;

  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

String _desktopEventAbsoluteTime(DateTime startsAt, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final startDay = DateTime(startsAt.year, startsAt.month, startsAt.day);
  final dayDelta = startDay.difference(today).inDays;
  final time = '${_twoDigits(startsAt.hour)}:${_twoDigits(startsAt.minute)}';

  if (dayDelta == 1) return 'tomorrow $time';

  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final weekday = weekdays[(startsAt.weekday - 1).clamp(0, 6)];
  final month = months[(startsAt.month - 1).clamp(0, 11)];
  if (startsAt.year == now.year) {
    return '$weekday $month ${startsAt.day}, $time';
  }
  return '$weekday $month ${startsAt.day}, ${startsAt.year}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
