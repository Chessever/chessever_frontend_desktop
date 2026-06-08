import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/engine_settings_popover.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:chessever/theme/app_theme.dart';

/// Live engine evaluation panel for the active board position.
///
/// Reads from `boardEvalProvider` — the same shared Stockfish source the
/// evaluation bar is bound to — so both stay perfectly in sync without
/// running a second engine subprocess. Renders every principal variation
/// (up to the user's configured `multiPV`) so desktop users can compare
/// alternatives the way desktop database and web analysis boards analysis boards do.
///
/// Each PV row is interactive:
///  - Click → plays the line's first move on the active board
///  - Right-click → context menu (play / copy SAN / copy first / copy UCI)
class EnginePanel extends ConsumerWidget {
  const EnginePanel({
    super.key,
    required this.fen,
    required this.sideToMove,
    this.onPlayUci,
  });

  final String fen;

  /// `'w'` or `'b'`. Unused now that the singleton normalizes evaluations to
  /// white-perspective; kept on the API to avoid touching every call site.
  final String sideToMove;

  /// Caller-supplied move dispatcher. When non-null, PV rows become
  /// clickable and play their first UCI through this callback. The Board
  /// pane wires it to the same `playUci` it uses for opening-explorer
  /// taps so both surfaces share the legality + onMove path.
  final void Function(String uci)? onPlayUci;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(engineSettingsProviderNew).valueOrNull ??
        const EngineSettings();
    if (!settings.showEngineAnalysis) {
      return const _EngineDisabled();
    }

    final ready = StockfishSingleton().isEngineHealthy;
    if (!ready && fen.isEmpty) {
      return const _EngineNotReady();
    }

    final state = ref.watch(boardEvalProvider(fen));
    final pvs = state.pvs;
    final topScore = _formatScore(state.evaluation, state.mate);

