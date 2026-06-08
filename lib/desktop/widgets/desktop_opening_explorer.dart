import 'package:chessground/chessground.dart' show PieceAssets;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/gamebase/models/move_aggregate.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/figurine_notation.dart';

/// Desktop-native opening explorer.
///
/// Reads the same `gamebaseExplorerProvider` mobile uses, but renders a
/// dense desktop-first table with forui-flavoured chrome instead of
/// embedding the mobile `MoveStatisticsPanel` (which scales itself with
/// `responsive_helper.dart` and felt like the tablet-mode of the phone
/// app showing through).
///
/// Layout adapts to the host column. Two render modes:
///   * **Wide** (≥ 460px) — MOVE · WDL bar · SCORE · GAMES + open · LAST
///   * **Narrow** — MOVE · WDL bar · GAMES + open · LAST   (SCORE dropped)
///
/// The narrow mode is what kicks in inside the BoardPane right rail; the
/// wide mode is the dedicated OpeningExplorerPane centre column.
class DesktopOpeningExplorer extends ConsumerWidget {
  const DesktopOpeningExplorer({
    super.key,
    required this.onMove,
    this.onShowGames,
    this.shrinkWrap = false,
    this.bottomSlot,
    this.focusedMoveIndex,
    this.onFocusMoveIndex,
    this.moveCountCallback,
    this.sortedAggregatesCallback,
    this.compactColumns = false,
    this.showHeader = true,
    this.enableRowHover = true,
  });

  /// Invoked when the user clicks a move row. UCI form (e.g. `e2e4`).
  final void Function(String uci) onMove;

  /// Invoked when the user clicks the per-row "open games" icon — caller
  /// is expected to flip the surrounding pane to its Games view with this
  /// UCI applied as a pinned next-move filter. When null, the icon is
  /// hidden (used by the BoardPane right rail, which only advances moves).
  final void Function(String uci)? onShowGames;

  /// When `true`, the move table renders in `shrinkWrap` mode and gives up
  /// its own scrolling — used by the combined moves+games explorer view
  /// so a single outer scrollbar covers both lists Lichess-style.
  final bool shrinkWrap;

  /// Optional widget rendered after the move rows. The combined explorer
  /// uses this to pin the games table directly beneath the moves so one
  /// scroll covers both lists.
  final Widget? bottomSlot;

  /// Highlighted row index for keyboard navigation. Null means no row is
  /// focused — the caller drives keyboard selection by passing a value in.
  final int? focusedMoveIndex;

  /// Called when the user clicks/hovers a move row so the caller can sync
  /// its keyboard-nav cursor. The callback receives the row index.
  final void Function(int index)? onFocusMoveIndex;

  /// Reports the move-row count after each rebuild. Lets the host extend
  /// its keyboard-nav cursor range without re-watching the provider.
  final void Function(int count)? moveCountCallback;

  /// Reports the post-sort aggregate list after each rebuild. Host stores
  /// it so keyboard Enter resolves to the same row index the user sees
  /// (sort order is owned here, but Enter handling lives in the host).
  final void Function(List<MoveAggregate> aggs)? sortedAggregatesCallback;

  /// Use the right-rail schema: Move, result bar, Games, Last played.
  /// Percentages stay inside the W/D/L bar so the panel does not spend
  /// separate columns on result text.
  final bool compactColumns;

  /// Whether to render the title/count strip above the column headers.
  /// The in-game split Explorer hides this so the moves table aligns with
  /// the adjacent games table header.
  final bool showHeader;

  /// When false, pointer hover over move rows is passive: no hover row
  /// background and no focus/selection change. Click and keyboard selection
  /// remain active.
  final bool enableRowHover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(gamebaseExplorerProvider);
    final localPlayerId =
        state.filters.playerIds.length == 1
            ? state.filters.playerIds.first.trim()
            : null;
    if (localPlayerId != null && localPlayerId.isNotEmpty) {
      ref.listen<PlayerOpeningTreeState>(
        playerOpeningTreeProvider(localPlayerId),
        (previous, next) {
          if (previous?.index == next.index &&
              previous?.progress.status == next.progress.status) {
            return;
          }
          Future.microtask(() {
            ref
                .read(gamebaseExplorerProvider.notifier)
                .syncLocalPlayerTree(localPlayerId);
          });
        },
      );
      Future.microtask(() {
        ref
            .read(gamebaseExplorerProvider.notifier)
            .enableLocalPlayerTree(localPlayerId);
        ref.read(playerOpeningTreeProvider(localPlayerId).notifier).start();
      });
    } else {
      Future.microtask(() {
        ref.read(gamebaseExplorerProvider.notifier).disableLocalPlayerTree();
      });
    }
    return FTheme(
      data: FThemes.zinc.dark,
      child: ColoredBox(
        color: kBlack2Color,
        child: _ExplorerBody(
          state: state,
          onMove: onMove,
          onShowGames: onShowGames,
          shrinkWrap: shrinkWrap,
          bottomSlot: bottomSlot,
          focusedMoveIndex: focusedMoveIndex,
          onFocusMoveIndex: onFocusMoveIndex,
          moveCountCallback: moveCountCallback,
          sortedAggregatesCallback: sortedAggregatesCallback,
          compactColumns: compactColumns,
          showHeader: showHeader,
          enableRowHover: enableRowHover,
        ),
      ),
    );
  }
}

