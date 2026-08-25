import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/library_pane.dart'
    show
        DatabaseWorkspaceArgs,
        LocalDatabaseWorkspaceKey,
        openDatabaseWorkspaceTab;
import 'package:chessever/desktop/services/local_chess_drop_zone.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_pgn_catalog.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_explorer_scope.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/utils/player_build_tree_filters.dart';
import 'package:chessever/screens/gamebase/models/gamebase_player.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/library/local_chess_files_view.dart';
import 'package:chessever/desktop/widgets/player_stats_dashboard.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_player_title_chip.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/library/local_tree_action_button.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/screens/favorites/tabs/favorites_players_tab.dart'
    show playerPhotoProvider;
import 'package:chessever/screens/gamebase/models/models.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

const _startingFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

@visibleForTesting
String playerWorkspaceDisplayName(PlayerWorkspacePlayer player) {
  final displayName = player.displayName.trim();
  final title = player.title?.trim();
  if (displayName.isEmpty || title == null || title.isEmpty) {
    return displayName;
  }
  return displayName.replaceFirst(
    RegExp('^${RegExp.escape(title)}\\s+', caseSensitive: false),
    '',
  );
}

/// Canonical visual order for sources in the player-detail rail.
///
/// Kept as a single testable value so the generated Combined database cannot
/// silently drift below Manual PGN again when source cards are rearranged.
@visibleForTesting
const playerWorkspaceSourceRailOrder = <PlayerWorkspaceSource>[
  PlayerWorkspaceSource.chessever,
  PlayerWorkspaceSource.lichess,
  PlayerWorkspaceSource.chesscom,
  PlayerWorkspaceSource.combined,
  PlayerWorkspaceSource.manual,
];

enum _PlayerWorkspaceTab { overview, accounts, games, buildTree }

final _cachedPlayerWorkspaceTreeIndexProvider = FutureProvider.autoDispose
    .family<PlayerOpeningTreeIndex?, String>((ref, path) async {
      final clean = path.trim();
      if (clean.isEmpty) return null;
      final liveIndex = ref.watch(
        localChessLibraryProvider.select((state) {
          final node = state.source?.nodeForPath(clean);
          if (node is! LocalChessFileNode) return null;
          final index = node.openingTreeIndex;
          return index?.isUsable == true ? index : null;
        }),
      );
      if (liveIndex != null) return liveIndex;
      final index = ref
          .read(localChessDatabaseRepositoryProvider)
          .loadCompactOpeningTreeIndexForDatabase(databasePath: clean);
      return index?.isUsable == true ? index : null;
    });

final _playerWorkspaceGamesSourceProvider = FutureProvider.autoDispose
    .family<LocalChessSource, LocalDatabaseWorkspaceKey>((ref, key) async {
      return PlayerPgnCatalog.instance.load(key.path);
    });

@immutable
class _PlayerTreeBuildState {
  const _PlayerTreeBuildState({
    this.progressByPath = const <String, LocalChessTreeBuildProgress>{},
    this.indexByPath = const <String, PlayerOpeningTreeIndex>{},
  });

  final Map<String, LocalChessTreeBuildProgress> progressByPath;
  final Map<String, PlayerOpeningTreeIndex> indexByPath;

  LocalChessTreeBuildProgress? progressFor(String path) =>
      progressByPath[localChessInputPathKey(path)];

  PlayerOpeningTreeIndex? indexFor(String path) =>
      indexByPath[localChessInputPathKey(path)];
}

class _PlayerTreeBuildController extends StateNotifier<_PlayerTreeBuildState> {
  _PlayerTreeBuildController(this._repository)
    : super(const _PlayerTreeBuildState());

  final LocalChessDatabaseRepository _repository;
  final Map<String, OperationCancellationToken> _tokens =
      <String, OperationCancellationToken>{};
  final Map<String, Future<PlayerOpeningTreeIndex?>> _builds =
      <String, Future<PlayerOpeningTreeIndex?>>{};

  Future<PlayerOpeningTreeIndex?> build(String path) {
    final key = localChessInputPathKey(path);
    final active = _builds[key];
    if (active != null) return active;
    final token = OperationCancellationToken();
    _tokens[key] = token;
    _setProgress(
      key,
      LocalChessTreeBuildProgress(
        path: path,
        phase: LocalChessTreeBuildPhase.queued,
        fraction: 0,
        message: 'Preparing PGN tree...',
      ),
    );
    late final Future<PlayerOpeningTreeIndex?> task;
    task = _runBuild(path, key, token).whenComplete(() {
      if (identical(_tokens[key], token)) _tokens.remove(key);
      if (identical(_builds[key], task)) _builds.remove(key);
    });
    _builds[key] = task;
    return task;
  }

