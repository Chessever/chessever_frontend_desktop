import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_event_favorite_button.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';

enum _DesktopEventAction { open, toggleFavorite, share, copyLink }

/// Desktop right-click menu for tournament/event cards.
class DesktopEventContextMenu extends ConsumerWidget {
  const DesktopEventContextMenu({
    super.key,
    required this.event,
    required this.child,
    this.onOpen,
  });

  final GroupEventCardModel event;
  final Widget child;
  final VoidCallback? onOpen;

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Offset position,
  ) async {
    final canShare = event.eventSource != EventSource.communityEvent;
    final isStarred = ref.read(isEventFavoritedProvider(event.id));
    final action = await showDesktopContextMenu<_DesktopEventAction>(
      context: context,
      position: position,
      width: 224,
      entries: [
        if (onOpen != null)
          const DesktopContextMenuItem(
            value: _DesktopEventAction.open,
            icon: Icons.open_in_new_rounded,
            label: 'Open event',
          ),
        if (onOpen != null) const DesktopContextMenuDivider(),
        DesktopContextMenuItem(
          value: _DesktopEventAction.toggleFavorite,
          icon: isStarred ? Icons.star_rounded : Icons.star_border_rounded,
          label: isStarred ? 'Unstar event' : 'Star event',
        ),
        const DesktopContextMenuDivider(),
        DesktopContextMenuItem(
          value: _DesktopEventAction.share,
          icon: Icons.ios_share_rounded,
          label: 'Share event',
          enabled: canShare,
        ),
        DesktopContextMenuItem(
          value: _DesktopEventAction.copyLink,
          icon: Icons.copy_rounded,
          label: 'Copy event link',
          enabled: canShare,
        ),
      ],
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case _DesktopEventAction.open:
        onOpen?.call();
      case _DesktopEventAction.toggleFavorite:
        await toggleDesktopEventFavorite(
          context: context,
          ref: ref,
          event: event,
        );
      case _DesktopEventAction.share:
        await shareDesktopEvent(context: context, ref: ref, event: event);
      case _DesktopEventAction.copyLink:
        final url = await resolveDesktopEventShareUrl(ref: ref, event: event);
        if (!context.mounted) return;
        await copyDesktopShareUrl(
          context,
          url,
          copiedLabel: 'Event link copied to clipboard',
          missingLabel: 'This event has no shareable broadcast link.',
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp:
          (details) => _open(context, ref, details.globalPosition),
      onLongPressStart:
          (details) => _open(context, ref, details.globalPosition),
      child: child,
    );
  }
}
