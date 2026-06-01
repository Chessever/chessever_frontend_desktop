import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/current_user_profile.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_user_profile_button.dart';
import 'package:chessever/desktop/widgets/list_keyboard_scroll.dart';
import 'package:chessever/desktop/widgets/new_tab_modifier.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/favorite_players_provider.dart';
import 'package:chessever/screens/players/providers/player_providers.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/favorite_limit_guard.dart';
import 'package:chessever/widgets/auth/auth_upgrade_sheet.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

/// Desktop players route.
///
/// Uses the same player pagination/search provider as onboarding, but presents
/// it as a persistent desktop main route: search, scroll, open a profile, and
/// favorite/unfavorite directly from the list.
class PlayersPane extends HookConsumerWidget {
  const PlayersPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchController = useTextEditingController();
    final scrollController = useScrollController();
    final debounceTimer = useRef<Timer?>(null);
    final asyncPlayers = ref.watch(playerPaginationProvider);
    final favorites = ref.watch(favoritePlayersProviderNew);

    useEffect(() {
      unawaited(ref.read(playerPaginationProvider.notifier).initFirstPage());

      void onScroll() {
        if (!scrollController.hasClients) return;
        final remaining =
            scrollController.position.maxScrollExtent -
            scrollController.position.pixels;
        if (remaining <= 280) {
          unawaited(
            ref.read(playerPaginationProvider.notifier).fetchNextPage(),
          );
        }
      }

      scrollController.addListener(onScroll);
      return () {
        debounceTimer.value?.cancel();
        scrollController.removeListener(onScroll);
      };
    }, const []);

    void submitSearch(String query) {
      debounceTimer.value?.cancel();
      debounceTimer.value = Timer(const Duration(milliseconds: 240), () {
        ref.read(playerSearchQueryProvider.notifier).state = query;
        unawaited(
          ref
              .read(playerPaginationProvider.notifier)
              .setSearchQuery(query.trim()),
        );
      });
    }

