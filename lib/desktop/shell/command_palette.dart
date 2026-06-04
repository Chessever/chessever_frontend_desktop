import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/utils/list_keyboard_nav.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/global_search_query.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/group_event/providers/supabase_combined_search_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/search/enhanced_group_broadcast_local_storage.dart';
import 'package:chessever/widgets/search/search_result_model.dart';

/// reference-style global command palette. Opens with Cmd/Ctrl+K from
/// anywhere in the desktop shell.
///
/// Modes:
/// 1. Empty query — pane jumps + quick actions (flip board, import PGN…).
/// 2. Typed query — real Supabase search across tournaments and players via
///    [supabaseCombinedSearchProvider]. Pane jumps fall to the bottom as a
///    fallback. Country names / FIDE codes (e.g. "USA", "Norway") trigger
///    the country-players path that returns the top-rated chess players for
///    that federation. Player rows open a Player Profile tab; tournament
///    rows open a Tournament Detail tab.
class CommandPalette extends HookConsumerWidget {
  const CommandPalette({
    super.key,
    required this.onSelectPane,
    required this.onAction,
    required this.onDismiss,
  });

  final ValueChanged<DesktopPane> onSelectPane;
  final ValueChanged<CommandAction> onAction;
  final VoidCallback onDismiss;

  static Future<void> show(
    BuildContext context, {
    required ValueChanged<DesktopPane> onSelectPane,
    required ValueChanged<CommandAction> onAction,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss command palette',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (context, _, __) {
        return CommandPalette(
          onSelectPane: onSelectPane,
          onAction: onAction,
          onDismiss: () => Navigator.of(context).pop(),
        );
      },
      transitionBuilder: (context, animation, _, child) {
        final curve = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curve,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.04),
              end: Offset.zero,
            ).animate(curve),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = useState<String>('');
    final debounced = useState<String>('');
    final highlighted = useState<int?>(null);
    final controller = useTextEditingController();
    final focusNode = useFocusNode();
    final debounceTimer = useRef<Timer?>(null);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusNode.requestFocus();
      });
      return () {
        debounceTimer.value?.cancel();
      };
    }, const []);

    final paneEntries = useMemoized(_buildPaneEntries, const []);

    // 250ms debounce so we don't fire a Supabase RPC on every keystroke.
    void onQueryChanged(String value) {
      query.value = value;
      highlighted.value = null;
      debounceTimer.value?.cancel();
      if (value.trim().length < 2) {
        debounced.value = '';
        return;
      }
      debounceTimer.value = Timer(const Duration(milliseconds: 250), () {
        debounced.value = value.trim();
      });
    }

    // Pane jumps & quick actions filtered by the live query.
    final filteredPanes = _filterPanes(paneEntries, query.value);

    // Supabase results for the *debounced* query. The provider handles caching
    // and short-query bail-out, but we still gate on length here so the empty
    // state doesn't flicker between "no query" and "0 results".
    final hasRemoteQuery = debounced.value.trim().length >= 2;
    final remoteSearch = hasRemoteQuery
        ? ref.watch(supabaseCombinedSearchProvider(debounced.value))
        : AsyncValue<EnhancedSearchResult>.data(EnhancedSearchResult.empty());

    final remoteResult = remoteSearch.maybeWhen(
      data: (data) => data,
      orElse: () => EnhancedSearchResult.empty(),
    );
    final isRemoteLoading = hasRemoteQuery && remoteSearch.isLoading;
    // Pending = user typed something but the debounce hasn't released the
    // value into the provider yet. Show "searching…" so the user knows the
    // empty list isn't authoritative.
    final isRemotePending =
        query.value.trim().length >= 2 &&
        debounced.value.trim() != query.value.trim();

    // Build a flat ordered list of selectable rows so arrow-key navigation
    // can walk across sections without caring about layout.
    final flat = <_PaletteRowData>[];
    for (final p in remoteResult.playerResults.take(10)) {
      flat.add(_PaletteRowData.player(p));
    }
    for (final t in remoteResult.tournamentResults.take(10)) {
      flat.add(_PaletteRowData.tournament(t));
    }
    for (final entry in filteredPanes) {
      flat.add(_PaletteRowData.entry(entry));
    }

    void invokeRow(_PaletteRowData row) {
      ref.read(desktopGlobalSearchQueryProvider.notifier).state = null;
      onDismiss();
      switch (row.kind) {
        case _RowKind.player:
          final player = row.player!.player;
          if (player == null) return;
          openPlayerProfile(
            ref,
            PlayerProfileArgs(
              playerName: player.name,
              fideId: player.fideId,
              title: player.title,
              federation: player.fed,
              rating: player.rating,
            ),
          );
        case _RowKind.tournament:
          setActiveTournament(ref, row.tournament!.tournament);
        case _RowKind.entry:
          final e = row.entry!;
          switch (e.kind) {
            case _EntryKind.pane:
              onSelectPane(e.pane!);
            case _EntryKind.action:
              onAction(e.action!);
          }
      }
    }

    void openSearchResultsForQuery() {
      final value = query.value.trim();
      if (value.length < 2) return;
      ref.read(desktopGlobalSearchQueryProvider.notifier).state = value;
      onDismiss();
      onSelectPane(DesktopPane.tournaments);
    }

    void onKey(KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
      if (flat.isEmpty) {
        if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) {
          openSearchResultsForQuery();
        } else if (event.logicalKey == LogicalKeyboardKey.escape) {
          onDismiss();
        }
        return;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        highlighted.value = nextCommandPaletteHighlight(
          current: highlighted.value,
          itemCount: flat.length,
          direction: 1,
        );
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        highlighted.value = nextCommandPaletteHighlight(
          current: highlighted.value,
          itemCount: flat.length,
          direction: -1,
        );
      } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
        highlighted.value = ((highlighted.value ?? -1) + kDesktopListPageStep)
            .clamp(0, flat.length - 1);
      } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
        highlighted.value =
            ((highlighted.value ?? flat.length) - kDesktopListPageStep)
                .clamp(0, flat.length - 1);
      } else if (event.logicalKey == LogicalKeyboardKey.home) {
        highlighted.value = 0;
      } else if (event.logicalKey == LogicalKeyboardKey.end) {
        highlighted.value = flat.length - 1;
      } else if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        final selected = highlighted.value;
        if (selected == null) {
          openSearchResultsForQuery();
        } else {
          invokeRow(flat[selected]);
        }
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        onDismiss();
      }
    }

    // Reset highlight when the row count shrinks below the cursor.
    useEffect(() {
      final selected = highlighted.value;
      if (selected != null && selected >= flat.length) {
        highlighted.value = null;
      }
      return null;
    }, [flat.length]);

    return Align(
      alignment: const Alignment(0, -0.4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
        child: Material(
          color: Colors.transparent,
          child: KeyboardListener(
            focusNode: FocusNode(skipTraversal: true),
            onKeyEvent: onKey,
            child: Container(
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 32,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SearchField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: onQueryChanged,
                    isLoading: isRemoteLoading || isRemotePending,
                  ),
                  const Divider(height: 1, color: kDividerColor),
                  Flexible(
                    child: _buildBody(
                      remote: remoteResult,
                      panes: filteredPanes,
                      query: query.value,
                      isLoading: isRemoteLoading || isRemotePending,
                      hasRemoteQuery: hasRemoteQuery,
                      highlighted: highlighted.value,
                      flat: flat,
                      onTap: invokeRow,
                      onHover: (i) => highlighted.value = i,
                    ),
                  ),
                  const Divider(height: 1, color: kDividerColor),
                  const _PaletteFooter(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody({
    required EnhancedSearchResult remote,
    required List<_PaletteEntry> panes,
    required String query,
    required bool isLoading,
    required bool hasRemoteQuery,
    int? highlighted,
    required List<_PaletteRowData> flat,
    required ValueChanged<_PaletteRowData> onTap,
    required ValueChanged<int> onHover,
  }) {
    if (flat.isEmpty) {
      if (isLoading) return const _LoadingState();
      if (hasRemoteQuery && query.trim().length >= 2) {
        return _NoResults(query: query);
      }
      return const _EmptyEntries();
    }

    final hasPlayers = remote.playerResults.isNotEmpty;
    final hasTournaments = remote.tournamentResults.isNotEmpty;
    final hasPanes = panes.isNotEmpty;

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (hasPlayers) ...[
          _SectionHeader(
            label: 'Players',
            count: remote.playerResults.length,
            icon: Icons.person_rounded,
          ),
          for (var i = 0; i < remote.playerResults.take(10).length; i++)
            _PlayerRow(
              player: remote.playerResults[i],
              selected: highlighted == _indexOf(flat, _RowKind.player, i),
              onTap: () => onTap(flat[_indexOf(flat, _RowKind.player, i)]),
              onHover: () => onHover(_indexOf(flat, _RowKind.player, i)),
              query: query,
            ),
        ],
        if (hasTournaments) ...[
          _SectionHeader(
            label: 'Tournaments',
            count: remote.tournamentResults.length,
            icon: Icons.emoji_events_rounded,
          ),
          for (var i = 0; i < remote.tournamentResults.take(10).length; i++)
            _TournamentRow(
              result: remote.tournamentResults[i],
              selected: highlighted == _indexOf(flat, _RowKind.tournament, i),
              onTap: () => onTap(flat[_indexOf(flat, _RowKind.tournament, i)]),
              onHover: () => onHover(_indexOf(flat, _RowKind.tournament, i)),
              query: query,
            ),
        ],
        if (isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _InlineLoading(),
          ),
        if (hasPanes) ...[
          _SectionHeader(
            label: hasPlayers || hasTournaments ? 'Jump to' : 'Navigate',
            count: panes.length,
            icon: Icons.arrow_forward_rounded,
          ),
          for (var i = 0; i < panes.length; i++)
            _PaletteRow(
              entry: panes[i],
              selected: highlighted == _indexOf(flat, _RowKind.entry, i),
              onTap: () => onTap(flat[_indexOf(flat, _RowKind.entry, i)]),
              onHover: () => onHover(_indexOf(flat, _RowKind.entry, i)),
            ),
        ],
      ],
    );
  }

  /// Index of the i-th row of [kind] within the flat list. Linear scan,
  /// fine for our row counts (~30 max).
  int _indexOf(List<_PaletteRowData> flat, _RowKind kind, int nth) {
    var seen = 0;
    for (var i = 0; i < flat.length; i++) {
      if (flat[i].kind == kind) {
        if (seen == nth) return i;
        seen++;
      }
    }
    return 0;
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.isLoading,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (isLoading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            )
          else
            const Icon(Icons.search, size: 18, color: kLightGreyColor),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              autofocus: true,
              cursorColor: kPrimaryColor,
              style: const TextStyle(color: kWhiteColor, fontSize: 15),
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search players, tournaments, openings, or country…',
                hintStyle: TextStyle(color: kLightGreyColor, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.count,
    required this.icon,
  });

  final String label;
  final int count;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 12, color: kLightGreyColor),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '· $count',
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.player,
    required this.selected,
    required this.onTap,
    required this.onHover,
    required this.query,
  });

  final SearchResult player;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final String query;

  @override
  Widget build(BuildContext context) {
    final p = player.player;
    if (p == null) return const SizedBox.shrink();
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => onHover(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SingleMotionBuilder(
            value: selected ? 1.01 : 1.0,
            motion: DesktopMotion.hover,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? kPrimaryColor.withValues(alpha: 0.18) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  _AvatarBadge(text: p.title ?? _initial(p.name)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (p.fed != null && p.fed!.isNotEmpty) ...[
                              FederationFlag(
                                federation: p.fed,
                                width: 16,
                                height: 11,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: selected ? kWhiteColor : kWhiteColor70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _playerSubtitle(p),
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (p.rating != null && p.rating! > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: kBlack3Color,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: kDividerColor),
                      ),
                      child: Text(
                        p.rating.toString(),
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _initial(String name) {
    final parts = name.split(RegExp(r'[ ,]+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.first.substring(0, 1).toUpperCase();
  }

  String _playerSubtitle(SearchPlayer p) {
    final pieces = <String>[
      if (p.fed != null && p.fed!.isNotEmpty) p.fed!.toUpperCase(),
      if (p.fideId != null && p.fideId! > 0) 'FIDE ${p.fideId}',
    ];
    if (pieces.isEmpty) return 'Player';
    return pieces.join(' · ');
  }
}

class _TournamentRow extends StatelessWidget {
  const _TournamentRow({
    required this.result,
    required this.selected,
    required this.onTap,
    required this.onHover,
    required this.query,
  });

  final SearchResult result;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final String query;

  @override
  Widget build(BuildContext context) {
    final t = result.tournament;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => onHover(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SingleMotionBuilder(
            value: selected ? 1.01 : 1.0,
            motion: DesktopMotion.hover,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? kPrimaryColor.withValues(alpha: 0.18) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  _StatusDot(category: t.tourEventCategory),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title,
                          style: TextStyle(
                            color: selected ? kWhiteColor : kWhiteColor70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(t),
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (t.maxAvgElo > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: kBlack3Color,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: kDividerColor),
                      ),
                      child: Text(
                        'avg ${t.maxAvgElo}',
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(GroupEventCardModel t) {
    final pieces = <String>[
      if (t.dates.isNotEmpty) t.dates,
      if (t.location != null && t.location!.isNotEmpty) t.location!,
      t.timeControl,
    ];
    return pieces.join(' · ');
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.category});

  final TourEventCategory category;

  @override
  Widget build(BuildContext context) {
    final color = switch (category) {
      TourEventCategory.live => kRedColor,
      TourEventCategory.ongoing => kGreenColor,
      TourEventCategory.upcoming => kPrimaryColor,
      TourEventCategory.completed => kLightGreyColor,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: category == TourEventCategory.live
            ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)]
            : null,
      ),
    );
  }
}

class _AvatarBadge extends StatelessWidget {
  const _AvatarBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: kPrimaryColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 160,
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      ),
    );
  }
}

class _InlineLoading extends StatelessWidget {
  const _InlineLoading();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
        SizedBox(width: 8),
        Text(
          'Searching…',
          style: TextStyle(color: kLightGreyColor, fontSize: 11),
        ),
      ],
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.search_off_rounded,
              size: 28,
              color: kLightGreyColor,
            ),
            const SizedBox(height: 10),
            Text(
              'No matches for "$query"',
              style: const TextStyle(color: kWhiteColor70, fontSize: 13),
            ),
            const SizedBox(height: 4),
            const Text(
              'Try a player surname, an event keyword, or a country.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyEntries extends StatelessWidget {
  const _EmptyEntries();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Text(
          'No matches',
          style: TextStyle(color: kWhiteColor70, fontSize: 12),
        ),
      ),
    );
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final _PaletteEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => onHover(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SingleMotionBuilder(
            value: selected ? 1.01 : 1.0,
            motion: DesktopMotion.hover,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? kPrimaryColor.withValues(alpha: 0.18) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    entry.icon,
                    size: 18,
                    color: selected ? kPrimaryColor : kWhiteColor70,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          style: TextStyle(
                            color: selected ? kWhiteColor : kWhiteColor70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (entry.subtitle != null)
                          Text(
                            entry.subtitle!,
                            style: const TextStyle(
                              color: kLightGreyColor,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (entry.shortcut != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: kBlack3Color,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: kDividerColor),
                      ),
                      child: Text(
                        entry.shortcut!,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteFooter extends StatelessWidget {
  const _PaletteFooter();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: DefaultTextStyle(
        style: const TextStyle(color: kLightGreyColor, fontSize: 11),
        child: Row(
          children: const [
            _FooterHint(label: 'Navigate', keys: ['↑', '↓']),
            SizedBox(width: 16),
            _FooterHint(label: 'Open', keys: ['↵']),
            SizedBox(width: 16),
            _FooterHint(label: 'Close', keys: ['Esc']),
          ],
        ),
      ),
    );
  }
}

class _FooterHint extends StatelessWidget {
  const _FooterHint({required this.label, required this.keys});

  final String label;
  final List<String> keys;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final k in keys) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: kBlack3Color,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: kDividerColor),
            ),
            child: Text(k),
          ),
          const SizedBox(width: 4),
        ],
        Text(label),
      ],
    );
  }
}

