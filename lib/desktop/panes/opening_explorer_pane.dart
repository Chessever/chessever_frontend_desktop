import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart'
    as fic;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/play_from_here.dart';

import 'package:chessever/desktop/state/opening_explorer_seed.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/desktop/widgets/desktop_opening_explorer.dart';
import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/explorer_filters_popover.dart';
import 'package:chessever/desktop/widgets/move_navigation_bar.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';
import 'package:chessever/screens/gamebase/providers/explorer_eval_provider.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop-native Opening Explorer pane.
///
/// Layout mirrors the sidebar `Board` pane so the "Build tree" view feels
/// like the same workspace:
///   ┌──────────────────────────────────────────────────────────────┐
///   │  Games (29%)  │  Board + nav (41%)  │  Analysis (30%)        │
///   │  dismissible  │  breadcrumb + board │  Moves (60%)           │
///   │  + pin chip   │  + MoveNavBar        │  ────────              │
///   │               │                      │  Notation (40%)        │
///   └──────────────────────────────────────────────────────────────┘
///
/// Filter access lives behind the "Filters" popover in the games-rail
/// header (Trello #461). The right rail is a vertical split: top 60% is
/// `DesktopOpeningExplorer` (the same move-stats table the in-board swipe
/// panel uses); bottom 40% is `NotationLadderView`. Both tables read off
/// the same FEN driven by local `Position` history — clicking a row in
/// either table updates the board, which in turn refreshes the other.
class OpeningExplorerPane extends HookConsumerWidget {
  const OpeningExplorerPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One-shot seed: anything that wants to "open the explorer at this FEN"
    // stashes it in `openingExplorerSeedProvider` and navigates here. Watch it
    // so an already-open explorer tab can still consume a fresh Board Editor
    // position-search request.
    final seed = ref.watch(openingExplorerSeedProvider);
    final notationUseFigurine = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.useFigurine ?? const BoardSettingsNew().useFigurine,
      ),
    );
    final notationPieceAssets = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.pieceAssets ?? const BoardSettingsNew().pieceAssets,
      ),
    );
    // UCI of the move whose games are pinned in the rail — set when
    // the user clicks the per-row "GAMES" pill in the moves table.
    // Cleared automatically when the explored position changes (the
    // pin only makes sense at the FEN it was opened from).
    final pinnedGamesUci = useState<String?>(null);
    // History as `(Position, Move?)` pairs — same shape the BoardPane
    // uses, just simpler since we don't load PGNs here. Cursor lets the
    // user step through the line they explored with arrow keys.
    final history = useState<List<_ExplorerPly>>(<_ExplorerPly>[
      _ExplorerPly(position: _seedPosition(seed?.fen), move: null),
    ]);
    final seededLineUcis = useState<List<String>>(
      _sanitizeUcis(seed?.moves ?? const <String>[]),
    );
    final exactFenSearch = useState<bool>(seed?.exactFenSearch ?? false);
    final scopedPlayer = useState<GamebasePlayer?>(seed?.player);
    final cursor = useState<int>(0);
    final flipped = useState<bool>(false);
    // Pane-level keyboard host. We re-grab focus after every board move
    // so chessground's internal focus doesn't swallow arrow keys after a
    // mouse drag — same pattern BoardPane uses inside applyMove.
    final focusNode = useFocusNode(debugLabel: 'opening-explorer-pane');
    final notationNags = useState<Map<int, List<int>>>(
      const <int, List<int>>{},
    );
    final notationComments = useState<Map<int, String>>(const <int, String>{});

    useEffect(() {
      if (seed == null) return null;
      Future.microtask(() {
        if (!context.mounted) return;
        history.value = <_ExplorerPly>[
          _ExplorerPly(position: _seedPosition(seed.fen), move: null),
        ];
        cursor.value = 0;
        pinnedGamesUci.value = null;
        notationNags.value = const <int, List<int>>{};
        notationComments.value = const <int, String>{};
        seededLineUcis.value = _sanitizeUcis(seed.moves);
        exactFenSearch.value = seed.exactFenSearch;
        scopedPlayer.value = seed.player;

        // Apply seeded player/filters before the position-sync effect fires
        // its own microtask — both useEffects schedule on the same queue and
        // this one runs first, so the explorer's `_scheduleFetch` debounce
        // sees the merged filter set on the very first fetch. Only touched
        // when the caller actually supplied scoping; generic FEN seeds (board
        // pane, board editor) leave the user's existing filter chips alone.
        if (seed.player != null || seed.filters != null) {
          final base = seed.filters ?? const GamebaseFilters();
          final scoped =
              seed.player != null
                  ? base.copyWith(
                    playerIds: <String>[seed.player!.id],
                    selectedPlayers: <GamebasePlayer>[seed.player!],
                  )
                  : base;
          ref.read(gamebaseExplorerProvider.notifier).updateFilters(scoped);
        } else if (ref.read(gamebaseExplorerProvider).filters !=
            const GamebaseFilters()) {
          ref
              .read(gamebaseExplorerProvider.notifier)
              .updateFilters(const GamebaseFilters());
        }

        ref.read(openingExplorerSeedProvider.notifier).state = null;
      });
      return null;
    }, [seed]);

    final currentPly = history.value[cursor.value];
    final position = currentPly.position;
    final lastMove = currentPly.move;
    final canBack = cursor.value > 0;
    final canForward = cursor.value < history.value.length - 1;

    // Build the UCI line up to the cursor for the explorer's deep-line
    // aggregation (the service falls back to opening-book lookup beyond
    // the indexed window when we hand it the played sequence).
    final localLineUcis = <String>[
      for (final p in history.value.skip(1))
        if (p.move != null) p.move!.uci,
    ].sublist(0, cursor.value.clamp(0, history.value.length - 1));
    final lineUcis = <String>[...seededLineUcis.value, ...localLineUcis];
    final lineKey = lineUcis.join(' ');
    final notationStartsAtInitial = seededLineUcis.value.isNotEmpty;
    final notationStartPosition =
        notationStartsAtInitial ? Chess.initial : history.value.first.position;
    final notationMoves = notationStartsAtInitial ? lineUcis : localLineUcis;
    final notationGame = _notationGameFromUcis(
      startingPosition: notationStartPosition,
      ucis: notationMoves,
      commentsByPly: notationComments.value,
    );
    final activeNotationIndex =
        notationStartsAtInitial
            ? seededLineUcis.value.length + cursor.value - 1
            : cursor.value - 1;
    final activeNotationPointer =
        activeNotationIndex >= 0 ? <int>[activeNotationIndex] : const <int>[];

    // Sync the explorer provider on every cursor change.
    useEffect(() {
      Future.microtask(() {
        if (!context.mounted) return;
        if (scopedPlayer.value == null &&
            ref.read(gamebaseExplorerProvider).filters !=
                const GamebaseFilters()) {
          ref
              .read(gamebaseExplorerProvider.notifier)
              .updateFilters(const GamebaseFilters());
        }
        ref
            .read(gamebaseExplorerProvider.notifier)
            .setPositionWithMoves(position.fen, lineUcis);
      });
      return null;
    }, [position.fen, cursor.value, lineKey]);

    // Drop the pinned-uci filter whenever the underlying position
    // changes — it was scoped to a specific FEN, so keeping it across a
    // navigation would silently apply to the wrong board state.
    useEffect(() {
      if (pinnedGamesUci.value != null) {
        Future.microtask(() {
          if (!context.mounted) return;
          pinnedGamesUci.value = null;
        });
      }
      return null;
    }, [position.fen]);

    void jumpTo(int target) {
      final clamped = target.clamp(0, history.value.length - 1);
      if (clamped == cursor.value) return;
      cursor.value = clamped;
    }

    void playUci(String uci) {
      try {
        final move = Move.parse(uci);
        if (move == null) return;
        if (!position.isLegal(move)) return;
        // Truncate forward branch — same "branch from here" semantics
        // every analysis tool ships.
        final upTo = history.value.sublist(0, cursor.value + 1);
        final next = position.playUnchecked(move);
        history.value = [...upTo, _ExplorerPly(position: next, move: move)];
        cursor.value = history.value.length - 1;
        final keptMoveCount = seededLineUcis.value.length + cursor.value;
        notationNags.value = _pruneNags(notationNags.value, keptMoveCount);
        notationComments.value = _pruneComments(
          notationComments.value,
          keptMoveCount,
        );
        // Re-grab pane focus so arrow keys keep walking the history after a
        // mouse drag/tap on the board (chessground holds focus otherwise).
        focusNode.requestFocus();
      } catch (_) {}
    }

    void onBoardMove(Move move, {bool? viaDragAndDrop}) {
      playUci(move.uci);
    }

    void jumpNotation(List<int> pointer) {
      if (pointer.isEmpty) {
        if (notationStartsAtInitial) {
          seededLineUcis.value = const <String>[];
          history.value = <_ExplorerPly>[
            _ExplorerPly(position: Chess.initial, move: null),
          ];
          exactFenSearch.value = false;
        }
        cursor.value = 0;
        pinnedGamesUci.value = null;
        return;
      }

      final targetMoveCount = pointer.first + 1;
      if (notationStartsAtInitial) {
        final targetMoves = lineUcis.take(targetMoveCount).toList();
        final targetPosition =
            _positionAfterUcis(Chess.initial, targetMoves) ?? Chess.initial;
        seededLineUcis.value = targetMoves;
        history.value = <_ExplorerPly>[
          _ExplorerPly(position: targetPosition, move: null),
        ];
        cursor.value = 0;
        exactFenSearch.value = false;
        pinnedGamesUci.value = null;
        notationNags.value = _pruneNags(notationNags.value, targetMoveCount);
        notationComments.value = _pruneComments(
          notationComments.value,
          targetMoveCount,
        );
        return;
      }

      jumpTo(targetMoveCount);
    }

    void setNotationQualityNag(int ply, int? nag) {
      final next = Map<int, List<int>>.from(notationNags.value);
      final existing = next[ply] ?? const <int>[];
      final preserved = existing.where((n) => n < 1 || n > 7).toList();
      if (nag != null) preserved.add(nag);
      if (preserved.isEmpty) {
        next.remove(ply);
      } else {
        next[ply] = List<int>.unmodifiable(preserved);
      }
      notationNags.value = Map<int, List<int>>.unmodifiable(next);
    }

    void toggleNotationNag(int ply, int nag) {
      final tapped = getNagDisplay(nag);
      if (tapped == null) return;
      final next = Map<int, List<int>>.from(notationNags.value);
      final existing = List<int>.from(next[ply] ?? const <int>[]);
      if (existing.contains(nag)) {
        existing.remove(nag);
      } else {
        existing.removeWhere((other) {
          final display = getNagDisplay(other);
          return display != null && display.category == tapped.category;
        });
        existing.add(nag);
      }
      if (existing.isEmpty) {
        next.remove(ply);
      } else {
        next[ply] = List<int>.unmodifiable(existing);
      }
      notationNags.value = Map<int, List<int>>.unmodifiable(next);
    }

    void clearNotationNags(int ply) {
      if (!notationNags.value.containsKey(ply)) return;
      final next = Map<int, List<int>>.from(notationNags.value)..remove(ply);
      notationNags.value = Map<int, List<int>>.unmodifiable(next);
    }

    void setNotationComment(ChessMovePointer pointer, String? comment) {
      if (pointer.isEmpty) return;
      final ply = pointer.first;
      final next = Map<int, String>.from(notationComments.value);
      final trimmed = comment?.trim() ?? '';
      if (trimmed.isEmpty) {
        next.remove(ply);
      } else {
        next[ply] = trimmed;
      }
      notationComments.value = Map<int, String>.unmodifiable(next);
    }

    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.arrowLeft): const _PrevIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowRight): const _NextIntent(),
      const SingleActivator(LogicalKeyboardKey.home): const _FirstIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
          const _FirstIntent(),
      const SingleActivator(LogicalKeyboardKey.end): const _LastIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
          const _LastIntent(),
      const SingleActivator(LogicalKeyboardKey.keyF): const _FlipIntent(),
    };
    final actions = <Type, Action<Intent>>{
      _PrevIntent: CallbackAction<_PrevIntent>(
        onInvoke: (_) {
          jumpTo(cursor.value - 1);
          return null;
        },
      ),
      _NextIntent: CallbackAction<_NextIntent>(
        onInvoke: (_) {
          jumpTo(cursor.value + 1);
          return null;
        },
      ),
      _FirstIntent: CallbackAction<_FirstIntent>(
        onInvoke: (_) {
          jumpTo(0);
          return null;
        },
      ),
      _LastIntent: CallbackAction<_LastIntent>(
        onInvoke: (_) {
          jumpTo(history.value.length - 1);
          return null;
        },
      ),
      _FlipIntent: CallbackAction<_FlipIntent>(
        onInvoke: (_) {
          flipped.value = !flipped.value;
          return null;
        },
      ),
    };

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: Focus(
          focusNode: focusNode,
          autofocus: true,
          canRequestFocus: true,
          child: ResizableSplitView(
            axis: Axis.horizontal,
            storageKey: 'opening_explorer.main.v2',
            children: [
              // LEFT — games for the current FEN (mirrors board pane's
              // dismissible left games rail). Filter access lives in the
              // header popover so the rail keeps full height for game rows.
              SplitChild(
                minSize: 220,
                maxSize: 520,
                initialWeight: 0.29,
                label: 'Games',
                collapsedIcon: Icons.view_list_rounded,
                dismissible: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _GamesRailHeader(scopedPlayer: scopedPlayer.value),
                    Container(height: 1, color: kDividerColor),
                    if (pinnedGamesUci.value != null) ...[
                      _PinnedUciChip(
                        fen: position.fen,
                        uci: pinnedGamesUci.value!,
                        onClear: () => pinnedGamesUci.value = null,
                      ),
                      Container(height: 1, color: kDividerColor),
                    ],
                    Expanded(
                      child: DesktopPositionGamesTable(
                        fen: position.fen,
                        moves: lineUcis,
                        uci: pinnedGamesUci.value,
                        exactFenSearch: exactFenSearch.value,
                      ),
                    ),
                  ],
                ),
              ),
              // CENTER — board column with breadcrumb + nav. Same slot the
              // board pane uses for chrome + board + MoveNavigationBar.
              SplitChild(
                minSize: 380,
                initialWeight: 0.41,
                label: 'Board',
                collapsedIcon: Icons.grid_on_rounded,
                dismissible: false,
                child: _BoardColumn(
                  position: position,
                  flipped: flipped.value,
                  lastMove: lastMove,
                  onMove: onBoardMove,
                  canGoBack: canBack,
                  canGoForward: canForward,
                  onFirst: () => jumpTo(0),
                  onPrev: () => jumpTo(cursor.value - 1),
                  onNext: () => jumpTo(cursor.value + 1),
                  onLast: () => jumpTo(history.value.length - 1),
                  onFlip: () => flipped.value = !flipped.value,
                  moveLabel: _moveLabel(history.value, cursor.value),
                  playFromHereStartingFen:
                      notationMoves.isEmpty ? null : notationStartPosition.fen,
                  playFromHereMovesUci: notationMoves,
                ),
              ),
              // RIGHT — analysis rail. Vertical split mirroring the board
              // pane: top 60% is the explorer move stats (analogous to the
              // notation panel slot), bottom 40% is the notation ladder
              // (analogous to the engine slot).
              SplitChild(
                minSize: 280,
                initialWeight: 0.30,
                label: 'Analysis',
                collapsedIcon: Icons.analytics_outlined,
                child: ResizableSplitView(
                  axis: Axis.vertical,
                  storageKey: 'opening_explorer.right_rail.v2',
                  children: [
                    SplitChild(
                      minSize: 200,
                      initialWeight: 0.60,
                      label: 'Moves',
                      collapsedIcon: Icons.account_tree_outlined,
                      child: ColoredBox(
                        color: kBlack2Color,
                        child: DesktopOpeningExplorer(
                          onMove: playUci,
                          onShowGames: (uci) => pinnedGamesUci.value = uci,
                        ),
                      ),
                    ),
                    SplitChild(
                      minSize: 180,
                      initialWeight: 0.40,
                      label: 'Notation',
                      collapsedIcon: Icons.format_list_numbered_rounded,
                      child: NotationLadderView(
                        game: notationGame,
                        activePointer: activeNotationPointer,
                        onJump: jumpNotation,
                        userNags: notationNags.value,
                        onSetUserQualityNag: setNotationQualityNag,
                        onToggleUserNag: toggleNotationNag,
                        onClearUserNags: clearNotationNags,
                        onSetMoveComment: setNotationComment,
                        useFigurine: notationUseFigurine,
                        pieceAssets: notationPieceAssets,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centre column — board + breadcrumb FEN copy + nav cluster pinned
/// directly under the board.
class _BoardColumn extends ConsumerWidget {
  const _BoardColumn({
    required this.position,
    required this.flipped,
    required this.lastMove,
    required this.onMove,
    required this.canGoBack,
    required this.canGoForward,
    required this.onFirst,
    required this.onPrev,
    required this.onNext,
    required this.onLast,
    required this.onFlip,
    required this.moveLabel,
    required this.playFromHereStartingFen,
    required this.playFromHereMovesUci,
  });

  final Position position;
  final bool flipped;
  final Move? lastMove;
  final void Function(Move move, {bool? viaDragAndDrop}) onMove;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onFirst;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onLast;
  final VoidCallback onFlip;
  final String moveLabel;
  final String? playFromHereStartingFen;
  final List<String> playFromHereMovesUci;

  static const double _evalBarWidth = 22;
  static const double _evalBarGap = 12;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orientation = flipped ? Side.black : Side.white;
    final isCheck = position.isCheck;
    final sideToMove = position.turn;
    final playerSide =
        position.isGameOver
            ? cg.PlayerSide.none
            : (sideToMove == Side.white
                ? cg.PlayerSide.white
                : cg.PlayerSide.black);

    return Column(
      children: [
        _PositionBreadcrumb(position: position),
        Container(height: 1, color: kDividerColor),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availableWidth =
                    constraints.biggest.width - _evalBarWidth - _evalBarGap;
                final availableHeight = constraints.biggest.height;
                final maxBoard =
                    availableWidth < availableHeight
                        ? availableWidth
                        : availableHeight;
                final boardSize = maxBoard.clamp(360.0, 760.0).toDouble();
                return Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: _evalBarWidth,
                        height: boardSize,
                        child: _ExplorerEvalBar(
                          fen: position.fen,
                          width: _evalBarWidth,
                          height: boardSize,
                          isFlipped: flipped,
                        ),
                      ),
                      const SizedBox(width: _evalBarGap),
                      SizedBox(
                        width: boardSize,
                        height: boardSize,
                        child: Consumer(
                          builder:
                              (context, ref, _) => GestureDetector(
                                onSecondaryTapUp: (details) {
                                  showPlayFromHereDialog(
                                    context,
                                    ref,
                                    seed: PlayFromHereSeed(
                                      fen: position.fen,
                                      startingFen: playFromHereStartingFen,
                                      movesUci: playFromHereMovesUci,
                                    ),
                                  );
                                },
                                child: DesktopChessBoard(
                                  size: boardSize,
                                  fen: position.fen,
                                  orientation: orientation,
                                  playerSide: playerSide,
                                  sideToMove: sideToMove,
                                  validMoves: makeLegalMoves(position),
                                  isCheck: isCheck,
                                  lastMove: lastMove,
                                  onMove: onMove,
                                  shapes: const fic.ISet<cg.Shape>.empty(),
                                ),
                              ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        MoveNavigationBar(
          canGoBack: canGoBack,
          canGoForward: canGoForward,
          onFirst: onFirst,
          onPrevious: onPrev,
          onNext: onNext,
          onLast: onLast,
          onFlipBoard: onFlip,
          moveLabel: moveLabel,
        ),
      ],
    );
  }
}

/// Active-pin breadcrumb shown above the games rail. Reads as
/// "Games for: 1.e4 ×" — clicking × clears the pin and reverts to the
/// full FEN games listing.
class _PinnedUciChip extends StatelessWidget {
  const _PinnedUciChip({
    required this.fen,
    required this.uci,
    required this.onClear,
  });

  final String fen;
  final String uci;
  final VoidCallback onClear;

  String _san() {
    try {
      final setup = Setup.parseFen(fen);
      final pos = Chess.fromSetup(setup, ignoreImpossibleCheck: true);
      final move = Move.parse(uci);
      if (move == null) return uci;
      return pos.makeSan(move).$2;
    } catch (_) {
      return uci;
    }
  }

  @override
  Widget build(BuildContext context) {
    final san = _san();
    return ColoredBox(
      color: kBlack2Color,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            const Text(
              'Games for:',
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: kPrimaryColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: kPrimaryColor.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    san,
                    style: const TextStyle(
                      color: kPrimaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 6),
                  ClickCursor(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onClear,
                      child: const Icon(
                        Icons.close_rounded,
                        size: 13,
                        color: kPrimaryColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Position breadcrumb at the top of the board column. Shows side-to-
/// move + a quiet copy-FEN button. Replaces the mobile screen's
/// app-bar.
class _PositionBreadcrumb extends StatefulWidget {
  const _PositionBreadcrumb({required this.position});
  final Position position;

  @override
  State<_PositionBreadcrumb> createState() => _PositionBreadcrumbState();
}

class _PositionBreadcrumbState extends State<_PositionBreadcrumb> {
  bool _justCopied = false;

  Future<void> _copyFen() async {
    await Clipboard.setData(ClipboardData(text: widget.position.fen));
    if (!mounted) return;
    setState(() => _justCopied = true);
    Future.delayed(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _justCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final sideToMove =
        widget.position.turn == Side.white ? 'White to move' : 'Black to move';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color:
                  widget.position.turn == Side.white
                      ? kWhiteColor
                      : Colors.black,
              shape: BoxShape.circle,
              border: Border.all(color: kDividerColor),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            sideToMove,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          DesktopTooltip(
            message: _justCopied ? 'Copied' : 'Copy FEN',
            child: ClickCursor(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _copyFen,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _justCopied
                            ? kPrimaryColor.withValues(alpha: 0.18)
                            : kBlack3Color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _justCopied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 12,
                        color: _justCopied ? kPrimaryColor : kWhiteColor70,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'FEN',
                        style: TextStyle(
                          color: kWhiteColor70,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live eval bar for the explorer board. Drives `explorerEvalProvider`
/// (the same notifier the mobile gamebase explorer uses) and feeds its
/// streamed eval/mate/isEvaluating into `DesktopEvalBar` so the desktop
/// pane matches the mobile bar's UI and behaviour.
class _ExplorerEvalBar extends ConsumerStatefulWidget {
  const _ExplorerEvalBar({
    required this.fen,
    required this.width,
    required this.height,
    required this.isFlipped,
  });

  final String fen;
  final double width;
  final double height;
  final bool isFlipped;

  @override
  ConsumerState<_ExplorerEvalBar> createState() => _ExplorerEvalBarState();
}

class _ExplorerEvalBarState extends ConsumerState<_ExplorerEvalBar> {
  String _positionKey(String fen) {
    final parts = fen.trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return fen.trim();
    return parts.take(4).join(' ');
  }

  bool _samePosition(String a, String b) => _positionKey(a) == _positionKey(b);

  void _syncEngineState({bool force = false}) {
    ref
        .read(explorerEvalProvider.notifier)
        .setEngineEnabled(enabled: true, fen: widget.fen, force: force);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncEngineState(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant _ExplorerEvalBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePosition(widget.fen, oldWidget.fen)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncEngineState(force: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final evalState = ref.watch(explorerEvalProvider);
    final currentKey = _positionKey(widget.fen);
    final isEvalForCurrentPosition = currentKey == _positionKey(evalState.fen);

    return DesktopEvalBar(
      width: widget.width,
      height: widget.height,
      isFlipped: widget.isFlipped,
      evaluation: isEvalForCurrentPosition ? evalState.evaluation : null,
      mate: isEvalForCurrentPosition ? evalState.mate : null,
      isEvaluating: isEvalForCurrentPosition ? evalState.isEvaluating : true,
      positionKey: currentKey,
    );
  }
}

class _ExplorerPly {
  const _ExplorerPly({required this.position, required this.move});
  final Position position;
  final Move? move;
}

/// Build the initial `Position` for the explorer, falling back to the
/// standard starting position when [fen] is null or unparseable. The
/// caller (the pane's `useState` initialiser) needs a synchronous
/// non-null value, so we never throw — a malformed seed just degrades
/// to the start position.
Position _seedPosition(String? fen) {
  if (fen == null || fen.trim().isEmpty) return Chess.initial;
  try {
    final setup = Setup.parseFen(fen);
    return Chess.fromSetup(setup, ignoreImpossibleCheck: true);
  } catch (_) {
    return Chess.initial;
  }
}

List<String> _sanitizeUcis(List<String> moves) {
  final uciPattern = RegExp(r'^[a-h][1-8][a-h][1-8][qrbn]?$');
  return moves
      .map((m) => m.trim().toLowerCase())
      .where(uciPattern.hasMatch)
      .toList(growable: false);
}

ChessGame _notationGameFromUcis({
  required Position startingPosition,
  required List<String> ucis,
  Map<int, String> commentsByPly = const <int, String>{},
}) {
  var position = startingPosition;
  final mainline = <ChessMove>[];

  for (final uci in ucis) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) break;
    final san = position.makeSan(move).$2;
    final next = position.playUnchecked(move);
    mainline.add(
      ChessMove(
        num: position.fullmoves,
        fen: next.fen,
        san: san,
        uci: move.uci,
        turn: position.turn == Side.black ? ChessColor.black : ChessColor.white,
        comments:
            (commentsByPly[mainline.length]?.trim().isNotEmpty ?? false)
                ? <String>[commentsByPly[mainline.length]!.trim()]
                : null,
      ),
    );
    position = next;
  }

  return ChessGame(
    gameId: 'opening-explorer',
    startingFen: startingPosition.fen,
    metadata: const <String, dynamic>{
      'Event': 'Opening Explorer',
      'Result': '*',
    },
    mainline: List<ChessMove>.unmodifiable(mainline),
  );
}

Position? _positionAfterUcis(Position startingPosition, List<String> ucis) {
  var position = startingPosition;
  for (final uci in ucis) {
    final move = Move.parse(uci);
    if (move == null || !position.isLegal(move)) return null;
    position = position.playUnchecked(move);
  }
  return position;
}

Map<int, List<int>> _pruneNags(Map<int, List<int>> nags, int moveCount) {
  if (nags.isEmpty) return nags;
  return Map<int, List<int>>.unmodifiable(
    Map<int, List<int>>.fromEntries(
      nags.entries.where((entry) => entry.key < moveCount),
    ),
  );
}

Map<int, String> _pruneComments(Map<int, String> comments, int moveCount) {
  if (comments.isEmpty) return comments;
  return Map<int, String>.unmodifiable(
    Map<int, String>.fromEntries(
      comments.entries.where((entry) => entry.key < moveCount),
    ),
  );
}

String _moveLabel(List<_ExplorerPly> history, int cursor) {
  if (cursor == 0) return 'Start position';
  final fullMove = (cursor + 1) ~/ 2;
  final isWhite = cursor.isOdd;
  final marker = isWhite ? '$fullMove.' : '$fullMove…';
  final progress = '$cursor / ${history.length - 1}';
  return '$marker   ·   $progress';
}

/// Small banner above the games rail. Hosts the "Games" label and the
/// filter trigger — both filters and the games table read from the same
/// `gamebaseExplorerProvider` so opening the popover from here updates
/// the table beneath it.
class _GamesRailHeader extends StatelessWidget {
  const _GamesRailHeader({required this.scopedPlayer});

  final GamebasePlayer? scopedPlayer;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBlack2Color,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Text(
              'Games',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const Spacer(),
            ExplorerFiltersPopoverButton(scopedPlayer: scopedPlayer),
          ],
        ),
      ),
    );
  }
}

class _PrevIntent extends Intent {
  const _PrevIntent();
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _FirstIntent extends Intent {
  const _FirstIntent();
}

class _LastIntent extends Intent {
  const _LastIntent();
}

class _FlipIntent extends Intent {
  const _FlipIntent();
}