class _ExplorerBody extends StatefulWidget {
  const _ExplorerBody({
    required this.state,
    required this.onMove,
    required this.onShowGames,
    required this.shrinkWrap,
    required this.bottomSlot,
    required this.focusedMoveIndex,
    required this.onFocusMoveIndex,
    required this.moveCountCallback,
    required this.sortedAggregatesCallback,
    required this.compactColumns,
    required this.showHeader,
    required this.enableRowHover,
  });

  final GamebaseExplorerState state;
  final void Function(String uci) onMove;
  final void Function(String uci)? onShowGames;
  final bool shrinkWrap;
  final Widget? bottomSlot;
  final int? focusedMoveIndex;
  final void Function(int index)? onFocusMoveIndex;
  final void Function(int count)? moveCountCallback;
  final void Function(List<MoveAggregate> aggs)? sortedAggregatesCallback;
  final bool compactColumns;
  final bool showHeader;
  final bool enableRowHover;

  @override
  State<_ExplorerBody> createState() => _ExplorerBodyState();
}

class _ExplorerBodyState extends State<_ExplorerBody> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _moveKeys = <int, GlobalKey>{};
  int? _suppressRevealForFocusedMoveIndex;
  String? _lastFenKey;
  _MoveSort? _sort;

  void _cycleSort(_MoveSortField field) {
    setState(() {
      final current = _sort;
      if (current == null || current.field != field) {
        _sort = _MoveSort(field: field, ascending: true);
      } else if (current.ascending) {
        _sort = _MoveSort(field: field, ascending: false);
      } else {
        _sort = null;
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String _positionKey(String fen) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return fen.trim();
    return parts.take(4).join(' ');
  }

  @override
  void didUpdateWidget(covariant _ExplorerBody old) {
    super.didUpdateWidget(old);
    // Whenever the board's position changes we jump back to the top of
    // the move list. The previous scroll offset belonged to a different
    // position's aggregate and would just feel random. (#461)
    final nextKey = _positionKey(widget.state.currentFen);
    if (_lastFenKey != null &&
        _lastFenKey != nextKey &&
        _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(0);
      });
    }
    _lastFenKey = nextKey;
    // Keyboard-driven focus walks the unified moves+games cursor in the
    // host. Keep that selected row visible as the index changes, but do not
    // move the scroll position for pointer hover: these are already scrollable
    // lists, and hover should only change the highlight.
    final focusedMoveChanged =
        widget.focusedMoveIndex != null &&
        widget.focusedMoveIndex != old.focusedMoveIndex;
    if (focusedMoveChanged) {
      final suppressReveal =
          _suppressRevealForFocusedMoveIndex == widget.focusedMoveIndex;
      _suppressRevealForFocusedMoveIndex = null;
      if (!suppressReveal) {
        if (!widget.shrinkWrap) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _animateToMoveIndex(widget.focusedMoveIndex!);
          });
        } else {
          _ensureMoveIndexVisible(widget.focusedMoveIndex!);
        }
      }
    }
  }

  static const double _approxRowHeight = 36;

  void _animateToMoveIndex(int index) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final viewport = position.viewportDimension;
    final target =
        (index * _approxRowHeight) - viewport / 2 + _approxRowHeight / 2;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  GlobalKey _moveKeyFor(int index) {
    return _moveKeys.putIfAbsent(
      index,
      () => GlobalKey(debugLabel: 'desktop-opening-move-$index'),
    );
  }

  void _pruneMoveKeys(int count) {
    _moveKeys.removeWhere((index, _) => index >= count);
  }

  void _ensureMoveIndexVisible(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _moveKeys[index]?.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.14,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _focusMoveFromPointer(int index) {
    final focus = widget.onFocusMoveIndex;
    if (focus == null) return;
    if (widget.focusedMoveIndex != index) {
      _suppressRevealForFocusedMoveIndex = index;
    }
    focus(index);
  }

  @override
  Widget build(BuildContext context) {
    _lastFenKey ??= _positionKey(widget.state.currentFen);
    final state = widget.state;
    final onMove = widget.onMove;
    final onShowGames = widget.onShowGames;
    final bottomSlot = widget.bottomSlot;
    if (state.isLoading && state.moveAggregates.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      );
    }
    if (state.error != null && state.moveAggregates.isEmpty) {
      return _ExplorerEmpty(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load explorer data',
        message: state.error!,
      );
    }
    final aggs = _applySort(state.moveAggregates, _sort, state.currentFen);
    _pruneMoveKeys(aggs.length);
    // Report move-count up to the host before render so the keyboard-nav
    // cursor can extend through this rebuild's range without lagging a
    // frame behind the visible rows.
    widget.moveCountCallback?.call(aggs.length);
    widget.sortedAggregatesCallback?.call(aggs);
    if (aggs.isEmpty && bottomSlot == null) {
      return const _ExplorerEmpty(
        icon: Icons.menu_book_outlined,
        title: 'No games match this position',
        message:
            'No master/online games are indexed for the position on the board.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final dims = _ColumnDims.forWidth(
          constraints.maxWidth,
          compact: widget.compactColumns,
        );
        final header =
            widget.showHeader
                ? _ExplorerHeader(
                  totalGames: state.totalGames,
                  moveCount: aggs.length,
                  isLoading: state.isLoading,
                )
                : null;
        final columnHeader = _ColumnHeader(
          dims: dims,
          sort: _sort,
          onSort: _cycleSort,
        );

        Widget movesArea;
        if (widget.shrinkWrap) {
          movesArea = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (aggs.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text(
                      'No replies indexed for this position',
                      style: TextStyle(color: kLightGreyColor, fontSize: 11),
                    ),
                  ),
                ),
              for (var i = 0; i < aggs.length; i++) ...[
                _MoveRow(
                  key: _moveKeyFor(i),
                  aggregate: aggs[i],
                  fen: state.currentFen,
                  dims: dims,
                  selected: widget.focusedMoveIndex == i,
                  enableHoverFeedback: widget.enableRowHover,
                  onFocus: () => _focusMoveFromPointer(i),
                  onTap: () {
                    widget.onFocusMoveIndex?.call(i);
                    onMove(aggs[i].uci);
                  },
                  onShowGames:
                      onShowGames == null
                          ? null
                          : () => onShowGames(aggs[i].uci),
                ),
                if (i < aggs.length - 1)
                  const Divider(color: kDividerColor, height: 1, indent: 14),
              ],
            ],
          );
        } else {
          movesArea = Expanded(
            child: ListView.separated(
              controller: _scrollController,
              physics: const DesktopScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 2),
              itemCount: aggs.length,
              separatorBuilder:
                  (_, __) => const Divider(
                    color: kDividerColor,
                    height: 1,
                    indent: 14,
                  ),
              itemBuilder: (_, i) {
                final agg = aggs[i];
                return _MoveRow(
                  key: _moveKeyFor(i),
                  aggregate: agg,
                  fen: state.currentFen,
                  dims: dims,
                  selected: widget.focusedMoveIndex == i,
                  enableHoverFeedback: widget.enableRowHover,
                  onFocus: () => _focusMoveFromPointer(i),
                  onTap: () {
                    widget.onFocusMoveIndex?.call(i);
                    onMove(agg.uci);
                  },
                  onShowGames:
                      onShowGames == null ? null : () => onShowGames(agg.uci),
                );
              },
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
          children: [
            if (header != null) ...[header, const FDivider()],
            columnHeader,
            movesArea,
            if (bottomSlot != null) bottomSlot,
          ],
        );
      },
    );
  }
}

