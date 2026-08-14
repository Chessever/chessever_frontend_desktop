import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/tournament_bracket_canvas.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/bracket/models/knockout_bracket.dart';
import 'package:chessever/screens/tour_detail/bracket/utils/bracket_game_result.dart';
import 'package:chessever/screens/tour_detail/bracket/widgets/bracket_graph_layout.dart';
import 'package:chessever/theme/app_theme.dart';

final _bracketCameraProvider = StateProvider.family<Matrix4?, String>(
  (ref, key) => null,
);

final _bracketSelectionProvider = StateProvider.family<String?, String>(
  (ref, key) => null,
);

/// Explicit data-state boundary around the interactive bracket viewport.
class DesktopTournamentBracketContent extends StatelessWidget {
  const DesktopTournamentBracketContent({
    super.key,
    required this.state,
    required this.cameraKey,
    required this.onRetry,
    required this.onOpenGame,
  });

  final AsyncValue<KnockoutBracket> state;
  final String cameraKey;
  final VoidCallback onRetry;
  final ValueChanged<Games> onOpenGame;

  @override
  Widget build(BuildContext context) {
    return state.when(
      loading:
          () => const Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: kPrimaryColor,
              ),
            ),
          ),
      error:
          (error, stackTrace) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.account_tree_outlined,
                    size: 30,
                    color: kWhiteColor70,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Bracket could not be loaded',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The tournament remains available. Retry only the bracket feed.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kWhiteColor70, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  DesktopToolbarPillButton(
                    label: 'Try again',
                    icon: Icons.refresh_rounded,
                    onPress: onRetry,
                  ),
                ],
              ),
            ),
          ),
      data:
          (bracket) =>
              bracket.isEmpty
                  ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.account_tree_outlined,
                          size: 30,
                          color: kWhiteColor70,
                        ),
                        SizedBox(height: 10),
                        Text(
                          'No bracket has been published yet.',
                          style: TextStyle(
                            color: kWhiteColor70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                  : DesktopTournamentBracketViewport(
                    bracket: bracket,
                    cameraKey: cameraKey,
                    onOpenGame: onOpenGame,
                  ),
    );
  }
}

/// Resizable Desktop host for the static bracket graph.
///
/// Camera and selected-match state are scoped by [cameraKey], which should be a
/// stable `tab::tour` identity. Leaving Bracket and returning to it therefore
/// does not discard the user's pan/zoom position, and two event tabs never
/// share a camera.
class DesktopTournamentBracketViewport extends ConsumerStatefulWidget {
  const DesktopTournamentBracketViewport({
    super.key,
    required this.bracket,
    required this.cameraKey,
    required this.onOpenGame,
  });

  final KnockoutBracket bracket;
  final String cameraKey;
  final ValueChanged<Games> onOpenGame;

  @override
  ConsumerState<DesktopTournamentBracketViewport> createState() =>
      _DesktopTournamentBracketViewportState();
}

