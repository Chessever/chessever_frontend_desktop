import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

const playerHoverIntentDelay = Duration(milliseconds: 260);
const playerHoverGraceDelay = Duration(milliseconds: 450);
const double playerHoverDismissDistance = 32;

@visibleForTesting
bool isPlayerHoverPointerNearby({
  required Offset pointer,
  required Rect triggerRect,
  required Rect cardRect,
  double distance = playerHoverDismissDistance,
}) {
  return triggerRect.inflate(distance).contains(pointer) ||
      cardRect.inflate(distance).contains(pointer);
}

@immutable
class PlayerHoverPreviewIdentity {
  const PlayerHoverPreviewIdentity({
    required this.name,
    this.federation = '',
    this.title = '',
    this.rating = 0,
    this.ratingChange,
    this.pointsText,
    this.fideId,
    this.photoUrl,
  });

  final String name;
  final String federation;
  final String title;
  final int rating;
  final int? ratingChange;
  final String? pointsText;
  final int? fideId;
  final String? photoUrl;
}

/// Hover-intent preview anchored to a board player name.
///
/// The trigger and popover share a short dismissal grace period so crossing the
/// portal gap does not flicker. The popover owns a real vertical scroll view;
/// wheel events stay inside the card and do not dismiss it.
class PlayerHoverPreview extends StatefulWidget {
  const PlayerHoverPreview({
    super.key,
    required this.player,
    required this.games,
    required this.onOpenOpponentInNewTab,
    required this.onOpenGameInNewTab,
    this.onOpenPlayerInNewTab,
    this.onPreviewOpened,
    this.onPreviewClosed,
    this.isLoading = false,
    this.openAbove = false,
    this.contextKey = '',
    this.textStyle = const TextStyle(
      color: kWhiteColor,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
  });

  final PlayerHoverPreviewIdentity player;
  final List<TournamentGameSummary> games;
  final ValueChanged<PlayerHoverPreviewIdentity>? onOpenPlayerInNewTab;
  final ValueChanged<PlayerHoverPreviewIdentity> onOpenOpponentInNewTab;
  final ValueChanged<TournamentGameSummary> onOpenGameInNewTab;
  final VoidCallback? onPreviewOpened;
  final VoidCallback? onPreviewClosed;
  final bool isLoading;
  final bool openAbove;
  final String contextKey;
  final TextStyle textStyle;

  @override
  State<PlayerHoverPreview> createState() => _PlayerHoverPreviewState();
}

class _PlayerHoverPreviewState extends State<PlayerHoverPreview>
    with
        SingleTickerProviderStateMixin,
        DeferredPointerStateMixin<PlayerHoverPreview> {
  late final FPopoverController _controller = FPopoverController(vsync: this);
  final GlobalKey _triggerRegionKey = GlobalKey(
    debugLabel: 'player-hover-trigger-region',
  );
  final GlobalKey _popoverRegionKey = GlobalKey(
    debugLabel: 'player-hover-popover-region',
  );
  final ScrollController _scrollController = ScrollController();
  Timer? _openTimer;
  Timer? _dismissTimer;
  bool _hoveringTrigger = false;
  bool _hoveringPopover = false;
  bool _active = false;
  bool _reportedOpen = false;
  Offset? _lastPointerPosition;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncControllerState);
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleGlobalPointerEvent,
    );
  }

  @override
  void didUpdateWidget(covariant PlayerHoverPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final playerChanged =
        oldWidget.player.name != widget.player.name ||
        oldWidget.player.fideId != widget.player.fideId;
    if (!playerChanged && oldWidget.contextKey == widget.contextKey) return;

    if (_reportedOpen) {
      _reportedOpen = false;
      final onClosed = oldWidget.onPreviewClosed;
      if (onClosed != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onClosed());
      }
    }
    _openTimer?.cancel();
    _dismissTimer?.cancel();
    _hoveringTrigger = false;
    _hoveringPopover = false;
    _active = false;
    _lastPointerPosition = null;
    _controller.hide();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleGlobalPointerEvent,
    );
    _openTimer?.cancel();
    _dismissTimer?.cancel();
    _controller.removeListener(_syncControllerState);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _syncControllerState() {
    if (!mounted) return;
    final active = _controller.status != AnimationStatus.dismissed;
    if (_active != active) setState(() => _active = active);
    if (!active) {
      _reportClosed();
      _dismissTimer?.cancel();
      _lastPointerPosition = null;
    }
  }

  void _scheduleOpen() {
    _dismissTimer?.cancel();
    _openTimer?.cancel();
    if (_controller.status == AnimationStatus.completed ||
        _controller.status == AnimationStatus.forward) {
      if (!_active) setState(() => _active = true);
      return;
    }
    _openTimer = Timer(playerHoverIntentDelay, () {
      if (!mounted || !_hoveringTrigger) return;
      setState(() => _active = true);
      _reportedOpen = true;
      widget.onPreviewOpened?.call();
      _controller.show();
    });
  }

  void _reportClosed() {
    if (!_reportedOpen) return;
    _reportedOpen = false;
    widget.onPreviewClosed?.call();
  }

  void _scheduleDismiss() {
    _openTimer?.cancel();
    _dismissTimer?.cancel();
    _dismissTimer = Timer(playerHoverGraceDelay, () {
      if (!mounted || _hoveringTrigger || _hoveringPopover) return;
      final pointer = _lastPointerPosition;
      if (pointer != null && _isPointerNearby(pointer)) return;
      _controller.hide();
    });
  }

  void _handleGlobalPointerEvent(PointerEvent event) {
    if (!mounted || !_active) return;
    if (event is PointerDownEvent) {
      if (!_isPointerInsideInteractiveRegion(event.position)) {
        _dismissTimer?.cancel();
        _controller.hide();
      }
      return;
    }
    if (event is! PointerHoverEvent && event is! PointerMoveEvent) return;

    _lastPointerPosition = event.position;
    if (_hoveringTrigger ||
        _hoveringPopover ||
        _isPointerNearby(event.position)) {
      _dismissTimer?.cancel();
      return;
    }
    _scheduleDismiss();
  }

  bool _isPointerNearby(Offset pointer) {
    final triggerRect = _globalRect(_triggerRegionKey);
    final popoverRect = _globalRect(_popoverRegionKey);
    if (triggerRect == null || popoverRect == null) return false;
    return isPlayerHoverPointerNearby(
      pointer: pointer,
      triggerRect: triggerRect,
      cardRect: popoverRect,
    );
  }

  bool _isPointerInsideInteractiveRegion(Offset pointer) {
    final triggerRect = _globalRect(_triggerRegionKey);
    final popoverRect = _globalRect(_popoverRegionKey);
    return (triggerRect?.contains(pointer) ?? false) ||
        (popoverRect?.contains(pointer) ?? false);
  }

  Rect? _globalRect(GlobalKey key) {
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _hideBeforeAction(VoidCallback action) {
    _openTimer?.cancel();
    _dismissTimer?.cancel();
    _hoveringTrigger = false;
    _hoveringPopover = false;
    _controller.hide();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final filteredGames = playerHoverPreviewGames(widget.player, widget.games);
    final triggerAnchor =
        widget.openAbove ? Alignment.topLeft : Alignment.bottomLeft;
    final popoverAnchor =
        widget.openAbove ? Alignment.bottomLeft : Alignment.topLeft;

    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        childAnchor: triggerAnchor,
        popoverAnchor: popoverAnchor,
        spacing: const FPortalSpacing(6),
        hideRegion: FPopoverHideRegion.anywhere,
        popoverBuilder:
            (context, _) => MouseRegion(
              key: _popoverRegionKey,
              onEnter:
                  (_) => runAfterPointerEvent(() {
                    if (!mounted) return;
                    _hoveringPopover = true;
                    _openTimer?.cancel();
                    _dismissTimer?.cancel();
                  }),
              onExit:
                  (event) => runAfterPointerEvent(() {
                    if (!mounted) return;
                    _lastPointerPosition = event.position;
                    _hoveringPopover = false;
                    _scheduleDismiss();
                  }),
              child: _PlayerPreviewCard(
                player: widget.player,
                games: filteredGames,
                isLoading: widget.isLoading,
                scrollController: _scrollController,
                onOpenPlayer:
                    widget.onOpenPlayerInNewTab == null
                        ? null
                        : () => _hideBeforeAction(
                          () => widget.onOpenPlayerInNewTab!(widget.player),
                        ),
                onOpenOpponent:
                    (opponent) => _hideBeforeAction(
                      () => widget.onOpenOpponentInNewTab(opponent),
                    ),
                onOpenGame:
                    (game) => _hideBeforeAction(
                      () => widget.onOpenGameInNewTab(game),
                    ),
              ),
            ),
        child: MouseRegion(
          key: _triggerRegionKey,
          onEnter:
              (_) => runAfterPointerEvent(() {
                if (!mounted) return;
                _hoveringTrigger = true;
                _scheduleOpen();
              }),
          onExit:
              (event) => runAfterPointerEvent(() {
                if (!mounted) return;
                _lastPointerPosition = event.position;
                _hoveringTrigger = false;
                _scheduleDismiss();
              }),
          child: AnimatedContainer(
            key: const ValueKey<String>('player-hover-preview-trigger'),
            duration: const Duration(milliseconds: 100),
            decoration: BoxDecoration(
              color:
                  _active
                      ? kPrimaryColor.withValues(alpha: 0.18)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color:
                    _active
                        ? kPrimaryColor.withValues(alpha: 0.50)
                        : Colors.transparent,
              ),
            ),
            child: Text(
              widget.player.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.textStyle,
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
List<TournamentGameSummary> playerHoverPreviewGames(
  PlayerHoverPreviewIdentity player,
  List<TournamentGameSummary> games,
) {
  final seen = <String>{};
  final filtered = [
    for (final game in games)
      if (_playerSide(player, game) != null && seen.add(game.id)) game,
  ];
  final indexed = filtered.indexed.toList(growable: false);
  indexed.sort((left, right) {
    final roundOrder = _compareRoundParts(
      _roundSortParts(right.$2),
      _roundSortParts(left.$2),
    );
    return roundOrder != 0 ? roundOrder : left.$1.compareTo(right.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

List<int> _roundSortParts(TournamentGameSummary game) => [
  for (final match in RegExp(r'\d+').allMatches(_roundLabel(game)))
    int.parse(match.group(0)!),
];

int _compareRoundParts(List<int> left, List<int> right) {
  if (left.isEmpty || right.isEmpty) {
    if (left.isEmpty == right.isEmpty) return 0;
    return left.isEmpty ? -1 : 1;
  }
  final sharedLength = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < sharedLength; index++) {
    final compared = left[index].compareTo(right[index]);
    if (compared != 0) return compared;
  }
  return left.length.compareTo(right.length);
}

class _PlayerPreviewCard extends StatelessWidget {
  const _PlayerPreviewCard({
    required this.player,
    required this.games,
    required this.isLoading,
    required this.scrollController,
    required this.onOpenPlayer,
    required this.onOpenOpponent,
    required this.onOpenGame,
  });

  final PlayerHoverPreviewIdentity player;
  final List<TournamentGameSummary> games;
  final bool isLoading;
  final ScrollController scrollController;
  final VoidCallback? onOpenPlayer;
  final ValueChanged<PlayerHoverPreviewIdentity> onOpenOpponent;
  final ValueChanged<TournamentGameSummary> onOpenGame;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        key: const ValueKey<String>('player-hover-preview-card'),
        width: 420,
        decoration: BoxDecoration(
          color: kPopUpColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.48),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PlayerPreviewHeader(player: player, onOpenPlayer: onOpenPlayer),
            const Divider(height: 1, thickness: 1, color: kDividerColor),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Row(
                children: [
                  const Text(
                    'Games',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: kBlack3Color,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${games.length}',
                      style: const TextStyle(
                        color: kLightGreyColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    'Opponent · result',
                    style: TextStyle(color: kLightGreyColor, fontSize: 10),
                  ),
                ],
              ),
            ),
            if (isLoading && games.isEmpty)
              const SizedBox(
                height: 92,
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (games.isEmpty)
              const SizedBox(
                height: 82,
                child: Center(
                  child: Text(
                    'No games available in this context.',
                    style: TextStyle(color: kLightGreyColor, fontSize: 12),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: Scrollbar(
                  controller: scrollController,
                  thumbVisibility: games.length > 4,
                  interactive: true,
                  thickness: 10,
                  radius: const Radius.circular(5),
                  child: ListView.separated(
                    key: const ValueKey<String>('player-hover-preview-scroll'),
                    controller: scrollController,
                    primary: false,
                    shrinkWrap: true,
                    physics: const DesktopScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: games.length,
                    separatorBuilder:
                        (_, __) => const Divider(
                          height: 1,
                          thickness: 1,
                          color: kDividerColor,
                        ),
                    itemBuilder: (context, index) {
                      final game = games[index];
                      final side = _playerSide(player, game)!;
                      final opponent = _opponentFor(game, side);
                      return _PreviewGameRow(
                        game: game,
                        opponent: opponent,
                        playerIsWhite: side,
                        onOpenOpponent: () => onOpenOpponent(opponent),
                        onOpenGame: () => onOpenGame(game),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlayerPreviewHeader extends StatelessWidget {
  const _PlayerPreviewHeader({
    required this.player,
    required this.onOpenPlayer,
  });

  final PlayerHoverPreviewIdentity player;
  final VoidCallback? onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final photoUrl = player.photoUrl?.trim();
    final ratingChange = player.ratingChange;
    final score = _scoreValue(player.pointsText);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          PlayerInitialsAvatarCompact(
            photoUrl: photoUrl?.isEmpty == true ? null : photoUrl,
            initials: _initials(player.name),
            size: 48,
            borderRadius: 8,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BackfilledFederationFlag(
                      federation: player.federation,
                      fideId: player.fideId,
                      playerName: player.name,
                      width: 20,
                      height: 14,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    const SizedBox(width: 7),
                    if (player.title.trim().isNotEmpty) ...[
                      Text(
                        player.title.trim(),
                        style: const TextStyle(
                          color: kPrimaryColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ClickCursor(
                          child: GestureDetector(
                            key: const ValueKey<String>(
                              'player-hover-header-name',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onTap: onOpenPlayer,
                            child: Text(
                              player.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: kWhiteColor,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (player.rating > 0 || ratingChange != null) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      if (player.rating > 0)
                        Text(
                          '${player.rating}',
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      if (ratingChange != null && ratingChange != 0) ...[
                        const SizedBox(width: 7),
                        Icon(
                          ratingChange > 0
                              ? Icons.trending_up_rounded
                              : Icons.trending_down_rounded,
                          size: 14,
                          color: ratingChange > 0 ? kGreenColor : kRedColor,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          ratingChange > 0 ? '+$ratingChange' : '$ratingChange',
                          style: TextStyle(
                            color: ratingChange > 0 ? kGreenColor : kRedColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                if (score != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Score $score',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewGameRow extends StatelessWidget {
  const _PreviewGameRow({
    required this.game,
    required this.opponent,
    required this.playerIsWhite,
    required this.onOpenOpponent,
    required this.onOpenGame,
  });

  final TournamentGameSummary game;
  final PlayerHoverPreviewIdentity opponent;
  final bool playerIsWhite;
  final VoidCallback onOpenOpponent;
  final VoidCallback onOpenGame;

  @override
  Widget build(BuildContext context) {
    final result = _resultFor(game.status, playerIsWhite);
    final round = _roundLabel(game);
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                key: ValueKey<String>('game-round-${game.id}'),
                round,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 6),
            ClickCursor(
              child: GestureDetector(
                key: ValueKey<String>('game-result-${game.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: onOpenGame,
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: result.background,
                    border: Border.all(color: result.border),
                  ),
                  child: Text(
                    result.glyph,
                    style: TextStyle(
                      color: result.foreground,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            BackfilledFederationFlag(
              federation: opponent.federation,
              fideId: opponent.fideId,
              playerName: opponent.name,
              width: 20,
              height: 14,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(width: 7),
            if (opponent.title.trim().isNotEmpty) ...[
              Text(
                opponent.title,
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              fit: FlexFit.loose,
              child: ClickCursor(
                child: GestureDetector(
                  key: ValueKey<String>('opponent-name-${game.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onOpenOpponent,
                  child: Text(
                    opponent.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            if (opponent.rating > 0) ...[
              const SizedBox(width: 6),
              Text(
                key: ValueKey<String>('opponent-rating-${game.id}'),
                '${opponent.rating}',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

bool? _playerSide(
  PlayerHoverPreviewIdentity player,
  TournamentGameSummary game,
) {
  final fideId = player.fideId;
  final name = _normalizedName(player.name);
  if (name.isEmpty) return null;

  if (fideId != null) {
    if (game.whiteFideId == fideId) return true;
    if (game.blackFideId == fideId) return false;
    if (game.whiteFideId == null && _normalizedName(game.whitePlayer) == name) {
      return true;
    }
    if (game.blackFideId == null && _normalizedName(game.blackPlayer) == name) {
      return false;
    }
    return null;
  }

  if (_normalizedName(game.whitePlayer) == name) return true;
  if (_normalizedName(game.blackPlayer) == name) return false;
  return null;
}

PlayerHoverPreviewIdentity _opponentFor(
  TournamentGameSummary game,
  bool playerIsWhite,
) {
  return playerIsWhite
      ? PlayerHoverPreviewIdentity(
        name: game.blackPlayer,
        federation: game.blackFederation,
        title: game.blackTitle,
        rating: game.blackRating,
        fideId: game.blackFideId,
      )
      : PlayerHoverPreviewIdentity(
        name: game.whitePlayer,
        federation: game.whiteFederation,
        title: game.whiteTitle,
        rating: game.whiteRating,
        fideId: game.whiteFideId,
      );
}

String _normalizedName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

String? _scoreValue(String? pointsText) {
  final value = pointsText?.trim() ?? '';
  if (value.isEmpty) return null;
  final score = value.split('/').first.trim();
  return score.isEmpty ? null : score;
}

String _roundLabel(TournamentGameSummary game) {
  final explicit = game.roundLabel.trim();
  if (explicit.isNotEmpty) return explicit;
  final source =
      game.roundSlug.trim().isNotEmpty ? game.roundSlug : game.roundId;
  final match = RegExp(r'(\d+)').firstMatch(source);
  return match?.group(1) ?? '–';
}

({String glyph, Color background, Color border, Color foreground}) _resultFor(
  GameStatus status,
  bool playerIsWhite,
) {
  final score = switch (status) {
    GameStatus.whiteWins => playerIsWhite ? '1' : '0',
    GameStatus.blackWins => playerIsWhite ? '0' : '1',
    GameStatus.draw => '½',
    GameStatus.ongoing => '•',
    GameStatus.unknown => '–',
  };
  if (playerIsWhite) {
    return (
      glyph: score,
      background: kWhiteColor,
      border: kWhiteColor,
      foreground: kBlackColor,
    );
  }
  return (
    glyph: score,
    background: kBlackColor,
    border: kWhiteColor.withValues(alpha: 0.28),
    foreground: kWhiteColor,
  );
}

String _initials(String name) {
  final parts =
      name
          .trim()
          .split(RegExp(r'[\s,]+'))
          .where((part) => part.isNotEmpty)
          .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final value = parts.first;
    final end = value.length > 2 ? 2 : value.length;
    return value.substring(0, end).toUpperCase();
  }
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}