  Future<PlayerOpeningTreeIndex?> _runBuild(
    String path,
    String key,
    OperationCancellationToken token,
  ) async {
    final startedAtMs = DateTime.now().millisecondsSinceEpoch;
    try {
      final result = await _repository.rebuildOpeningTreeFromPgnFile(
        databasePath: path,
        cancellationToken: token,
        onProgress: (progress) {
          if (token.isCanceled || !identical(_tokens[key], token)) return;
          final message = progress.message.toLowerCase();
          final phase =
              message.contains('publish') ||
                      message.contains('saving') ||
                      message.contains('finaliz')
                  ? LocalChessTreeBuildPhase.persisting
                  : LocalChessTreeBuildPhase.building;
          _setProgress(
            key,
            LocalChessTreeBuildProgress(
              path: path,
              phase: phase,
              fraction: progress.fraction,
              message: progress.message,
              startedAtMs: startedAtMs,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
        },
      );
      token.throwIfCanceled();
      final index = result?.index;
      if (index?.isUsable != true) {
        throw StateError('Opening tree build did not produce an index.');
      }
      final nextIndexes = Map<String, PlayerOpeningTreeIndex>.of(
        state.indexByPath,
      )..[key] = index!;
      final nextProgress = Map<String, LocalChessTreeBuildProgress>.of(
        state.progressByPath,
      )..remove(key);
      state = _PlayerTreeBuildState(
        progressByPath: Map.unmodifiable(nextProgress),
        indexByPath: Map.unmodifiable(nextIndexes),
      );
      return index;
    } catch (error) {
      if (token.isCanceled || isOperationCanceled(error)) {
        _removeProgress(key);
        return null;
      }
      _setProgress(
        key,
        LocalChessTreeBuildProgress(
          path: path,
          phase: LocalChessTreeBuildPhase.failed,
          fraction: 0,
          message: 'Opening tree rebuild failed. Click Retry Tree.',
          error: localChessOpenErrorMessage(error),
          startedAtMs: startedAtMs,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      rethrow;
    }
  }

  bool cancel(String path) {
    final key = localChessInputPathKey(path);
    final token = _tokens[key];
    if (token == null) return false;
    token.cancel();
    _removeProgress(key);
    return true;
  }

  void _setProgress(String key, LocalChessTreeBuildProgress progress) {
    final next = Map<String, LocalChessTreeBuildProgress>.of(
      state.progressByPath,
    )..[key] = progress;
    state = _PlayerTreeBuildState(
      progressByPath: Map.unmodifiable(next),
      indexByPath: state.indexByPath,
    );
  }

  void _removeProgress(String key) {
    if (!state.progressByPath.containsKey(key)) return;
    final next = Map<String, LocalChessTreeBuildProgress>.of(
      state.progressByPath,
    )..remove(key);
    state = _PlayerTreeBuildState(
      progressByPath: Map.unmodifiable(next),
      indexByPath: state.indexByPath,
    );
  }

  @override
  void dispose() {
    for (final token in _tokens.values) {
      token.cancel();
    }
    _tokens.clear();
    super.dispose();
  }
}

final _playerTreeBuildProvider = StateNotifierProvider<
  _PlayerTreeBuildController,
  _PlayerTreeBuildState
>((ref) {
  return _PlayerTreeBuildController(
    ref.read(localChessDatabaseRepositoryProvider),
  );
});

class PlayerWorkspacePane extends HookConsumerWidget {
  const PlayerWorkspacePane({super.key, this.tabId});

  final String? tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final players = ref.watch(
      playerWorkspaceProvider.select((state) => state.players),
    );
    final isLoading = ref.watch(
      playerWorkspaceProvider.select((state) => state.isLoading),
    );
    final error = ref.watch(
      playerWorkspaceProvider.select((state) => state.error),
    );
    final requestedPlayerId = ref.watch(
      playerWorkspacePlayerByTabIdProvider.select(
        (targets) => tabId == null ? null : targets[tabId],
      ),
    );
    final routedPlayerId = ref.watch(
      desktopTabsProvider.select((tabs) {
        if (tabId == null) return null;
        for (final tab in tabs.tabs) {
          if (tab.id == tabId) return playerWorkspacePlayerIdFromTab(tab);
        }
        return null;
      }),
    );
    final openedPlayerId = useState<String?>(requestedPlayerId);
    final visiblePlayerId =
        tabId == null
            ? requestedPlayerId ?? openedPlayerId.value
            : routedPlayerId;
    final selected = _playerById(players, visiblePlayerId);
    final isActiveTab = ref.watch(
      desktopTabsProvider.select(
        (tabs) => tabId == null || tabs.activeId == tabId,
      ),
    );
    final tab = useState(_PlayerWorkspaceTab.overview);
    final gamesFilter = useState(LocalChessGameFilter());
    final gamesSourcePath = useState<String?>(null);
    final gamesFilterNonce = useState(0);

    useEffect(() {
      if (!isActiveTab || visiblePlayerId == null) return null;
      unawaited(
        Future<void>(() {
          ref
              .read(playerWorkspaceProvider.notifier)
              .selectPlayer(visiblePlayerId);
        }),
      );
      return null;
    }, [isActiveTab, visiblePlayerId]);

    void openPlayer(String playerId) {
      openedPlayerId.value = playerId;
      final currentTabId = tabId;
      if (currentTabId != null) {
        ref
            .read(playerWorkspacePlayerByTabIdProvider.notifier)
            .update(
              (targets) => <String, String>{...targets, currentTabId: playerId},
            );
        ref
            .read(desktopTabsProvider.notifier)
            .navigateActive(
              TabKind.players,
              subtitle: playerWorkspaceRouteSubtitle(playerId),
            );
      }
      tab.value = _PlayerWorkspaceTab.overview;
      gamesFilter.value = LocalChessGameFilter();
      gamesSourcePath.value = null;
      gamesFilterNonce.value = 0;
      unawaited(
        ref.read(playerWorkspaceProvider.notifier).selectPlayer(playerId),
      );
    }

    void applyOverviewFilter(PlayerOverviewFilterRequest request) {
      gamesFilter.value = localChessGameFilterFromOverview(request);
      if (request.sourcePath != null && request.sourcePath!.isNotEmpty) {
        gamesSourcePath.value = request.sourcePath;
      }
      gamesFilterNonce.value++;
      tab.value = _PlayerWorkspaceTab.games;
    }

    final body = ColoredBox(
      color: kBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected == null)
            _Header(
              onAddPlayer:
                  () => unawaited(
                    _showAddPlayerDialog(
                      context,
                      ref,
                      onOpenPlayer: openPlayer,
                    ),
                  ),
            ),
          Expanded(
            child:
                isLoading
                    ? const Center(
                      child: CircularProgressIndicator(color: kPrimaryColor),
                    )
                    : selected == null
                    ? _PlayerLibraryHome(
                      players: players,
                      error: error,
                      onAddPlayer:
                          () => unawaited(
                            _showAddPlayerDialog(
                              context,
                              ref,
                              onOpenPlayer: openPlayer,
                            ),
                          ),
                      onOpenPlayer: openPlayer,
                      onRenamePlayer:
                          (player) => unawaited(
                            _showRenamePlayerDialog(context, ref, player),
                          ),
                      onRemovePlayer:
                          (player) => unawaited(
                            _confirmRemovePlayer(context, ref, player),
                          ),
                    )
                    : Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 330,
                            child: _PlayerSourceRail(
                              player: selected,
                              onAddAccount:
                                  (source) => unawaited(
                                    _showAccountConnectFlow(
                                      context,
                                      ref,
                                      source,
                                    ),
                                  ),
                              onEditAccount:
                                  (account) => unawaited(
                                    _showEditAccountDialog(
                                      context,
                                      ref,
                                      account,
                                    ),
                                  ),
                              onRefreshAccount:
                                  (account) => unawaited(
                                    _runRefreshAccountEntry(
                                      context,
                                      ref,
                                      account,
                                    ),
                                  ),
                              onRemoveAccount:
                                  (account) => unawaited(
                                    _confirmRemoveAccountEntry(
                                      context,
                                      ref,
                                      account,
                                    ),
                                  ),
                              onSync:
                                  (account) => unawaited(
                                    _runAccountSync(context, ref, account),
                                  ),
                              onReinstall:
                                  (account) => unawaited(
                                    _confirmReinstallAccount(
                                      context,
                                      ref,
                                      account,
                                    ),
                                  ),
                              onCancelOperation:
                                  (account) => unawaited(
                                    _runCancelAccountOperation(
                                      context,
                                      ref,
                                      account,
                                    ),
                                  ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _PlayerWorkspaceMain(
                              selectedTab: tab.value,
                              onTabChanged: (value) => tab.value = value,
                              player: selected,
                              onGoToAccounts:
                                  () =>
                                      tab.value = _PlayerWorkspaceTab.accounts,
                              gamesFilter: gamesFilter.value,
                              gamesSourcePath: gamesSourcePath.value,
                              gamesFilterNonce: gamesFilterNonce.value,
                              onOverviewFilter: applyOverviewFilter,
                              onGamesFilterChanged: (next) {
                                gamesFilter.value = next;
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
          ),
        ],
      ),
    );
    return LocalChessDropZone(
      enabled: selected != null,
      onChessPathsDropped: (paths) async {
        if (selected == null) return;
        try {
          await ref
              .read(playerWorkspaceProvider.notifier)
              .importManualPgnPaths(paths: paths);
        } catch (error) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      },
      child: body,
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onAddPlayer});

  final VoidCallback onAddPlayer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Row(
        children: [
          const Icon(
            Icons.person_search_outlined,
            size: 18,
            color: kPrimaryColor,
          ),
          const SizedBox(width: 10),
          // One Expanded absorbs all the slack so the trailing action pins to
          // the right edge. (A Flexible title next to a Spacer would split the
          // free space between them and strand the button mid-header.)
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    'Players',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DesktopHeaderActionButton(
            label: 'Add player',
            icon: Icons.person_add_alt_1_outlined,
            accented: true,
            onPress: onAddPlayer,
          ),
        ],
      ),
    );
  }
}

class _PlayerLibraryHome extends HookWidget {
  const _PlayerLibraryHome({
    required this.players,
    required this.error,
    required this.onAddPlayer,
    required this.onOpenPlayer,
    required this.onRenamePlayer,
    required this.onRemovePlayer,
  });

  final List<PlayerWorkspacePlayer> players;
  final String? error;
  final VoidCallback onAddPlayer;
  final ValueChanged<String> onOpenPlayer;
  final ValueChanged<PlayerWorkspacePlayer> onRenamePlayer;
  final ValueChanged<PlayerWorkspacePlayer> onRemovePlayer;

  @override
  Widget build(BuildContext context) {
    final searchController = useTextEditingController();
    final query = useState('');
    final filtered =
        players
            .where((player) => _matchesPlayerQuery(player, query.value))
            .toList()
          ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            _LibraryErrorBanner(message: error!),
            const SizedBox(height: 12),
          ],
          if (players.isEmpty)
            Expanded(child: _EmptyPlayerWorkspace(onAddPlayer: onAddPlayer))
          else ...[
            _PlayerLibraryToolbar(
              players: players,
              controller: searchController,
              onSearchChanged: (value) => query.value = value,
            ),
            const SizedBox(height: 12),
            Expanded(
              child:
                  filtered.isEmpty
                      ? _NoMatchingPlayers(
                        onClear: () {
                          searchController.clear();
                          query.value = '';
                        },
                      )
                      : _PlayerLibraryList(
                        players: filtered,
                        onOpenPlayer: onOpenPlayer,
                        onRenamePlayer: onRenamePlayer,
                        onRemovePlayer: onRemovePlayer,
                      ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlayerLibraryToolbar extends StatelessWidget {
  const _PlayerLibraryToolbar({
    required this.players,
    required this.controller,
    required this.onSearchChanged,
  });

  final List<PlayerWorkspacePlayer> players;
  final TextEditingController controller;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final totalGames = players.fold<int>(
      0,
      (sum, player) => sum + player.totalGames,
    );
    final databaseCount = players.fold<int>(
      0,
      (sum, player) => sum + _databaseTargets(player).length,
    );
    final connectedSources = players.fold<int>(
      0,
      (sum, player) => sum + player.connectedSourceCount,
    );
    final metrics = <Widget>[
      _LibraryMetric(
        label: 'Players',
        value: _formatInt(players.length),
        icon: Icons.people_alt_outlined,
      ),
      _LibraryMetric(
        label: 'Games',
        value: _formatInt(totalGames),
        icon: Icons.table_chart_outlined,
      ),
      _LibraryMetric(
        label: 'Databases',
        value: _formatInt(databaseCount),
        icon: Icons.storage_outlined,
      ),
      _LibraryMetric(
        label: 'Sources',
        value: _formatInt(connectedSources),
        icon: Icons.link_outlined,
      ),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final search = DesktopSearchField(
              controller: controller,
              hintText: 'Search imported players',
              maxWidth: constraints.maxWidth < 920 ? double.infinity : 360,
              onChanged: onSearchChanged,
              onClear: () => onSearchChanged(''),
            );
            if (constraints.maxWidth < 920) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(spacing: 10, runSpacing: 10, children: metrics),
                  const SizedBox(height: 12),
                  search,
                ],
              );
            }
            return Row(
              children: [
                for (final metric in metrics) ...[
                  metric,
                  if (metric != metrics.last) const SizedBox(width: 10),
                ],
                const Spacer(),
                search,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LibraryMetric extends StatelessWidget {
  const _LibraryMetric({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kPrimaryColor.withValues(alpha: 0.24)),
            ),
            child: Icon(icon, size: 16, color: kPrimaryColor),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerLibraryList extends StatelessWidget {
  const _PlayerLibraryList({
    required this.players,
    required this.onOpenPlayer,
    required this.onRenamePlayer,
    required this.onRemovePlayer,
  });

  final List<PlayerWorkspacePlayer> players;
  final ValueChanged<String> onOpenPlayer;
  final ValueChanged<PlayerWorkspacePlayer> onRenamePlayer;
  final ValueChanged<PlayerWorkspacePlayer> onRemovePlayer;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        children: [
          const _PlayerLibraryHeaderRow(),
          const Divider(height: 1, color: kDividerColor),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: players.length,
              separatorBuilder:
                  (_, __) => const Divider(height: 1, color: kDividerColor),
              itemBuilder: (context, index) {
                final player = players[index];
                return _PlayerLibraryRow(
                  player: player,
                  onOpen: () => onOpenPlayer(player.id),
                  onRename: () => onRenamePlayer(player),
                  onRemove: () => onRemovePlayer(player),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Shared column geometry so the header labels and every data row stay on the
// same grid. The gaps are explicit columns (not padding on the cells) so the
// numeric "Games" value can never butt up against the "Last sync" date the way
// it did when the two fixed columns sat flush against each other.
const double _kColGap = 22;
const double _kSourcesColWidth = 176;
const double _kGamesColWidth = 92;
const double _kLastSyncColWidth = 120;
const double _kRowActionsWidth = 112;

class _PlayerLibraryHeaderRow extends StatelessWidget {
  const _PlayerLibraryHeaderRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 11, 16, 10),
      child: Row(
        children: [
          Expanded(child: _TableHeaderLabel('Player')),
          SizedBox(width: _kColGap),
          SizedBox(
            width: _kSourcesColWidth,
            child: _TableHeaderLabel('Sources'),
          ),
          SizedBox(width: _kColGap),
          SizedBox(
            width: _kGamesColWidth,
            child: _TableHeaderLabel('Games', alignRight: true),
          ),
          SizedBox(width: _kColGap),
          SizedBox(
            width: _kLastSyncColWidth,
            child: _TableHeaderLabel('Last sync'),
          ),
          SizedBox(width: _kColGap),
          SizedBox(width: _kRowActionsWidth),
        ],
      ),
    );
  }
}

class _TableHeaderLabel extends StatelessWidget {
  const _TableHeaderLabel(this.label, {this.alignRight = false});

  final String label;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      textAlign: alignRight ? TextAlign.right : TextAlign.left,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
      ),
    );
  }
}

class _PlayerLibraryRow extends StatefulWidget {
  const _PlayerLibraryRow({
    required this.player,
    required this.onOpen,
    required this.onRename,
    required this.onRemove,
  });

  final PlayerWorkspacePlayer player;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  State<_PlayerLibraryRow> createState() => _PlayerLibraryRowState();
}

class _PlayerLibraryRowState extends State<_PlayerLibraryRow>
    with DeferredPointerStateMixin<_PlayerLibraryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return MouseRegion(
      onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
      onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          color: _hovered ? kBlack3Color : kBlack2Color,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    _PlayerAvatar(player: player, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              if (player.title != null) ...[
                                DesktopPlayerTitleChip(
                                  title: player.title!,
                                  compact: true,
                                ),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Text(
                                  playerWorkspaceDisplayName(player),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kWhiteColor,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          _PlayerFacets(player: player),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              ...[
                const SizedBox(width: _kColGap),
                SizedBox(
                  width: _kSourcesColWidth,
                  child: _SourceChipRow(player: player),
                ),
                const SizedBox(width: _kColGap),
                SizedBox(
                  width: _kGamesColWidth,
                  child: _GamesCell(player: player),
                ),
                const SizedBox(width: _kColGap),
                SizedBox(
                  width: _kLastSyncColWidth,
                  child: _LastSyncCell(ms: player.lastSyncAtMs),
                ),
                const SizedBox(width: _kColGap),
                SizedBox(
                  width: _kRowActionsWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DesktopDialogIconButton(
                        icon: Icons.edit_outlined,
                        tooltip: 'Rename player',
                        onPress: widget.onRename,
                      ),
                      const SizedBox(width: 4),
                      DesktopDialogIconButton(
                        icon: Icons.delete_outline_rounded,
                        tooltip: 'Remove player',
                        tone: DesktopDialogButtonTone.danger,
                        onPress: widget.onRemove,
                      ),
                      const SizedBox(width: 6),
                      DesktopDialogIconButton(
                        icon: Icons.chevron_right_rounded,
                        tooltip: 'Open player',
                        tone: DesktopDialogButtonTone.primary,
                        onPress: widget.onOpen,
                      ),
                    ],
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

/// Second line of the player cell. Surfaces the identity/strength facts we
/// actually hold for the player — federation flag, FIDE standard rating (from
/// the linked ChessEver profile) and FIDE id — instead of a flat text line.
class _PlayerFacets extends StatelessWidget {
  const _PlayerFacets({required this.player});

  final PlayerWorkspacePlayer player;

  @override
  Widget build(BuildContext context) {
    final country = player.country?.trim();
    final rating = _playerPrimaryRating(player);
    final fideId = player.fideId?.trim();
    final hasCountry = country != null && country.isNotEmpty;
    final hasFide = fideId != null && fideId.isNotEmpty;

    if (!hasCountry && rating == null && !hasFide) {
      return const Text(
        'No FIDE profile linked',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: kLightGreyColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Row(
      children: [
        if (hasCountry) ...[
          FederationFlag(
            federation: country,
            width: 17,
            height: 12,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(width: 6),
          Text(
            country.toUpperCase(),
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (rating != null) ...[
          if (hasCountry) const _FacetDot(),
          _TempoIcon(label: rating.label, size: 13),
          const SizedBox(width: 4),
          Text(
            rating.value.toString(),
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (hasFide) ...[
          if (hasCountry || rating != null) const _FacetDot(),
          Flexible(
            child: Text(
              'FIDE $fideId',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _FacetDot extends StatelessWidget {
  const _FacetDot();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 7),
      child: Text(
        '·',
        style: TextStyle(
          color: kLightGreyColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// Right-aligned "Games" column: total game count with a small source-count
/// caption so the number has context without leaning on the neighbouring
/// column.
class _GamesCell extends StatelessWidget {
  const _GamesCell({required this.player});

  final PlayerWorkspacePlayer player;

  @override
  Widget build(BuildContext context) {
    final sources = player.connectedSourceCount;
    final caption = switch (sources) {
      <= 0 => '—',
      1 => '1 source',
      _ => '$sources sources',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _formatInt(player.totalGames),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 14,
            fontWeight: FontWeight.w900,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Left-aligned "Last sync" column: a friendly relative label on top with the
/// exact date underneath when they differ.
class _LastSyncCell extends StatelessWidget {
  const _LastSyncCell({required this.ms});

  final int? ms;

  @override
  Widget build(BuildContext context) {
    final synced = ms != null && ms! > 0;
    final relative = _formatRelativeSync(ms);
    final exact = synced ? _formatDate(ms) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          relative,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: synced ? kWhiteColor : kLightGreyColor,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (exact != null && exact != relative) ...[
          const SizedBox(height: 2),
          Text(
            exact,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

class _SourceChipRow extends StatelessWidget {
  const _SourceChipRow({required this.player});

  final PlayerWorkspacePlayer player;

  @override
  Widget build(BuildContext context) {
    final sources = player.allAccounts
      .map((account) => account.source)
      .toSet()
      .toList(growable: false)..sort((a, b) => a.index.compareTo(b.index));
    if (sources.isEmpty) {
      return const Text(
        'No accounts',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: kLightGreyColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final source in sources.take(3)) _SourceChip(source: source),
        if (sources.length > 3)
          Text(
            '+${sources.length - 3}',
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});

  final PlayerWorkspaceSource source;

  @override
  Widget build(BuildContext context) {
    final accent = _sourceAccentColor(source);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SourceBrandMark(
            source: source,
            size: 13,
            color: source == PlayerWorkspaceSource.lichess ? kWhiteColor : null,
          ),
          const SizedBox(width: 5),
          Text(
            source.label,
            style: TextStyle(
              color: _sourceLabelColor(source),
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoMatchingPlayers extends StatelessWidget {
  const _NoMatchingPlayers({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return _InlineEmpty(
      icon: Icons.search_off_rounded,
      title: 'No matching players',
      subtitle: 'Clear search to return to the full player library.',
      actionLabel: 'Clear search',
      onAction: onClear,
    );
  }
}

class _LibraryErrorBanner extends StatelessWidget {
  const _LibraryErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kRedColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kRedColor.withValues(alpha: 0.34)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: kRedColor, size: 17),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPlayerWorkspace extends StatelessWidget {
  const _EmptyPlayerWorkspace({required this.onAddPlayer});

  final VoidCallback onAddPlayer;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kPrimaryColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: kPrimaryColor.withValues(alpha: 0.32),
                    ),
                  ),
                  child: const Icon(
                    Icons.person_search_outlined,
                    color: kPrimaryColor,
                    size: 25,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'No imported players',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add players here first. Each player gets a manageable workspace for accounts, source databases, and opening trees.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                DesktopDialogButton(
                  label: 'Add player',
                  icon: Icons.person_add_alt_1_outlined,
                  tone: DesktopDialogButtonTone.primary,
                  onPress: onAddPlayer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerSourceRail extends ConsumerWidget {
  const _PlayerSourceRail({
    required this.player,
    required this.onAddAccount,
    required this.onEditAccount,
    required this.onRefreshAccount,
    required this.onRemoveAccount,
    required this.onSync,
    required this.onReinstall,
    required this.onCancelOperation,
  });

  final PlayerWorkspacePlayer player;
  final ValueChanged<PlayerWorkspaceSource> onAddAccount;
  final ValueChanged<PlayerWorkspaceAccount> onEditAccount;
  final ValueChanged<PlayerWorkspaceAccount> onRefreshAccount;
  final ValueChanged<PlayerWorkspaceAccount> onRemoveAccount;
  final ValueChanged<PlayerWorkspaceAccount> onSync;
  final ValueChanged<PlayerWorkspaceAccount> onReinstall;
  final ValueChanged<PlayerWorkspaceAccount> onCancelOperation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operations = ref.watch(
      playerWorkspaceProvider.select((state) => state.operations),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _PlayerIdentityCard(player: player),
          const SizedBox(height: 14),
          const _RailSectionLabel('Sources'),
          const SizedBox(height: 8),
          for (final source in playerWorkspaceSourceRailOrder) ...[
            if (source != PlayerWorkspaceSource.combined) ...[
              for (final account in player.accountsFor(source))
                _SourceCard(
                  source: source,
                  account: account,
                  operation: _operationForAccount(operations, account),
                  onAddAccount: () => onAddAccount(source),
                  onEditAccount: () => onEditAccount(account),
                  onRefreshAccount: () => onRefreshAccount(account),
                  onRemoveAccount: () => onRemoveAccount(account),
                  onSync: () => onSync(account),
                  onReinstall: () => onReinstall(account),
                  onCancelOperation: () => onCancelOperation(account),
                ),
              if (player.accountsFor(source).isEmpty)
                _SourceCard(
                  source: source,
                  account: null,
                  operation: _operationForSource(operations, source),
                  onAddAccount: () => onAddAccount(source),
                  onEditAccount: null,
                  onRefreshAccount: null,
                  onRemoveAccount: null,
                  onSync: null,
                  onReinstall: null,
                  onCancelOperation: null,
                )
              else if (source.allowsMultipleAccounts)
                _AddSourceAccountButton(
                  source: source,
                  onPress: () => onAddAccount(source),
                ),
            ],
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _PlayerIdentityCard extends StatelessWidget {
  const _PlayerIdentityCard({required this.player});

  final PlayerWorkspacePlayer player;

  @override
  Widget build(BuildContext context) {
    final title = player.title?.trim();
    final country = player.country?.trim();
    final hasTitle = title != null && title.isNotEmpty;
    final hasCountry = country != null && country.isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kWhiteColor.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _PlayerAvatar(player: player, size: 58),
                const SizedBox(width: 12),
                Expanded(
                  // Flag, then title chip, then name — all on one line.
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (hasCountry) ...[
                        FederationFlag(
                          federation: country,
                          width: 18,
                          height: 13,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (hasTitle) ...[
                        DesktopPlayerTitleChip(title: title),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          playerWorkspaceDisplayName(player),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _MiniMetric(
                    label: 'Games',
                    value: _formatInt(player.totalGames),
                  ),
                ),
                Expanded(
                  child: _MiniMetric(
                    label: 'Sources',
                    value: player.connectedSourceCount.toString(),
                  ),
                ),
                Expanded(
                  child: _MiniMetric(
                    label: 'Win',
                    value: _formatPercent(player.winRate),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Player avatar that prefers the official FIDE photo (resolved by fideId via
/// [playerPhotoProvider] — always available once the ChessEver source is linked),
/// then a linked source avatar (Lichess/Chess.com), then stylized initials.
///
/// Routes the resolved URL through [PlayerInitialsAvatarCompact] so it inherits
/// its cached loading, placeholder-image rejection, and initials fallback.
class _FidePhotoAvatar extends ConsumerWidget {
  const _FidePhotoAvatar({
    required this.fideId,
    required this.initials,
    required this.size,
    this.fallbackAvatarUrl,
    this.borderRadius,
  });

  final int? fideId;
  final String initials;
  final double size;
  final String? fallbackAvatarUrl;
  final double? borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fidePhoto =
        fideId == null
            ? null
            : ref.watch(playerPhotoProvider(fideId)).valueOrNull?.trim();
    final photoUrl =
        (fidePhoto != null && fidePhoto.isNotEmpty)
            ? fidePhoto
            : fallbackAvatarUrl;
    return PlayerInitialsAvatarCompact(
      photoUrl: photoUrl,
      initials: initials,
      size: size,
      borderRadius: borderRadius ?? 8,
    );
  }
}

class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar({required this.player, required this.size});

  final PlayerWorkspacePlayer player;
  final double size;

  @override
  Widget build(BuildContext context) {
    return _FidePhotoAvatar(
      fideId: int.tryParse(player.fideId?.trim() ?? ''),
      initials: _initials(player.displayName),
      size: size,
      fallbackAvatarUrl: player.bestAvatarUrl,
      borderRadius: size / 2, // circular, matching the previous ClipOval
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _RailSectionLabel extends StatelessWidget {
  const _RailSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.account,
    required this.operation,
    required this.onAddAccount,
    required this.onEditAccount,
    required this.onRefreshAccount,
    required this.onRemoveAccount,
    required this.onSync,
    required this.onReinstall,
    required this.onCancelOperation,
  });

  final PlayerWorkspaceSource source;
  final PlayerWorkspaceAccount? account;
  final PlayerWorkspaceOperation? operation;
  final VoidCallback onAddAccount;
  final VoidCallback? onEditAccount;
  final VoidCallback? onRefreshAccount;
  final VoidCallback? onRemoveAccount;
  final VoidCallback? onSync;
  final VoidCallback? onReinstall;
  final VoidCallback? onCancelOperation;

  @override
  Widget build(BuildContext context) {
    final currentAccount = account;
    final connected = currentAccount?.isConnected == true;
    final working = operation != null;
    final hasGames = currentAccount?.hasDownloadedGames == true;
    final isManual = source == PlayerWorkspaceSource.manual;
    final canEditUsername =
        source == PlayerWorkspaceSource.lichess ||
        source == PlayerWorkspaceSource.chesscom;
    final gameLine =
        currentAccount == null ? null : _sourceGameCountLine(currentAccount);
    final showIdleDownloadProgress =
        currentAccount != null &&
        playerWorkspaceShowsIdleDownloadProgress(currentAccount);
    final error = currentAccount?.error;
    final operationMessage = operation?.message.toLowerCase() ?? '';
    final showInitialLichessDownloadNotice =
        source == PlayerWorkspaceSource.lichess &&
        connected &&
        !hasGames &&
        operation != null &&
        !operationMessage.startsWith('importing') &&
        !operationMessage.contains('already current');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBackgroundColor.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              connected ? kPrimaryColor.withValues(alpha: 0.24) : kDividerColor,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _SourceIcon(source: source),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    source.label,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (connected) ...[
                  if (canEditUsername) ...[
                    DesktopDialogIconButton(
                      icon: Icons.edit_outlined,
                      tooltip: 'Edit username',
                      onPress: working ? null : onEditAccount,
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (!isManual) ...[
                    DesktopDialogIconButton(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Refresh stats',
                      onPress: working ? null : onRefreshAccount,
                    ),
                    const SizedBox(width: 4),
                  ],
                  DesktopDialogIconButton(
                    icon: Icons.link_off_rounded,
                    tooltip: isManual ? 'Remove PGN' : 'Remove account',
                    tone: DesktopDialogButtonTone.danger,
                    onPress: working ? null : onRemoveAccount,
                  ),
                ] else
                  _StatusDot(active: connected, working: working),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              connected
                  ? (currentAccount?.displayName ??
                      currentAccount?.username ??
                      '')
                  : 'Not connected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: connected ? kWhiteColor70 : kLightGreyColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (connected && gameLine != null) ...[
              const SizedBox(height: 8),
              Text(
                gameLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kLightGreyColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!working && showIdleDownloadProgress) ...[
                const SizedBox(height: 7),
                _DownloadProgress(account: currentAccount),
              ],
            ],
            if (operation != null) ...[
              const SizedBox(height: 10),
              _OperationProgress(operation: operation!),
              if (showInitialLichessDownloadNotice) ...[
                const SizedBox(height: 7),
                Text(
                  playerWorkspaceLichessDownloadNotice(
                    currentAccount!,
                    operation!,
                  ),
                  style: const TextStyle(
                    color: kLightGreyColor,
                    fontSize: 10.5,
                    height: 1.3,
                  ),
                ),
              ],
              if (onCancelOperation != null) ...[
                const SizedBox(height: 8),
                DesktopDialogButton(
                  label: 'Stop',
                  icon: Icons.stop_rounded,
                  tone: DesktopDialogButtonTone.danger,
                  fillWidth: true,
                  onPress: onCancelOperation,
                ),
              ],
            ],
            if (!working && error != null) ...[
              const SizedBox(height: 8),
              Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kRedColor,
                  fontSize: 11,
                  height: 1.25,
                ),
              ),
            ],
            const SizedBox(height: 10),
            DesktopDialogButton(
              label:
                  !connected
                      ? isManual
                          ? 'Import PGN'
                          : 'Add account'
                      : hasGames
                      ? isManual
                          ? 'Import more PGN'
                          : 'Sync new games'
                      : isManual
                      ? 'Import PGN'
                      : 'Download games',
              icon:
                  !connected
                      ? isManual
                          ? Icons.note_add_outlined
                          : Icons.add_link_outlined
                      : hasGames
                      ? isManual
                          ? Icons.note_add_outlined
                          : Icons.sync_rounded
                      : isManual
                      ? Icons.note_add_outlined
                      : Icons.download_outlined,
              tone:
                  connected
                      ? DesktopDialogButtonTone.primary
                      : DesktopDialogButtonTone.secondary,
              fillWidth: true,
              onPress:
                  working
                      ? null
                      : isManual
                      ? onAddAccount
                      : (connected ? onSync : onAddAccount),
            ),
            if (connected && hasGames && !isManual) ...[
              const SizedBox(height: 8),
              DesktopDialogButton(
                label: 'Reinstall source',
                icon: Icons.restart_alt_rounded,
                fillWidth: true,
                onPress: working ? null : onReinstall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddSourceAccountButton extends StatelessWidget {
  const _AddSourceAccountButton({required this.source, required this.onPress});

  final PlayerWorkspaceSource source;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final manual = source == PlayerWorkspaceSource.manual;
    return DesktopDialogButton(
      label: manual ? 'Import another PGN' : 'Add another username',
      icon: manual ? Icons.note_add_outlined : Icons.add_link_outlined,
      fillWidth: true,
      onPress: onPress,
    );
  }
}

class _OperationProgress extends StatelessWidget {
  const _OperationProgress({required this.operation});

  final PlayerWorkspaceOperation operation;

  @override
  Widget build(BuildContext context) {
    final status = playerWorkspaceOperationStatus(operation);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              operation.source.label,
              style: TextStyle(
                color: _sourceLabelColor(operation.source),
                fontSize: 10,
                fontWeight: FontWeight.w900,
              ),
            ),
            const Spacer(),
            Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
                height: 1.25,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        DesktopTooltip(
          message: operation.message,
          child: SizedBox(
            height: 30,
            child: Align(
              alignment: Alignment.topLeft,
              child: Text(
                operation.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: operation.progress,
            minHeight: 4,
            valueColor: const AlwaysStoppedAnimation(kPrimaryColor),
            backgroundColor: kDividerColor,
          ),
        ),
      ],
    );
  }
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.account});

  final PlayerWorkspaceAccount account;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: account.downloadProgress,
        minHeight: 3,
        valueColor: const AlwaysStoppedAnimation(kPrimaryColor),
        backgroundColor: kDividerColor,
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active, required this.working});

  final bool active;
  final bool working;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color:
            working
                ? kPrimaryColor
                : active
                ? kGreenColor
                : kDividerColor,
      ),
    );
  }
}

class _SourceIcon extends StatelessWidget {
  const _SourceIcon({required this.source});

  final PlayerWorkspaceSource source;

  @override
  Widget build(BuildContext context) {
    // Chessever gets its own self-contained dark app-logo tile (blue mark on
    // black), not the shared white pill lichess/chess.com marks need.
    if (source == PlayerWorkspaceSource.chessever) {
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kWhiteColor.withValues(alpha: 0.12)),
        ),
        child: const _SourceBrandMark(
          source: PlayerWorkspaceSource.chessever,
          size: 28,
        ),
      );
    }
    final branded =
        source == PlayerWorkspaceSource.lichess ||
        source == PlayerWorkspaceSource.chesscom;
    final icon = switch (source) {
      PlayerWorkspaceSource.chessever => Icons.diamond_outlined,
      PlayerWorkspaceSource.lichess => Icons.flash_on_outlined,
      PlayerWorkspaceSource.chesscom => Icons.public_outlined,
      PlayerWorkspaceSource.manual => Icons.note_add_outlined,
      PlayerWorkspaceSource.combined => Icons.hub_outlined,
    };
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            branded
                ? kWhiteColor.withValues(alpha: 0.94)
                : kPrimaryColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              branded
                  ? kWhiteColor.withValues(alpha: 0.35)
                  : kPrimaryColor.withValues(alpha: 0.24),
        ),
      ),
      child:
          branded
              ? _SourceBrandMark(source: source, size: 18)
              : Icon(icon, size: 16, color: kPrimaryColor),
    );
  }
}

class _SourceBrandMark extends StatelessWidget {
  const _SourceBrandMark({
    required this.source,
    required this.size,
    this.color,
  });

  final PlayerWorkspaceSource source;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: switch (source) {
        PlayerWorkspaceSource.lichess => SvgPicture.asset(
          'assets/svgs/lichess_logo.svg',
          width: size,
          height: size,
          colorFilter:
              color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn),
        ),
        PlayerWorkspaceSource.chesscom => Image.asset(
          'assets/pngs/chesscom_pawn.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
        PlayerWorkspaceSource.chessever => ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.28),
          child: Image.asset(
            'assets/pngs/new_app_logo.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
          ),
        ),
        PlayerWorkspaceSource.manual || PlayerWorkspaceSource.combined => Icon(
          _sourceFallbackIcon(source),
          size: size,
          color: _sourceAccentColor(source),
        ),
      },
    );
  }
}

IconData _sourceFallbackIcon(PlayerWorkspaceSource source) {
  return switch (source) {
    PlayerWorkspaceSource.chessever => Icons.diamond_outlined,
    PlayerWorkspaceSource.lichess => Icons.flash_on_outlined,
    PlayerWorkspaceSource.chesscom => Icons.public_outlined,
    PlayerWorkspaceSource.manual => Icons.note_add_outlined,
    PlayerWorkspaceSource.combined => Icons.hub_outlined,
  };
}

Color _sourceAccentColor(PlayerWorkspaceSource source) {
  return switch (source) {
    PlayerWorkspaceSource.lichess => kWhiteColor,
    PlayerWorkspaceSource.chesscom => const Color(0xFF81B64C),
    PlayerWorkspaceSource.chessever ||
    PlayerWorkspaceSource.manual ||
    PlayerWorkspaceSource.combined => kPrimaryColor,
  };
}

Color _sourceLabelColor(PlayerWorkspaceSource source) {
  return switch (source) {
    PlayerWorkspaceSource.lichess => kWhiteColor,
    PlayerWorkspaceSource.chesscom => const Color(0xFFD6F3B0),
    PlayerWorkspaceSource.chessever ||
    PlayerWorkspaceSource.manual ||
    PlayerWorkspaceSource.combined => kLightYellowColor,
  };
}

class _PlayerWorkspaceMain extends StatelessWidget {
  const _PlayerWorkspaceMain({
    required this.selectedTab,
    required this.onTabChanged,
    required this.player,
    required this.onGoToAccounts,
    required this.gamesFilter,
    required this.gamesSourcePath,
    required this.gamesFilterNonce,
    required this.onOverviewFilter,
    required this.onGamesFilterChanged,
  });

  final _PlayerWorkspaceTab selectedTab;
  final ValueChanged<_PlayerWorkspaceTab> onTabChanged;
  final PlayerWorkspacePlayer player;
  final VoidCallback onGoToAccounts;
  final LocalChessGameFilter gamesFilter;
  final String? gamesSourcePath;
  final int gamesFilterNonce;
  final ValueChanged<PlayerOverviewFilterRequest> onOverviewFilter;
  final ValueChanged<LocalChessGameFilter> onGamesFilterChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: DesktopSegmentedTabs<_PlayerWorkspaceTab>(
                    expand: true,
                    selected: selectedTab,
                    onChanged: onTabChanged,
                    tabs: const [
                      DesktopSegmentedTab(
                        value: _PlayerWorkspaceTab.overview,
                        label: 'Overview',
                        icon: Icons.dashboard_outlined,
                      ),
                      DesktopSegmentedTab(
                        value: _PlayerWorkspaceTab.accounts,
                        label: 'Accounts',
                        icon: Icons.link_outlined,
                      ),
                      DesktopSegmentedTab(
                        value: _PlayerWorkspaceTab.games,
                        label: 'Games',
                        icon: Icons.table_chart_outlined,
                      ),
                      DesktopSegmentedTab(
                        value: _PlayerWorkspaceTab.buildTree,
                        label: 'Build Tree',
                        icon: Icons.account_tree_outlined,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: kDividerColor),
          Expanded(
            child: switch (selectedTab) {
              _PlayerWorkspaceTab.overview => _OverviewTab(
                player: player,
                onGoToAccounts: onGoToAccounts,
                onOverviewFilter: onOverviewFilter,
              ),
              _PlayerWorkspaceTab.accounts => _AccountsTab(player: player),
              _PlayerWorkspaceTab.games => _GamesTab(
                player: player,
                gamesFilter: gamesFilter,
                preferredSourcePath: gamesSourcePath,
                filterNonce: gamesFilterNonce,
                onFilterChanged: onGamesFilterChanged,
              ),
              _PlayerWorkspaceTab.buildTree => _BuildTreeTab(
                player: player,
                onGoToAccounts: onGoToAccounts,
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// Landing tab: the rich, locally-computed statistics dashboard. Pulls metrics
/// from the selected source database via fast GROUP BY aggregates and renders
/// them in the Play-profile visual language.
class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.player,
    required this.onGoToAccounts,
    required this.onOverviewFilter,
  });

  final PlayerWorkspacePlayer player;
  final VoidCallback onGoToAccounts;
  final ValueChanged<PlayerOverviewFilterRequest> onOverviewFilter;

  @override
  Widget build(BuildContext context) {
    final sources = playerOverviewStatsSources(player);
    if (sources.isEmpty) {
      return _InlineEmpty(
        icon: Icons.query_stats_outlined,
        title: 'No games to analyze yet',
        subtitle:
            'Download this player\'s games from a connected source to see the '
            'full statistics dashboard — computed locally.',
        actionLabel: 'Go to Accounts',
        onAction: onGoToAccounts,
      );
    }
    return PlayerStatsDashboard(
      sources: sources,
      aliases: _statsAliases(player),
      playerFideId: player.fideId,
      revision: player.lastSyncAtMs ?? player.totalGames,
      onDownloadGames: onGoToAccounts,
      onOverviewFilter: onOverviewFilter,
    );
  }
}

@visibleForTesting
List<PlayerStatsSource> playerOverviewStatsSources(
  PlayerWorkspacePlayer player,
) {
  return _statsSources(player)
      .where((source) => source.kind != PlayerWorkspaceSource.combined)
      .toList(growable: false);
}

/// Selectable local databases. Labels disambiguate same-source accounts (e.g.
/// two Lichess usernames) by title. Combined remains available to Games and
/// Build Tree, but the Overview intentionally uses only real source databases.
List<PlayerStatsSource> _statsSources(PlayerWorkspacePlayer player) {
  final targets = _databaseTargets(player);
  final sourceCounts = <PlayerWorkspaceSource, int>{};
  for (final target in targets) {
    sourceCounts[target.source] = (sourceCounts[target.source] ?? 0) + 1;
  }
  return <PlayerStatsSource>[
    for (final target in targets)
      PlayerStatsSource(
        label:
            target.source == PlayerWorkspaceSource.combined
                ? 'Combined'
                : (sourceCounts[target.source] ?? 0) > 1
                ? target.title
                : target.source.label,
        accent: _sourceAccentColor(target.source),
        path: target.path,
        gameCount: target.gameCount,
        kind: target.source,
        // Online sources default overview/rating to blitz; Combined /
        // ChessEver / manual default to classical.
        preferredTimeControl:
            target.source == PlayerWorkspaceSource.lichess ||
                    target.source == PlayerWorkspaceSource.chesscom
                ? 'blitz'
                : 'classical',
        unclassifiedTimeControlCategory:
            target.source == PlayerWorkspaceSource.chessever
                ? 'classical'
                : null,
      ),
  ];
}

class _AccountsTab extends ConsumerWidget {
  const _AccountsTab({required this.player});

  final PlayerWorkspacePlayer player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operations = ref.watch(
      playerWorkspaceProvider.select((state) => state.operations),
    );
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: _SectionTitle(
                icon: Icons.link_outlined,
                title: 'Connected accounts',
                subtitle:
                    'Fetch profile and stats first, then download games explicitly.',
              ),
            ),
            const SizedBox(width: 12),
            DesktopDialogButton(
              label: 'Add account',
              icon: Icons.add_link_outlined,
              tone: DesktopDialogButtonTone.primary,
              onPress:
                  () => unawaited(_showAddAccountChoiceDialog(context, ref)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final source in const [
          PlayerWorkspaceSource.chessever,
          PlayerWorkspaceSource.lichess,
          PlayerWorkspaceSource.chesscom,
          PlayerWorkspaceSource.manual,
        ]) ...[
          for (final account in player.accountsFor(source))
            _AccountDetailCard(
              source: source,
              account: account,
              operation: _operationForAccount(operations, account),
              onAddAccount:
                  () =>
                      unawaited(_showAccountConnectFlow(context, ref, source)),
              onEditAccount:
                  () =>
                      unawaited(_showEditAccountDialog(context, ref, account)),
              onRefreshAccount:
                  () =>
                      unawaited(_runRefreshAccountEntry(context, ref, account)),
              onRemoveAccount:
                  () => unawaited(
                    _confirmRemoveAccountEntry(context, ref, account),
                  ),
              onSyncAccount:
                  () => unawaited(_runAccountSync(context, ref, account)),
              onReinstallAccount:
                  () => unawaited(
                    _confirmReinstallAccount(context, ref, account),
                  ),
              onCancelOperation:
                  () => unawaited(
                    _runCancelAccountOperation(context, ref, account),
                  ),
            ),
          if (player.accountsFor(source).isEmpty)
            _AccountDetailCard(
              source: source,
              account: null,
              operation: _operationForSource(operations, source),
              onAddAccount:
                  () =>
                      unawaited(_showAccountConnectFlow(context, ref, source)),
              onEditAccount: null,
              onRefreshAccount: null,
              onRemoveAccount: null,
              onSyncAccount: null,
              onReinstallAccount: null,
              onCancelOperation: null,
            )
          else if (source.allowsMultipleAccounts)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _AddSourceAccountButton(
                source: source,
                onPress:
                    () => unawaited(
                      _showAccountConnectFlow(context, ref, source),
                    ),
              ),
            ),
        ],
      ],
    );
  }
}

/// Games tab: an inline, keyboard-navigable table of the selected source's
/// games. Reuses the Library's local-database view (search, sort, pagination,
/// filters, arrow-key selection, on-demand title/flag enrichment) scoped to
/// one source or the merged combined set.
class _GamesTab extends HookConsumerWidget {
  const _GamesTab({
    required this.player,
    required this.gamesFilter,
    required this.preferredSourcePath,
    required this.filterNonce,
    required this.onFilterChanged,
  });

  final PlayerWorkspacePlayer player;
  final LocalChessGameFilter gamesFilter;
  final String? preferredSourcePath;
  final int filterNonce;
  final ValueChanged<LocalChessGameFilter> onFilterChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = _statsSources(player);
    if (sources.isEmpty) {
      return const _InlineEmpty(
        icon: Icons.table_chart_outlined,
        title: 'No games to browse yet',
        subtitle:
            'Connect an account and download games, or build the combined '
            'database, to browse every merged game here — indexed and searchable.',
      );
    }
    final selected = useState(0);
    // Prefer the Overview source when a facet tap hands off a path.
    useEffect(() {
      final path = preferredSourcePath;
      if (path == null || path.isEmpty) return null;
      final i = sources.indexWhere((s) => s.path == path);
      if (i >= 0) selected.value = i;
      return null;
    }, [preferredSourcePath, filterNonce, sources.length]);
    final index = selected.value.clamp(0, sources.length - 1);
    final source = sources[index];
    final saveController = useMemoized(LocalChessFilesViewController.new, [
      source.path,
    ]);
    useEffect(() => saveController.dispose, [saveController]);
    final aliases = _statsAliases(player);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < sources.length; i++)
                      PlayerSourceChip(
                        source: sources[i],
                        selected: i == index,
                        onTap: () => selected.value = i,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              DesktopToolbarPillButton(
                label: 'Open',
                icon: Icons.open_in_new_rounded,
                onPress:
                    () => openDatabaseWorkspaceTab(
                      ref,
                      DatabaseWorkspaceArgs.local(
                        localPath: source.path,
                        title: source.label,
                      ),
                    ),
              ),
              const SizedBox(width: 8),
              DesktopToolbarPillButton(
                label: 'Save to cloud',
                icon: Icons.library_add_outlined,
                tone: DesktopToolbarPillTone.primary,
                onPress:
                    source.gameCount <= 0
                        ? null
                        : saveController.saveVisibleGamesToCloud,
              ),
            ],
          ),
        ),
        Expanded(
          child: _EmbeddedLocalGames(
            key: ValueKey<String>('${source.path}#$filterNonce'),
            path: source.path,
            revision: source.gameCount,
            initialFilter: gamesFilter,
            onFilterChanged: onFilterChanged,
            playerFideId: player.fideId,
            playerAliases: aliases,
            controller: saveController,
          ),
        ),
      ],
    );
  }
}

/// Loads a header-only PGN catalog and renders one local database's games via
/// the shared [LocalChessFilesView]. No SQLite import is needed just to browse.
class _EmbeddedLocalGames extends ConsumerWidget {
  const _EmbeddedLocalGames({
    super.key,
    required this.path,
    required this.controller,
    this.revision = 0,
    this.initialFilter,
    this.onFilterChanged,
    this.playerFideId,
    this.playerAliases = const <String>[],
  });

  final String path;
  final LocalChessFilesViewController controller;
  final int revision;
  final LocalChessGameFilter? initialFilter;
  final ValueChanged<LocalChessGameFilter>? onFilterChanged;
  final String? playerFideId;
  final List<String> playerAliases;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = LocalDatabaseWorkspaceKey(path, revision: revision);
    final treeIndex =
        ref.watch(_cachedPlayerWorkspaceTreeIndexProvider(path)).valueOrNull;
    final async = ref.watch(_playerWorkspaceGamesSourceProvider(key));
    return async.when(
      loading:
          () => const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: kPrimaryColor,
              ),
            ),
          ),
      error:
          (error, _) => _InlineEmpty(
            icon: Icons.error_outline_rounded,
            title: 'Could not open games',
            subtitle: '$error',
          ),
      data:
          (source) => LocalChessFilesView(
            key: ValueKey<Object?>(initialFilter),
            selectedPath: path,
            onSelectPath: (_) {},
            stateOverride: LocalChessLibraryState(
              source: source,
              selectedPath: path,
            ),
            onRefreshOverride: () async {
              PlayerPgnCatalog.instance.invalidate(path);
              ref.invalidate(_playerWorkspaceGamesSourceProvider(key));
              await ref.read(_playerWorkspaceGamesSourceProvider(key).future);
            },
            initialFilter: initialFilter,
            onFilterChanged: onFilterChanged,
            playerFideId: playerFideId,
            playerAliases: playerAliases,
            openingTreeIndexOverride: treeIndex,
            controller: controller,
            // The Players Games tab already owns the source identity and
            // actions, so the local database filename strip is redundant.
            showCountMeta: false,
            showDatabaseHeader: false,
            compactTablePadding: true,
            showLatestGamesFirst: true,
          ),
    );
  }
}

/// Names that identify the player in PGN White/Black tags. Mirrors
/// `_aliasesFor` in player_workspace.dart so the stats agree with import stats.
List<String> _statsAliases(PlayerWorkspacePlayer player) {
  final aliases = <String>{
    player.displayName,
    if (player.title != null) '${player.title} ${player.displayName}',
    for (final account in player.allAccounts) ...[
      account.username,
      if (account.displayName != null) account.displayName!,
    ],
  };
  return aliases
      .where((alias) => alias.trim().isNotEmpty)
      .toList(growable: false);
}

class _BuildTreeTab extends HookConsumerWidget {
  const _BuildTreeTab({required this.player, required this.onGoToAccounts});

  final PlayerWorkspacePlayer player;
  final VoidCallback onGoToAccounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(_playerTreeBuildProvider);
    final workspaceState = ref.watch(playerWorkspaceProvider);
    final choices = _treeChoices(player);
    final side = useState(PlayerBuildTreePreparationSide.both);
    final combinedBuildQueued = useState(false);
    final combinedBuildCancellation = useRef<OperationCancellationToken?>(null);
    final combinedChoice = choices.first;
    final combinedOperation = _operationForSource(
      workspaceState.operations,
      PlayerWorkspaceSource.combined,
    );
    final sourcePreparationOperation = _firstSourcePreparationOperation(
      workspaceState.operations,
    );
    final preparationOperation =
        combinedOperation ?? sourcePreparationOperation;
    final hasSourceGames = _hasDownloadedSourceGames(player);
    final canPrepareCombined =
        combinedChoice.target == null &&
        (hasSourceGames || preparationOperation != null);
    final hasAnyGames =
        choices.any((choice) => choice.target != null) || canPrepareCombined;

    void queueCombinedTreeBuild() {
      if (combinedBuildQueued.value) return;
      final cancellationToken = OperationCancellationToken();
      combinedBuildCancellation.value = cancellationToken;
      combinedBuildQueued.value = true;
      unawaited(
        _prepareAndBuildCombinedTree(
          context,
          ref,
          player,
          preparationSide: side.value,
          cancellationToken: cancellationToken,
          onPreparationFinished: () {
            if (context.mounted &&
                identical(combinedBuildCancellation.value, cancellationToken)) {
              combinedBuildCancellation.value = null;
              combinedBuildQueued.value = false;
            }
          },
        ),
      );
    }

    void stopCombinedTreeBuild() {
      combinedBuildCancellation.value?.cancel();
      combinedBuildCancellation.value = null;
      combinedBuildQueued.value = false;
      ref
          .read(playerWorkspaceProvider.notifier)
          .cancelCombinedDatabasePreparation(player.id);
    }

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: _SectionTitle(
                icon: Icons.account_tree_outlined,
                title: 'Opening trees',
                subtitle:
                    'Build per-source trees or the combined opponent tree. Set '
                    'which colour to prep against — it applies as you open a tree.',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _PrepSideControl(
          side: side.value,
          onChanged: (value) => side.value = value,
        ),
        const SizedBox(height: 12),
        if (!hasAnyGames) ...[
          _InlineEmpty(
            icon: Icons.account_tree_outlined,
            title: 'No games available for tree yet',
            subtitle: 'Connect an account and download games first.',
            actionLabel: 'Go to Accounts',
            onAction: onGoToAccounts,
          ),
          const SizedBox(height: 12),
        ],
        for (final choice in choices) ...[
          if (choice.source == PlayerWorkspaceSource.combined &&
              (combinedBuildQueued.value ||
                  (choice.target == null && canPrepareCombined)))
            _PreparingCombinedTreeTargetCard(
              choice: choice,
              operation: preparationOperation,
              queued: combinedBuildQueued.value,
              onBuild: queueCombinedTreeBuild,
              onStop: stopCombinedTreeBuild,
            )
          else if (choice.target case final target?)
            _TreeTargetCard(
              target: target,
              preparationSide: side.value,
              player: player,
            )
          else
            _DisabledTreeTargetCard(choice: choice),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// The "gear" for opening-tree scope: choose which colour to prepare against.
/// Local trees carry per-colour buckets, so this applies as a live filter when
/// a tree opens — no rebuild needed.
class _PrepSideControl extends StatelessWidget {
  const _PrepSideControl({required this.side, required this.onChanged});

  final PlayerBuildTreePreparationSide side;
  final ValueChanged<PlayerBuildTreePreparationSide> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            const Icon(Icons.tune_rounded, size: 15, color: kPrimaryColor),
            const SizedBox(width: 8),
            const Text(
              'PREP',
              style: TextStyle(
                color: kSecondaryTextColor,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final option in PlayerBuildTreePreparationSide.values)
                    _PrepSidePill(
                      label: _prepSideLabel(option),
                      selected: option == side,
                      onTap: () => onChanged(option),
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

String _prepSideLabel(PlayerBuildTreePreparationSide side) {
  return switch (side) {
    PlayerBuildTreePreparationSide.white => 'vs White',
    PlayerBuildTreePreparationSide.black => 'vs Black',
    PlayerBuildTreePreparationSide.both => 'Both colours',
  };
}

class _PrepSidePill extends StatelessWidget {
  const _PrepSidePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color:
                selected ? kPrimaryColor.withValues(alpha: 0.15) : kBlack2Color,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.55)
                      : kDividerColor,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? kPrimaryColor : kWhiteColor70,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: kPrimaryColor),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AccountDetailCard extends StatelessWidget {
  const _AccountDetailCard({
    required this.source,
    required this.account,
    required this.operation,
    required this.onAddAccount,
    required this.onEditAccount,
    required this.onRefreshAccount,
    required this.onRemoveAccount,
    required this.onSyncAccount,
    required this.onReinstallAccount,
    required this.onCancelOperation,
  });

  final PlayerWorkspaceSource source;
  final PlayerWorkspaceAccount? account;
  final PlayerWorkspaceOperation? operation;
  final VoidCallback onAddAccount;
  final VoidCallback? onEditAccount;
  final VoidCallback? onRefreshAccount;
  final VoidCallback? onRemoveAccount;
  final VoidCallback? onSyncAccount;
  final VoidCallback? onReinstallAccount;
  final VoidCallback? onCancelOperation;

  @override
  Widget build(BuildContext context) {
    final currentAccount = account;
    final ratings =
        currentAccount?.ratings.entries.toList(growable: false) ?? const [];
    final connected = currentAccount?.isConnected == true;
    final working = operation != null;
    final isManual = source == PlayerWorkspaceSource.manual;
    final canEditUsername =
        source == PlayerWorkspaceSource.lichess ||
        source == PlayerWorkspaceSource.chesscom;
    final hasDownloadedGames = currentAccount?.hasDownloadedGames == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBackgroundColor.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SourceIcon(source: source),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.label,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      currentAccount == null
                          ? 'Not connected'
                          : currentAccount.displayName ??
                              currentAccount.username,
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                currentAccount == null
                    ? '0 games'
                    : playerWorkspaceAccountGamesLabel(currentAccount),
                style: const TextStyle(
                  color: kLightGreyColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              if (connected) ...[
                if (canEditUsername) ...[
                  DesktopDialogIconButton(
                    icon: Icons.edit_outlined,
                    tooltip: 'Edit username',
                    onPress: working ? null : onEditAccount,
                  ),
                  const SizedBox(width: 4),
                ],
                if (!isManual) ...[
                  DesktopDialogIconButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Refresh stats',
                    onPress: working ? null : onRefreshAccount,
                  ),
                  const SizedBox(width: 4),
                ],
                DesktopDialogIconButton(
                  icon: Icons.link_off_rounded,
                  tooltip: isManual ? 'Remove PGN' : 'Remove account',
                  tone: DesktopDialogButtonTone.danger,
                  onPress: working ? null : onRemoveAccount,
                ),
              ] else
                DesktopDialogButton(
                  label: 'Add account',
                  icon: Icons.add_link_outlined,
                  onPress: onAddAccount,
                ),
            ],
          ),
          if (operation != null) ...[
            const SizedBox(height: 12),
            _OperationProgress(operation: operation!),
            if (onCancelOperation != null) ...[
              const SizedBox(height: 8),
              DesktopDialogButton(
                label: 'Stop',
                icon: Icons.stop_rounded,
                tone: DesktopDialogButtonTone.danger,
                onPress: onCancelOperation,
              ),
            ],
          ],
          if (ratings.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final rating in ratings.take(8))
                  _RatingPill(label: rating.key, value: rating.value),
              ],
            ),
          ],
          if (connected && !isManual) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                DesktopDialogButton(
                  label:
                      hasDownloadedGames ? 'Sync new games' : 'Download games',
                  icon:
                      hasDownloadedGames
                          ? Icons.sync_rounded
                          : Icons.download_outlined,
                  tone: DesktopDialogButtonTone.primary,
                  onPress: working ? null : onSyncAccount,
                ),
                if (hasDownloadedGames)
                  DesktopDialogButton(
                    label: 'Reinstall source',
                    icon: Icons.restart_alt_rounded,
                    onPress: working ? null : onReinstallAccount,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RatingPill extends StatelessWidget {
  const _RatingPill({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TempoIcon(label: label, size: 15),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value.toString(),
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _TreeTargetCard extends HookConsumerWidget {
  const _TreeTargetCard({
    required this.target,
    required this.preparationSide,
    required this.player,
  });

  final _DatabaseTarget target;
  final PlayerBuildTreePreparationSide preparationSide;
  final PlayerWorkspacePlayer player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final startingBuild = useState(false);
    final startCancellation = useRef<OperationCancellationToken?>(null);
    final buildState = ref.watch(_playerTreeBuildProvider);
    final progress = buildState.progressFor(target.path);
    final builtIndex = buildState.indexFor(target.path);
    final localState = ref.watch(localChessLibraryProvider);
    final node = localState.source?.nodeForPath(target.path);
    final liveIndex =
        node is LocalChessFileNode && node.openingTreeIndex?.isUsable == true
            ? node.openingTreeIndex
            : null;
    final cachedIndexState = ref.watch(
      _cachedPlayerWorkspaceTreeIndexProvider(target.path),
    );
    final cachedIndex = cachedIndexState.valueOrNull;
    final openingTreeIndex = liveIndex ?? builtIndex ?? cachedIndex;

    void startBuild() {
      if (startingBuild.value || progress?.isActive == true) return;
      final cancellationToken = OperationCancellationToken();
      startCancellation.value = cancellationToken;
      startingBuild.value = true;
      unawaited(() async {
        try {
          await _openOrBuildLocalTreeTarget(
            context,
            ref,
            target,
            player,
            preparationSide: preparationSide,
            cancellationToken: cancellationToken,
          );
        } catch (error) {
          if (!context.mounted ||
              cancellationToken.isCanceled ||
              isOperationCanceled(error)) {
            return;
          }
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.toString())));
        } finally {
          if (context.mounted &&
              identical(startCancellation.value, cancellationToken)) {
            startCancellation.value = null;
            startingBuild.value = false;
          }
        }
      }());
    }

    void stopBuild() {
      startCancellation.value?.cancel();
      startCancellation.value = null;
      startingBuild.value = false;
      ref.read(_playerTreeBuildProvider.notifier).cancel(target.path);
      ref
          .read(localChessLibraryProvider.notifier)
          .cancelOpeningTreeBuild(target.path);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBackgroundColor.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _SourceIcon(source: target.source),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_formatInt(target.gameCount)} games · ${_prepSideLabel(preparationSide)}',
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            LocalTreeActionButton(
              progress: progress,
              preparingBuild: startingBuild.value && progress?.isActive != true,
              checkingCache: liveIndex == null && cachedIndexState.isLoading,
              onOpen:
                  openingTreeIndex != null
                      ? () => _openLocalTree(
                        ref,
                        target,
                        openingTreeIndex,
                        preparationSide: preparationSide,
                        player: player,
                      )
                      : null,
              onBuild: startBuild,
              onCancel:
                  startingBuild.value || progress?.isActive == true
                      ? stopBuild
                      : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _DisabledTreeTargetCard extends StatelessWidget {
  const _DisabledTreeTargetCard({required this.choice});

  final _TreeChoice choice;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBackgroundColor.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor.withValues(alpha: 0.72)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _SourceIcon(source: choice.source),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    choice.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    choice.disabledReason,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            DesktopDialogButton(
              label: _disabledTreeActionLabel(choice.disabledReason),
              icon: Icons.lock_outline_rounded,
              onPress: null,
            ),
          ],
        ),
      ),
    );
  }
}

class _PreparingCombinedTreeTargetCard extends StatelessWidget {
  const _PreparingCombinedTreeTargetCard({
    required this.choice,
    required this.operation,
    required this.queued,
    required this.onBuild,
    required this.onStop,
  });

  final _TreeChoice choice;
  final PlayerWorkspaceOperation? operation;
  final bool queued;
  final VoidCallback onBuild;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final progress = operation?.progress;
    final isPreparing = queued || operation != null;
    final progressValue =
        progress != null && progress > 0 && progress < 1 ? progress : null;
    final preparationPercent = operation?.percent;
    final message =
        queued
            ? '${operation?.message ?? 'Preparing combined database...'}'
                '${preparationPercent == null ? '' : ' · $preparationPercent%'}'
            : operation?.message ?? 'Combined database needs preparation.';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBackgroundColor.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            _SourceIcon(source: choice.source),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    choice.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (isPreparing)
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            value: progressValue,
                            valueColor: const AlwaysStoppedAnimation(
                              kPrimaryColor,
                            ),
                            backgroundColor: kDividerColor,
                          ),
                        )
                      else
                        const Icon(
                          Icons.hourglass_top_rounded,
                          size: 13,
                          color: kLightGreyColor,
                        ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kLightGreyColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            DesktopToolbarPillButton(
              key: const ValueKey('queue-combined-tree-build'),
              label: queued ? 'Tree 0%' : 'Build Tree',
              icon: Icons.account_tree_outlined,
              leading:
                  queued
                      ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                        ),
                      )
                      : null,
              onPress: queued ? onStop : onBuild,
              busy: queued,
              tooltip:
                  queued
                      ? 'Preparing the combined database. Click to stop.'
                      : 'Build the tree after preparing the combined database',
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: kBackgroundColor.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final message = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: kLightGreyColor, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final action =
              actionLabel == null
                  ? null
                  : DesktopDialogButton(
                    label: actionLabel!,
                    icon: Icons.arrow_forward_rounded,
                    tone: DesktopDialogButtonTone.primary,
                    onPress: onAction,
                  );

          if (action == null) return message;
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                message,
                const SizedBox(height: 14),
                Align(alignment: Alignment.centerRight, child: action),
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: message),
              const SizedBox(width: 12),
              action,
            ],
          );
        },
      ),
    );
  }
}

class _DatabaseTarget {
  const _DatabaseTarget({
    required this.source,
    required this.title,
    required this.path,
    required this.gameCount,
  });

  final PlayerWorkspaceSource source;
  final String title;
  final String path;
  final int gameCount;
}

class _TreeChoice {
  const _TreeChoice({
    required this.source,
    required this.title,
    required this.disabledReason,
    this.target,
  });

  final PlayerWorkspaceSource source;
  final String title;
  final String disabledReason;
  final _DatabaseTarget? target;
}

PlayerWorkspacePlayer? _playerById(
  List<PlayerWorkspacePlayer> players,
  String? id,
) {
  if (id == null) return null;
  for (final player in players) {
    if (player.id == id) return player;
  }
  return null;
}

bool _matchesPlayerQuery(PlayerWorkspacePlayer player, String query) {
  final clean = query.trim().toLowerCase();
  if (clean.isEmpty) return true;
  final searchable =
      <String>[
        player.displayName,
        if (player.title != null) player.title!,
        if (player.country != null) player.country!,
        if (player.fideId != null) player.fideId!,
        for (final account in player.allAccounts) ...[
          account.username,
          if (account.displayName != null) account.displayName!,
          account.source.label,
        ],
      ].join(' ').toLowerCase();
  return searchable.contains(clean);
}

@immutable
class _RatingFact {
  const _RatingFact({required this.label, required this.value});

  final String label;
  final int value;
}

/// Best available player rating, read from a linked source profile. Classical
/// is preferred, then rapid/blitz/bullet, then any other source rating.
_RatingFact? _playerPrimaryRating(PlayerWorkspacePlayer player) {
  for (final source in const [
    PlayerWorkspaceSource.chessever,
    PlayerWorkspaceSource.chesscom,
    PlayerWorkspaceSource.lichess,
  ]) {
    for (final account in player.accountsFor(source)) {
      final ratings = account.ratings;
      for (final label in const ['Classical', 'Rapid', 'Blitz', 'Bullet']) {
        final value = ratings[label];
        if (value != null && value > 0) {
          return _RatingFact(label: label, value: value);
        }
      }
      for (final entry in ratings.entries) {
        if (entry.value > 0) {
          return _RatingFact(label: entry.key, value: entry.value);
        }
      }
    }
  }
  return null;
}

_RatingFact? _strongestAccountRating(PlayerWorkspaceAccount account) {
  MapEntry<String, int>? top;
  for (final entry in account.ratings.entries) {
    if (entry.value <= 0) continue;
    if (top == null || entry.value > top.value) top = entry;
  }
  return top == null ? null : _RatingFact(label: top.key, value: top.value);
}

String? _tempoIconAssetForLabel(String label) {
  final normalized = label.trim().toLowerCase();
  if (normalized.contains('classical') || normalized.contains('standard')) {
    return PngAsset.classicalIcon;
  }
  if (normalized.contains('rapid')) return PngAsset.rapidIcon;
  if (normalized.contains('blitz') || normalized.contains('bullet')) {
    return PngAsset.blitzIcon;
  }
  return null;
}

class _TempoIcon extends StatelessWidget {
  const _TempoIcon({required this.label, this.size = 14});

  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = _tempoIconAssetForLabel(label);
    if (asset == null) {
      return Icon(Icons.equalizer_rounded, size: size, color: kPrimaryColor);
    }
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Image.asset(
      asset,
      width: size,
      height: size,
      cacheWidth: (size * pixelRatio).round(),
      cacheHeight: (size * pixelRatio).round(),
      filterQuality: FilterQuality.medium,
    );
  }
}

class _InlineRatingFact extends StatelessWidget {
  const _InlineRatingFact({required this.rating});

  final _RatingFact rating;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TempoIcon(label: rating.label, size: 13),
        const SizedBox(width: 4),
        Text(
          '${rating.value} ${rating.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            height: 1.2,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

String _formatRelativeSync(int? ms) {
  if (ms == null || ms <= 0) return 'Never';
  final date = DateTime.fromMillisecondsSinceEpoch(ms);
  final days =
      DateUtils.dateOnly(
        DateTime.now(),
      ).difference(DateUtils.dateOnly(date)).inDays;
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days days ago';
  if (days < 14) return 'Last week';
  return _formatDate(ms);
}

List<_DatabaseTarget> _databaseTargets(PlayerWorkspacePlayer player) {
  return <_DatabaseTarget>[
    if (player.combinedPgnPath != null && player.combinedGameCount > 0)
      _DatabaseTarget(
        source: PlayerWorkspaceSource.combined,
        title: '${player.displayName} Combined',
        path: player.combinedPgnPath!,
        gameCount: player.combinedGameCount,
      ),
    for (final account in player.allAccounts)
      if (account.pgnPath != null && account.gameCount > 0)
        _DatabaseTarget(
          source: account.source,
          title: _databaseTargetTitle(player, account),
          path: account.pgnPath!,
          gameCount: account.gameCount,
        ),
  ];
}

List<_TreeChoice> _treeChoices(PlayerWorkspacePlayer player) {
  final targets = _databaseTargets(player);
  final combinedTarget = _firstDatabaseTarget(
    targets,
    PlayerWorkspaceSource.combined,
  );
  final hasSourceGames = player.allAccounts.any(
    (account) => account.hasDownloadedGames,
  );
  return <_TreeChoice>[
    _treeChoiceFor(
      source: PlayerWorkspaceSource.combined,
      title: 'Combined database',
      target: combinedTarget,
      fallbackReason:
          hasSourceGames ? 'Build combined first.' : 'Download games first.',
    ),
    for (final source in const [
      PlayerWorkspaceSource.chessever,
      PlayerWorkspaceSource.chesscom,
      PlayerWorkspaceSource.lichess,
      PlayerWorkspaceSource.manual,
    ])
      ..._treeChoicesForSource(source, targets),
  ];
}

bool _hasDownloadedSourceGames(PlayerWorkspacePlayer player) {
  return player.allAccounts.any((account) => account.hasDownloadedGames);
}

PlayerWorkspaceOperation? _firstSourcePreparationOperation(
  Map<String, PlayerWorkspaceOperation> operations,
) {
  for (final operation in operations.values) {
    if (operation.source != PlayerWorkspaceSource.combined) return operation;
  }
  return null;
}

_DatabaseTarget? _firstDatabaseTarget(
  List<_DatabaseTarget> targets,
  PlayerWorkspaceSource source,
) {
  for (final target in targets) {
    if (target.source == source) return target;
  }
  return null;
}

String _databaseTargetTitle(
  PlayerWorkspacePlayer player,
  PlayerWorkspaceAccount account,
) {
  final label =
      account.displayName?.trim().isNotEmpty == true
          ? account.displayName!.trim()
          : account.username.trim();
  if (account.source == PlayerWorkspaceSource.manual) {
    return label.isEmpty ? '${player.displayName} Manual PGN' : label;
  }
  return label.isEmpty
      ? '${player.displayName} ${account.source.label}'
      : '${account.source.label}: $label';
}

List<_TreeChoice> _treeChoicesForSource(
  PlayerWorkspaceSource source,
  List<_DatabaseTarget> targets,
) {
  final sourceTargets = targets
      .where((target) => target.source == source)
      .toList(growable: false);
  if (sourceTargets.isEmpty) {
    return <_TreeChoice>[
      _treeChoiceFor(
        source: source,
        title: source.label,
        target: null,
        fallbackReason: 'Download games first.',
      ),
    ];
  }
  return <_TreeChoice>[
    for (final target in sourceTargets)
      _treeChoiceFor(
        source: source,
        title: target.title,
        target: target,
        fallbackReason: 'Download games first.',
      ),
  ];
}

_TreeChoice _treeChoiceFor({
  required PlayerWorkspaceSource source,
  required String title,
  required _DatabaseTarget? target,
  required String fallbackReason,
}) {
  if (target == null || target.gameCount <= 0) {
    return _TreeChoice(
      source: source,
      title: title,
      disabledReason: fallbackReason,
    );
  }
  if (!File(target.path).existsSync()) {
    return _TreeChoice(
      source: source,
      title: title,
      disabledReason: 'Re-sync games first.',
    );
  }
  return _TreeChoice(
    source: source,
    title: title,
    disabledReason: '',
    target: target,
  );
}

String _disabledTreeActionLabel(String reason) {
  final clean = reason.trim();
  if (clean.isEmpty) return 'Unavailable';
  return clean.endsWith('.') ? clean.substring(0, clean.length - 1) : clean;
}

/// Opens the same per-source tree used by the Players Build Tree tab, building
/// its local index first when needed. If the source has not been downloaded
/// yet, it is synced through [PlayerWorkspaceNotifier] before tree generation.
Future<void> openOrBuildPlayerWorkspaceSourceTree({
  required BuildContext context,
  required WidgetRef ref,
  required PlayerWorkspacePlayer player,
  required PlayerWorkspaceSource source,
  required PlayerBuildTreePreparationSide preparationSide,
}) async {
  final workspaceNotifier = ref.read(playerWorkspaceProvider.notifier);
  await workspaceNotifier.selectPlayer(player.id);

  var currentPlayer =
      _playerById(ref.read(playerWorkspaceProvider).players, player.id) ??
      player;
  var choice = _treeChoiceForSource(currentPlayer, source);
  if (choice.target == null) {
    final account = currentPlayer.account(source);
    if (account == null) {
      throw StateError('${source.label} is not connected.');
    }
    await workspaceNotifier.syncAccount(account);
    currentPlayer =
        _playerById(ref.read(playerWorkspaceProvider).players, player.id) ??
        currentPlayer;
    choice = _treeChoiceForSource(currentPlayer, source);
  }

  final target = choice.target;
  if (target == null) {
    throw StateError(
      'No ${source.label} games were available to build a tree.',
    );
  }
  if (!context.mounted) return;

  final cachedIndex = await ref.read(
    _cachedPlayerWorkspaceTreeIndexProvider(target.path).future,
  );
  if (!context.mounted) return;
  if (cachedIndex?.isUsable == true) {
    _openLocalTree(
      ref,
      target,
      cachedIndex!,
      preparationSide: preparationSide,
      player: currentPlayer,
    );
    return;
  }

  await _buildLocalTree(
    context,
    ref,
    target,
    currentPlayer,
    preparationSide: preparationSide,
  );
}

_TreeChoice _treeChoiceForSource(
  PlayerWorkspacePlayer player,
  PlayerWorkspaceSource source,
) {
  final choices = _treeChoicesForSource(source, _databaseTargets(player));
  return choices.first;
}

Future<void> _prepareAndBuildCombinedTree(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspacePlayer player, {
  required PlayerBuildTreePreparationSide preparationSide,
  required OperationCancellationToken cancellationToken,
  required VoidCallback onPreparationFinished,
}) async {
  var preparationFinished = false;
  void finishPreparation() {
    if (preparationFinished) return;
    preparationFinished = true;
    onPreparationFinished();
  }

  try {
    cancellationToken.throwIfCanceled();
    final readyPlayer = await ref
        .read(playerWorkspaceProvider.notifier)
        .prepareCombinedDatabaseForTree(player.id);
    cancellationToken.throwIfCanceled();
    if (!context.mounted) return;
    if (readyPlayer == null) {
      throw StateError(
        'No downloaded games are available for a combined tree.',
      );
    }
    final choice = _treeChoiceForSource(
      readyPlayer,
      PlayerWorkspaceSource.combined,
    );
    final target = choice.target;
    if (target == null) {
      throw StateError('The combined database could not be prepared.');
    }
    finishPreparation();
    await _buildLocalTree(
      context,
      ref,
      target,
      readyPlayer,
      preparationSide: preparationSide,
      cancellationToken: cancellationToken,
    );
  } catch (error) {
    if (!context.mounted) return;
    finishPreparation();
    if (isOperationCanceled(error)) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<void> _buildLocalTree(
  BuildContext context,
  WidgetRef ref,
  _DatabaseTarget target,
  PlayerWorkspacePlayer player, {
  required PlayerBuildTreePreparationSide preparationSide,
  OperationCancellationToken? cancellationToken,
}) async {
  cancellationToken?.throwIfCanceled();
  final index = await ref
      .read(_playerTreeBuildProvider.notifier)
      .build(target.path);
  cancellationToken?.throwIfCanceled();
  if (!context.mounted || index?.isUsable != true) return;
  ref.invalidate(_cachedPlayerWorkspaceTreeIndexProvider(target.path));
  _openLocalTree(
    ref,
    target,
    index!,
    preparationSide: preparationSide,
    player: player,
  );
}

Future<void> _openOrBuildLocalTreeTarget(
  BuildContext context,
  WidgetRef ref,
  _DatabaseTarget target,
  PlayerWorkspacePlayer player, {
  required PlayerBuildTreePreparationSide preparationSide,
  OperationCancellationToken? cancellationToken,
}) async {
  cancellationToken?.throwIfCanceled();
  PlayerOpeningTreeIndex? cachedIndex;
  try {
    cachedIndex = await ref.read(
      _cachedPlayerWorkspaceTreeIndexProvider(target.path).future,
    );
  } catch (_) {
    // Cache lookup is best-effort. A real miss still needs to build normally.
  }
  cancellationToken?.throwIfCanceled();
  if (!context.mounted) return;
  if (cachedIndex?.isUsable == true) {
    _openLocalTree(
      ref,
      target,
      cachedIndex!,
      preparationSide: preparationSide,
      player: player,
    );
    return;
  }
  cancellationToken?.throwIfCanceled();
  await _buildLocalTree(
    context,
    ref,
    target,
    player,
    preparationSide: preparationSide,
    cancellationToken: cancellationToken,
  );
}

void _openLocalTree(
  WidgetRef ref,
  _DatabaseTarget target,
  PlayerOpeningTreeIndex index, {
  required PlayerBuildTreePreparationSide preparationSide,
  required PlayerWorkspacePlayer player,
}) {
  final tabId = openBoardGameTab(
    ref,
    BoardTabGameArgs(
      pgn: '',
      label: target.title,
      whiteName: '',
      blackName: '',
      fenSeed: _startingFen,
      initialFen: _startingFen,
      databaseTitle: target.title,
      localOpeningTreeIndex: index,
      localOpeningTreeTitle: target.title,
      // A Player tree is intentionally fixed to the selected source. The
      // library keeps its picker, but switching to Global or another tree here
      // would silently break the player's prep scope.
      hideLocalOpeningTreePicker: true,
    ),
    reuseExisting: false,
  );
  // Seed the opening explorer with the chosen prep colour. Local trees carry
  // per-colour buckets, so this filters the tree by side via the same
  // BoardExplorerScope → gamebase filter seam used by Players tree actions
  // (NotationOpeningPanel applies scope.playerColor on open).
  final color = preparationSide.targetPlayerColor;
  ref
      .read(boardExplorerScopeByTabIdProvider.notifier)
      .update(
        (scopes) => <String, BoardExplorerScope>{
          ...scopes,
          tabId: buildPlayerTreeExplorerScope(
            player: _workspaceGamebasePlayer(player),
            playerAliases: _workspaceGamebasePlayerAliases(player),
            playerColor: color,
          ),
        },
      );
  ref.read(rightRailActivePageProvider(tabId).notifier).state = 1;
  try {
    unawaited(
      ref
          .read(localLibraryRegistryProvider.notifier)
          .registerAll(
            <String>[target.path],
            metadataByPath: <String, LocalLibraryEntryMetadata>{
              target.path: LocalLibraryEntryMetadata.playerWorkspace(
                playerId: player.id,
                playerName: player.displayName,
                gameCount: target.gameCount,
                indexedAt: index.generatedAt,
                playerWorkspaceSource: target.source.storageKey,
              ),
            },
          )
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {},
          ),
    );
  } catch (_) {
    // Registry metadata is best-effort and must never block opening the tree.
  }
}

/// Minimal [GamebasePlayer] from a workspace player, used only to carry the
/// prep-colour scope into the opening explorer for a locally-built tree.
GamebasePlayer _workspaceGamebasePlayer(PlayerWorkspacePlayer player) {
  return GamebasePlayer(
    id: player.chesseverPlayerId ?? player.fideId ?? player.id,
    fideId: player.fideId ?? '',
    name: player.displayName,
    gender: PlayerGender.male,
    fed: player.country ?? '',
    title: player.title,
  );
}

List<GamebasePlayer> _workspaceGamebasePlayerAliases(
  PlayerWorkspacePlayer player,
) {
  final seenNames = <String>{_treePlayerAliasKey(player.displayName)};
  final aliases = <GamebasePlayer>[];

  void addAlias(PlayerWorkspaceAccount account, String? name) {
    final trimmed = name?.trim() ?? '';
    final key = _treePlayerAliasKey(trimmed);
    if (key.isEmpty || !seenNames.add(key)) return;
    aliases.add(
      GamebasePlayer(
        // This ID is deliberately local-only. BoardExplorerScope keeps the
        // canonical ChessEver ID in playerIds for any remote fallback.
        id: 'workspace-${account.identityKey}',
        fideId: '',
        name: trimmed,
        gender: PlayerGender.male,
        fed: player.country ?? '',
      ),
    );
  }

  for (final account in player.allAccounts) {
    addAlias(account, account.username);
    addAlias(account, account.displayName);
  }
  return List<GamebasePlayer>.unmodifiable(aliases);
}

String _treePlayerAliasKey(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

Future<void> _runAccountSync(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceAccount account,
) async {
  try {
    await ref.read(playerWorkspaceProvider.notifier).syncAccount(account);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<void> _confirmReinstallAccount(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceAccount account,
) async {
  final confirmed = await showFDialog<bool>(
    context: context,
    builder:
        (context, _, animation) => _ConfirmReinstallAccountDialog(
          account: account,
          animation: animation,
        ),
  );
  if (confirmed != true || !context.mounted) return;
  await _runAccountReinstall(context, ref, account);
}

Future<void> _runAccountReinstall(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceAccount account,
) async {
  try {
    await ref.read(playerWorkspaceProvider.notifier).reinstallAccount(account);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<void> _runCancelAccountOperation(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceAccount account,
) async {
  try {
    await ref
        .read(playerWorkspaceProvider.notifier)
        .cancelAccountOperation(account);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<void> _runRefreshAccountEntry(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceAccount account,
) async {
  try {
    await ref
        .read(playerWorkspaceProvider.notifier)
        .refreshAccountEntry(account);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<void> _confirmRemoveAccountEntry(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceAccount account,
) async {
  final confirmed = await showFDialog<bool>(
    context: context,
    builder:
        (context, _, animation) => _ConfirmRemoveAccountDialog(
          source: account.source,
          account: account,
          animation: animation,
        ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await ref
        .read(playerWorkspaceProvider.notifier)
        .removeAccountEntry(account);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<void> _showRenamePlayerDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspacePlayer player,
) {
  return showFDialog<void>(
    context: context,
    builder:
        (context, _, animation) => _RenamePlayerDialog(
          player: player,
          animation: animation,
          onRename:
              (name) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .renamePlayer(player.id, name),
        ),
  );
}

Future<void> _confirmRemovePlayer(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspacePlayer player,
) async {
  final confirmed = await showFDialog<bool>(
    context: context,
    builder:
        (context, _, animation) =>
            _ConfirmRemovePlayerDialog(player: player, animation: animation),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await ref.read(playerWorkspaceProvider.notifier).removePlayer(player.id);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

Future<void> _showAddAccountChoiceDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final source = await showFDialog<PlayerWorkspaceSource>(
    context: context,
    builder:
        (context, _, animation) =>
            _AddAccountChoiceDialog(animation: animation),
  );
  if (source == null || !context.mounted) return;
  await _showAccountConnectFlow(context, ref, source);
}

Future<void> _showAccountConnectFlow(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceSource source,
) async {
  if (source == PlayerWorkspaceSource.chessever) {
    final lockedFideId = _normalizedDialogFideId(
      ref.read(playerWorkspaceProvider).selectedPlayer?.fideId,
    );
    if (lockedFideId != null) {
      try {
        await ref
            .read(playerWorkspaceProvider.notifier)
            .reconnectLockedChessEverSource();
      } catch (error) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_stageErrorText(error))));
      }
      return;
    }
    await _showConnectChessEverDialog(context, ref);
    return;
  }
  if (source == PlayerWorkspaceSource.manual) {
    await _showManualPgnDialog(context, ref);
    return;
  }
  if (source == PlayerWorkspaceSource.lichess ||
      source == PlayerWorkspaceSource.chesscom) {
    await _showConnectAccountsDialog(context, ref, source);
  }
}

/// Opens the multi-username connect dialog for an online platform. One dialog
/// stages several usernames — each verified against Lichess/Chess.com as it is
/// added — then attaches every confirmed account to the selected player in a
/// single write. Reached from the source rail, the Accounts tab, the "Add
/// another username" button, and the add-player flow, so all four routes share
/// the same "add one or many" surface.
Future<void> _showConnectAccountsDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceSource source,
) {
  final player = ref.read(playerWorkspaceProvider).selectedPlayer;
  final existing = <String>[
    if (player != null)
      for (final account in player.accountsFor(source)) account.username,
  ];
  final repository = ref.read(playerWorkspaceRepositoryProvider);
  return showFDialog<void>(
    context: context,
    builder:
        (context, _, animation) => _ConnectAccountsDialog(
          source: source,
          animation: animation,
          existingUsernames: existing,
          onValidate:
              (username) => switch (source) {
                PlayerWorkspaceSource.lichess => repository.fetchLichessAccount(
                  username,
                ),
                PlayerWorkspaceSource.chesscom => repository
                    .fetchChessComAccount(username),
                _ => throw StateError('Unsupported account source.'),
              },
          onConnect:
              (accounts) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .attachFetchedAccounts(accounts),
        ),
  );
}

Future<void> _showEditAccountDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerWorkspaceAccount account,
) {
  if (account.source != PlayerWorkspaceSource.lichess &&
      account.source != PlayerWorkspaceSource.chesscom) {
    return Future<void>.value();
  }
  return showFDialog<void>(
    context: context,
    builder:
        (context, _, animation) => _ConnectAccountDialog(
          source: account.source,
          animation: animation,
          initialUsername: account.username,
          title: 'Edit ${account.source.label}',
          submitLabel: 'Save',
          submitIcon: Icons.check_rounded,
          onConnect: (username) async {
            await ref
                .read(playerWorkspaceProvider.notifier)
                .editExternalAccount(account: account, username: username);
          },
        ),
  );
}

Future<void> _showManualPgnDialog(BuildContext context, WidgetRef ref) {
  return showFDialog<void>(
    context: context,
    builder:
        (context, _, animation) => _ManualPgnDialog(
          animation: animation,
          onImportPgn:
              (label, pgn) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .importManualPgn(label: label, pgn: pgn),
          onImportPaths:
              (paths) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .importManualPgnPaths(paths: paths),
        ),
  );
}

class _AddAccountChoiceDialog extends StatelessWidget {
  const _AddAccountChoiceDialog({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return FDialog.raw(
      animation: animation,
      constraints: const BoxConstraints(maxWidth: 460),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Add account',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose the source to connect to this player.',
                style: TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 16),
              for (final source in const [
                PlayerWorkspaceSource.chessever,
                PlayerWorkspaceSource.chesscom,
                PlayerWorkspaceSource.lichess,
                PlayerWorkspaceSource.manual,
              ]) ...[
                _SourceChoiceButton(
                  source: source,
                  onPress: () => Navigator.of(context).pop(source),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: DesktopDialogButton(
                  label: 'Cancel',
                  icon: Icons.close_rounded,
                  onPress: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SourceChoiceButton extends StatelessWidget {
  const _SourceChoiceButton({required this.source, required this.onPress});

  final PlayerWorkspaceSource source;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return DesktopDialogButton(
      label: source.label,
      fillWidth: true,
      prefix: _SourceIcon(source: source),
      onPress: onPress,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(source.accountLabel),
      ),
    );
  }
}

class _ManualPgnDialog extends StatefulWidget {
  const _ManualPgnDialog({
    required this.animation,
    required this.onImportPgn,
    required this.onImportPaths,
  });

  final Animation<double> animation;
  final Future<void> Function(String label, String pgn) onImportPgn;
  final Future<void> Function(List<String> paths) onImportPaths;

  @override
  State<_ManualPgnDialog> createState() => _ManualPgnDialogState();
}

class _ManualPgnDialogState extends State<_ManualPgnDialog> {
  late final TextEditingController _labelController;
  late final TextEditingController _pgnController;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: 'Manual PGN');
    _pgnController = TextEditingController();
  }

  @override
  void dispose() {
    _labelController.dispose();
    _pgnController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    if (_working) return;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import player PGN',
      type: FileType.custom,
      allowedExtensions: localChessPickerExtensions,
      allowMultiple: true,
      withData: false,
      lockParentWindow: true,
    );
    final paths =
        result?.files
            .map((file) => file.path)
            .whereType<String>()
            .where((path) => path.trim().isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    if (paths.isEmpty) return;
    await _importPaths(paths);
  }

  Future<void> _pickFolder() async {
    if (_working) return;
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Import player PGN folder',
      lockParentWindow: true,
    );
    if (path == null || path.trim().isEmpty) return;
    await _importPaths(<String>[path]);
  }

  Future<void> _importPaths(List<String> paths) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onImportPaths(paths);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _submitPgn() async {
    final pgn = _pgnController.text.trim();
    if (pgn.isEmpty || _working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onImportPgn(_labelController.text, pgn);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: const [
                  Icon(Icons.note_add_outlined, color: kPrimaryColor, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Import manual PGN',
                      style: TextStyle(
                        color: kWhiteColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DesktopSearchField(
                controller: _labelController,
                hintText: 'Source label',
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              FTheme(
                data: FThemes.zinc.dark,
                child: FTextField(
                  controller: _pgnController,
                  hint: 'Paste one or more PGN games',
                  minLines: 8,
                  maxLines: 12,
                  onChange: (_) => setState(() {}),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: kRedColor, fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  DesktopDialogButton(
                    label: 'Choose files',
                    icon: Icons.file_open_outlined,
                    onPress: _working ? null : () => unawaited(_pickFiles()),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label: 'Choose folder',
                    icon: Icons.folder_open_outlined,
                    onPress: _working ? null : () => unawaited(_pickFolder()),
                  ),
                  const Spacer(),
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress:
                        _working ? null : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label: _working ? 'Importing' : 'Import pasted PGN',
                    icon: Icons.note_add_outlined,
                    tone: DesktopDialogButtonTone.primary,
                    onPress:
                        !_working && _pgnController.text.trim().isNotEmpty
                            ? () => unawaited(_submitPgn())
                            : null,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConfirmRemoveAccountDialog extends StatelessWidget {
  const _ConfirmRemoveAccountDialog({
    required this.source,
    required this.animation,
    this.account,
  });

  final PlayerWorkspaceSource source;
  final Animation<double> animation;
  final PlayerWorkspaceAccount? account;

  @override
  Widget build(BuildContext context) {
    final currentAccount = account;
    final title =
        currentAccount == null
            ? 'Remove ${source.label}'
            : 'Remove ${currentAccount.displayName ?? currentAccount.username}';
    return FDialog.raw(
      animation: animation,
      constraints: const BoxConstraints(maxWidth: 430),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _SourceIcon(source: source),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                source == PlayerWorkspaceSource.manual
                    ? 'This removes the manual PGN from this player, deletes the generated PGN file and local cache, and rebuilds the combined database.'
                    : 'This disconnects the account, deletes its generated PGN files and local cache, and rebuilds the combined database.',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label:
                        source == PlayerWorkspaceSource.manual
                            ? 'Remove PGN'
                            : 'Remove',
                    icon:
                        source == PlayerWorkspaceSource.manual
                            ? Icons.delete_outline_rounded
                            : Icons.link_off_rounded,
                    tone: DesktopDialogButtonTone.danger,
                    onPress: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConfirmReinstallAccountDialog extends StatelessWidget {
  const _ConfirmReinstallAccountDialog({
    required this.account,
    required this.animation,
  });

  final PlayerWorkspaceAccount account;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final label =
        account.displayName?.trim().isNotEmpty == true
            ? account.displayName!.trim()
            : account.username.trim();
    return FDialog.raw(
      animation: animation,
      constraints: const BoxConstraints(maxWidth: 450),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _SourceIcon(source: account.source),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Reinstall ${account.source.label}',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'This redownloads every game for $label and replaces this '
                'source database from scratch. The account stays connected, '
                'and the combined database will be rebuilt afterward.',
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label: 'Reinstall',
                    icon: Icons.restart_alt_rounded,
                    tone: DesktopDialogButtonTone.danger,
                    onPress: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RenamePlayerDialog extends StatefulWidget {
  const _RenamePlayerDialog({
    required this.player,
    required this.animation,
    required this.onRename,
  });

  final PlayerWorkspacePlayer player;
  final Animation<double> animation;
  final Future<void> Function(String name) onRename;

  @override
  State<_RenamePlayerDialog> createState() => _RenamePlayerDialogState();
}

class _RenamePlayerDialogState extends State<_RenamePlayerDialog> {
  late final TextEditingController _controller;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.player.displayName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.isEmpty || _working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onRename(name);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 440),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.edit_outlined,
                    color: kPrimaryColor,
                    size: 21,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Rename player',
                      style: TextStyle(
                        color: kWhiteColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DesktopSearchField(
                controller: _controller,
                autofocus: true,
                hintText: 'Player name',
                onChanged: (_) => setState(() {}),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: kRedColor, fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress:
                        _working ? null : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label: _working ? 'Renaming' : 'Rename',
                    icon: Icons.check_rounded,
                    tone: DesktopDialogButtonTone.primary,
                    onPress:
                        !_working && _controller.text.trim().isNotEmpty
                            ? () => unawaited(_submit())
                            : null,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConfirmRemovePlayerDialog extends StatelessWidget {
  const _ConfirmRemovePlayerDialog({
    required this.player,
    required this.animation,
  });

  final PlayerWorkspacePlayer player;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return FDialog.raw(
      animation: animation,
      constraints: const BoxConstraints(maxWidth: 450),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.delete_outline_rounded,
                    color: kRedColor,
                    size: 21,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Remove ${player.displayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'This removes the player from the Players workspace and deletes generated PGN files, combined databases, and local cache from this computer.',
                style: TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label: 'Remove',
                    icon: Icons.delete_outline_rounded,
                    tone: DesktopDialogButtonTone.danger,
                    onPress: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectAccountDialog extends StatefulWidget {
  const _ConnectAccountDialog({
    required this.source,
    required this.animation,
    required this.onConnect,
    this.initialUsername,
    this.title,
    this.submitLabel,
    this.submitIcon = Icons.add_link_outlined,
  });

  final PlayerWorkspaceSource source;
  final Animation<double> animation;
  final Future<void> Function(String username) onConnect;
  final String? initialUsername;
  final String? title;
  final String? submitLabel;
  final IconData submitIcon;

  @override
  State<_ConnectAccountDialog> createState() => _ConnectAccountDialogState();
}

class _ConnectAccountDialogState extends State<_ConnectAccountDialog> {
  late final TextEditingController _controller;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialUsername ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _controller.text.trim();
    if (username.isEmpty || _working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onConnect(username);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 440),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _SourceIcon(source: widget.source),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title ?? 'Connect ${widget.source.label}',
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DesktopSearchField(
                controller: _controller,
                autofocus: true,
                hintText: widget.source.accountLabel,
                onChanged: (_) => setState(() {}),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: kRedColor, fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress:
                        _working ? null : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label:
                        _working
                            ? 'Working'
                            : (widget.submitLabel ?? 'Connect'),
                    icon: widget.submitIcon,
                    tone: DesktopDialogButtonTone.primary,
                    onPress:
                        !_working && _controller.text.trim().isNotEmpty
                            ? () => unawaited(_submit())
                            : null,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

enum _UsernameStageStatus { validating, ok, error }

/// One username the user has staged in the multi-connect dialog, together with
/// its live verification status. Distinct from [PlayerWorkspaceAccount] because
/// it also carries the in-flight ("validating") and failed ("error") states
/// that never reach the player model.
class _StagedUsername {
  _StagedUsername(this.input);

  final String input;
  _UsernameStageStatus status = _UsernameStageStatus.validating;
  PlayerWorkspaceAccount? account;
  String? error;

  String get key => input.trim().toLowerCase();
}

/// Connect one *or several* usernames for a single online platform in one pass.
///
/// Each username is verified against Lichess/Chess.com the moment it is added
/// (staged as a pill that resolves to the real profile name + rating, or shows
/// why it failed), so the player model is only touched on "Add" — with every
/// confirmed account attached in a single write. This is the surface the
/// add-player flow, the source rail, and "Add another username" all open, which
/// is what makes "add multiple usernames per platform" a first-class flow rather
/// than a repeated one-at-a-time loop.
class _ConnectAccountsDialog extends StatefulWidget {
  const _ConnectAccountsDialog({
    required this.source,
    required this.animation,
    required this.existingUsernames,
    required this.onValidate,
    required this.onConnect,
  });

  final PlayerWorkspaceSource source;
  final Animation<double> animation;

  /// Usernames already attached to this player for [source] — used to reject
  /// duplicates before a needless network round-trip.
  final List<String> existingUsernames;
  final Future<PlayerWorkspaceAccount> Function(String username) onValidate;
  final Future<void> Function(List<PlayerWorkspaceAccount> accounts) onConnect;

  @override
  State<_ConnectAccountsDialog> createState() => _ConnectAccountsDialogState();
}

class _ConnectAccountsDialogState extends State<_ConnectAccountsDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<_StagedUsername> _staged = <_StagedUsername>[];
  late final Set<String> _existingKeys;
  String? _inputError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _existingKeys = <String>{
      for (final username in widget.existingUsernames)
        username.trim().toLowerCase(),
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  int get _okCount =>
      _staged.where((s) => s.status == _UsernameStageStatus.ok).length;

  bool get _anyValidating =>
      _staged.any((s) => s.status == _UsernameStageStatus.validating);

  void _add() {
    if (_saving) return;
    final raw = _controller.text.trim();
    if (raw.isEmpty) return;
    final key = raw.toLowerCase();
    if (_existingKeys.contains(key)) {
      setState(() => _inputError = '"$raw" is already connected.');
      return;
    }
    if (_staged.any((s) => s.key == key)) {
      setState(() => _inputError = '"$raw" is already in the list.');
      return;
    }
    final staged = _StagedUsername(raw);
    setState(() {
      _staged.insert(0, staged);
      _controller.clear();
      _inputError = null;
    });
    _focusNode.requestFocus();
    unawaited(_validate(staged));
  }

  Future<void> _validate(_StagedUsername staged) async {
    try {
      final account = await widget.onValidate(staged.input);
      if (!mounted) return;
      setState(() {
        staged.status = _UsernameStageStatus.ok;
        staged.account = account;
        staged.error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        staged.status = _UsernameStageStatus.error;
        staged.error = _stageErrorText(error);
      });
    }
  }

  void _remove(_StagedUsername staged) {
    setState(() => _staged.remove(staged));
  }

  void _retry(_StagedUsername staged) {
    setState(() {
      staged.status = _UsernameStageStatus.validating;
      staged.error = null;
    });
    unawaited(_validate(staged));
  }

  Future<void> _submit() async {
    // Preserve the order in which usernames were typed (newest is inserted at
    // the top, so read the staged list in reverse when handing accounts over).
    final accounts = <PlayerWorkspaceAccount>[
      for (final staged in _staged.reversed)
        if (staged.status == _UsernameStageStatus.ok && staged.account != null)
          staged.account!,
    ];
    if (accounts.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.onConnect(accounts);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _inputError = _stageErrorText(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = _controller.text.trim().isNotEmpty && !_saving;
    final okCount = _okCount;
    final canSubmit = okCount > 0 && !_anyValidating && !_saving;
    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 460),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SourceIcon(source: widget.source),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connect ${widget.source.label}',
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        const Text(
                          'Add one or more usernames — each is verified as you go.',
                          style: TextStyle(
                            color: kLightGreyColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildInput(canAdd),
              if (_inputError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _inputError!,
                  style: const TextStyle(color: kRedColor, fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              _buildStaged(),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress: _saving ? null : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  DesktopDialogButton(
                    label:
                        _saving
                            ? 'Connecting'
                            : okCount > 0
                            ? (okCount == 1
                                ? 'Add 1 username'
                                : 'Add $okCount usernames')
                            : 'Add usernames',
                    icon: Icons.add_link_outlined,
                    tone: DesktopDialogButtonTone.primary,
                    onPress: canSubmit ? () => unawaited(_submit()) : null,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInput(bool canAdd) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kDividerColor),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.alternate_email_rounded,
                  size: 16,
                  color: kLightGreyColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Material(
                    type: MaterialType.transparency,
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus: true,
                      cursorColor: kPrimaryColor,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() => _inputError = null),
                      onSubmitted: (_) => _add(),
                      style: const TextStyle(color: kWhiteColor, fontSize: 13),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: widget.source.accountLabel,
                        hintStyle: const TextStyle(
                          color: kLightGreyColor,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        DesktopDialogButton(
          label: 'Search',
          icon: Icons.search_rounded,
          onPress: canAdd ? _add : null,
        ),
      ],
    );
  }

  Widget _buildStaged() {
    if (_staged.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
        decoration: BoxDecoration(
          color: kBackgroundColor.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor.withValues(alpha: 0.6)),
        ),
        child: const Column(
          children: [
            Icon(
              Icons.person_add_alt_1_outlined,
              size: 22,
              color: kLightGreyColor,
            ),
            SizedBox(height: 8),
            Text(
              'No usernames yet',
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: 3),
            Text(
              'Type a username and press Enter to add it. '
              'Repeat for as many as you like.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: kLightGreyColor,
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 264),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _staged.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final staged = _staged[index];
          return _StagedUsernameRow(
            key: ValueKey(staged.key),
            staged: staged,
            onRemove: () => _remove(staged),
            onRetry: () => _retry(staged),
          );
        },
      ),
    );
  }
}

class _StagedUsernameRow extends StatelessWidget {
  const _StagedUsernameRow({
    super.key,
    required this.staged,
    required this.onRemove,
    required this.onRetry,
  });

  final _StagedUsername staged;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final account = staged.account;
    final ok = staged.status == _UsernameStageStatus.ok;
    final error = staged.status == _UsernameStageStatus.error;
    final borderColor =
        ok
            ? kPrimaryColor.withValues(alpha: 0.30)
            : error
            ? kRedColor.withValues(alpha: 0.34)
            : kDividerColor;
    final title = ok && account != null ? account.username : staged.input;
    final secondary =
        error
            ? (staged.error ?? 'Could not verify this username.')
            : ok
            ? 'Verified'
            : 'Verifying…';

    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kBlack2Color.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          _StageStatusDot(status: staged.status),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                if (ok && account != null)
                  _AccountSummaryLine(account: account)
                else
                  Text(
                    secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: error ? kRedColor : kLightGreyColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
              ],
            ),
          ),
          if (error) ...[
            const SizedBox(width: 6),
            DesktopDialogIconButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Try again',
              onPress: onRetry,
            ),
          ],
          const SizedBox(width: 2),
          DesktopDialogIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Remove',
            tone: DesktopDialogButtonTone.danger,
            onPress: onRemove,
          ),
        ],
      ),
    );

    if (MediaQuery.of(context).disableAnimations) return row;
    // Each pill slides + fades in once, when it is first staged. The tween end
    // is fixed at 1, so later rebuilds (status resolving) don't re-trigger it.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 8),
            child: child,
          ),
        );
      },
      child: row,
    );
  }
}

class _AccountSummaryLine extends StatelessWidget {
  const _AccountSummaryLine({required this.account});

  final PlayerWorkspaceAccount account;

  @override
  Widget build(BuildContext context) {
    final username = account.username.trim();
    final display = account.displayName?.trim();
    final title = account.title?.trim();
    final rating = _strongestAccountRating(account);
    final identity = <String>[
      if (title != null && title.isNotEmpty) title,
      if (display != null &&
          display.isNotEmpty &&
          display.toLowerCase() != username.toLowerCase())
        display,
    ].join(' · ');

    if (identity.isEmpty && rating == null) {
      return const Text(
        'Verified',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: kLightGreyColor,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      );
    }

    return Row(
      children: [
        if (identity.isNotEmpty)
          Flexible(
            child: Text(
              identity,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ),
        if (identity.isNotEmpty && rating != null) const _FacetDot(),
        if (rating != null) _InlineRatingFact(rating: rating),
      ],
    );
  }
}

class _StageStatusDot extends StatelessWidget {
  const _StageStatusDot({required this.status});

  final _UsernameStageStatus status;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case _UsernameStageStatus.validating:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: kPrimaryColor,
          ),
        );
      case _UsernameStageStatus.ok:
        return const Icon(
          Icons.check_circle_rounded,
          size: 17,
          color: kPrimaryColor,
        );
      case _UsernameStageStatus.error:
        return const Icon(
          Icons.error_outline_rounded,
          size: 17,
          color: kRedColor,
        );
    }
  }
}

/// Strips Dart's exception-type prefixes so the raw thrown message (e.g.
/// `Lichess user "x" was not found.`) reads cleanly inside a pill.
String _stageErrorText(Object error) {
  final text = error.toString();
  for (final prefix in const <String>[
    'Bad state: ',
    'Invalid argument(s): ',
    'Invalid argument: ',
    'Exception: ',
  ]) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}

String? _normalizedDialogFideId(String? fideId) {
  final clean = fideId?.trim();
  if (clean == null || clean.isEmpty || clean == '?') return null;
  return clean;
}

/// Result of the add-player dialog: which player was created, and whether the
/// user asked to jump straight into connecting online usernames afterwards.
class _AddPlayerResult {
  const _AddPlayerResult({
    required this.playerId,
    required this.connectUsernames,
  });

  final String playerId;
  final bool connectUsernames;
}

Future<void> _showAddPlayerDialog(
  BuildContext context,
  WidgetRef ref, {
  required void Function(String playerId) onOpenPlayer,
}) async {
  final result = await showFDialog<_AddPlayerResult>(
    context: context,
    builder:
        (context, _, animation) => _AddPlayerDialog(
          title: 'Add player',
          animation: animation,
          offerConnect: true,
          onSearch:
              (query) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .searchChessEverPlayers(query),
          onAddManual:
              (name) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .addManualPlayer(name),
          onAddChessEver:
              (player) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .addChessEverPlayer(player),
        ),
  );
  if (result == null || !context.mounted) return;
  onOpenPlayer(result.playerId);
  if (!result.connectUsernames || !context.mounted) return;
  // Make sure the just-created player is the selected one before the connect
  // dialog attaches usernames to it.
  await ref
      .read(playerWorkspaceProvider.notifier)
      .selectPlayer(result.playerId);
  if (!context.mounted) return;
  await _showAddAccountChoiceDialog(context, ref);
}

Future<void> _showConnectChessEverDialog(BuildContext context, WidgetRef ref) {
  final lockedFideId = _normalizedDialogFideId(
    ref.read(playerWorkspaceProvider).selectedPlayer?.fideId,
  );
  return showFDialog<void>(
    context: context,
    builder:
        (context, _, animation) => _AddPlayerDialog(
          title: 'Connect ChessEver',
          animation: animation,
          lockedFideId: lockedFideId,
          onSearch:
              (query) => ref
                  .read(playerWorkspaceProvider.notifier)
                  .searchChessEverPlayers(query),
          onAddChessEver: (player) async {
            await ref
                .read(playerWorkspaceProvider.notifier)
                .connectChessEverPlayer(player);
            return null;
          },
        ),
  );
}

class _AddPlayerDialog extends StatefulWidget {
  const _AddPlayerDialog({
    required this.title,
    required this.animation,
    required this.onSearch,
    required this.onAddChessEver,
    this.onAddManual,
    this.lockedFideId,
    this.offerConnect = false,
  });

  final String title;
  final Animation<double> animation;
  final Future<List<GamebasePlayer>> Function(String query) onSearch;

  /// Returns the new player's id when adding, or null when this dialog is being
  /// reused to connect a ChessEver source to an already-open player.
  final Future<String?> Function(GamebasePlayer player) onAddChessEver;
  final Future<String?> Function(String name)? onAddManual;

  /// When true, a successful add offers "Add & connect", which closes with a
  /// request to open the connect-usernames flow for the new player.
  final bool offerConnect;

  /// When present, this dialog is connecting ChessEver to an existing
  /// FIDE-backed workspace and must not offer other ChessEver players.
  final String? lockedFideId;

  @override
  State<_AddPlayerDialog> createState() => _AddPlayerDialogState();
}

class _AddPlayerDialogState extends State<_AddPlayerDialog> {
  late final TextEditingController _controller;
  Timer? _debounce;
  Future<List<GamebasePlayer>>? _results;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      setState(() {
        _results = _searchChessEver(query);
        _error = null;
      });
    });
  }

  Future<List<GamebasePlayer>> _searchChessEver(String query) async {
    final players = await widget.onSearch(query);
    final lockedFideId = _lockedFideId;
    if (lockedFideId == null) return players;
    return players
        .where(
          (player) => _normalizedDialogFideId(player.fideId) == lockedFideId,
        )
        .toList(growable: false);
  }

  Future<void> _addManual({required bool connect}) async {
    final addManual = widget.onAddManual;
    if (addManual == null) return;
    final name = _controller.text.trim();
    if (name.isEmpty || _working) return;
    setState(() => _working = true);
    try {
      final id = await addManual(name);
      if (!mounted) return;
      Navigator.of(context).pop(
        id == null
            ? null
            : _AddPlayerResult(
              playerId: id,
              connectUsernames: connect && widget.offerConnect,
            ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = _stageErrorText(error);
      });
    }
  }

  Future<void> _addChessEver(GamebasePlayer player) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final id = await widget.onAddChessEver(player);
      if (!mounted) return;
      Navigator.of(context).pop(
        widget.offerConnect && id != null
            ? _AddPlayerResult(playerId: id, connectUsernames: false)
            : null,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = _stageErrorText(error);
      });
    }
  }

  String? get _lockedFideId => _normalizedDialogFideId(widget.lockedFideId);

  @override
  Widget build(BuildContext context) {
    final lockedFideId = _lockedFideId;
    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.person_add_alt_1_outlined,
                    color: kPrimaryColor,
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DesktopSearchField(
                controller: _controller,
                autofocus: true,
                hintText:
                    lockedFideId == null
                        ? 'Search ChessEver player or type a name'
                        : 'Search ChessEver FIDE $lockedFideId',
                onChanged: _onQueryChanged,
              ),
              if (lockedFideId != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Locked to FIDE $lockedFideId. Only this ChessEver player can be connected here.',
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 11,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: kRedColor, fontSize: 12),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 330,
                child:
                    _results == null
                        ? _InlineEmpty(
                          icon: Icons.search_outlined,
                          title: 'Search ChessEver',
                          subtitle:
                              lockedFideId == null
                                  ? 'Use the global player index first, or add a manual prep target.'
                                  : 'This workspace only accepts ChessEver result with FIDE $lockedFideId.',
                        )
                        : FutureBuilder<List<GamebasePlayer>>(
                          future: _results,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState !=
                                ConnectionState.done) {
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: kPrimaryColor,
                                ),
                              );
                            }
                            final players =
                                snapshot.data ?? const <GamebasePlayer>[];
                            if (players.isEmpty) {
                              return _InlineEmpty(
                                icon: Icons.person_off_outlined,
                                title: 'No ChessEver match',
                                subtitle:
                                    lockedFideId == null
                                        ? 'Add this name manually and connect online accounts next.'
                                        : 'No result matched the locked FIDE $lockedFideId.',
                              );
                            }
                            return ListView.separated(
                              itemCount: players.length,
                              separatorBuilder:
                                  (_, __) => const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final player = players[index];
                                return _ChessEverPlayerResult(
                                  player: player,
                                  onTap: () => unawaited(_addChessEver(player)),
                                );
                              },
                            );
                          },
                        ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  DesktopDialogButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    onPress:
                        _working ? null : () => Navigator.of(context).pop(),
                  ),
                  if (widget.onAddManual != null) ...[
                    DesktopDialogButton(
                      label:
                          widget.offerConnect
                              ? 'Create manual player'
                              : 'Add manually',
                      icon: Icons.person_add_alt_1_outlined,
                      tone:
                          widget.offerConnect
                              ? DesktopDialogButtonTone.secondary
                              : DesktopDialogButtonTone.primary,
                      onPress:
                          !_working && _controller.text.trim().isNotEmpty
                              ? () => unawaited(_addManual(connect: false))
                              : null,
                    ),
                    if (widget.offerConnect) ...[
                      DesktopDialogButton(
                        label: 'Add & connect',
                        icon: Icons.add_link_outlined,
                        tone: DesktopDialogButtonTone.primary,
                        tooltip:
                            'Add this player, then connect lichess.org / '
                            'chess.com usernames',
                        onPress:
                            !_working && _controller.text.trim().isNotEmpty
                                ? () => unawaited(_addManual(connect: true))
                                : null,
                      ),
                    ],
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChessEverPlayerResult extends StatelessWidget {
  const _ChessEverPlayerResult({required this.player, required this.onTap});

  final GamebasePlayer player;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kBlack3Color.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor),
        ),
        child: Row(
          children: [
            _FidePhotoAvatar(
              fideId: int.tryParse(player.fideId.trim()),
              initials: _initials(player.displayName),
              size: 34,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    player.titleAndName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${player.fed} · FIDE ${player.fideId}',
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (player.highestRating != null)
              Text(
                player.highestRating!.toString(),
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

PlayerWorkspaceOperation? _operationForAccount(
  Map<String, PlayerWorkspaceOperation> operations,
  PlayerWorkspaceAccount account,
) {
  return operations[playerWorkspaceAccountOperationKey(account)];
}

PlayerWorkspaceOperation? _operationForSource(
  Map<String, PlayerWorkspaceOperation> operations,
  PlayerWorkspaceSource source,
) {
  return operations[playerWorkspaceSourceOperationKey(source)];
}

String _formatInt(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final remaining = text.length - i;
    buffer.write(text[i]);
    if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
  }
  return buffer.toString();
}

String _formatPercent(double? value) {
  if (value == null) return '—';
  return '${(value * 100).round()}%';
}

bool _isPreparingExternalHistory(PlayerWorkspaceOperation operation) {
  if (operation.source != PlayerWorkspaceSource.lichess ||
      operation.progress != null) {
    return false;
  }
  return operation.message.toLowerCase().contains(
    'preparing the complete game history on chessever',
  );
}

@visibleForTesting
String playerWorkspaceOperationStatus(PlayerWorkspaceOperation operation) {
  if (_isPreparingExternalHistory(operation)) return 'Preparing online';
  final percent = operation.percent;
  return percent == null ? 'Working' : '$percent%';
}

@visibleForTesting
String playerWorkspaceLichessDownloadNotice(
  PlayerWorkspaceAccount account,
  PlayerWorkspaceOperation operation,
) {
  if (_isPreparingExternalHistory(operation)) {
    final available = account.effectiveAvailableGameCount;
    final readyCopy =
        available > 0
            ? 'all ${_formatInt(available)} games are ready'
            : 'the full history is ready';
    return 'ChessEver is preparing your Lichess history on its servers. The '
        'imported count stays at 0 until $readyCopy. Large accounts can take '
        '20 minutes or longer; future syncs are faster.';
  }
  return 'Lichess limits full-history downloads, so large accounts may take '
      'several minutes. Future syncs will be faster.';
}

@visibleForTesting
String playerWorkspaceAccountGamesLabel(PlayerWorkspaceAccount account) {
  if (account.source == PlayerWorkspaceSource.chessever &&
      account.hasDownloadedGames) {
    final imported = _formatInt(account.gameCount);
    return '$imported/$imported games';
  }
  final available = account.effectiveAvailableGameCount;
  if (available > account.gameCount) {
    return '${_formatInt(account.gameCount)} / ${_formatInt(available)} games';
  }
  if (account.gameCount > 0) return '${_formatInt(account.gameCount)} games';
  if (available > 0) return '${_formatInt(available)} available';
  return '0 games';
}

@visibleForTesting
bool playerWorkspaceShowsIdleDownloadProgress(PlayerWorkspaceAccount account) {
  if (account.source == PlayerWorkspaceSource.chessever &&
      account.hasDownloadedGames) {
    return false;
  }
  return account.downloadProgress != null && account.remainingGameCount > 0;
}

String? _sourceGameCountLine(PlayerWorkspaceAccount account) {
  final available = account.effectiveAvailableGameCount;
  if (available <= 0) return null;
  final label = playerWorkspaceAccountGamesLabel(account);
  if (account.hasDownloadedGames) {
    return '$label · ${_formatDate(account.lastSyncAtMs)}';
  }
  return '$label · not downloaded';
}

String _formatDate(int? ms) {
  if (ms == null || ms <= 0) return 'Never';
  final date = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String _initials(String name) {
  final parts = name
      .replaceAll(',', ' ')
      .split(RegExp(r'\s+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    return parts.single.characters.take(2).toString().toUpperCase();
  }
  return '${parts.first.characters.first}${parts.last.characters.first}'
      .toUpperCase();
}
