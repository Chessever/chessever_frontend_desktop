import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/desktop/widgets/tournament_about_view.dart';
import 'package:chessever/desktop/widgets/tournament_category_switcher.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/desktop/widgets/tournament_standings_view.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_broadcast.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';
import 'package:chessever/theme/app_theme.dart';

/// Single-tournament detail view, mirroring mobile's tour_detail screen.
///
/// Three segments — About / Games / Standings — shown via a desktop
/// segmented switcher. Reads the focused tournament from
/// `activeTournamentProvider`; the Tournaments list pane writes there when
/// the user activates a row.
class TournamentDetailPane extends HookConsumerWidget {
  const TournamentDetailPane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tournament = ref.watch(tournamentForTabProvider(tabId));
    final segment = ref.watch(tournamentDetailSegmentByTabIdProvider(tabId));
    final bodyFocusNode = useFocusNode(debugLabel: 'tournament-detail-body');
    final bodyKey = useMemoized(
      () => GlobalKey(debugLabel: 'tournament-detail-body-root'),
    );

    // When the user switches between Tournament-Detail tabs, the active
    // tournament changes — re-point the mobile broadcast provider at the
    // newly focused tournament so the rounds/games/standings chain
    // recomputes for it.
    ref.listen<GroupEventCardModel?>(tournamentForTabProvider(tabId), (
      prev,
      next,
    ) {
      if (next == null || next.id == prev?.id) return;
      ref.read(selectedBroadcastModelProvider.notifier).state = GroupBroadcast(
        id: next.id,
        createdAt: DateTime.now(),
        name: next.title,
        search: const <String>[],
      );
    });

    // Refocus the body when the segment switches so keyboard scroll keeps
    // working after the user clicks Games / About / Standings (each segment
    // tear-down would otherwise leave focus on a now-disposed descendant).
    ref.listen<TournamentDetailSegment>(
      tournamentDetailSegmentByTabIdProvider(tabId),
      (_, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (bodyFocusNode.canRequestFocus) {
            bodyFocusNode.requestFocus();
          }
        });
      },
    );

    if (tournament == null) {
      return const _EmptyState();
    }

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DetailHeader(title: tournament.title, dates: tournament.dates),
          _SegmentBar(
            segments: TournamentDetailSegment.values,
            selected: segment,
            info:
                segment == TournamentDetailSegment.games
                    ? const TournamentGamesCountLabel()
                    : null,
            trailing:
                segment == TournamentDetailSegment.games
                    ? const TournamentGamesHeaderControls()
                    : null,
            onSelect:
                (next) =>
                    ref
                        .read(
                          tournamentDetailSegmentByTabIdProvider(
                            tabId,
                          ).notifier,
                        )
                        .state = next,
          ),
          Expanded(
            child: Focus(
              focusNode: bodyFocusNode,
              autofocus: true,
              canRequestFocus: true,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                final key = event.logicalKey;
                final isPageDown = key == LogicalKeyboardKey.pageDown;
                final isPageUp = key == LogicalKeyboardKey.pageUp;
                final isHome = key == LogicalKeyboardKey.home;
                final isEnd = key == LogicalKeyboardKey.end;
                final isArrowDown = key == LogicalKeyboardKey.arrowDown;
                final isArrowUp = key == LogicalKeyboardKey.arrowUp;
                if (!isPageDown &&
                    !isPageUp &&
                    !isHome &&
                    !isEnd &&
                    !isArrowDown &&
                    !isArrowUp) {
                  return KeyEventResult.ignored;
                }
                final scrollable = _findFirstScrollable(bodyKey.currentContext);
                if (scrollable == null) {
                  return KeyEventResult.ignored;
                }
                final pos = scrollable.position;
                final viewport = pos.viewportDimension;
                double target;
                if (isHome) {
                  target = pos.minScrollExtent;
                } else if (isEnd) {
                  target = pos.maxScrollExtent;
                } else if (isArrowDown) {
                  target = pos.pixels + 60;
                } else if (isArrowUp) {
                  target = pos.pixels - 60;
                } else {
                  final delta = viewport * 0.9;
                  target = isPageDown ? pos.pixels + delta : pos.pixels - delta;
                }
                target = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
                pos.animateTo(
                  target,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                );
                return KeyEventResult.handled;
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) {
                  // Body owns keyboard scroll. After any pointer-down inside
                  // the segment body, hand focus back to bodyFocusNode so the
                  // next ArrowDown / PageDown reaches the key handler above.
                  // TextField taps still claim focus on pointer-up after this,
                  // so search / inputs keep working.
                  if (bodyFocusNode.canRequestFocus &&
                      FocusManager.instance.primaryFocus != bodyFocusNode) {
                    bodyFocusNode.requestFocus();
                  }
                },
                child: KeyedSubtree(
                  key: bodyKey,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    child: KeyedSubtree(
                      key: ValueKey(segment),
                      child: _segmentBody(segment, tournament.id),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _segmentBody(TournamentDetailSegment segment, String tournamentId) {
    switch (segment) {
      case TournamentDetailSegment.about:
        return TournamentAboutView(tabId: tabId, tournamentId: tournamentId);
      case TournamentDetailSegment.games:
        return TournamentGamesView(tabId: tabId, tournamentId: tournamentId);
      case TournamentDetailSegment.standings:
        return TournamentStandingsView(
          tabId: tabId,
          tournamentId: tournamentId,
        );
    }
  }
}

/// Search text per tournament-detail tab. Survives the tab.kind flip when
/// the user opens a game from this tab (which disposes the entire detail
/// subtree) so the search field is restored on goBack.
final tournamentDetailGamesSearchByTabIdProvider =
    StateProvider.family<String, String>((ref, _) => '');

final tournamentDetailStandingsSearchByTabIdProvider =
    StateProvider.family<String, String>((ref, _) => '');

/// Scroll offset for the About segment, keyed by tab id. Games and
/// Standings restore their offsets via PageStorage; the About panel uses a
/// SingleChildScrollView which does not participate in PageStorage, so we
/// persist it explicitly.
final tournamentDetailAboutScrollByTabIdProvider =
    StateProvider.family<double, String>((ref, _) => 0.0);

ScrollableState? _findFirstScrollable(BuildContext? root) {
  if (root == null) return null;
  ScrollableState? found;
  void visit(Element el) {
    if (found != null) return;
    if (el is StatefulElement && el.state is ScrollableState) {
      final state = el.state as ScrollableState;
      if (state.position.axis == Axis.vertical) {
        found = state;
        return;
      }
    }
    el.visitChildren(visit);
  }

  (root as Element).visitChildren(visit);
  return found;
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.title, required this.dates});
  final String title;
  final String dates;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (dates.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    dates,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Switcher hides itself when only one tour exists, so the
          // header stays clean for single-category broadcasts.
          const TournamentCategorySwitcher(),
        ],
      ),
    );
  }
}

