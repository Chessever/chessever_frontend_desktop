import 'dart:math' as math;

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/game_tab_drag_payload.dart';
import 'package:chessever/desktop/widgets/motion_card.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/chessboard/widgets/evaluation_bar_widget.dart';
import 'package:chessever/screens/chessboard/widgets/player_first_row_detail_widget.dart'
    show PlayerView;
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_list_view_mode_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/atomic_countdown_text.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';

const String _kStartFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// View modes for the desktop game card. Each renders inside the multi-
/// column [DesktopGameCardsFlow]; the desktop look is its own thing and
/// not tied to the mobile card layouts.
enum DesktopCardLayout { compact, list, grid }

/// Reads desktop's [DesktopCardLayout] off the existing persisted
/// [GamesListViewMode] record so the in-toolbar Compact / List / Grid
/// toggle stays in sync everywhere — purely a persistence/dispatch
/// helper, not a styling contract with mobile.
extension GamesListViewModeDesktopX on GamesListViewMode {
  DesktopCardLayout get desktopLayout {
    switch (this) {
      case GamesListViewMode.gamesCard:
        return DesktopCardLayout.compact;
      case GamesListViewMode.chessBoardGrid:
        return DesktopCardLayout.grid;
      case GamesListViewMode.chessBoard:
        return DesktopCardLayout.list;
    }
  }
}

final _desktopGamebaseFinalFenProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, gameId) async {
      final normalizedGameId = gameId.trim();
      if (normalizedGameId.isEmpty) return null;

      final repo = ref.read(gamebaseRepositoryProvider);
      final gameWithPgn = await repo.getGameWithPgn(normalizedGameId);
      if (gameWithPgn == null) return null;

      final pgn =
          (gameWithPgn.pgn?.trim().isNotEmpty ?? false)
              ? gameWithPgn.pgn!.trim()
              : buildPgnFromGamebaseData(gameWithPgn.data);
      final resolvedFen = resolveFinalPositionFromPgn(pgn)?.fen;
      return isValidGameFen(resolvedFen) ? resolvedFen : null;
    });

/// One game card, used in both the list and grid game-tour layouts.
///
/// Driven by [GameCardData] so the same card renders both live tournament
/// games and saved analyses out of the Library. Board-visible layouts show a
/// real chessground preview of the FEN rather than a placeholder icon, while
/// compact mode stays metadata-only for dense scanning.
class DesktopGameCard extends ConsumerWidget {
  const DesktopGameCard({
    super.key,
    required this.data,
    required this.onTap,
    this.layout = DesktopCardLayout.list,
    this.selected = false,
    this.dragPayload,
    this.onContextMenu,
    this.allowStockfishFallback = true,
  });

  final GameCardData data;
  final VoidCallback onTap;
  final DesktopCardLayout layout;
  final bool selected;
  final ValueChanged<Offset>? onContextMenu;

  /// When false, the eval bar inside this card will only display cached or
  /// server-resolved evaluations and skip the local Stockfish fallback path.
  /// Set to false while a feed is actively scrolling so the user's main
  /// thread isn't competing with engine evaluations they can't see settle.
  final bool allowStockfishFallback;

  /// When supplied, the card becomes draggable: press-and-hold + drag
  /// onto the tab strip spawns a Board tab focused on this game (see
  /// `DesktopTabBar`'s drop target). We use a *long-press* draggable
  /// (with a deliberately short delay) so vertical drags inside a
  /// scrollable list still scroll the list — only an intentional press
  /// initiates a tab spawn. Same pattern the reorderable tab strip uses
  /// for its own drag handles.
  final GameTabDragPayload? dragPayload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showEvaluationBar =
        ref.watch(boardSettingsProviderNew).valueOrNull?.showEvaluationBar ??
        true;
    final Widget card;
    switch (layout) {
      case DesktopCardLayout.grid:
        card = _GridLayout(
          data: data,
          selected: selected,
          allowStockfishFallback: allowStockfishFallback,
          showEvaluationBar: showEvaluationBar,
        );
      case DesktopCardLayout.compact:
        card = _CompactLayout(
          data: data,
          selected: selected,
          allowStockfishFallback: allowStockfishFallback,
          showEvaluationBar: showEvaluationBar,
        );
      case DesktopCardLayout.list:
        card = _ListLayout(
          data: data,
          selected: selected,
          allowStockfishFallback: allowStockfishFallback,
          showEvaluationBar: showEvaluationBar,
        );
    }

    final payload = dragPayload;
    void openInBackgroundTab() {
      final p = payload;
      if (p == null) {
        onTap();
        return;
      }
      p.spawn(ref, focus: false);
    }