/// Per-render layout dimensions, derived from the host column width.
///
/// The same widget is used inside the BoardPane right rail (narrow) and
/// the OpeningExplorerPane centre column (wide). Picking column widths
/// off `constraints.maxWidth` keeps both rendering modes in one place
/// instead of forcing the caller to pass a "compact" flag.
class _ColumnDims {
  const _ColumnDims({
    required this.move,
    required this.gamesValue,
    required this.gamesIcon,
    required this.last,
    required this.score,
    required this.resultBar,
    required this.gap,
    required this.horizontalPad,
    required this.useFullDate,
    required this.useFullCount,
    required this.showResultBar,
    required this.headerHeight,
    required this.rowMinHeight,
  });

  final double move;
  final double gamesValue;
  final double gamesIcon;
  final double last;

  /// `null` when SCORE column is hidden (narrow mode).
  final double? score;

  /// Result-bar width is proportional to the moves view so W/D/L percentages
  /// have enough room to breathe in both the right rail and full explorer.
  final double resultBar;

  final double gap;
  final double horizontalPad;
  final bool useFullDate;
  final bool useFullCount;
  final bool showResultBar;
  final double headerHeight;
  final double rowMinHeight;

  bool get hasScore => score != null;

  factory _ColumnDims.forWidth(double width, {required bool compact}) {
    double resultBarFor({
      required double horizontalPad,
      required double move,
      required double gamesValue,
      required double gamesIcon,
      required double last,
      required double? score,
      required double gap,
    }) {
      final contentWidth = (width - horizontalPad * 2).clamp(0, width);
      final fixedWidth =
          move +
          gamesValue +
          gamesIcon +
          last +
          (score ?? 0) +
          gap * (score == null ? 3 : 5);
      return (contentWidth - fixedWidth).clamp(48.0, contentWidth * 0.5);
    }

    if (compact) {
      if (width >= 300) {
        const horizontalPad = 8.0;
        const move = 72.0;
        const gamesValue = 36.0;
        const gamesIcon = 0.0;
        const last = 30.0;
        const double? score = null;
        const gap = 5.0;
        return _ColumnDims(
          move: move,
          gamesValue: gamesValue,
          gamesIcon: gamesIcon,
          last: last,
          score: score,
          resultBar: resultBarFor(
            horizontalPad: horizontalPad,
            move: move,
            gamesValue: gamesValue,
            gamesIcon: gamesIcon,
            last: last,
            score: score,
            gap: gap,
          ),
          gap: gap,
          horizontalPad: horizontalPad,
          useFullDate: false,
          useFullCount: true,
          showResultBar: true,
          headerHeight: 24,
          rowMinHeight: 30,
        );
      }
      const horizontalPad = 8.0;
      const move = 58.0;
      const gamesValue = 30.0;
      const gamesIcon = 0.0;
      const last = 24.0;
      const double? score = null;
      const gap = 4.0;
      return _ColumnDims(
        move: move,
        gamesValue: gamesValue,
        gamesIcon: gamesIcon,
        last: last,
        score: score,
        resultBar: resultBarFor(
          horizontalPad: horizontalPad,
          move: move,
          gamesValue: gamesValue,
          gamesIcon: gamesIcon,
          last: last,
          score: score,
          gap: gap,
        ),
        gap: gap,
        horizontalPad: horizontalPad,
        useFullDate: false,
        useFullCount: false,
        showResultBar: true,
        headerHeight: 24,
        rowMinHeight: 30,
      );
    }
    if (width >= 660) {
      const horizontalPad = 12.0;
      const move = 112.0;
      const gamesValue = 54.0;
      const gamesIcon = 18.0;
      const last = 52.0;
      const score = 44.0;
      const gap = 6.0;
      return _ColumnDims(
        move: move,
        gamesValue: gamesValue,
        gamesIcon: gamesIcon,
        last: last,
        score: score,
        resultBar: resultBarFor(
          horizontalPad: horizontalPad,
          move: move,
          gamesValue: gamesValue,
          gamesIcon: gamesIcon,
          last: last,
          score: score,
          gap: gap,
        ),
        gap: gap,
        horizontalPad: horizontalPad,
        useFullDate: true,
        useFullCount: true,
        showResultBar: true,
        headerHeight: 28,
        rowMinHeight: 36,
      );
    }
    if (width >= 460) {
      const horizontalPad = 10.0;
      const move = 88.0;
      const gamesValue = 48.0;
      const gamesIcon = 18.0;
      const last = 44.0;
      const double? score = null;
      const gap = 6.0;
      return _ColumnDims(
        move: move,
        gamesValue: gamesValue,
        gamesIcon: gamesIcon,
        last: last,
        score: score,
        resultBar: resultBarFor(
          horizontalPad: horizontalPad,
          move: move,
          gamesValue: gamesValue,
          gamesIcon: gamesIcon,
          last: last,
          score: score,
          gap: gap,
        ),
        gap: gap,
        horizontalPad: horizontalPad,
        useFullDate: false,
        useFullCount: true,
        showResultBar: true,
        headerHeight: 28,
        rowMinHeight: 36,
      );
    }
    if (width >= 340) {
      const horizontalPad = 10.0;
      const move = 72.0;
      const gamesValue = 38.0;
      const gamesIcon = 14.0;
      const last = 30.0;
      const double? score = null;
      const gap = 5.0;
      return _ColumnDims(
        move: move,
        gamesValue: gamesValue,
        gamesIcon: gamesIcon,
        last: last,
        score: score,
        resultBar: resultBarFor(
          horizontalPad: horizontalPad,
          move: move,
          gamesValue: gamesValue,
          gamesIcon: gamesIcon,
          last: last,
          score: score,
          gap: gap,
        ),
        gap: gap,
        horizontalPad: horizontalPad,
        useFullDate: false,
        useFullCount: true,
        showResultBar: true,
        headerHeight: 28,
        rowMinHeight: 34,
      );
    }
    const horizontalPad = 8.0;
    const move = 62.0;
    const gamesValue = 32.0;
    const gamesIcon = 12.0;
    const last = 26.0;
    const double? score = null;
    const gap = 4.0;
    return _ColumnDims(
      move: move,
      gamesValue: gamesValue,
      gamesIcon: gamesIcon,
      last: last,
      score: score,
      resultBar: resultBarFor(
        horizontalPad: horizontalPad,
        move: move,
        gamesValue: gamesValue,
        gamesIcon: gamesIcon,
        last: last,
        score: score,
        gap: gap,
      ),
      gap: gap,
      horizontalPad: horizontalPad,
      useFullDate: false,
      useFullCount: false,
      showResultBar: true,
      headerHeight: 28,
      rowMinHeight: 34,
    );
  }
}