enum _EntryKind { pane, action }

enum _RowKind { player, tournament, entry }

class _PaletteRowData {
  const _PaletteRowData.player(this.player)
    : kind = _RowKind.player,
      tournament = null,
      entry = null;
  const _PaletteRowData.tournament(this.tournament)
    : kind = _RowKind.tournament,
      player = null,
      entry = null;
  const _PaletteRowData.entry(this.entry)
    : kind = _RowKind.entry,
      player = null,
      tournament = null;

  final _RowKind kind;
  final SearchResult? player;
  final SearchResult? tournament;
  final _PaletteEntry? entry;
}

class _PaletteEntry {
  const _PaletteEntry.pane({
    required this.pane,
    required this.title,
    required this.icon,
    this.subtitle,
    this.shortcut,
  }) : kind = _EntryKind.pane,
       action = null;

  const _PaletteEntry.action({
    required this.action,
    required this.title,
    required this.icon,
    this.subtitle,
    this.shortcut,
  }) : kind = _EntryKind.action,
       pane = null;

  final _EntryKind kind;
  final DesktopPane? pane;
  final CommandAction? action;
  final String title;
  final String? subtitle;

  /// Material outlined icon. Pane jumps and quick actions both use the
  /// same family so the palette stays visually uniform with the sidebar.
  final IconData icon;
  final String? shortcut;
}

