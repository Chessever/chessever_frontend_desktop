import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/services/analytics/analytics_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';

class DesktopEventFavoriteIconButton extends ConsumerWidget {
  const DesktopEventFavoriteIconButton({
    super.key,
    required this.event,
    this.compact = false,
  });

  final GroupEventCardModel event;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(isEventFavoritedProvider(event.id));
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message: selected ? 'Unstar event' : 'Star event',
        child: FButton.icon(
          style: _eventFavoriteIconStyle(selected: selected, compact: compact),
          selected: selected,
          onPress:
              () => unawaited(
                toggleDesktopEventFavorite(
                  context: context,
                  ref: ref,
                  event: event,
                ),
              ),
          child: Icon(
            selected ? Icons.star_rounded : Icons.star_border_rounded,
          ),
        ),
      ),
    );
  }
}

Future<bool?> toggleDesktopEventFavorite({
  required BuildContext context,
  required WidgetRef ref,
  required GroupEventCardModel event,
}) async {
  final allowed = await requireFullAuthGuard(context);
  if (!allowed || !context.mounted) return null;

  final favoritesCount =
      ref.read(favoriteEventsProvider).valueOrNull?.length ?? 0;

  try {
    final isFavorited = await ref
        .read(favoriteEventsProvider.notifier)
        .toggleFavorite(
          eventId: event.id,
          eventName: event.title,
          timeControl: event.timeControl,
          maxAvgElo: event.maxAvgElo > 0 ? event.maxAvgElo : null,
          dates: event.dates.isNotEmpty ? event.dates : null,
        );

    final nextCount =
        isFavorited
            ? favoritesCount + 1
            : (favoritesCount - 1).clamp(0, favoritesCount);
    AnalyticsService.instance.trackEventDetached(
      'Event Favorite Toggled',
      properties: {
        'event_id': event.id,
        'event_name': event.title,
        'time_control': event.timeControl,
        'event_source': event.eventSource.name,
        'tour_category': event.tourEventCategory.name,
        'is_favorited': isFavorited,
        'new_favorites_total': nextCount,
        if (event.location != null && event.location!.isNotEmpty)
          'location': event.location,
        if (event.maxAvgElo > 0) 'max_avg_elo': event.maxAvgElo,
      },
    );
    return isFavorited;
  } catch (error, stackTrace) {
    debugPrint('[DesktopEventFavorite] Error toggling favorite: $error');
    debugPrint('$stackTrace');
    return null;
  }
}

FBaseButtonStyle Function(FButtonStyle style) _eventFavoriteIconStyle({
  required bool selected,
  required bool compact,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _eventFavoriteDecoration(selected: selected),
      iconContentStyle:
          (content) => content.copyWith(
            padding: EdgeInsets.all(compact ? 5 : 7),
            iconStyle: _eventFavoriteIconTheme(selected: selected),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _eventFavoriteDecoration({
  required bool selected,
}) {
  final idleFill =
      selected
          ? const Color(0xFFFFC857).withValues(alpha: 0.13)
          : kBlackColor.withValues(alpha: 0.32);
  final idleBorder =
      selected
          ? const Color(0xFFFFC857).withValues(alpha: 0.34)
          : kWhiteColor.withValues(alpha: 0.12);

  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color:
          selected
              ? const Color(0xFFFFC857).withValues(alpha: 0.2)
              : kWhiteColor.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(
        color:
            selected
                ? const Color(0xFFFFC857).withValues(alpha: 0.58)
                : kWhiteColor.withValues(alpha: 0.22),
      ),
    ),
    WidgetState.any: BoxDecoration(
      color: idleFill,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: idleBorder),
    ),
  });
}

FWidgetStateMap<IconThemeData> _eventFavoriteIconTheme({
  required bool selected,
}) {
  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color: kLightGreyColor.withValues(alpha: 0.45),
      size: 17,
    ),
    WidgetState.any: IconThemeData(
      color: selected ? const Color(0xFFFFC857) : kWhiteColor70,
      size: 17,
    ),
  });
}