class _DesktopTournamentBracketViewportState
    extends ConsumerState<DesktopTournamentBracketViewport> {
  late TransformationController _camera;
  Size _viewportSize = Size.zero;
  bool _initialCameraApplied = false;

  @override
  void initState() {
    super.initState();
    _restoreCamera();
  }

  @override
  void didUpdateWidget(covariant DesktopTournamentBracketViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cameraKey == widget.cameraKey) return;
    _saveCamera(oldWidget.cameraKey);
    _camera.removeListener(_handleCameraChanged);
    _camera.dispose();
    _initialCameraApplied = false;
    _restoreCamera();
  }

  void _restoreCamera() {
    final saved = ref.read(_bracketCameraProvider(widget.cameraKey));
    _camera = TransformationController(saved?.clone() ?? Matrix4.identity())
      ..addListener(_handleCameraChanged);
    _initialCameraApplied = saved != null;
  }

  void _handleCameraChanged() => _saveCamera(widget.cameraKey);

  void _saveCamera(String key) {
    ref.read(_bracketCameraProvider(key).notifier).state =
        _camera.value.clone();
  }

  @override
  void dispose() {
    _camera.removeListener(_handleCameraChanged);
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedMatchKey = ref.watch(
      _bracketSelectionProvider(widget.cameraKey),
    );
    final selectedMatch = _findMatch(widget.bracket, selectedMatchKey);

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableSize = constraints.biggest;
        final narrow = availableSize.width < 900;
        final inspectorExtent = narrow ? 194.0 : 300.0;
        final canvasSize = Size(
          availableSize.width -
              (selectedMatch != null && !narrow ? inspectorExtent + 1 : 0),
          availableSize.height -
              (selectedMatch != null && narrow ? inspectorExtent + 1 : 0),
        );
        _viewportSize = canvasSize;
        _scheduleInitialCamera();

        final canvas = _buildCanvas(selectedMatchKey);
        if (selectedMatch == null) return canvas;

        final inspector = _DesktopBracketMatchInspector(
          match: selectedMatch,
          compact: narrow,
          onClose:
              () =>
                  ref
                      .read(
                        _bracketSelectionProvider(widget.cameraKey).notifier,
                      )
                      .state = null,
          onOpenGame: widget.onOpenGame,
        );

        return narrow
            ? Column(
              children: [
                Expanded(child: canvas),
                const Divider(height: 1, color: kDividerColor),
                SizedBox(height: inspectorExtent, child: inspector),
              ],
            )
            : Row(
              children: [
                Expanded(child: canvas),
                const VerticalDivider(width: 1, color: kDividerColor),
                SizedBox(width: inspectorExtent, child: inspector),
              ],
            );
      },
    );
  }

  Widget _buildCanvas(String? selectedMatchKey) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: kBlackColor,
            child: InteractiveViewer(
              key: const ValueKey('desktop-bracket-viewport'),
              transformationController: _camera,
              constrained: false,
              minScale: 0.3,
              maxScale: 2.4,
              boundaryMargin: const EdgeInsets.all(180),
              clipBehavior: Clip.none,
              panEnabled: true,
              scaleEnabled: true,
              child: DesktopKnockoutBracketCanvas(
                bracket: widget.bracket,
                focusedMatchKey: selectedMatchKey,
                onMatchActivate:
                    (match) =>
                        ref
                            .read(
                              _bracketSelectionProvider(
                                widget.cameraKey,
                              ).notifier,
                            )
                            .state = match.key,
              ),
            ),
          ),
        ),
        Positioned(
          right: 14,
          top: 14,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: kBlack2Color.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDividerColor),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 10),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    key: const ValueKey('bracket-zoom-out-button'),
                    child: DesktopHeaderIconButton(
                      icon: Icons.remove_rounded,
                      tooltip: 'Zoom out',
                      onPress: () => _zoomBy(0.82),
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('bracket-zoom-in-button'),
                    child: DesktopHeaderIconButton(
                      icon: Icons.add_rounded,
                      tooltip: 'Zoom in',
                      onPress: () => _zoomBy(1.22),
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('bracket-fit-button'),
                    child: DesktopHeaderIconButton(
                      icon: Icons.fit_screen_rounded,
                      tooltip: 'Fit bracket',
                      onPress: _fitBracket,
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('bracket-current-stage-button'),
                    child: DesktopHeaderIconButton(
                      icon: Icons.my_location_rounded,
                      tooltip: 'Jump to current stage',
                      onPress:
                          widget.bracket.currentStageKey == null
                              ? null
                              : _focusCurrentStage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.bracket.isPartial)
          Positioned(
            left: 14,
            right: 14,
            bottom: 14,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: kBlack2Color.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDividerColor),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: kWhiteColor70,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'The source feed is incomplete. Only published paths are connected.',
                        style: TextStyle(
                          color: kWhiteColor70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _scheduleInitialCamera() {
    if (_initialCameraApplied ||
        _viewportSize.isEmpty ||
        !_viewportSize.width.isFinite ||
        !_viewportSize.height.isFinite) {
      return;
    }
    _initialCameraApplied = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.bracket.currentStageKey != null) {
        _focusCurrentStage();
      } else {
        _fitBracket();
      }
    });
  }

  void _fitBracket() {
    final layout = buildBracketGraphLayout(widget.bracket);
    _animateCamera(_cameraForRect(Offset.zero & layout.size, maxScale: 1));
  }

  void _focusCurrentStage() {
    final stageKey = widget.bracket.currentStageKey;
    if (stageKey == null) return;
    final stage =
        widget.bracket.stages
            .where((candidate) => candidate.key == stageKey)
            .firstOrNull;
    if (stage == null) return;
    final rect = buildBracketGraphLayout(
      widget.bracket,
    ).readableFocusRectForStage(stage);
    if (rect == null) return;
    _animateCamera(_cameraForRect(rect, maxScale: 1.15));
  }

  Matrix4 _cameraForRect(Rect rect, {required double maxScale}) {
    final horizontalPadding = math.min(90.0, _viewportSize.width * 0.12);
    final verticalPadding = math.min(70.0, _viewportSize.height * 0.12);
    final availableWidth = math.max(
      1.0,
      _viewportSize.width - horizontalPadding * 2,
    );
    final availableHeight = math.max(
      1.0,
      _viewportSize.height - verticalPadding * 2,
    );
    final scale =
        math
            .min(availableWidth / rect.width, availableHeight / rect.height)
            .clamp(0.3, maxScale)
            .toDouble();
    final tx = _viewportSize.width / 2 - rect.center.dx * scale;
    final ty = _viewportSize.height / 2 - rect.center.dy * scale;
    return Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(tx, ty, 0);
  }

  void _zoomBy(double factor) {
    if (_viewportSize.isEmpty) return;
    final current = _camera.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(0.3, 2.4).toDouble();
    final translation = _camera.value.getTranslation();
    final center = _viewportSize.center(Offset.zero);
    final sceneCenter = Offset(
      (center.dx - translation.x) / current,
      (center.dy - translation.y) / current,
    );
    final nextMatrix = Matrix4.diagonal3Values(next, next, 1)
      ..setTranslationRaw(
        center.dx - sceneCenter.dx * next,
        center.dy - sceneCenter.dy * next,
        0,
      );
    _animateCamera(nextMatrix);
  }

  void _animateCamera(Matrix4 target) {
    _camera.value = target;
  }
}