/// Command-palette actions that are not pane jumps. The shell decides what
/// to do with each one in a single switch — keeps the wiring centralized.
enum CommandAction {
  flipBoard,
  importPgn,
  openLocalChessFolder,
  openLocalChessFiles,
  toggleSidebar,
  openPreferences,
}

List<_PaletteEntry> _buildPaneEntries() {
  return <_PaletteEntry>[
    const _PaletteEntry.pane(
      pane: DesktopPane.tournaments,
      title: 'Open Tournaments',
      subtitle: 'Live broadcasts and recent events',
      icon: Icons.emoji_events_outlined,
      shortcut: '⌘1',
    ),
    const _PaletteEntry.pane(
      pane: DesktopPane.library,
      title: 'Open Library',
      subtitle: 'Search games, players, openings',
      icon: Icons.menu_book_outlined,
      shortcut: '⌘2',
    ),
    const _PaletteEntry.pane(
      pane: DesktopPane.favorites,
      title: 'Open Favorites',
      icon: Icons.favorite_outline,
      shortcut: '⌘3',
    ),
    const _PaletteEntry.pane(
      pane: DesktopPane.players,
      title: 'Open Players',
      icon: Icons.people_outline,
      shortcut: '⌘4',
    ),
    const _PaletteEntry.pane(
      pane: DesktopPane.calendar,
      title: 'Open Calendar',
      icon: Icons.calendar_today_outlined,
      shortcut: '⌘5',
    ),
    const _PaletteEntry.pane(
      pane: DesktopPane.countrymen,
      title: 'Open Countrymen',
      icon: Icons.public_outlined,
      shortcut: '⌘6',
    ),
    const _PaletteEntry.pane(
      pane: DesktopPane.boardEditor,
      title: 'Open Board Editor',
      icon: Icons.edit_outlined,
      shortcut: '⌘8',
    ),
    const _PaletteEntry.pane(
      pane: DesktopPane.settings,
      title: 'Open Settings',
      icon: Icons.settings_outlined,
      shortcut: '⌘,',
    ),
    const _PaletteEntry.action(
      action: CommandAction.flipBoard,
      title: 'Flip Board',
      subtitle: 'Show the position from the other side',
      icon: Icons.flip_camera_android_rounded,
      shortcut: 'F',
    ),
    const _PaletteEntry.action(
      action: CommandAction.importPgn,
      title: 'Open PGN on Board…',
      subtitle: 'Load a single .pgn as an analysis tab',
      icon: Icons.file_open_rounded,
      shortcut: '⌘O',
    ),
    const _PaletteEntry.action(
      action: CommandAction.openLocalChessFolder,
      title: 'Browse Local Chess Folder…',
      subtitle: 'Open a folder in Library without importing it',
      icon: Icons.account_tree_outlined,
    ),
    const _PaletteEntry.action(
      action: CommandAction.openLocalChessFiles,
      title: 'Open Local Chess Files…',
      subtitle: 'Browse PGN files',
      icon: Icons.snippet_folder_outlined,
    ),
    const _PaletteEntry.action(
      action: CommandAction.toggleSidebar,
      title: 'Toggle Sidebar',
      icon: Icons.menu_open_rounded,
      shortcut: '⌘B',
    ),
    const _PaletteEntry.action(
      action: CommandAction.openPreferences,
      title: 'Preferences…',
      icon: Icons.tune_rounded,
      shortcut: '⌘,',
    ),
  ];
}