    final tappable = ClickCursor(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (event.buttons & kTertiaryButton != 0) {
            openInBackgroundTab();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown:
              onContextMenu == null
                  ? null
                  : (details) => onContextMenu!(details.globalPosition),
          onTap: () {
            if (payload != null && isNewTabModifierPressed()) {
              openInBackgroundTab();
              return;
            }
            onTap();
          },
          child: card,
        ),
      ),
    );

    if (payload == null) return tappable;

    // Drag feedback is a compact pill mimicking a tab chip (icon + names)
    // so the strip's drop target reads as "this becomes a tab". Sized to
    // a comfortable cursor-anchor width, not the full card — dragging a
    // 700-px card around the screen feels heavy.
    return LongPressDraggable<GameTabDragPayload>(
      data: payload,
      delay: const Duration(milliseconds: 220),
      hapticFeedbackOnStart: false,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _GameDragFeedback(data: data),
      childWhenDragging: Opacity(opacity: 0.4, child: tappable),
      child: tappable,
    );
  }
}

/// Compact cursor-anchored chip rendered while a game card is being
/// dragged. Material is required for text rendering inside an Overlay.
class _GameDragFeedback extends StatelessWidget {
  const _GameDragFeedback({required this.data});
  final GameCardData data;

  @override
  Widget build(BuildContext context) {
    final label =
        data.whiteName.isEmpty && data.blackName.isEmpty
            ? data.title
            : '${_shortName(data.whiteName)} vs ${_shortName(data.blackName)}';
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.grid_4x4_outlined, size: 14, color: kPrimaryColor),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortName(String n) {
    final t = n.trim();
    if (t.isEmpty) return '';
    if (t.contains(',')) return t.split(',').first.trim();
    final parts = t.split(RegExp(r'\s+'));
    return parts.length == 1 ? parts.first : parts.last;
  }
}

class _ListLayout extends StatefulWidget {
  const _ListLayout({
    required this.data,
    required this.selected,
    required this.allowStockfishFallback,
    required this.showEvaluationBar,
  });
  final GameCardData data;
  final bool selected;
  final bool allowStockfishFallback;
  final bool showEvaluationBar;

  @override
  State<_ListLayout> createState() => _ListLayoutState();
}

class _ListLayoutState extends State<_ListLayout> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Editorial list card. Three pieces of furniture only: the position
    // (board + horizontal eval gauge), two clean player rows separated
    // by a hairline, and a tiny live pulse in the top-right corner when
    // the game is in play. No status text, no ECO chip, no footer.
    // Ambient state tint on the tile surface carries finished/live so
    // the eye sorts a flow without reading a single chip.
    final highlight = widget.selected || _hovered;
    final baseFill = _tileBaseFill(data: widget.data, highlight: highlight);
    final borderColor =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.48)
            : (_hovered
                ? kPrimaryColor.withValues(alpha: 0.14)
                : kDividerColor);
    final isLive = widget.data.hasStarted && !widget.data.status.isFinished;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: MotionCard(
        borderRadius: 12,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: baseFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
            // Selection keeps a persistent shadow; the hover/press shadow is
            // now owned by the [MotionCard] dock above.
            boxShadow:
                widget.selected
                    ? [
                      BoxShadow(
                        color: kPrimaryColor.withValues(alpha: 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ]
                    : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(12, isLive ? 14 : 12, 12, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: _BoardPreview(
                            data: widget.data,
                            flipped: false,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _CleanPlayerRow(data: widget.data, isWhite: true),
                            const _TileHairline(),
                            _CleanPlayerRow(data: widget.data, isWhite: false),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (isLive) ...[
                  if (widget.showEvaluationBar)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _HorizontalEvalBar(
                        fen: widget.data.fen,
                        height: 3,
                        allowStockfishFallback: widget.allowStockfishFallback,
                      ),
                    ),
                  Positioned(
                    top: 8,
                    right: 10,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _Pulse(color: kPrimaryColor),
                        const SizedBox(width: 6),
                        _LiveEvalScoreText(
                          fen: widget.data.fen,
                          allowStockfishFallback: widget.allowStockfishFallback,
                        ),
                      ],
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

/// Tile background fill. Picks a subtle state-aware ambient tint on top
/// of the base kBlack2/kBlack3 surfaces — green for LIVE, primary for
/// finished — so cards advertise their state without a billboard pill.
/// The tints are 4–7% opacity so they read as atmosphere, not a stamp.
Color _tileBaseFill({required GameCardData data, required bool highlight}) {
  final base = highlight ? kBlack3Color : kBlack2Color;
  if (data.hasStarted && !data.status.isFinished) {
    return Color.alphaBlend(
      kPrimaryColor.withValues(alpha: highlight ? 0.045 : 0.025),
      base,
    );
  }
  if (data.status.isFinished) {
    return Color.alphaBlend(
      kPrimaryColor.withValues(alpha: highlight ? 0.025 : 0.012),
      base,
    );
  }
  return base;
}

/// Hairline divider with a transparent → divider → transparent gradient so
/// it reads as a typographic seam rather than a hard rule. Used between
/// the white/black player rows.
class _TileHairline extends StatelessWidget {
  const _TileHairline();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            kDividerColor.withValues(alpha: 0.65),
            kDividerColor.withValues(alpha: 0.65),
            Colors.transparent,
          ],
          stops: const [0.0, 0.18, 0.82, 1.0],
        ),
      ),
    );
  }
}