    return Container(
      color: kBlack2Color,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: state.isEvaluating ? kGreenColor : kLightGreyColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Stockfish',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                topScore,
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              _DepthChip(depth: state.depth, isEvaluating: state.isEvaluating),
              const SizedBox(width: 6),
              _EngineQuickToggle(enabled: settings.showEngineAnalysis),
              const SizedBox(width: 4),
              const EngineSettingsPopover(),
            ],
          ),
          const SizedBox(height: 10),
          if (pvs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                state.isEvaluating
                    ? 'Searching…'
                    : (state.statusText ?? 'No engine line for this position.'),
                style: const TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                physics: const DesktopScrollPhysics(),
                padding: const EdgeInsets.only(right: 8),
                itemCount: pvs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, i) => _PvLine(
                  rank: i + 1,
                  pv: pvs[i],
                  fen: fen,
                  onPlayUci: onPlayUci,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PvLine extends StatefulWidget {
  const _PvLine({
    required this.rank,
    required this.pv,
    required this.fen,
    required this.onPlayUci,
  });

  final int rank;
  final BoardPv pv;
  final String fen;
  final void Function(String uci)? onPlayUci;

  @override
  State<_PvLine> createState() => _PvLineState();
}

class _PvLineState extends State<_PvLine> {
  bool _hovered = false;
  bool _expanded = false;
  String? _cachedFen;
  String? _cachedMoves;
  String? _cachedFirstUci;
  String _cachedDisplayLine = '';
  List<_PvToken> _cachedTokens = const <_PvToken>[];

  static final RegExp _pvWhitespace = RegExp(r'\s+');

  @override
  void initState() {
    super.initState();
    _refreshCachedLine();
  }

  @override
  void didUpdateWidget(covariant _PvLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen || oldWidget.pv.moves != widget.pv.moves) {
      _refreshCachedLine();
    }
  }

  void _refreshCachedLine() {
    final moves = widget.pv.moves;
    final parts = moves
        .split(_pvWhitespace)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    _cachedFen = widget.fen;
    _cachedMoves = moves;
    _cachedFirstUci = parts.isEmpty ? null : parts.first.trim();

    final tokens = _tokensFor(widget.fen, parts);
    _cachedTokens = tokens;
    _cachedDisplayLine = tokens.isEmpty
        ? moves
        : tokens.map((t) => t.san).join(' ');
  }

  /// First UCI move of the line. The bar's `pv.moves` is a space-
  /// separated UCI string ("e2e4 e7e5 g1f3 …"); the first token is what
  /// gets played when the user clicks the row.
  String? get _firstUci {
    if (_cachedFen != widget.fen || _cachedMoves != widget.pv.moves) {
      _refreshCachedLine();
    }
    return _cachedFirstUci;
  }

  /// Render the PV line as numbered SAN ("8.dxc3 Bc5 9.Qe2+ Qe7 10.O-O …")
  /// — readable, copy-friendly, and matches how desktop database and web analysis boards print
  /// engine lines. Move numbers are derived from the queried FEN's full-
  /// move + side-to-move fields (same logic as the position-games table's
  /// Notation column). Falls back to the raw UCI string when the position
  /// can't be parsed (e.g. a stale snapshot mid-position-update).
  /// Walks the UCI line on top of [fen] and emits one [_PvToken] per
  /// move with the formatted SAN label, the move's UCI, and the
  /// cumulative UCI list up to (and including) that token. The hover
  /// preview reads `ucisUpTo` to render the position after the hovered
  /// move; the visible label uses `san`.
  List<_PvToken> _tokensFor(String fen, List<String> uciMoves) {
    try {
      final position = Chess.fromSetup(Setup.parseFen(fen));
      final parts = fen.trim().split(_pvWhitespace);
      final initialFullMove = parts.length >= 6
          ? int.tryParse(parts[5]) ?? 1
          : 1;
      final whiteFirst = parts.length >= 2 ? parts[1] == 'w' : true;

      final out = <_PvToken>[];
      Position cursor = position;
      var fullMove = initialFullMove;
      var whiteToMove = whiteFirst;
      final ucisSoFar = <String>[];
      for (final raw in uciMoves) {
        final uci = raw.trim();
        if (uci.isEmpty) continue;
        final move = Move.parse(uci);
        if (move == null) break;
        if (!cursor.isLegal(move)) break;
        final san = cursor.makeSan(move).$2;
        final String label;
        if (whiteToMove) {
          label = '$fullMove.$san';
        } else if (out.isEmpty) {
          label = '$fullMove…$san';
        } else {
          label = san;
        }
        ucisSoFar.add(uci);
        out.add(
          _PvToken(
            san: label,
            uci: uci,
            ucisUpTo: List<String>.unmodifiable(ucisSoFar),
          ),
        );
        cursor = cursor.playUnchecked(move);
        if (!whiteToMove) fullMove += 1;
        whiteToMove = !whiteToMove;
      }
      return out;
    } catch (_) {
      return uciMoves
          .map((u) => _PvToken(san: u, uci: u, ucisUpTo: const <String>[]))
          .toList(growable: false);
    }
  }

  String _sanLineString() {
    if (_cachedFen != widget.fen || _cachedMoves != widget.pv.moves) {
      _refreshCachedLine();
    }
    return _cachedDisplayLine;
  }

  Future<void> _showContextMenu(Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final firstUci = _firstUci;
    final selected = await showMenu<_PvAction>(
      context: context,
      color: kBlack2Color,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      items: [
        if (firstUci != null && widget.onPlayUci != null)
          const PopupMenuItem<_PvAction>(
            value: _PvAction.play,
            child: _MenuRow(
              icon: Icons.play_arrow_rounded,
              label: 'Play this move',
            ),
          ),
        const PopupMenuItem<_PvAction>(
          value: _PvAction.copySan,
          child: _MenuRow(icon: Icons.copy_rounded, label: 'Copy SAN line'),
        ),
        const PopupMenuItem<_PvAction>(
          value: _PvAction.copyFirst,
          child: _MenuRow(
            icon: Icons.first_page_rounded,
            label: 'Copy first move',
          ),
        ),
        const PopupMenuItem<_PvAction>(
          value: _PvAction.copyUci,
          child: _MenuRow(
            icon: Icons.format_quote_rounded,
            label: 'Copy UCI line',
          ),
        ),
      ],
    );
    if (selected == null) return;
    switch (selected) {
      case _PvAction.play:
        if (firstUci != null) widget.onPlayUci?.call(firstUci);
      case _PvAction.copySan:
        await Clipboard.setData(ClipboardData(text: _sanLineString()));
      case _PvAction.copyFirst:
        if (firstUci != null) {
          await Clipboard.setData(ClipboardData(text: firstUci));
        }
      case _PvAction.copyUci:
        await Clipboard.setData(ClipboardData(text: widget.pv.moves));
    }
  }

  @override
  Widget build(BuildContext context) {
    final score = _formatScore(widget.pv.evaluation, widget.pv.mate);
    final isAdvantage =
        (widget.pv.mate ?? 0) > 0 || widget.pv.evaluation > 0.05;
    final scoreColor = (widget.pv.mate ?? 0) != 0
        ? kPrimaryColor
        : (isAdvantage
              ? kWhiteColor
              : (widget.pv.evaluation < -0.05 ? kRedColor : kWhiteColor70));

    if (_cachedFen != widget.fen || _cachedMoves != widget.pv.moves) {
      _refreshCachedLine();
    }
    final displayLine = _cachedDisplayLine;

    final clickable = widget.onPlayUci != null && _firstUci != null;

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: widget.rank == 1
            ? (_hovered ? kBlack2Color.withValues(alpha: 0.6) : kBlack3Color)
            : (_hovered ? kBlack3Color : Colors.transparent),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: _hovered
              ? kPrimaryColor.withValues(alpha: 0.4)
              : Colors.transparent,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              score,
              style: TextStyle(
                color: scoreColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _cachedTokens.isEmpty
                ? Text(
                    displayLine,
                    maxLines: _expanded ? 4 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  )
                : _PvTokensLine(
                    fen: widget.fen,
                    tokens: _cachedTokens,
                    expanded: _expanded,
                  ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: DesktopTooltip(
              message: _expanded
                  ? 'Collapse engine line'
                  : 'Expand engine line',
              child: Icon(
                _expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.chevron_right_rounded,
                size: 16,
                color: kWhiteColor70,
              ),
            ),
          ),
        ],
      ),
    );

    // Subtle hover scale on PV rows (1.005) — too tiny to be a
    // distraction during the engine's high-frequency updates, but enough
    // to make the row feel like a real button when the user mouses
    // toward it. We don't track press here — these rows update many
    // times a second, and a press-down spring would conflict with the
    // ongoing redraws.
    return ClickCursor(
      enabled: clickable,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: clickable ? () => widget.onPlayUci!(_firstUci!) : null,
          onSecondaryTapUp: (details) =>
              _showContextMenu(details.globalPosition),
          child: SingleMotionBuilder(
            value: clickable && _hovered ? 1.005 : 1.0,
            motion: DesktopMotion.hover,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// Tiny chip showing the current Stockfish search depth next to the
/// evaluation score. Lives in the side panel only — never on the board
/// surface — so analysis output stays out of the playing surface (#461).
class _DepthChip extends StatelessWidget {
  const _DepthChip({required this.depth, required this.isEvaluating});

  final int depth;
  final bool isEvaluating;

  @override
  Widget build(BuildContext context) {
    if (depth <= 0 && !isEvaluating) {
      return const SizedBox.shrink();
    }
    final visible = depth.clamp(0, 99).toInt();
    final label = visible > 0 ? 'd$visible' : '…';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: kLightGreyColor.withValues(alpha: isEvaluating ? 0.9 : 0.65),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

enum _PvAction { play, copySan, copyFirst, copyUci }

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: kWhiteColor70),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: kWhiteColor, fontSize: 13)),
      ],
    );
  }
}