class _SegmentBar extends StatelessWidget {
  const _SegmentBar({
    required this.segments,
    required this.selected,
    required this.onSelect,
    this.info,
    this.trailing,
  });

  final List<TournamentDetailSegment> segments;
  final TournamentDetailSegment selected;
  final ValueChanged<TournamentDetailSegment> onSelect;

  /// Inline info widget rendered right after the tabs, before the spacer.
  /// Use for things like a game count that should sit near the active tab
  /// rather than ride along with the right-edge controllers.
  final Widget? info;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    // Browser-style tab bar — bottom underline marks the active section
    // and the inactive segments stay legible (not low-contrast). The
    // older flat pill style was easy to mistake for empty header chrome,
    // which is why About / Standings looked "missing" (#461 feedback).
    return Container(
      decoration: const BoxDecoration(
        color: kBackgroundColor,
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          for (final s in segments)
            _SegmentTab(
              label: s.label,
              selected: s == selected,
              onTap: () => onSelect(s),
            ),
          if (info != null) ...[
            const SizedBox(width: 16),
            // Constrain info to its intrinsic width so the Spacer below
            // can claim 100% of the remaining row, anchoring trailing to
            // the far right. A `Flexible` here splits remaining width
            // 50/50 with the Spacer and parks trailing near the middle.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: info!,
            ),
          ],
          const Spacer(),
          if (trailing != null) ...[
            trailing!,
            const SizedBox(width: 24),
          ],
        ],
      ),
    );
  }
}

class _SegmentTab extends StatefulWidget {
  const _SegmentTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SegmentTab> createState() => _SegmentTabState();
}

class _SegmentTabState extends State<_SegmentTab> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fg =
        selected ? kWhiteColor : (_hovered ? kWhiteColor : kWhiteColor70);
    final indicatorColor =
        selected
            ? kPrimaryColor
            : (_hovered
                ? kPrimaryColor.withValues(alpha: 0.35)
                : Colors.transparent);
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit:
            (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.96 : (_hovered ? 1.01 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: indicatorColor,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(2),
                      ),
                    ),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBackgroundColor,
      alignment: Alignment.center,
      child: const Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events_outlined, size: 36, color: kLightGreyColor),
            SizedBox(height: 16),
            Text(
              'No tournament selected',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Open a tournament from the Tournaments tab to see its '
              'about page, rounds, and standings here.',
              style: TextStyle(color: kLightGreyColor, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