    final favoriteIds =
        favorites.valueOrNull
            ?.map((p) => p.fideId?.trim().toLowerCase() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet() ??
        const <String>{};
    final favoriteNames =
        favorites.valueOrNull
            ?.map((p) => _normalizeName(p.playerName))
            .where((name) => name.isNotEmpty)
            .toSet() ??
        const <String>{};

    return Container(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.groups_outlined,
                  size: 18,
                  color: kPrimaryColor,
                ),
                const SizedBox(width: 10),
                const Text(
                  'Players',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
                const Spacer(),
                DesktopSearchField(
                  controller: searchController,
                  hintText: 'Search players',
                  maxWidth: 420,
                  onChanged: submitSearch,
                  onClear: () => submitSearch(''),
                ),
                const SizedBox(width: 10),
                DesktopUserProfileButton(
                  size: 32,
                  showLabel: true,
                  onPress: () => openCurrentUserProfileTab(ref),
                ),
              ],
            ),
          ),
          Expanded(
            child: asyncPlayers.when(
              data: (players) {
                if (players.isEmpty) {
                  return _PlayersEmpty(
                    isSearching: searchController.text.isNotEmpty,
                  );
                }
                return _PlayersList(
                  controller: scrollController,
                  players: players,
                  favoriteIds: favoriteIds,
                  favoriteNames: favoriteNames,
                );
              },
              loading: () => const _CenteredSpinner(),
              error:
                  (error, _) => _PlayersError(
                    message: 'Could not load players: $error',
                    onRetry:
                        () => unawaited(
                          ref
                              .read(playerPaginationProvider.notifier)
                              .initFirstPage(),
                        ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayersList extends HookConsumerWidget {
  const _PlayersList({
    required this.controller,
    required this.players,
    required this.favoriteIds,
    required this.favoriteNames,
  });

  final ScrollController controller;
  final List<Map<String, dynamic>> players;
  final Set<String> favoriteIds;
  final Set<String> favoriteNames;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(playerPaginationProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
        child: ListKeyboardScrollFocus(
          controller: controller,
          step: 72,
          child: ListView.separated(
            controller: controller,
            physics: const DesktopScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: players.length + (notifier.hasMore ? 1 : 0),
            separatorBuilder:
                (_, index) =>
                    index >= players.length - 1
                        ? const SizedBox.shrink()
                        : const Divider(height: 1, color: kDividerColor),
            itemBuilder: (context, index) {
              if (index >= players.length) {
                return const _LoadMoreRow();
              }

              final player = players[index];
              final favorite = _isFavorite(
                player,
                favoriteIds: favoriteIds,
                favoriteNames: favoriteNames,
              );
              return _PlayerTile(
                key: ValueKey(_playerKey(player, index)),
                player: player,
                rank: index + 1,
                isFavorite: favorite,
                onOpen:
                    ({required bool inNewTab}) =>
                        _openPlayer(ref, player, focus: !inNewTab),
                onContextMenu: (position) async {
                  final action = await showDesktopContextMenu<_PlayerRowAction>(
                    context: context,
                    position: position,
                    entries: [
                      const DesktopContextMenuItem<_PlayerRowAction>(
                        value: _PlayerRowAction.openProfile,
                        icon: Icons.person_outline_rounded,
                        label: 'Open profile',
                      ),
                      const DesktopContextMenuItem<_PlayerRowAction>(
                        value: _PlayerRowAction.openInNewTab,
                        icon: Icons.open_in_new_rounded,
                        label: 'Open in new tab',
                        shortcut: '⌘·Click',
                      ),
                      const DesktopContextMenuDivider<_PlayerRowAction>(),
                      DesktopContextMenuItem<_PlayerRowAction>(
                        value: _PlayerRowAction.toggleFavorite,
                        icon:
                            favorite
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                        label:
                            favorite
                                ? 'Remove from favorites'
                                : 'Add to favorites',
                      ),
                    ],
                  );
                  if (action == null) return;
                  switch (action) {
                    case _PlayerRowAction.openProfile:
                      _openPlayer(ref, player, focus: true);
                      break;
                    case _PlayerRowAction.openInNewTab:
                      _openPlayer(ref, player, focus: false);
                      break;
                    case _PlayerRowAction.toggleFavorite:
                      if (!context.mounted) return;
                      await _toggleFavorite(
                        context,
                        ref,
                        player,
                        isFavorite: favorite,
                      );
                      break;
                  }
                },
                onFavoriteTap:
                    () => _toggleFavorite(
                      context,
                      ref,
                      player,
                      isFavorite: favorite,
                    ),
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _PlayerRowAction { openProfile, openInNewTab, toggleFavorite }

class _PlayerTile extends StatefulWidget {
  const _PlayerTile({
    super.key,
    required this.player,
    required this.rank,
    required this.isFavorite,
    required this.onOpen,
    required this.onContextMenu,
    required this.onFavoriteTap,
  });

  final Map<String, dynamic> player;
  final int rank;
  final bool isFavorite;

  /// Tap handler. `inNewTab` is true when Cmd/Ctrl is held — opens the
  /// profile in a background tab (Chrome convention).
  final void Function({required bool inNewTab}) onOpen;
  final void Function(Offset globalPosition) onContextMenu;
  final Future<void> Function() onFavoriteTap;

  @override
  State<_PlayerTile> createState() => _PlayerTileState();
}

class _PlayerTileState extends State<_PlayerTile> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final name = desktopPlayerDisplayName(widget.player);
    final title = _playerTitle(widget.player);
    final federation = _playerFederation(widget.player);
    final fideId = _playerFideId(widget.player);
    final rating = _playerRating(widget.player);

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
          onTap: () => widget.onOpen(inNewTab: isNewTabModifierPressed()),
          onSecondaryTapDown:
              (details) => widget.onContextMenu(details.globalPosition),
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: SingleMotionBuilder(
            value: _pressed ? 0.99 : (_hovered ? 1.003 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              color: _hovered ? kBlack3Color : kBlack2Color,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  _PlayerRank(label: desktopPlayerRankLabel(widget.rank)),
                  const SizedBox(width: 12),
                  _PlayerAvatar(
                    fideId: fideId,
                    initials: _initials(name),
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (title != null) ...[
                              _TitlePill(title: title),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                name.isEmpty ? 'Unknown player' : name,
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
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            if (federation != null) ...[
                              FederationFlag(
                                federation: federation,
                                width: 18,
                                height: 13,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                federation.toUpperCase(),
                                style: const TextStyle(
                                  color: kWhiteColor70,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                            if (rating != null) ...[
                              if (federation != null) const SizedBox(width: 12),
                              const Icon(
                                Icons.equalizer_rounded,
                                size: 13,
                                color: kLightGreyColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                rating.toString(),
                                style: const TextStyle(
                                  color: kWhiteColor70,
                                  fontSize: 11,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                            if (fideId.isNotEmpty) ...[
                              const SizedBox(width: 12),
                              Text(
                                'FIDE $fideId',
                                style: const TextStyle(
                                  color: kLightGreyColor,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _FavoriteToggle(
                    active: widget.isFavorite,
                    onTap: () => unawaited(widget.onFavoriteTap()),
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

class _FavoriteToggle extends StatefulWidget {
  const _FavoriteToggle({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  State<_FavoriteToggle> createState() => _FavoriteToggleState();
}

class _FavoriteToggleState extends State<_FavoriteToggle> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
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
            value: _pressed ? 0.86 : (_hovered ? 1.1 : 1.0),
            motion: _pressed ? DesktopMotion.tap : DesktopMotion.arrival,
            builder:
                (context, scale, child) =>
                    Transform.scale(scale: scale, child: child),
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              child: Icon(
                widget.active
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: 19,
                color: widget.active ? kPrimaryColor : kWhiteColor70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerAvatar extends HookWidget {
  const _PlayerAvatar({
    required this.fideId,
    required this.initials,
    required this.size,
  });

  final String fideId;
  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) {
    final photoFuture = useMemoized(
      () =>
          fideId.isEmpty
              ? Future<String?>.value()
              : FidePhotoService.getPhotoUrlOrNull(fideId),
      [fideId],
    );
    final photo = useFuture(photoFuture).data;

    return PlayerInitialsAvatarCompact(
      photoUrl: photo,
      initials: initials,
      size: size,
      borderRadius: size / 2,
    );
  }
}

class _PlayerRank extends StatelessWidget {
  const _PlayerRank({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      child: Text(
        label,
        textAlign: TextAlign.right,
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}

class _TitlePill extends StatelessWidget {
  const _TitlePill({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
      ),
      child: Text(
        title,
        style: const TextStyle(
          color: kPrimaryColor,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LoadMoreRow extends StatelessWidget {
  const _LoadMoreRow();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 54,
      child: Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      ),
    );
  }
}

class _CenteredSpinner extends StatelessWidget {
  const _CenteredSpinner();

  @override
  Widget build(BuildContext context) {
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
}

class _PlayersEmpty extends StatelessWidget {
  const _PlayersEmpty({required this.isSearching});

  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          isSearching ? 'No players found' : 'No players available yet.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: kLightGreyColor, fontSize: 12),
        ),
      ),
    );
  }
}

class _PlayersError extends StatelessWidget {
  const _PlayersError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kRedColor, fontSize: 12),
            ),
            const SizedBox(height: 12),
            ClickCursor(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRetry,
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kBlack2Color,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: kDividerColor),
                  ),
                  child: const Text(
                    'Retry',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _toggleFavorite(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> player, {
  required bool isFavorite,
}) async {
  final allowed = await requireFullAuthGuard(context);
  if (!allowed || !context.mounted) return;

  if (!isFavorite) {
    final canAdd = await canAddMoreFavorites(context, ref);
    if (!canAdd || !context.mounted) return;
  }

  final fideId = _playerFideId(player);
  if (fideId.isEmpty) return;
  unawaited(
    ref
        .read(playerPaginationProvider.notifier)
        .setFavorite(fideId, !isFavorite),
  );
}

void _openPlayer(
  WidgetRef ref,
  Map<String, dynamic> player, {
  bool focus = true,
}) {
  final name = _playerName(player);
  if (name.isEmpty) return;
  openPlayerProfile(
    ref,
    PlayerProfileArgs(
      playerName: name,
      fideId: int.tryParse(_playerFideId(player)),
      title: _playerTitle(player),
      federation: _playerFederation(player),
      rating: _playerRating(player),
    ),
    focus: focus,
  );
}

bool _isFavorite(
  Map<String, dynamic> player, {
  required Set<String> favoriteIds,
  required Set<String> favoriteNames,
}) {
  final fideId = _playerFideId(player).toLowerCase();
  final name = _normalizeName(_playerName(player));
  final titledName = _normalizeName(
    [_playerTitle(player), _playerName(player)].whereType<String>().join(' '),
  );
  return player['isFavorite'] == true ||
      (fideId.isNotEmpty && favoriteIds.contains(fideId)) ||
      favoriteNames.contains(name) ||
      favoriteNames.contains(titledName);
}

String _playerKey(Map<String, dynamic> player, int index) {
  final fideId = _playerFideId(player);
  if (fideId.isNotEmpty) return fideId;
  final name = _playerName(player);
  if (name.isNotEmpty) return name;
  return 'player-$index';
}

String _playerName(Map<String, dynamic> player) {
  return _stringField(player, const ['name', 'playerName']);
}

@visibleForTesting
String desktopPlayerDisplayName(Map<String, dynamic> player) {
  return stripDesktopPlayerTitlePrefix(
    _playerName(player),
    _playerTitle(player),
  );
}

@visibleForTesting
String stripDesktopPlayerTitlePrefix(String name, String? title) {
  final trimmed = name.trim();
  final normalizedTitle = title?.trim();
  if (trimmed.isEmpty || normalizedTitle == null || normalizedTitle.isEmpty) {
    return trimmed;
  }

  return trimmed.replaceFirst(
    RegExp('^${RegExp.escape(normalizedTitle)}\\s+', caseSensitive: false),
    '',
  );
}

@visibleForTesting
String desktopPlayerRankLabel(int rank) {
  return rank.toString();
}

String? _playerTitle(Map<String, dynamic> player) {
  final title = _stringField(player, const ['title']);
  if (title.isEmpty || title == '-' || title.toLowerCase() == 'null') {
    return null;
  }
  return title;
}

String? _playerFederation(Map<String, dynamic> player) {
  final federation = _stringField(player, const [
    'fed',
    'federation',
    'country',
    'countryCode',
  ]);
  if (federation.isEmpty ||
      federation == '-' ||
      federation.toLowerCase() == 'null') {
    return null;
  }
  return federation;
}

String _playerFideId(Map<String, dynamic> player) {
  return _stringField(player, const ['fideId', 'fide_id', 'playerId']);
}

int? _playerRating(Map<String, dynamic> player) {
  for (final key in const ['rating', 'elo', 'score']) {
    final value = player[key];
    if (value is int) return value > 0 ? value : null;
    if (value is num) return value > 0 ? value.toInt() : null;
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

String _stringField(Map<String, dynamic> player, List<String> keys) {
  for (final key in keys) {
    final value = player[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

String _normalizeName(String name) {
  return name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

String _initials(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final commaParts = trimmed.split(', ');
  if (commaParts.length >= 2 &&
      commaParts[0].isNotEmpty &&
      commaParts[1].isNotEmpty) {
    return '${commaParts[1][0]}${commaParts[0][0]}'.toUpperCase();
  }
  final words =
      trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length >= 2) return '${words[0][0]}${words[1][0]}'.toUpperCase();
  return trimmed
      .substring(0, trimmed.length >= 2 ? 2 : trimmed.length)
      .toUpperCase();
}
