import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/smart_event/smart_event_accent.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/screens/group_event/smart_event/smart_aggregate_event_provider.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/filter_popup_provider.dart';
import 'package:chessever/screens/group_event/widget/filter_popup/filter_popup_state.dart';
import 'package:chessever/theme/app_theme.dart';

/// The smart-event cards to show on For You, in order: the generated card
/// (from the applied For You filter) first, then saved smart events.
///
/// Pure so the merge rule is testable: when a generated card is visible, the
/// saved card with the same `favoriteEventId` is dropped (the generated card
/// already represents those criteria). Dismissal is keyed on
/// `cardDismissKey`, i.e. on criteria, never on the source tab. Saved rows are
/// de-duplicated by criteria so legacy v1 and v2 rows of the same criteria
/// render once.
@visibleForTesting
({SmartEventCardData? generated, List<SmartEventRequest> saved})
selectDesktopSmartEventCards({
  required SmartEventCardData? generated,
  required Set<String> dismissedKeys,
  required List<SmartEventRequest> savedRequests,
}) {
  final visibleGenerated = visibleSmartEventCardData(generated, dismissedKeys);
  final seenCriteria = <String>{};
  final saved = <SmartEventRequest>[];
  for (final request in savedRequests) {
    if (!seenCriteria.add(request.criteriaKey)) continue;
    if (visibleGenerated != null &&
        request.favoriteEventId == visibleGenerated.request.favoriteEventId) {
      continue;
    }
    saved.add(request);
  }
  return (generated: visibleGenerated, saved: saved);
}

/// Generated and saved smart-event cards on the For You feed.
class DesktopSmartEventShelf extends ConsumerWidget {
  const DesktopSmartEventShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoriteEventsProvider).valueOrNull ?? const [];
    final savedRequests = [
      for (final favorite in favorites)
        if (isSmartFavoriteEvent(favorite))
          SmartEventRequest.fromFavoriteEvent(favorite),
    ];
    final cards = selectDesktopSmartEventCards(
      generated: _generatedCard(ref, ref.watch(forYouAppliedFilterProvider)),
      dismissedKeys: ref.watch(dismissedSmartEventCardKeysProvider),
      savedRequests: savedRequests,
    );
    final generated = cards.generated;
    if (generated == null && cards.saved.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (generated != null) _GeneratedSmartEventCard(data: generated),
            for (final request in cards.saved) ...[
              if (generated != null || request != cards.saved.first)
                const SizedBox(width: 14),
              _SavedSmartEventCard(request: request),
            ],
          ],
        ),
      ),
    );
  }

  SmartEventCardData? _generatedCard(WidgetRef ref, FilterPopupState filter) {
    if (filter.formatsAndStates.isEmpty &&
        !filter.hasEloFilter &&
        filter.eco.isAll) {
      return null;
    }
    final criteria = SmartEventCriteria(
      minElo: filter.minElo ?? kFilterMinElo.round(),
      maxElo: filter.maxElo ?? kFilterMaxElo.round(),
      formatsAndStates: filter.formatsAndStates,
      eco: filter.eco,
    );
    final events =
        ref.watch(smartEventResolvedEventsProvider(criteria)).valueOrNull;
    if (events == null) return null;
    return SmartEventCardData.fromState(
      filter: filter,
      events: events,
      source: SmartEventSource.forYou,
    );
  }
}

class _GeneratedSmartEventCard extends ConsumerWidget {
  const _GeneratedSmartEventCard({required this.data});

  final SmartEventCardData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = data.request;
    return _SmartEventCardFrame(
      request: request,
      count: data.eventCount,
      onOpen: () => ref.read(desktopSmartEventOpenerProvider).open(request),
      trailing: DesktopTooltip(
        message: 'Hide this card',
        child: _IconAction(
          icon: Icons.close_rounded,
          onTap:
              () => ref
                  .read(dismissedSmartEventCardKeysProvider.notifier)
                  .update((keys) => {...keys, request.cardDismissKey}),
        ),
      ),
    );
  }
}

class _SavedSmartEventCard extends ConsumerWidget {
  const _SavedSmartEventCard({required this.request});

  final SmartEventRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps the saved row in step with server-fresh membership (and runs the
    // legacy v1 -> v2 re-key) while the card is on screen.
    final sync = ref.watch(savedSmartEventSyncProvider(request.criteriaKey));
    // Server-fresh membership. The stored snapshot only covers the frames
    // before resolution and offline use.
    final resolved = ref.watch(
      smartEventResolvedEventsProvider(request.criteria),
    );
    final events = resolved.valueOrNull ?? request.events;
    final fresh = request.withEvents(events);
    return _SmartEventCardFrame(
      request: fresh,
      count: events.length,
      onOpen:
          () => ref
              .read(desktopSmartEventOpenerProvider)
              .open(fresh, savedCriteriaKey: request.criteriaKey),
      trailing:
          sync.hasError
              ? DesktopTooltip(
                message: "Couldn't sync this saved smart event. Retry.",
                child: _IconAction(
                  icon: Icons.sync_problem_rounded,
                  onTap:
                      () => ref.invalidate(
                        savedSmartEventSyncProvider(request.criteriaKey),
                      ),
                ),
              )
              : const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(
                  Icons.bookmark_rounded,
                  size: 16,
                  color: kWhiteColor70,
                ),
              ),
    );
  }
}

class _SmartEventCardFrame extends StatefulWidget {
  const _SmartEventCardFrame({
    required this.request,
    required this.count,
    required this.onOpen,
    required this.trailing,
  });

  final SmartEventRequest request;
  final int count;
  final VoidCallback onOpen;
  final Widget trailing;

  @override
  State<_SmartEventCardFrame> createState() => _SmartEventCardFrameState();
}

class _SmartEventCardFrameState extends State<_SmartEventCardFrame> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final accent = smartEventAccentColor(request.criteriaKey);
    final countLabel =
        widget.count == 1 ? request.countSingular : request.countPlural;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpen,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            width: 240,
            constraints: const BoxConstraints(minHeight: 112),
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                accent.withValues(alpha: _hovered ? 0.14 : 0.08),
                kBlack2Color,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: accent.withValues(alpha: _hovered ? 0.42 : 0.26),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        request.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    widget.trailing,
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    request.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: kWhiteColor.withValues(alpha: 0.66),
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  '${widget.count} $countLabel',
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatefulWidget {
  const _IconAction({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox.square(
            dimension: 32,
            child: Center(
              child: Icon(
                widget.icon,
                size: 16,
                color: _hovered ? kWhiteColor : kWhiteColor70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
