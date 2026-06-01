import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/play_tournament_history_repository.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/theme/app_theme.dart';

class PlayEventsPane extends ConsumerWidget {
  const PlayEventsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventsAsync = ref.watch(playedTournamentEventsProvider);
    return FTheme(
      data: FThemes.zinc.dark,
      child: eventsAsync.when(
        loading:
            () => const Center(
              child: CircularProgressIndicator(color: kPrimaryColor),
            ),
        error:
            (error, _) => _EventsError(
              message: 'Events could not load: $error',
              onRetry: () => ref.invalidate(playedTournamentEventsProvider),
            ),
        data: (events) => _EventsBody(events: events),
      ),
    );
  }
}

class _EventsBody extends StatelessWidget {
  const _EventsBody({required this.events});

  final List<PlayedTournamentEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const _EmptyEvents();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(40, 34, 40, 40),
      itemCount: events.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _EventCard(event: events[index]),
    );
  }
}

class _EmptyEvents extends StatelessWidget {
  const _EmptyEvents();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_available_outlined,
              color: kSecondaryTextColor,
              size: 56,
            ),
            SizedBox(height: 14),
            Text(
              'No events played yet',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 7),
            Text(
              'Created tournaments will appear here with their local event records.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kSecondaryTextColor,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventsError extends StatelessWidget {
  const _EventsError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(18),
        decoration: _panelDecoration(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, style: const TextStyle(color: kRedColor)),
            const SizedBox(height: 14),
            FButton(
              style: playPrimaryActionButtonStyle(),
              prefix: const Icon(Icons.refresh_rounded),
              onPress: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event});

  final PlayedTournamentEvent event;

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (event.status) {
      PlayedTournamentStatus.running => kGreenColor,
      PlayedTournamentStatus.stopped => kPrimaryColor,
      PlayedTournamentStatus.aborted => kRedColor,
      PlayedTournamentStatus.completed => kWhiteColor70,
    };
    return FButton.raw(
      onPress: () => _showEventDetails(context, event),
      style: _eventCardButtonStyle(statusColor),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                border: Border.all(color: statusColor.withValues(alpha: 0.42)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.emoji_events_outlined, color: statusColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          event.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _StatusPill(
                        label: event.status.label,
                        color: statusColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    [
                      event.format.displayName,
                      '${event.participantCount} players',
                      '${event.finishedGameCount}/${event.gameCount} games',
                      _formatDate(event.updatedAt),
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kSecondaryTextColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _EventScore(event: event),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              color: kSecondaryTextColor,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showEventDetails(
  BuildContext context,
  PlayedTournamentEvent event,
) {
  final statusColor = switch (event.status) {
    PlayedTournamentStatus.running => kGreenColor,
    PlayedTournamentStatus.stopped => kPrimaryColor,
    PlayedTournamentStatus.aborted => kRedColor,
    PlayedTournamentStatus.completed => kWhiteColor70,
  };
  return showFDialog<void>(
    context: context,
    builder:
        (ctx, _, animation) => FDialog(
          animation: animation,
          direction: Axis.horizontal,
          title: Text(event.title),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusPill(label: event.status.label, color: statusColor),
              const SizedBox(height: 14),
              _EventDetailRow('Format', event.format.displayName),
              _EventDetailRow('Players', '${event.participantCount}'),
              _EventDetailRow(
                'Games',
                '${event.finishedGameCount}/${event.gameCount} finished',
              ),
              _EventDetailRow(
                'Your score',
                event.hasUserGames
                    ? '${event.userScore.toStringAsFixed(event.userScore == event.userScore.truncate() ? 0 : 1)} / ${event.userGameCount}'
                    : 'Spectated',
              ),
              _EventDetailRow('Updated', _formatDate(event.updatedAt)),
            ],
          ),
          actions: [
            FButton(
              style: playPrimaryActionButtonStyle(),
              prefix: const Icon(Icons.check_rounded),
              onPress: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
  );
}

class _EventDetailRow extends StatelessWidget {
  const _EventDetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(color: kSecondaryTextColor, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.38)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _EventScore extends StatelessWidget {
  const _EventScore({required this.event});

  final PlayedTournamentEvent event;

  @override
  Widget build(BuildContext context) {
    if (!event.hasUserGames) {
      return const SizedBox(
        width: 110,
        child: Text(
          'Spectated',
          textAlign: TextAlign.right,
          style: TextStyle(color: kSecondaryTextColor, fontSize: 12),
        ),
      );
    }
    return SizedBox(
      width: 110,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            event.userScore.toStringAsFixed(
              event.userScore == event.userScore.truncate() ? 0 : 1,
            ),
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 1),
          Text(
            '${event.userFinishedGameCount}/${event.userGameCount} played',
            style: const TextStyle(color: kSecondaryTextColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

BoxDecoration _panelDecoration() {
  return BoxDecoration(
    color: kBlack2Color,
    border: Border.all(color: kDividerColor),
    borderRadius: BorderRadius.circular(8),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _eventCardButtonStyle(
  Color accent,
) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          border: Border.all(color: accent.withValues(alpha: 0.58)),
          borderRadius: BorderRadius.circular(8),
        ),
        WidgetState.any: _panelDecoration(),
      }),
      contentStyle: (content) => content.copyWith(padding: EdgeInsets.zero),
    ),
  );
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.month}/${local.day}/${local.year}';
}