@visibleForTesting
int? nextCommandPaletteHighlight({
  required int? current,
  required int itemCount,
  required int direction,
}) {
  if (itemCount <= 0) return null;
  if (current == null) return direction >= 0 ? 0 : itemCount - 1;
  return (current + direction + itemCount) % itemCount;
}

@visibleForTesting
List<String> debugCommandPaletteEntryTitles() {
  return _buildPaneEntries().map((entry) => entry.title).toList();
}

@visibleForTesting
CommandAction? debugCommandPaletteActionForTitle(String title) {
  for (final entry in _buildPaneEntries()) {
    if (entry.title == title) return entry.action;
  }
  return null;
}

/// Lightweight subsequence-based fuzzy match for pane jumps. Score = shorter
/// remaining distance between matched characters wins.
List<_PaletteEntry> _filterPanes(List<_PaletteEntry> entries, String raw) {
  final query = raw.trim().toLowerCase();
  if (query.isEmpty) return entries;

  final scored = <(int score, _PaletteEntry entry)>[];
  for (final entry in entries) {
    final haystack = '${entry.title} ${entry.subtitle ?? ''}'.toLowerCase();
    final score = _subsequenceScore(haystack, query);
    if (score >= 0) scored.add((score, entry));
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return scored.map((s) => s.$2).toList(growable: false);
}

int _subsequenceScore(String haystack, String needle) {
  var i = 0;
  var firstMatch = -1;
  var lastMatch = -1;
  for (var c = 0; c < haystack.length && i < needle.length; c++) {
    if (haystack[c] == needle[i]) {
      firstMatch = firstMatch == -1 ? c : firstMatch;
      lastMatch = c;
      i++;
    }
  }
  if (i < needle.length) return -1;
  return (lastMatch - firstMatch) + firstMatch;
}