class _ExplorerHeader extends StatelessWidget {
  const _ExplorerHeader({
    required this.totalGames,
    required this.moveCount,
    required this.isLoading,
  });

  final int totalGames;
  final int moveCount;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          const Icon(Icons.menu_book_outlined, size: 14, color: kPrimaryColor),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: [
                const Flexible(
                  child: Text(
                    'Opening Explorer',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Move-count chip — quiet secondary signal next to the title
                // so users know how many candidate replies the table has.
                if (moveCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: kBlack3Color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '$moveCount',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isLoading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
                valueColor: AlwaysStoppedAnimation(kPrimaryColor),
              ),
            )
          else
            Text(
              '${_formatGamesCount(totalGames)} games',
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({
    required this.dims,
    required this.sort,
    required this.onSort,
  });
  final _ColumnDims dims;
  final _MoveSort? sort;
  final ValueChanged<_MoveSortField> onSort;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: kBackgroundColor,
        border: Border(bottom: BorderSide(color: kDividerColor, width: 1)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: dims.headerHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: dims.horizontalPad),
          child: Row(
            children: [
              SizedBox(
                width: dims.move,
                child: _SortHeader(
                  label: 'MOVE',
                  field: _MoveSortField.move,
                  align: TextAlign.left,
                  sort: sort,
                  onSort: onSort,
                ),
              ),
              SizedBox(width: dims.gap),
              if (dims.showResultBar) ...[
                SizedBox(
                  width: dims.resultBar,
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('RESULT', style: _kHeaderStyle),
                  ),
                ),
                if (dims.hasScore) ...[
                  SizedBox(width: dims.gap),
                  SizedBox(
                    width: dims.score!,
                    child: _SortHeader(
                      label: 'SCORE',
                      field: _MoveSortField.score,
                      align: TextAlign.right,
                      sort: sort,
                      onSort: onSort,
                    ),
                  ),
                ],
              ] else ...[
                SizedBox(
                  width: dims.gamesValue,
                  child: _SortHeader(
                    label: 'GAMES',
                    field: _MoveSortField.games,
                    align: TextAlign.right,
                    sort: sort,
                    onSort: onSort,
                  ),
                ),
                SizedBox(width: dims.gap),
                SizedBox(
                  width: dims.score!,
                  child: _SortHeader(
                    label: 'SCORE',
                    field: _MoveSortField.score,
                    align: TextAlign.right,
                    sort: sort,
                    onSort: onSort,
                  ),
                ),
                SizedBox(width: dims.gap),
                SizedBox(
                  width: dims.last,
                  child: _SortHeader(
                    label: 'LAST',
                    field: _MoveSortField.last,
                    align: TextAlign.right,
                    sort: sort,
                    onSort: onSort,
                  ),
                ),
              ],
              if (dims.showResultBar) ...[
                SizedBox(width: dims.gap),
                SizedBox(
                  width: dims.gamesValue,
                  child: _SortHeader(
                    label: 'GAMES',
                    field: _MoveSortField.games,
                    align: TextAlign.right,
                    sort: sort,
                    onSort: onSort,
                  ),
                ),
                // Icon column — header label intentionally blank (would just
                // duplicate "GAMES") but the slot is reserved so values align.
                SizedBox(width: dims.gamesIcon),
                SizedBox(width: dims.gap),
                SizedBox(
                  width: dims.last,
                  child: _SortHeader(
                    label: 'LAST',
                    field: _MoveSortField.last,
                    align: TextAlign.right,
                    sort: sort,
                    onSort: onSort,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

const TextStyle _kHeaderStyle = TextStyle(
  color: kLightGreyColor,
  fontSize: 10,
  fontWeight: FontWeight.w800,
  letterSpacing: 0.55,
);

const TextStyle _kHeaderActiveStyle = TextStyle(
  color: kWhiteColor,
  fontSize: 10,
  fontWeight: FontWeight.w800,
  letterSpacing: 0.55,
);

class _SortHeader extends StatefulWidget {
  const _SortHeader({
    required this.label,
    required this.field,
    required this.align,
    required this.sort,
    required this.onSort,
  });

  final String label;
  final _MoveSortField field;
  final TextAlign align;
  final _MoveSort? sort;
  final ValueChanged<_MoveSortField> onSort;

  @override
  State<_SortHeader> createState() => _SortHeaderState();
}

class _SortHeaderState extends State<_SortHeader> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.sort?.field == widget.field;
    final ascending = widget.sort?.ascending ?? true;
    final style = active ? _kHeaderActiveStyle : _kHeaderStyle;
    final rightAligned = widget.align == TextAlign.right;
    final children = <Widget>[
      Flexible(
        child: Text(
          widget.label,
          style: style,
          textAlign: widget.align,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (active) ...[
        const SizedBox(width: 2),
        Icon(
          ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
          size: 10,
          color: kPrimaryColor,
        ),
      ] else if (_hovered) ...[
        const SizedBox(width: 2),
        const Icon(Icons.unfold_more_rounded, size: 10, color: kLightGreyColor),
      ],
    ];
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSort(widget.field),
          child: Row(
            mainAxisAlignment:
                rightAligned ? MainAxisAlignment.end : MainAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: rightAligned ? children.reversed.toList() : children,
          ),
        ),
      ),
    );
  }
}

enum _MoveSortField { move, score, games, last }

class _MoveSort {
  const _MoveSort({required this.field, required this.ascending});
  final _MoveSortField field;
  final bool ascending;
}

List<MoveAggregate> _applySort(
  List<MoveAggregate> aggs,
  _MoveSort? sort,
  String fen,
) {
  if (sort == null || aggs.length < 2) return aggs;
  final sanCache = <String, String>{};
  String sanFor(MoveAggregate a) {
    return sanCache.putIfAbsent(a.uci, () {
      try {
        final setup = Setup.parseFen(fen);
        final position = Chess.fromSetup(setup, ignoreImpossibleCheck: true);
        final move = Move.parse(a.uci);
        if (move == null) return a.uci;
        return position.makeSan(move).$2;
      } catch (_) {
        return a.uci;
      }
    });
  }

  double scoreFor(MoveAggregate a) {
    if (a.total <= 0) return 0;
    return (a.white + a.draws * 0.5) / a.total;
  }

  int cmp(MoveAggregate a, MoveAggregate b) {
    final int c;
    switch (sort.field) {
      case _MoveSortField.move:
        c = sanFor(a).toLowerCase().compareTo(sanFor(b).toLowerCase());
        break;
      case _MoveSortField.score:
        c = scoreFor(a).compareTo(scoreFor(b));
        break;
      case _MoveSortField.games:
        c = a.total.compareTo(b.total);
        break;
      case _MoveSortField.last:
        final ta = a.lastPlayed?.millisecondsSinceEpoch ?? -1;
        final tb = b.lastPlayed?.millisecondsSinceEpoch ?? -1;
        c = ta.compareTo(tb);
        break;
    }
    if (c == 0) return b.total.compareTo(a.total);
    return sort.ascending ? c : -c;
  }

  return List<MoveAggregate>.of(aggs)..sort(cmp);
}

class _MoveRow extends ConsumerStatefulWidget {
  const _MoveRow({
    super.key,
    required this.aggregate,
    required this.fen,
    required this.dims,
    required this.onTap,
    required this.onShowGames,
    required this.enableHoverFeedback,
    this.onFocus,
    this.selected = false,
  });

  final MoveAggregate aggregate;
  final String fen;
  final _ColumnDims dims;
  final VoidCallback onTap;
  final VoidCallback? onShowGames;
  final bool enableHoverFeedback;
  final VoidCallback? onFocus;
  final bool selected;

  @override
  ConsumerState<_MoveRow> createState() => _MoveRowState();
}

class _MoveRowState extends ConsumerState<_MoveRow> {
  bool _hovered = false;

  /// Convert the row's UCI move into SAN using dartchess. Falls back to
  /// the raw UCI string if the position can't be parsed (the explorer
  /// occasionally returns moves illegal for the synced FEN — e.g. a stale
  /// cache during rapid scrubbing).
  String _san() {
    try {
      final setup = Setup.parseFen(widget.fen);
      final position = Chess.fromSetup(setup, ignoreImpossibleCheck: true);
      final move = Move.parse(widget.aggregate.uci);
      if (move == null) return widget.aggregate.uci;
      return position.makeSan(move).$2;
    } catch (_) {
      return widget.aggregate.uci;
    }
  }

  /// Move-number prefix for the side to move at this position
  /// (e.g. `1.` when white is to move, `1…` when black is). Mirrors how
  /// the mobile explorer prefixes rows so the table reads as a numbered
  /// candidate list rather than a flat blob of SAN tokens.
  String _moveNumberPrefix() {
    try {
      final parts = widget.fen.trim().split(RegExp(r'\s+'));
      final fullMove = parts.length >= 6 ? int.tryParse(parts[5]) ?? 1 : 1;
      final whiteToMove = parts.length >= 2 ? parts[1] == 'w' : true;
      return whiteToMove ? '$fullMove.' : '$fullMove…';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final agg = widget.aggregate;
    final san = _san();
    final prefix = _moveNumberPrefix();
    final dims = widget.dims;

    final useFigurine = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.useFigurine ?? const BoardSettingsNew().useFigurine,
      ),
    );
    final pieceAssets = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.pieceAssets ?? const BoardSettingsNew().pieceAssets,
      ),
    );

    final selected = widget.selected;
    final backgroundColor =
        selected
            ? kPrimaryColor.withValues(alpha: 0.16)
            : (widget.enableHoverFeedback && _hovered
                ? kBlack3Color
                : Colors.transparent);
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) {
          if (!widget.enableHoverFeedback) return;
          setState(() => _hovered = true);
          widget.onFocus?.call();
        },
        onExit:
            widget.enableHoverFeedback
                ? (_) => setState(() => _hovered = false)
                : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            constraints: BoxConstraints(minHeight: dims.rowMinHeight),
            decoration: BoxDecoration(
              color: backgroundColor,
              border:
                  selected
                      ? const Border(
                        left: BorderSide(color: kPrimaryColor, width: 2),
                      )
                      : null,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: dims.horizontalPad,
              vertical: 6,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: dims.move,
                  child: _MoveLabel(
                    prefix: prefix,
                    san: san,
                    useFigurine: useFigurine,
                    pieceAssets: pieceAssets,
                  ),
                ),
                SizedBox(width: dims.gap),
                if (dims.showResultBar) ...[
                  SizedBox(
                    width: dims.resultBar,
                    child: _ResultBar(aggregate: agg),
                  ),
                  if (dims.hasScore) ...[
                    SizedBox(width: dims.gap),
                    SizedBox(
                      width: dims.score!,
                      child: _ScoreCell(aggregate: agg),
                    ),
                  ],
                ] else ...[
                  SizedBox(
                    width: dims.gamesValue,
                    child: _GamesCountCell(
                      aggregate: agg,
                      full: dims.useFullCount,
                    ),
                  ),
                  SizedBox(width: dims.gap),
                  SizedBox(
                    width: dims.score!,
                    child: _ScoreCell(aggregate: agg, decimals: 1),
                  ),
                  SizedBox(width: dims.gap),
                  SizedBox(
                    width: dims.last,
                    child: _LastPlayedCell(
                      aggregate: agg,
                      full: dims.useFullDate,
                    ),
                  ),
                ],
                if (dims.showResultBar) ...[
                  SizedBox(width: dims.gap),
                  SizedBox(
                    width: dims.gamesValue,
                    child: _GamesCountCell(
                      aggregate: agg,
                      full: dims.useFullCount,
                    ),
                  ),
                  // Open-games icon — always rendered when supported so the
                  // affordance is discoverable without hovering. The slot
                  // collapses to zero width when unsupported, keeping
                  // header columns aligned with row content.
                  SizedBox(
                    width: dims.gamesIcon,
                    child:
                        widget.onShowGames == null
                            ? const SizedBox.shrink()
                            : Align(
                              alignment: Alignment.centerRight,
                              child: _OpenGamesIcon(
                                onTap: widget.onShowGames!,
                                highlighted: _hovered,
                              ),
                            ),
                  ),
                  SizedBox(width: dims.gap),
                  SizedBox(
                    width: dims.last,
                    child: _LastPlayedCell(
                      aggregate: agg,
                      full: dims.useFullDate,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GamesCountCell extends StatelessWidget {
  const _GamesCountCell({required this.aggregate, required this.full});

  final MoveAggregate aggregate;
  final bool full;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        _formatTotalCount(aggregate.total, full: full),
        textAlign: TextAlign.right,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: kWhiteColor,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _LastPlayedCell extends StatelessWidget {
  const _LastPlayedCell({required this.aggregate, required this.full});

  final MoveAggregate aggregate;
  final bool full;

  @override
  Widget build(BuildContext context) {
    return Text(
      _formatLastPlayed(aggregate.lastPlayed, full: full),
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 11,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Left column — `1. ` / `1… ` prefix + SAN move, optionally with
/// figurine glyphs in place of piece letters.
class _MoveLabel extends StatelessWidget {
  const _MoveLabel({
    required this.prefix,
    required this.san,
    required this.useFigurine,
    required this.pieceAssets,
  });

  final String prefix;
  final String san;
  final bool useFigurine;
  final PieceAssets pieceAssets;

  @override
  Widget build(BuildContext context) {
    const sanStyle = TextStyle(
      color: kWhiteColor,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    const prefixStyle = TextStyle(
      color: kLightGreyColor,
      fontSize: 12,
      fontWeight: FontWeight.w500,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (prefix.isNotEmpty) ...[
          Text(prefix, style: prefixStyle),
          const SizedBox(width: 4),
        ],
        Flexible(
          child:
              useFigurine
                  ? RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      children: buildFigurineSpans(
                        text: san,
                        pieceAssets: pieceAssets,
                        style: sanStyle,
                        pieceSize: 14,
                      ),
                    ),
                  )
                  : Text(
                    san,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sanStyle,
                  ),
        ),
      ],
    );
  }
}

/// Result distribution bar with inline % labels — adds three numeric
/// columns' worth of information without taking a single extra px of
/// horizontal track. We render the % inside each segment when the
/// segment is wide enough to fit the glyph (≥ 12% share); narrower
/// segments stay coloured but unlabelled so the bar still totals 100%.
class _ResultBar extends StatelessWidget {
  const _ResultBar({required this.aggregate});
  final MoveAggregate aggregate;

  @override
  Widget build(BuildContext context) {
    final w = aggregate.whiteWinRate;
    final d = aggregate.drawRate;
    final b = aggregate.blackWinRate;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 18,
        child: Row(
          children: [
            if (w > 0)
              Expanded(
                flex: (w * 1000).round(),
                child: _BarSegment(
                  rate: w,
                  bg: kMoveStatWhiteColor,
                  fg: kMoveStatBlackColor,
                ),
              ),
            if (d > 0)
              Expanded(
                flex: (d * 1000).round(),
                child: _BarSegment(
                  rate: d,
                  bg: kMoveStatDrawColor,
                  fg: kMoveStatWhiteColor,
                ),
              ),
            if (b > 0)
              Expanded(
                flex: (b * 1000).round(),
                child: _BarSegment(
                  rate: b,
                  bg: kMoveStatBlackColor,
                  fg: kMoveStatWhiteColor,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BarSegment extends StatelessWidget {
  const _BarSegment({required this.rate, required this.bg, required this.fg});
  final double rate;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final pct = (rate * 100).round();
    return Container(
      color: bg,
      alignment: Alignment.center,
      child:
          rate >= 0.12
              ? Text(
                '$pct%',
                style: TextStyle(
                  color: fg,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              )
              : null,
    );
  }
}

/// Score column — white-perspective performance score for the move,
/// computed from existing aggregate fields as `(W + 0.5·D) / total`.
/// Mirrors the column reference database shows in its opening reference; gives
/// a single at-a-glance "is this good for white" number that the WDL
/// bar's three percentages can't.
class _ScoreCell extends StatelessWidget {
  const _ScoreCell({required this.aggregate, this.decimals = 0});
  final MoveAggregate aggregate;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final total = aggregate.total;
    if (total <= 0) {
      return const Align(
        alignment: Alignment.centerRight,
        child: Text(
          '—',
          style: TextStyle(color: kLightGreyColor, fontSize: 12),
        ),
      );
    }
    final score = (aggregate.white + aggregate.draws * 0.5) / total;
    final pct = (score * 100).toStringAsFixed(decimals);
    // Tint the number toward white when ≥ 55%, black when ≤ 45%, neutral
    // in between. Quick visual triage when scrolling a long candidate
    // list — strong picks pop without the user having to read the bar.
    final color =
        score >= 0.55
            ? kMoveStatWhiteColor
            : score <= 0.45
            ? kChessBlackMoveColor
            : kWhiteColor70;
    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        '$pct%',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Always-visible icon button that opens the position-games table
/// pinned to this row's UCI. Replaces the prior fade-in "GAMES" pill,
/// which was both undiscoverable (hover-only) and a layout-eater (the
/// `AnimatedOpacity` reserved its full width even when hidden, which
/// was the source of the games-count truncation).
class _OpenGamesIcon extends StatefulWidget {
  const _OpenGamesIcon({required this.onTap, required this.highlighted});
  final VoidCallback onTap;
  final bool highlighted;

  @override
  State<_OpenGamesIcon> createState() => _OpenGamesIconState();
}

class _OpenGamesIconState extends State<_OpenGamesIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || widget.highlighted;
    return DesktopTooltip(
      message: 'Open games for this move',
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.onTap();
            },
            child: Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    _hovered
                        ? kPrimaryColor.withValues(alpha: 0.18)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                Icons.list_alt_rounded,
                size: 14,
                color:
                    _hovered
                        ? kPrimaryColor
                        : (active ? kWhiteColor70 : kLightGreyColor),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExplorerEmpty extends StatelessWidget {
  const _ExplorerEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: kLightGreyColor),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header total — abbreviated (the header doesn't have room for "1,234,567").
String _formatGamesCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return n.toString();
}

/// Per-row total — compact whole-unit counts keep the opening table from
/// crowding the result bars and date column (`63,000` → `63k`, `29,560` →
/// `30k`).
String _formatTotalCount(int n, {required bool full}) {
  if (n >= 1000000) return '${(n / 1000000).round()}M';
  if (n >= 1000) return '${(n / 1000).round()}k';
  return n.toString();
}

final DateFormat _yearFormat = DateFormat.y();
final DateFormat _monthYearFormat = DateFormat('MMM yyyy');
String _formatLastPlayed(DateTime? d, {required bool full}) {
  if (d == null) return '—';
  return full ? _monthYearFormat.format(d) : _yearFormat.format(d);
}