class _EngineDisabled extends StatelessWidget {
  const _EngineDisabled();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBlack2Color,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Row(
            children: [
              Text(
                'Engine analysis off',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Spacer(),
              _EngineQuickToggle(enabled: false),
              SizedBox(width: 4),
              EngineSettingsPopover(),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'Stockfish is paused for this position. Toggle it back on with the '
            'power button above, or open settings to tune search time and PV count.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// One-tap on/off toggle for engine analysis. Maps to the same
/// `showEngineAnalysis` switch the gear popover exposes, but lives where
/// users actually look for an engine switch — right next to the eval read-
/// out. Single global Stockfish process; toggling here pauses/resumes the
/// search for whichever board tab is focused (#461).
class _EngineQuickToggle extends ConsumerStatefulWidget {
  const _EngineQuickToggle({required this.enabled});

  final bool enabled;

  @override
  ConsumerState<_EngineQuickToggle> createState() => _EngineQuickToggleState();
}

class _EngineQuickToggleState extends ConsumerState<_EngineQuickToggle> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final tooltip = enabled ? 'Pause engine' : 'Resume engine';
    final fg = enabled
        ? kPrimaryColor
        : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg = enabled
        ? kPrimaryColor.withValues(alpha: _hovered ? 0.22 : 0.14)
        : (_hovered ? kBlack3Color : Colors.transparent);
    final border = enabled
        ? kPrimaryColor.withValues(alpha: 0.55)
        : (_hovered ? kWhiteColor.withValues(alpha: 0.20) : kDividerColor);

    Future<void> toggle() async {
      await ref
          .read(engineSettingsProviderNew.notifier)
          .toggleEngineAnalysis(!enabled);
    }

    return DesktopTooltip(
      message: tooltip,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: toggle,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: SingleMotionBuilder(
              value: _pressed ? 0.94 : (_hovered ? 1.04 : 1.0),
              motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 110),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: border),
                ),
                alignment: Alignment.center,
                child: Icon(
                  enabled
                      ? Icons.power_settings_new_rounded
                      : Icons.power_settings_new_outlined,
                  size: 14,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EngineNotReady extends StatelessWidget {
  const _EngineNotReady();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBlack2Color,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Engine off',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Open Settings → Engine to initialize Stockfish, '
            'or install via brew (macOS) / put on PATH.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// Per-token PV line model. Cached on `_PvLineState` and used by
/// [_PvTokensLine] so the hover preview can replay the cumulative line
/// without recomputing dartchess on every pointer move.
class _PvToken {
  const _PvToken({
    required this.san,
    required this.uci,
    required this.ucisUpTo,
  });

  final String san;
  final String uci;
  final List<String> ucisUpTo;
}

/// Renders the PV move list as a Wrap of SAN chips. The line owns one
/// stable [MoveHoverPreview] so moving between engine moves updates only
/// the popup board content/animation while the preview stays in its
/// clamped engine-line placement.
class _PvTokensLine extends StatefulWidget {
  const _PvTokensLine({
    required this.fen,
    required this.tokens,
    required this.expanded,
  });

  final String fen;
  final List<_PvToken> tokens;
  final bool expanded;

  @override
  State<_PvTokensLine> createState() => _PvTokensLineState();
}

class _PvTokensLineState extends State<_PvTokensLine> {
  final GlobalKey _lineAnchorKey = GlobalKey();
  int? _hoveredIndex;

  @override
  void didUpdateWidget(covariant _PvTokensLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.expanded ||
        (_hoveredIndex != null && _hoveredIndex! >= widget.tokens.length)) {
      _hoveredIndex = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    if (!widget.expanded) {
      return Text(
        tokens.map((t) => t.san).join(' '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 12,
          height: 1.35,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      );
    }
    final hoveredIndex = _hoveredIndex;
    return MoveHoverPreview(
      startingFen: widget.fen,
      movesUpToHover: hoveredIndex == null
          ? const <String>[]
          : tokens[hoveredIndex].ucisUpTo,
      enabled: hoveredIndex != null,
      placement: MoveHoverPreviewPlacement.engineLine,
      placementAnchorKey: _lineAnchorKey,
      child: MouseRegion(
        onExit: (_) => setState(() => _hoveredIndex = null),
        child: KeyedSubtree(
          key: _lineAnchorKey,
          child: Wrap(
            spacing: 5,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < tokens.length; i++)
                MouseRegion(
                  onEnter: (_) => setState(() => _hoveredIndex = i),
                  child: Text(
                    tokens[i].san,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.35,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatScore(double? evaluation, int? mate) {
  if (mate != null) {
    return mate > 0 ? '#$mate' : '#$mate';
  }
  if (evaluation == null) {
    return '—';
  }
  // Treat near-zero as exactly zero for display stability.
  final value = evaluation.abs() < 0.05 ? 0.0 : evaluation;
  if (value == 0.0) return '0.00';
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(2)}';
}