/// Editorial player row on list tiles. Three columns, generously
/// spaced: player name (large, white), rating (small, muted, tabular),
/// result digit (right-aligned, color-coded). No flag, no title chip,
/// no clock — they cluttered the tile and the user already has the
/// board to identify the position. Hairline divider between the two
/// rows is handled by the caller via [_TileHairline].
class _CleanPlayerRow extends StatelessWidget {
  const _CleanPlayerRow({required this.data, required this.isWhite});

  final GameCardData data;
  final bool isWhite;

  @override
  Widget build(BuildContext context) {
    final name = isWhite ? data.whiteName : data.blackName;
    final rating = isWhite ? data.whiteRating : data.blackRating;
    final fed = isWhite ? data.whiteFederation : data.blackFederation;
    final fideId = isWhite ? data.whiteFideId : data.blackFideId;
    final title = isWhite ? data.whiteTitle : data.blackTitle;
    final result = _resultFor(data.status, isWhite: isWhite);
    const nameColor = kWhiteColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          _SideMarker(isWhite: isWhite, compact: false),
          const SizedBox(width: 8),
          BackfilledFederationFlag(
            federation: fed,
            fideId: fideId,
            width: 18,
            height: 12,
            borderRadius: BorderRadius.circular(2),
          ),
          if (title.isNotEmpty) ...[
            const SizedBox(width: 6),
            _TitleChip(title: title, compact: true),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name.isEmpty ? 'Unknown' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: nameColor,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.05,
                height: 1.15,
              ),
            ),
          ),
          if (rating > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$rating',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (result.isNotEmpty) ...[
            const SizedBox(width: 10),
            _ResultBadge(label: result, compact: false),
          ],
        ],
      ),
    );
  }
}

/// One side of the compact face-off tile. Name on top (large, white,
/// flips to kPrimaryColor when on move). Below the name sits a tight
/// meta line: federation flag, optional title chip, and rating in
/// small muted tabular numerals. Black mirrors right-aligned so the
/// two sides read as opposing teams.
class _CleanFaceOffBlock extends StatelessWidget {
  const _CleanFaceOffBlock({required this.data, required this.isWhite});

  final GameCardData data;
  final bool isWhite;

  @override
  Widget build(BuildContext context) {
    final name = isWhite ? data.whiteName : data.blackName;
    final rating = isWhite ? data.whiteRating : data.blackRating;
    final fed = isWhite ? data.whiteFederation : data.blackFederation;
    final fideId = isWhite ? data.whiteFideId : data.blackFideId;
    final title = isWhite ? data.whiteTitle : data.blackTitle;
    const nameColor = kWhiteColor;
    final alignment =
        isWhite ? CrossAxisAlignment.start : CrossAxisAlignment.end;
    final textAlign = isWhite ? TextAlign.start : TextAlign.end;
    final mainAlign = isWhite ? MainAxisAlignment.start : MainAxisAlignment.end;

    final meta = <Widget>[
      BackfilledFederationFlag(
        federation: fed,
        fideId: fideId,
        width: 16,
        height: 11,
        borderRadius: BorderRadius.circular(2),
      ),
      if (title.isNotEmpty) ...[
        const SizedBox(width: 5),
        _TitleChip(title: title, compact: true),
      ],
      if (rating > 0) ...[
        const SizedBox(width: 6),
        Text(
          '$rating',
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ];

    return Column(
      crossAxisAlignment: alignment,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name.isEmpty ? 'Unknown' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
          style: TextStyle(
            color: nameColor,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.05,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: mainAlign,
          mainAxisSize: MainAxisSize.max,
          children: isWhite ? meta : meta.reversed.toList(growable: false),
        ),
      ],
    );
  }
}

/// Score panel anchored to the right edge of compact tiles. Renders the
/// composite final score ("1 – 0", "½ – ½") for finished games and a quiet
/// face-off placeholder before a game starts. Ongoing games leave this slot
/// blank because the top-right pulse/eval strip already carries live state;
/// showing a dash/minus there reads like a wrong result while play is active.
class _CompactScorePanel extends StatelessWidget {
  const _CompactScorePanel({required this.data});
  final GameCardData data;