class _DesktopBracketMatchInspector extends StatelessWidget {
  const _DesktopBracketMatchInspector({
    required this.match,
    required this.compact,
    required this.onClose,
    required this.onOpenGame,
  });

  final KnockoutMatch match;
  final bool compact;
  final VoidCallback onClose;
  final ValueChanged<Games> onOpenGame;

  @override
  Widget build(BuildContext context) {
    final summary =
        '${_formatScore(match.participant1Score)} – '
        '${_formatScore(match.participant2Score)}';
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Match details',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${match.participant1.displayName} vs ${match.participant2.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            summary,
            style: const TextStyle(
              color: kPrimaryColor,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 5),
          DesktopHeaderIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close match details',
            onPress: onClose,
          ),
        ],
      ),
    );

    if (match.games.isEmpty) {
      return ColoredBox(
        color: kBlack2Color,
        child: Column(
          children: [
            header,
            const Divider(height: 1, color: kDividerColor),
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'No game legs have been published yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kWhiteColor70, fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ColoredBox(
      color: kBlack2Color,
      child: Column(
        children: [
          header,
          const Divider(height: 1, color: kDividerColor),
          Expanded(
            child: ListView.builder(
              scrollDirection: compact ? Axis.horizontal : Axis.vertical,
              padding: const EdgeInsets.all(8),
              itemCount: match.games.length,
              itemBuilder: (context, index) {
                final game = match.games[index];
                return SizedBox(
                  width: compact ? 238 : null,
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: compact && index < match.games.length - 1 ? 8 : 0,
                      bottom:
                          !compact && index < match.games.length - 1 ? 6 : 0,
                    ),
                    child: _DesktopBracketLegRow(
                      game: game,
                      index: index,
                      onActivate: () => onOpenGame(game),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopBracketLegRow extends StatelessWidget {
  const _DesktopBracketLegRow({
    required this.game,
    required this.index,
    required this.onActivate,
  });

  final Games game;
  final int index;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    final players = game.players ?? const <Player>[];
    final white = players.isNotEmpty ? players.first.name : 'White';
    final black = players.length > 1 ? players[1].name : 'Black';
    final result = bracketGameResult(game).displayText;
    final board =
        game.boardNr != null ? 'Board ${game.boardNr}' : 'Game ${index + 1}';

    return DesktopTappable(
      onPress: onActivate,
      semanticsLabel:
          'Open $white versus $black, ${result.isEmpty ? board : result}',
      borderRadius: BorderRadius.circular(8),
      hoverColor: kBlack3Color,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: kBlackColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$white – $black',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    game.roundName?.trim().isNotEmpty == true
                        ? game.roundName!.trim()
                        : board,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              result.isEmpty ? (game.status?.trim() ?? 'LIVE') : result,
              style: TextStyle(
                color: result.isEmpty ? kPrimaryColor : kWhiteColor,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 5),
            const Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: kWhiteColor70,
            ),
          ],
        ),
      ),
    );
  }
}

KnockoutMatch? _findMatch(KnockoutBracket bracket, String? key) {
  if (key == null) return null;
  for (final stage in bracket.stages) {
    for (final match in stage.matches) {
      if (match.key == key) return match;
    }
  }
  return null;
}

String _formatScore(double score) =>
    score == score.roundToDouble()
        ? score.toInt().toString()
        : score.toStringAsFixed(1);