  @override
  Widget build(BuildContext context) {
    if (data.status.isFinished) {
      final winning =
          data.status == GameStatus.draw ? kLightGreyColor : kPrimaryColor;
      return _ScorePlate(label: _resultLabel(data.status), color: winning);
    }
    if (data.hasStarted) {
      return const SizedBox(width: 60);
    }
    return _ScorePlate(
      label: 'vs',
      color: kLightGreyColor.withValues(alpha: 0.55),
    );
  }
}

/// Standalone score readout used as the center column of the compact
/// face-off card. No box, no border, no background — just the text
/// (or dot) sitting on the tile surface. Constrained to a 60 px
/// minimum width so the score column stays visually stable down a
/// flow of mixed finished / live / unstarted rows.
class _ScorePlate extends StatelessWidget {
  const _ScorePlate({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 60),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Passive lightweight eval readout shown next to the live pulse:
/// e.g. "+0.34", "-1.2", or "M5". Watches the same provider chain as
/// [_HorizontalEvalBar] so there is no second engine call; loading /
/// error states collapse to an empty box (the pulse alone carries
/// the "this game is live" signal in that case).
class _LiveEvalScoreText extends ConsumerWidget {
  const _LiveEvalScoreText({
    required this.fen,
    this.allowStockfishFallback = true,
  });

  final String? fen;
  final bool allowStockfishFallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = fen?.trim();
    if (f == null || f.isEmpty) return const SizedBox.shrink();
    final async =
        allowStockfishFallback
            ? ref.watch(gameCardEvalWithStockfishFallbackProvider(f))
            : ref.watch(gameCardEvalCacheOnlyProvider(f));
    return async.maybeWhen(
      data: (cloud) {
        final pv = cloud.pvs.firstOrNull;
        if (pv == null) return const SizedBox.shrink();
        final label = _formatEvalLabel(pv);
        if (label == null) return const SizedBox.shrink();
        return Text(
          label,
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// Passive centered eval-score strip pinned just under the top-edge
/// eval bar on compact tiles. Mirrored at the bottom edge by
/// [_LiveLastMoveStrip], so the two read as a paired top/bottom
/// supplemental annotation.
class _LiveTopInfoStrip extends StatelessWidget {
  const _LiveTopInfoStrip({
    required this.fen,
    this.allowStockfishFallback = true,
  });

  final String? fen;
  final bool allowStockfishFallback;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 12,
      child: Center(
        child: _LiveEvalScoreText(
          fen: fen,
          allowStockfishFallback: allowStockfishFallback,
        ),
      ),
    );
  }
}

/// Passive centered last-move strip pinned right above the bottom
/// edge of compact tiles. Pairs with [_LiveTopInfoStrip] so the two
/// supplemental lines sit mirrored — eval at the top, move at the
/// bottom — and stay clear of the central face-off row.
class _LiveLastMoveStrip extends StatelessWidget {
  const _LiveLastMoveStrip({required this.lastMove});
  final String? lastMove;

  @override
  Widget build(BuildContext context) {
    final move = lastMove?.trim();
    if (move == null || move.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 12,
      child: Center(
        child: Text(
          move,
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

String? _formatEvalLabel(Pv pv) {
  if (pv.isMate) {
    final m = pv.mate;
    if (m == null) return null;
    final sign = m >= 0 ? '+' : '−';
    return '${sign}M${m.abs()}';
  }
  final whiteCp = pv.whitePerspective ? pv.cp : -pv.cp;
  final sign = whiteCp >= 0 ? '+' : '−';
  final magnitude = (whiteCp.abs() / 100).toStringAsFixed(1);
  return '$sign$magnitude';
}

/// Horizontal evaluation bar. Used at the bottom of list-tile board
/// columns and across the top edge of compact tiles. Implemented by
/// rotating the canonical [EvaluationBarWidgetForGames] 90° so the
/// engine-cached / Stockfish-fallback math reuses the same provider
/// path as the vertical rail — no parallel display logic to drift.
class _HorizontalEvalBar extends StatelessWidget {
  const _HorizontalEvalBar({
    required this.fen,
    required this.height,
    this.allowStockfishFallback = true,
  });

  final String? fen;
  final double height;
  final bool allowStockfishFallback;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = height;
          if (!w.isFinite || w <= 0 || !h.isFinite || h <= 0) {
            return const SizedBox.shrink();
          }
          final f = fen;
          if (f == null || f.isEmpty) {
            return const Row(
              children: [
                Expanded(child: ColoredBox(color: kWhiteColor)),
                Expanded(child: ColoredBox(color: kPopUpColor)),
              ],
            );
          }
          return RotatedBox(
            quarterTurns: 1,
            child: EvaluationBarWidgetForGames(
              width: h,
              height: w,
              fen: f,
              playerView: PlayerView.gridView,
              allowStockfishFallback: allowStockfishFallback,
              showText: false,
            ),
          );
        },
      ),
    );
  }
}

/// Densest layout — no board preview, thin eval rail, both player rows
/// stacked. Use when the user is skimming a long folder and wants signal
/// per pixel; the chessground previews on `_ListLayout` and `_GridLayout`
/// are heavier than they look (one per row), and dropping them lets us
/// pack ~50% more rows on a 1440p screen.
class _CompactLayout extends StatefulWidget {
  const _CompactLayout({
    required this.data,
    required this.selected,
    required this.allowStockfishFallback,
    required this.showEvaluationBar,
  });
  final GameCardData data;
  final bool selected;
  final bool allowStockfishFallback;
  final bool showEvaluationBar;

  @override
  State<_CompactLayout> createState() => _CompactLayoutState();
}

class _CompactLayoutState extends State<_CompactLayout> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // Editorial scorecard. One row: White (name / rating) — score —
    // Black (rating / name, mirrored). No flags, no titles, no clocks,
    // no opening, no eval bar across the top. A tiny live pulse in the
    // top-right corner is the only state chrome; ambient tint handles
    // the rest. Designed to read clearly even at 220 px tile width.
    const cardHeight = 82.0;

    final highlight = widget.selected || _hovered;
    final baseFill = _tileBaseFill(data: widget.data, highlight: highlight);
    final borderColor =
        widget.selected
            ? kPrimaryColor.withValues(alpha: 0.48)
            : (_hovered
                ? kPrimaryColor.withValues(alpha: 0.14)
                : kDividerColor);
    final isLive = widget.data.hasStarted && !widget.data.status.isFinished;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: MotionCard(
        borderRadius: 10,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: cardHeight,
          decoration: BoxDecoration(
            color: baseFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
            // Selection keeps a persistent shadow; hover/press shadow is
            // now owned by the [MotionCard] dock above.
            boxShadow:
                widget.selected
                    ? [
                      BoxShadow(
                        color: kPrimaryColor.withValues(alpha: 0.08),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ]
                    : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Stack(
              children: [
                Padding(
                  // When live, top padding clears the 3 px top-edge
                  // eval bar plus the 12 px centered eval-score strip
                  // beneath it; bottom padding clears the mirrored
                  // 12 px last-move strip pinned at the bottom edge.
                  // Non-live tiles keep the calmer 10 px both ways.
                  padding: EdgeInsets.fromLTRB(
                    14,
                    isLive ? 22 : 10,
                    14,
                    isLive ? 18 : 10,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _CleanFaceOffBlock(
                          data: widget.data,
                          isWhite: true,
                        ),
                      ),
                      const SizedBox(width: 12),
                      _CompactScorePanel(data: widget.data),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _CleanFaceOffBlock(
                          data: widget.data,
                          isWhite: false,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isLive) ...[
                  if (widget.showEvaluationBar)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _HorizontalEvalBar(
                        fen: widget.data.fen,
                        height: 3,
                        allowStockfishFallback: widget.allowStockfishFallback,
                      ),
                    ),
                  Positioned(
                    top: 5,
                    left: 12,
                    right: 12,
                    child: _LiveTopInfoStrip(
                      fen: widget.data.fen,
                      allowStockfishFallback: widget.allowStockfishFallback,
                    ),
                  ),
                  Positioned(
                    bottom: 4,
                    left: 12,
                    right: 12,
                    child: _LiveLastMoveStrip(lastMove: widget.data.lastMove),
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

class _GridLayout extends StatefulWidget {
  const _GridLayout({
    required this.data,
    required this.selected,
    required this.allowStockfishFallback,
    required this.showEvaluationBar,
  });
  final GameCardData data;
  final bool selected;
  final bool allowStockfishFallback;
  final bool showEvaluationBar;

  @override
  State<_GridLayout> createState() => _GridLayoutState();
}

class _GridLayoutState extends State<_GridLayout> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlight = widget.selected || _hovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: MotionCard(
        borderRadius: 12,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: highlight ? kBlack3Color : kBlack2Color,
            borderRadius: BorderRadius.circular(12),
            // Selection keeps a persistent shadow; hover/press shadow is
            // now owned by the [MotionCard] dock above.
            boxShadow:
                widget.selected
                    ? [
                      BoxShadow(
                        color: kPrimaryColor.withValues(alpha: 0.08),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ]
                    : null,
            border: Border.all(
              color:
                  widget.selected
                      ? kPrimaryColor.withValues(alpha: 0.48)
                      : (_hovered
                          ? kPrimaryColor.withValues(alpha: 0.16)
                          : kDividerColor),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PlayerRow(
                  data: widget.data,
                  isWhite: false,
                  result: _resultFor(widget.data.status, isWhite: false),
                  compact: true,
                ),
                const SizedBox(height: 10),
                Expanded(
                  // Build the eval-bar + board-preview square *off the cell
                  // width*, not via AspectRatio inside the Expanded. The
                  // AspectRatio approach NaN'd during GridView.shrinkWrap's
                  // intrinsic-sizing pass: the parent column hands its
                  // Expanded child unbounded height for intrinsic-dry
                  // layout, AspectRatio of 1 then returns infinity ×
                  // infinity, the inner LayoutBuilder receives
                  // maxHeight=infinity, the eval bar's `whiteHeight = ratio
                  // × infinity` collapses to NaN, and every constraint
                  // downstream goes NaN. Reading `maxWidth` first (always
                  // finite for a grid cell from
                  // SliverGridDelegateWithFixedCrossAxisCount) and forcing
                  // a square via SizedBox keeps the chain finite.
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final h = constraints.maxHeight;
                      if (!w.isFinite || w <= 0) {
                        return const SizedBox.shrink();
                      }
                      // Defensive: if maxHeight isn't finite (shrink-wrap
                      // intrinsic pass), fall back to the cell width so
                      // the square still has a valid size. The parent
                      // re-lays-out with finite constraints on the next
                      // pass; this just keeps us from emitting NaN.
                      final hSafe = h.isFinite ? h : w;
                      final side = math.min(w, hSafe);
                      if (!side.isFinite || side <= 0) {
                        return const SizedBox.shrink();
                      }
                      final railWidth = widget.showEvaluationBar ? 14.0 : 0.0;
                      final boardSide = math.min(w - railWidth, hSafe);
                      if (!boardSide.isFinite || boardSide <= 0) {
                        return const SizedBox.shrink();
                      }
                      return Center(
                        child: SizedBox(
                          width: boardSide + railWidth,
                          height: boardSide,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (widget.showEvaluationBar)
                                  // Give the mini-board eval rail enough
                                  // left-side width for readable numeric
                                  // labels. The earlier 8px sliver made the
                                  // top readout effectively disappear in dense
                                  // tournament grids.
                                  SizedBox(
                                    width: railWidth,
                                    height: boardSide,
                                    child: _EvalRail(
                                      fen: widget.data.fen,
                                      width: railWidth,
                                      height: boardSide,
                                      view: PlayerView.gridView,
                                      allowStockfishFallback:
                                          widget.allowStockfishFallback,
                                    ),
                                  ),
                                Expanded(
                                  child: _BoardPreview(
                                    data: widget.data,
                                    flipped: false,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                _PlayerRow(
                  data: widget.data,
                  isWhite: true,
                  result: _resultFor(widget.data.status, isWhite: true),
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Side-rail eval bar that gracefully degrades when no FEN is available
/// (50/50 placeholder split, matching the in-board eval bar).
class _EvalRail extends StatelessWidget {
  const _EvalRail({
    required this.fen,
    required this.width,
    required this.height,
    required this.view,
    this.allowStockfishFallback = true,
  });

  final String? fen;
  final double width;
  final double height;
  final PlayerView view;

  /// When false, the evaluation bar suppresses local Stockfish fallback while
  /// keeping cached / server-resolved evaluations. Used to avoid kicking off
  /// engine analyses for cards the user is rapidly scrolling past.
  final bool allowStockfishFallback;

  @override
  Widget build(BuildContext context) {
    final f = fen;
    // Defensive: an invalid (NaN / non-positive / infinite) height fed
    // to EvaluationBarWidgetForGames cascades NaN through the inner
    // Stack's `whiteHeight = ratio × height` math. Bail to the static
    // placeholder split so the layout pass never emits NaN constraints.
    final hOk = width.isFinite && width > 0 && height.isFinite && height > 0;
    if (!hOk || f == null || f.isEmpty) {
      return const _NoEvalSplit();
    }
    return EvaluationBarWidgetForGames(
      width: width,
      height: height,
      fen: f,
      playerView: view,
      allowStockfishFallback: allowStockfishFallback,
    );
  }
}

/// Static (non-interactive) chessground preview of a FEN. Used inside grid
/// game cards as the "second visual cue" beside the eval bar.
class _BoardPreview extends ConsumerWidget {
  const _BoardPreview({required this.data, required this.flipped});

  final GameCardData data;
  final bool flipped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localFen = data.fen?.trim();
    final hasLocalFen = isValidGameFen(localFen);
    final remoteFen =
        !hasLocalFen && data.canResolveRemoteFen
            ? ref
                .watch(_desktopGamebaseFinalFenProvider(data.id))
                .valueOrNull
                ?.trim()
            : null;
    final resolvedFen =
        isValidGameFen(remoteFen)
            ? remoteFen!
            : (hasLocalFen
                ? localFen!
                : (data.canResolveRemoteFen ? _kStartFen : null));

    if (resolvedFen == null || resolvedFen.isEmpty) {
      return Container(
        color: kBackgroundColor,
        alignment: Alignment.center,
        child: const Icon(
          Icons.hourglass_empty_rounded,
          color: kLightGreyColor,
          size: 18,
        ),
      );
    }
    // Pull the same colour scheme + piece set the main board uses so a
    // theme change in Settings re-skins these grid previews too.
    final settings =
        ref.watch(boardSettingsProviderNew).valueOrNull ??
        const BoardSettingsNew();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Chessground takes a fixed `size` and renders square. Use the
        // shorter side so it always fits, and center inside the parent so
        // any extra vertical space stays balanced.
        final side = constraints.biggest.shortestSide;
        return Center(
          child: cg.Chessboard.fixed(
            size: side,
            fen: resolvedFen,
            orientation: flipped ? Side.black : Side.white,
            settings: cg.ChessboardSettings(
              enableCoordinates: false,
              colorScheme: settings.colorScheme,
              pieceAssets: settings.pieceAssets,
            ),
            shapes: const ISet<cg.Shape>.empty(),
            lastMove: _uciToMove(data.lastMove ?? ''),
          ),
        );
      },
    );
  }
}

Move? _uciToMove(String uci) {
  if (uci.length != 4 && uci.length != 5) {
    return null;
  }
  try {
    final from = Square.fromName(uci.substring(0, 2));
    final to = Square.fromName(uci.substring(2, 4));
    final promotion = uci.length == 5 ? Role.fromChar(uci[4]) : null;
    return NormalMove(from: from, to: to, promotion: promotion);
  } catch (_) {
    return null;
  }
}

class _PlayerRow extends StatelessWidget {
  const _PlayerRow({
    required this.data,
    required this.isWhite,
    required this.result,
    this.compact = false,
  });

  final GameCardData data;
  final bool isWhite;
  final String result; // '1', '0', '½', or empty while ongoing/unknown.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final name = isWhite ? data.whiteName : data.blackName;
    final fed = isWhite ? data.whiteFederation : data.blackFederation;
    final fideId = isWhite ? data.whiteFideId : data.blackFideId;
    final title = isWhite ? data.whiteTitle : data.blackTitle;
    final rating = isWhite ? data.whiteRating : data.blackRating;
    final clockSeconds =
        isWhite ? data.whiteClockSeconds : data.blackClockSeconds;
    final clockCentiseconds =
        isWhite ? data.whiteClockCentiseconds : data.blackClockCentiseconds;
    final hasClockData =
        clockSeconds != null ||
        clockCentiseconds > 0 ||
        data.lastMoveTime != null;
    final isOngoing = !data.status.isFinished;
    final isOnMove =
        data.activePlayer != null &&
        ((isWhite && data.activePlayer == Side.white) ||
            (!isWhite && data.activePlayer == Side.black));
    final isClockRunning = isOngoing && isOnMove && data.lastMoveTime != null;

    return Row(
      children: [
        _SideMarker(isWhite: isWhite, compact: compact),
        SizedBox(width: compact ? 6 : 8),
        BackfilledFederationFlag(
          federation: fed,
          fideId: fideId,
          width: compact ? 16 : 22,
          height: compact ? 11 : 15,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(width: 8),
        if (title.isNotEmpty) ...[
          _TitleChip(title: title, compact: compact),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            name.isEmpty ? 'Unknown' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: kWhiteColor,
              fontSize: compact ? 11.5 : 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.05,
            ),
          ),
        ),
        if (rating > 0) ...[
          const SizedBox(width: 8),
          Text(
            '$rating',
            style: TextStyle(
              color: kWhiteColor70,
              fontSize: compact ? 10.5 : 12,
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (hasClockData && isOngoing) ...[
          const SizedBox(width: 10),
          _ClockPill(
            clockSeconds: clockSeconds,
            clockCentiseconds: clockCentiseconds,
            lastMoveTime: data.lastMoveTime,
            isActive: isClockRunning,
            compact: compact,
          ),
        ],
        if (result.isNotEmpty) ...[
          const SizedBox(width: 10),
          _ResultBadge(label: result, compact: compact),
        ],
      ],
    );
  }
}

/// Small circle that marks White vs Black — replaces the implicit "row 1
/// is White, row 2 is Black" convention with an explicit, scannable cue.
class _SideMarker extends StatelessWidget {
  const _SideMarker({required this.isWhite, required this.compact});
  final bool isWhite;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 8.0 : 10.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isWhite ? kWhiteColor : Colors.black,
        shape: BoxShape.circle,
        border: Border.all(
          color: isWhite ? kWhiteColor70 : kWhiteColor.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
    );
  }
}

class _TitleChip extends StatelessWidget {
  const _TitleChip({required this.title, required this.compact});
  final String title;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 5,
        vertical: compact ? 1 : 1.5,
      ),
      decoration: BoxDecoration(
        color: kLightYellowColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: kLightYellowColor.withValues(alpha: 0.45),
          width: 0.7,
        ),
      ),
      child: Text(
        title,
        style: TextStyle(
          color: kLightYellowColor,
          fontSize: compact ? 9.5 : 10.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _ClockPill extends StatelessWidget {
  const _ClockPill({
    required this.clockSeconds,
    required this.clockCentiseconds,
    required this.lastMoveTime,
    required this.isActive,
    required this.compact,
  });
  final int? clockSeconds;
  final int clockCentiseconds;
  final DateTime? lastMoveTime;
  final bool isActive;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const fg = kWhiteColor70;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 7,
        vertical: compact ? 1.5 : 2.5,
      ),
      decoration: BoxDecoration(
        color:
            isActive
                ? kWhiteColor.withValues(alpha: 0.06)
                : kBlack3Color.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isActive ? kWhiteColor.withValues(alpha: 0.16) : kDividerColor,
          width: 0.7,
        ),
      ),
      child: AtomicCountdownText(
        clockSeconds: clockSeconds,
        clockCentiseconds: clockCentiseconds,
        lastMoveTime: lastMoveTime,
        isActive: isActive,
        style: TextStyle(
          color: fg,
          fontSize: compact ? 10 : 11.5,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _ResultBadge extends StatelessWidget {
  const _ResultBadge({required this.label, required this.compact});
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = _resultBadgeColor(label);
    return SizedBox(
      width: compact ? 24 : 30,
      height: compact ? 18 : 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.28), width: 0.8),
        ),
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: compact ? 11 : 13,
              fontWeight: FontWeight.w800,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

Color _resultBadgeColor(String label) {
  return switch (label.trim()) {
    '1' || '1.0' => kPrimaryColor,
    '0' || '0.0' => kRedColor,
    '½' || '1/2' || '0.5' => kLightGreyColor,
    _ => kLightGreyColor,
  };
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.color});
  final Color color;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.18 + 0.18 * t),
                blurRadius: 4 + 2 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NoEvalSplit extends StatelessWidget {
  const _NoEvalSplit();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Expanded(child: ColoredBox(color: kPopUpColor)),
        Expanded(child: ColoredBox(color: kWhiteColor)),
      ],
    );
  }
}

String _resultFor(GameStatus s, {required bool isWhite}) {
  switch (s) {
    case GameStatus.whiteWins:
      return isWhite ? '1' : '0';
    case GameStatus.blackWins:
      return isWhite ? '0' : '1';
    case GameStatus.draw:
      return '½';
    case GameStatus.unknown:
    case GameStatus.ongoing:
      return '';
  }
}

String _resultLabel(GameStatus s) {
  switch (s) {
    case GameStatus.whiteWins:
      return '1 – 0';
    case GameStatus.blackWins:
      return '0 – 1';
    case GameStatus.draw:
      return '½ – ½';
    case GameStatus.ongoing:
      return 'Underway';
    case GameStatus.unknown:
      return '';
  }
}

/// Per-layout tile sizing for [DesktopGameCardsFlow].
///
/// Compact and list render in a responsive multi-column grid instead of
/// full-width vertical strips. Target widths are tuned so even a narrow
/// content pane (left-rail + right-inspector chewing into the window)
/// still lands at 2 columns — otherwise the redesign degrades back into
/// the full-width-strip look it was meant to replace.
const double _kListTileTargetWidth = 360;
const double _kListTileHeight = 138;
const double _kCompactTileTargetWidth = 300;
const double _kCompactTileHeight = 82;
const double _kGridTileTargetWidth = 280;

/// Responsive multi-column flow for [DesktopGameCard]s. Replaces the legacy
/// full-width `ListView.builder` host that all compact/list panes used to
/// share — game cards now sit in tile rows whose column count adapts to the
/// container's max width.
///
/// Grid mode keeps the original square-aspect tiles. List and compact modes
/// switch to fixed `mainAxisExtent` rows whose tile width is driven by
/// [_kListTileTargetWidth] / [_kCompactTileTargetWidth]. When [embedded] is
/// true the flow is rendered inside a parent scrollable (e.g. the rounds
/// list in `TournamentGamesView`) and shrink-wraps with a no-op scroll
/// physics; otherwise it owns its own scroll position.
/// Sizing knobs the flow uses internally — also exposed so a caller
/// with bounded vertical space (e.g. the tournament For You strip)
/// can compute its own cols × rows capacity and pre-truncate the
/// itemCount it hands the flow.
@immutable
class DesktopGameCardsFlowMetrics {
  const DesktopGameCardsFlowMetrics({
    required this.targetWidth,
    required this.tileHeight,
    required this.minCols,
    required this.maxCols,
    required this.spacing,
  });

  final double targetWidth;
  final double tileHeight;
  final int minCols;
  final int maxCols;
  final double spacing;
}

class DesktopGameCardsFlow extends StatelessWidget {
  const DesktopGameCardsFlow({
    super.key,
    required this.layout,
    required this.itemCount,
    required this.itemBuilder,
    this.padding,
    this.scrollController,
    this.embedded = false,
  });

  final DesktopCardLayout layout;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final EdgeInsetsGeometry? padding;
  final ScrollController? scrollController;

  /// When true, render inside a parent scrollable: shrink-wrap and disable
  /// our own scroll physics so the outer view drives scrolling.
  final bool embedded;

  static DesktopGameCardsFlowMetrics metricsFor(DesktopCardLayout layout) {
    switch (layout) {
      case DesktopCardLayout.compact:
        return const DesktopGameCardsFlowMetrics(
          targetWidth: _kCompactTileTargetWidth,
          tileHeight: _kCompactTileHeight,
          minCols: 2,
          maxCols: 6,
          spacing: 6,
        );
      case DesktopCardLayout.list:
        return const DesktopGameCardsFlowMetrics(
          targetWidth: _kListTileTargetWidth,
          tileHeight: _kListTileHeight,
          minCols: 2,
          maxCols: 4,
          spacing: 8,
        );
      case DesktopCardLayout.grid:
        return const DesktopGameCardsFlowMetrics(
          targetWidth: _kGridTileTargetWidth,
          tileHeight: _kGridTileTargetWidth, // square-ish; aspect handles it
          minCols: 2,
          maxCols: 6,
          spacing: 8,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth =
            constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.of(context).size.width;

        final padInsets = padding?.resolve(Directionality.of(context));
        final innerWidth =
            (maxWidth - (padInsets?.left ?? 0) - (padInsets?.right ?? 0))
                .clamp(0.0, double.infinity)
                .toDouble();

        final metrics = metricsFor(layout);
        final double? mainAxisExtent =
            layout == DesktopCardLayout.grid ? null : metrics.tileHeight;
        const aspect = 0.95;

        final rawCols = (innerWidth / metrics.targetWidth).floor();
        final columns = rawCols.clamp(metrics.minCols, metrics.maxCols).toInt();

        final delegate =
            mainAxisExtent != null
                ? SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: metrics.spacing,
                  crossAxisSpacing: metrics.spacing,
                  mainAxisExtent: mainAxisExtent,
                )
                : SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: metrics.spacing,
                  crossAxisSpacing: metrics.spacing,
                  childAspectRatio: aspect,
                );

        return GridView.builder(
          controller: embedded ? null : scrollController,
          padding: padding,
          shrinkWrap: embedded,
          physics:
              embedded
                  ? const NeverScrollableScrollPhysics()
                  : (scrollController != null
                      ? const AlwaysScrollableScrollPhysics()
                      : null),
          itemCount: itemCount,
          gridDelegate: delegate,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
