import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/local_chess_pgn_append.dart';
import 'package:chessever/desktop/services/local_player_enrichment_service.dart';
import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/desktop/widgets/library/library_table_row_style.dart';
import 'package:chessever/desktop/widgets/library/local_game_info_dialog.dart';
import 'package:chessever/desktop/widgets/library/local_game_player_cell.dart';
import 'package:chessever/desktop/widgets/library/library_chrome_bar.dart';
import 'package:chessever/desktop/widgets/library/local_tree_action_button.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/local_pgn_metadata.dart';

class LocalChessFilesView extends HookConsumerWidget {
  const LocalChessFilesView({
    super.key,
    required this.selectedPath,
    required this.onSelectPath,
    this.stateOverride,
    this.onRefreshOverride,
    this.initialFilter,
    this.onFilterChanged,
    this.playerFideId,
    this.playerAliases = const <String>[],
  });

  final String selectedPath;
  final ValueChanged<String> onSelectPath;
  final LocalChessLibraryState? stateOverride;
  final Future<void> Function()? onRefreshOverride;

  /// Seeded filters (e.g. from players Overview tap). Applied on first build
  /// and whenever the instance identity / value changes via [useEffect].
  final LocalChessGameFilter? initialFilter;

  /// Notifies parent when the user changes filters from this view.
  final ValueChanged<LocalChessGameFilter>? onFilterChanged;

  /// When set, colour / player-outcome filters resolve relative to this player.
  final String? playerFideId;
  final List<String> playerAliases;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchedState = ref.watch(localChessLibraryProvider);
    final state = stateOverride ?? watchedState;
    final source = state.source;
    final node = source?.nodeForPath(selectedPath);
    final searchController = useTextEditingController();
    final query = useState<String>('');
    final gameFilter = useState<LocalChessGameFilter>(
      initialFilter ?? LocalChessGameFilter(),
    );
    final sort = useState(
      const _LocalGamesSortConfig(
        _LocalGamesSortKey.originalOrder,
        _LocalGamesSortDir.asc,
      ),
    );
    final databasePageWindow = useState(const _LocalDatabasePageWindow('', 0));
    final databaseLoadedPages = useState(
      const _LoadedLocalDatabasePages.empty(),
    );
    // Pick up Overview → Games handoff and external clear without wiping
    // in-view edits when the parent re-passes the same filter instance.
    useEffect(() {
      final next = initialFilter;
      if (next != null && next != gameFilter.value) {
        gameFilter.value = next;
      }
      return null;
    }, [initialFilter]);

    Future<void> pickFolder() async {
      final opened =
          await ref.read(localChessLibraryProvider.notifier).pickFolder();
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) onSelectPath(selected);
    }

    Future<void> pickFiles() async {
      final opened =
          await ref.read(localChessLibraryProvider.notifier).pickFiles();
      if (!opened) return;
      final selected = ref.read(localChessLibraryProvider).selectedPath;
      if (selected != null) onSelectPath(selected);
    }

    if (state.isScanning) {
      return const _LocalLoading();
    }
    if (state.error != null) {
      return _LocalEmpty(
        icon: Icons.error_outline_rounded,
        title: 'Could not open local files',
        message: state.error!,
        onOpenFolder: pickFolder,
        onOpenFiles: pickFiles,
      );
    }
    if (source == null || node == null) {
      return _LocalEmpty(
        icon: Icons.account_tree_outlined,
        title: 'Open local chess files',
        message:
            'Browse a folder, choose chess files, or drop files here. Games '
            'and positions stay on disk until you explicitly save them to '
            'your ChessEver library.',
        onOpenFolder: pickFolder,
        onOpenFiles: pickFiles,
      );
    }

    final selectedDatabase = selectedLocalChessDatabaseFile(node);
    final openableTreeIndex =
        selectedDatabase?.openingTreeIndex?.isUsable == true
            ? selectedDatabase!.openingTreeIndex
            : null;
    final treeBuildProgress = state.treeBuildForPath(selectedDatabase?.path);
    final isBrowsingFolder =
        node is LocalChessFolderNode && selectedDatabase == null;
    final allGames = selectedDatabase?.games ?? const <LocalChessGame>[];
    final databaseEntryCount = selectedDatabase?.gameCount ?? allGames.length;
    final databaseTitle = selectedDatabase?.name ?? source.label;
    final enrichmentEpoch = ref.watch(localPlayerEnrichmentEpochProvider);
    final databaseQueryKey =
        Object.hash(
          selectedDatabase?.path,
          selectedDatabase?.gameCount,
          selectedDatabase?.sizeBytes,
          selectedDatabase?.modifiedAt?.millisecondsSinceEpoch,
          enrichmentEpoch,
          query.value,
          sort.value.key,
          sort.value.dir,
          gameFilter.value,
          playerFideId,
          Object.hashAll(playerAliases),
        ).toString();
    final effectiveDatabasePageWindow =
        databasePageWindow.value.queryKey == databaseQueryKey
            ? databasePageWindow.value
            : _LocalDatabasePageWindow(databaseQueryKey, 0);
    useEffect(() {
      if (databasePageWindow.value.queryKey != databaseQueryKey) {
        databasePageWindow.value = _LocalDatabasePageWindow(
          databaseQueryKey,
          0,
        );
      }
      if (databaseLoadedPages.value.queryKey != databaseQueryKey) {
        databaseLoadedPages.value = const _LoadedLocalDatabasePages.empty();
      }
      return null;
    }, [databaseQueryKey]);
    useEffect(() {
      final path = selectedDatabase?.path;
      if (path == null || databaseEntryCount <= 0) return null;
      Future<void>.microtask(
        () => ref
            .read(localPlayerEnrichmentServiceProvider)
            .ensureDatabaseEnriched(path),
      );
      return null;
    }, [selectedDatabase?.path, databaseEntryCount]);
    final fallbackFiltered = useMemoized(() {
      final q = query.value.trim().toLowerCase();
      final base =
          q.isEmpty
              ? List<LocalChessGame>.of(allGames)
              : allGames.where((game) => _matches(game, q)).toList();
      _sortLocalGames(base, sort.value);
      return base;
    }, [allGames, query.value, sort.value]);
    final databaseGamesPageFuture =
        useMemoized<Future<LocalChessGameQueryPage?>?>(
          () {
            final database = selectedDatabase;
            if (database == null || databaseEntryCount <= 0) return null;
            return _queryLocalDatabaseGamesPage(
              ref.read(localChessDatabaseRepositoryProvider),
              databasePath: database.path,
              search: query.value,
              sort: sort.value,
              filter: gameFilter.value,
              playerFideId: playerFideId,
              playerAliases: playerAliases,
              pageNumber: effectiveDatabasePageWindow.pageNumber,
              pageSize: _kLocalDatabaseGameQueryPageSize,
            );
          },
          [
            selectedDatabase?.path,
            databaseEntryCount,
            query.value,
            sort.value.key,
            sort.value.dir,
            gameFilter.value,
            playerFideId,
            Object.hashAll(playerAliases),
            effectiveDatabasePageWindow.queryKey,
            effectiveDatabasePageWindow.pageNumber,
          ],
        );
    final databaseGamesPageSnapshot = useFuture(
      databaseGamesPageFuture,
      preserveState: false,
    );
    final databaseGamesPage = databaseGamesPageSnapshot.data;
    useEffect(() {
      final page = databaseGamesPage;
      if (page == null) return null;
      if (databasePageWindow.value.queryKey != databaseQueryKey) return null;
      databaseLoadedPages.value = databaseLoadedPages.value.merge(
        queryKey: databaseQueryKey,
        page: page,
      );
      return null;
    }, [databaseGamesPage, databaseQueryKey]);
    final databaseRows = _visibleLocalDatabaseRows(
      queryKey: databaseQueryKey,
      loaded: databaseLoadedPages.value,
      livePage: databaseGamesPage,
    );
    final filtered = databaseRows?.games ?? fallbackFiltered;
    final totalFilteredCount =
        databaseRows?.totalCount ??
        databaseGamesPage?.totalCount ??
        filtered.length;
    final isLoadingDatabasePage =
        databaseGamesPageFuture != null &&
        databaseGamesPageSnapshot.connectionState != ConnectionState.done;
    final hasMoreDatabaseRows = databaseRows?.hasMore ?? false;
    final boardContextGames = databaseRows == null ? allGames : filtered;

    void selectLocalPath(String path) {
      ref.read(localChessLibraryProvider.notifier).selectPath(path);
      onSelectPath(path);
    }

    Future<void> saveVisible() async {
      if (filtered.isEmpty) return;
      // Scanner builds light ChessGames with empty mainlines. Re-parse the
      // raw PGN on a worker isolate so saved rows carry full move data.
      final hydrated = await compute(_hydrateLocalGamesForSave, filtered);
      if (!context.mounted) return;
      final outcome = await showLibrarySaveToFolderDialog(
        context: context,
        ref: ref,
        games: hydrated,
        sourceLabel: databaseTitle,
        destinationMode: LibrarySaveDestinationMode.cloudOnly,
      );
      if (outcome == null || !outcome.didSave || !context.mounted) return;
      showDesktopToast(context, outcome.toToastMessage());
    }

    Future<void> pasteIntoLocalDatabase() async {
      final target = selectedDatabase;
      if (target == null) {
        showDesktopToast(
          context,
          'Open a single local PGN database before pasting.',
          error: true,
        );
        return;
      }
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clipboard?.text?.trim();
      if (text == null || text.isEmpty) {
        if (context.mounted) {
          showDesktopToast(
            context,
            'Clipboard is empty — copy a PGN first.',
            error: true,
          );
        }
        return;
      }
      try {
        final count = await appendPgnTextToLocalChessDatabaseFile(
          repository: ref.read(localChessDatabaseRepositoryProvider),
          filePath: target.path,
          text: text,
          fallbackFingerprints: {
            for (final game in target.games)
              if (game.pgnFingerprint.trim().isNotEmpty) game.pgnFingerprint,
          },
        );
        if (!context.mounted) return;
        if (count <= 0) {
          showDesktopToast(
            context,
            'Clipboard does not contain a new PGN with moves.',
            error: true,
          );
          return;
        }
        if (onRefreshOverride != null) {
          await onRefreshOverride!();
        } else {
          final notifier = ref.read(localChessLibraryProvider.notifier);
          final refreshed = await notifier.refreshFile(target.path);
          if (!refreshed) {
            await notifier.refresh();
          }
        }
        if (!context.mounted) return;
        ref.read(localChessLibraryProvider.notifier).selectPath(target.path);
        onSelectPath(target.path);
        showDesktopToast(
          context,
          'Pasted $count ${count == 1 ? 'game' : 'games'} into ${target.name}.',
        );
      } catch (e) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          'Could not paste into local PGN: $e',
          error: true,
        );
      }
    }

    void openDatabaseTree() {
      final database = selectedDatabase;
      if (database == null || openableTreeIndex == null) return;
      _openLocalDatabaseTree(
        ref,
        database,
        title: '${database.name} Tree',
        sourceLabel: databaseTitle,
      );
    }

    void rebuildDatabaseTree() {
      final database = selectedDatabase;
      if (database == null) return;
      ref
          .read(localChessLibraryProvider.notifier)
          .rebuildOpeningTree(database.path);
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            pasteIntoLocalDatabase,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            pasteIntoLocalDatabase,
      },
      child: Focus(
        autofocus: true,
        child: FTheme(
          data: FThemes.zinc.dark,
          child: Container(
            color: kBackgroundColor,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LocalHeader(
                  source: source,
                  node: node,
                  onOpenFolder: pickFolder,
                  onOpenFiles: pickFiles,
                  onRefresh: () {
                    if (onRefreshOverride != null) {
                      unawaited(onRefreshOverride!());
                      return;
                    }
                    unawaited(
                      ref.read(localChessLibraryProvider.notifier).refresh(),
                    );
                  },
                  onSave: filtered.isEmpty ? null : saveVisible,
                  treeBuildProgress: treeBuildProgress,
                  onOpenTree:
                      openableTreeIndex == null ? null : openDatabaseTree,
                  onBuildTree:
                      selectedDatabase == null || openableTreeIndex != null
                          ? null
                          : rebuildDatabaseTree,
                  onSelectPath: selectLocalPath,
                ),
                if (!isBrowsingFolder)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: kDividerColor.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: DesktopSearchField(
                              controller: searchController,
                              hintText:
                                  'Search this database — players, events, openings, ECO',
                              onChanged: (value) => query.value = value,
                              onClear: () => query.value = '',
                            ),
                          ),
                          const SizedBox(width: 8),
                          DesktopGameFilterButton(
                            key: const ValueKey<String>(
                              'local-chess-files-filter-button',
                            ),
                            filter: gameFilter.value.base,
                            // Include player-outcome (Overview W/D/L handoff)
                            // so the badge reflects filters not stored on base.
                            activeCountOverride:
                                gameFilter.value.activeFilterCount,
                            onPress: () async {
                              final next = await showDesktopGameFilterDialog(
                                context: context,
                                currentFilter: gameFilter.value.base,
                                showFormatFilter: true,
                              );
                              if (next == null || !context.mounted) return;
                              final merged = gameFilter.value.applyingDialog(
                                next,
                              );
                              gameFilter.value = merged;
                              onFilterChanged?.call(merged);
                            },
                          ),
                          if (gameFilter.value.hasActiveFilters) ...[
                            const SizedBox(width: 6),
                            ClearDesktopGameFiltersButton(
                              key: const ValueKey<String>(
                                'local-chess-files-clear-filters',
                              ),
                              onPress: () {
                                final cleared = LocalChessGameFilter();
                                gameFilter.value = cleared;
                                onFilterChanged?.call(cleared);
                              },
                            ),
                          ],
                          const SizedBox(width: 8),
                          _LocalCountPill(
                            label: _localDatabaseCountLabel(
                              loadedCount: filtered.length,
                              totalFilteredCount: totalFilteredCount,
                              databaseEntryCount: databaseEntryCount,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (isBrowsingFolder && node.children.isNotEmpty)
                  _LocalChildrenStrip(
                    folder: node,
                    selectedPath: selectedPath,
                    onSelect: selectLocalPath,
                  ),
                Expanded(
                  child:
                      isBrowsingFolder
                          ? _LocalFolderBrowseState(folder: node)
                          : databaseEntryCount == 0
                          ? _LocalNodeEmpty(node: node)
                          : filtered.isEmpty && isLoadingDatabasePage
                          ? const _LocalLoading()
                          : filtered.isEmpty
                          ? _LocalEmpty(
                            icon: Icons.search_off_rounded,
                            title: 'No local entries match "$query"',
                            message:
                                'Try another player, event, opening, or file.',
                            onOpenFolder: pickFolder,
                            onOpenFiles: pickFiles,
                          )
                          : _LocalGamesTable(
                            databaseTitle: databaseTitle,
                            database: selectedDatabase,
                            games: filtered,
                            databaseGames: boardContextGames,
                            sort: sort.value,
                            onSortChange: (next) => sort.value = next,
                            onRefresh: onRefreshOverride,
                            onSelectPath: onSelectPath,
                            loadedCount: filtered.length,
                            totalCount: totalFilteredCount,
                            hasMore: hasMoreDatabaseRows,
                            isLoadingMore: isLoadingDatabasePage,
                            onLoadMore:
                                hasMoreDatabaseRows
                                    ? () {
                                      databasePageWindow
                                          .value = _LocalDatabasePageWindow(
                                        databaseQueryKey,
                                        databaseRows?.nextPageNumber ?? 0,
                                      );
                                    }
                                    : null,
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

class _LocalHeader extends StatelessWidget {
  const _LocalHeader({
    required this.source,
    required this.node,
    required this.onOpenFolder,
    required this.onOpenFiles,
    required this.onRefresh,
    required this.onSave,
    required this.treeBuildProgress,
    required this.onOpenTree,
    required this.onBuildTree,
    required this.onSelectPath,
  });

  final LocalChessSource source;
  final LocalChessNode node;
  final VoidCallback onOpenFolder;
  final VoidCallback onOpenFiles;
  final VoidCallback onRefresh;
  final VoidCallback? onSave;
  final LocalChessTreeBuildProgress? treeBuildProgress;
  final VoidCallback? onOpenTree;
  final VoidCallback? onBuildTree;
  final ValueChanged<String> onSelectPath;

  @override
  Widget build(BuildContext context) {
    final selectedDatabase = selectedLocalChessDatabaseFile(node);
    final isDatabaseView = selectedDatabase != null;
    final (gameCount, fileCount, unsupportedCount) = switch (node) {
      LocalChessFolderNode(
        :final gameCount,
        :final fileCount,
        :final unsupportedCount,
      ) =>
        (gameCount, fileCount, unsupportedCount),
      LocalChessFileNode(:final gameCount, :final isPlayable) => (
        gameCount,
        1,
        isPlayable ? 0 : 1,
      ),
      _ => (0, 0, 0),
    };
    late final String countLabel;
    if (selectedDatabase == null) {
      countLabel = '$fileCount files · ${localChessEntryCountLabel(gameCount)}';
    } else {
      final entryCountLabel = localChessEntryCountLabel(
        selectedDatabase.gameCount,
      );
      final treeIndex = selectedDatabase.openingTreeIndex;
      final treeProgress = treeBuildProgress;
      if (treeProgress?.isActive == true) {
        countLabel = '$entryCountLabel · tree ${treeProgress!.percent}%';
      } else if (treeProgress?.phase == LocalChessTreeBuildPhase.failed) {
        countLabel = '$entryCountLabel · tree rebuild failed';
      } else {
        countLabel =
            treeIndex != null && treeIndex.positionCount > 0
                ? '$entryCountLabel · ${treeIndex.positionCount} indexed positions'
                : entryCountLabel;
      }
    }
    final meta =
        '$countLabel${unsupportedCount == 0 ? '' : ' · $unsupportedCount recognized only'}';
    return LibraryChromeBar(
      icon: _iconFor(node),
      title: node.name.isEmpty ? source.label : node.name,
      meta: meta,
      badge:
          isDatabaseView
              ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: kBlack3Color.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: kDividerColor.withValues(alpha: 0.85),
                  ),
                ),
                child: const Text(
                  'Local',
                  style: TextStyle(
                    color: kWhiteColor70,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    height: 1,
                  ),
                ),
              )
              : null,
      bottom:
          isDatabaseView
              ? null
              : _Breadcrumb(
                source: source,
                node: node,
                onSelectPath: onSelectPath,
              ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isDatabaseView) ...[
            _HeaderAction(
              tooltip: 'Open another local folder',
              icon: Icons.folder_open_outlined,
              onPress: onOpenFolder,
            ),
            const SizedBox(width: 2),
            _HeaderAction(
              tooltip: 'Open local chess files',
              icon: Icons.file_open_outlined,
              onPress: onOpenFiles,
            ),
            const SizedBox(width: 2),
            _HeaderAction(
              tooltip: 'Rescan this local source',
              icon: Icons.refresh_rounded,
              onPress: onRefresh,
            ),
            const SizedBox(width: 6),
          ],
          if (isDatabaseView) ...[
            LocalTreeActionButton(
              progress: treeBuildProgress,
              onOpen: onOpenTree,
              onBuild: onBuildTree,
            ),
            const SizedBox(width: 6),
          ],
          DesktopToolbarPillButton(
            label: 'Save to cloud',
            icon: Icons.library_add_outlined,
            onPress: onSave,
            tone: DesktopToolbarPillTone.primary,
            tooltip:
                onSave == null
                    ? 'No parsed local entries here'
                    : 'Save visible local entries to your cloud library',
          ),
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.tooltip,
    required this.icon,
    required this.onPress,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: tooltip,
      child: FButton.icon(onPress: onPress, child: Icon(icon, size: 16)),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.source,
    required this.node,
    required this.onSelectPath,
  });

  final LocalChessSource source;
  final LocalChessNode node;
  final ValueChanged<String> onSelectPath;

  @override
  Widget build(BuildContext context) {
    final nodes = source.breadcrumbNodesForPath(node.path);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          if (i > 0)
            const Icon(
              Icons.chevron_right_rounded,
              size: 13,
              color: kLightGreyColor,
            ),
          _BreadcrumbSegment(
            label: i == 0 ? source.label : nodes[i].name,
            isCurrent: i == nodes.length - 1,
            onPress: () => onSelectPath(nodes[i].path),
          ),
        ],
      ],
    );
  }
}

class _BreadcrumbSegment extends StatelessWidget {
  const _BreadcrumbSegment({
    required this.label,
    required this.isCurrent,
    required this.onPress,
  });

  final String label;
  final bool isCurrent;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );

    if (isCurrent) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: DefaultTextStyle.merge(
          style: const TextStyle(
            color: kWhiteColor70,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          child: text,
        ),
      );
    }

    return FButton(
      style: _breadcrumbButtonStyle(),
      mainAxisSize: MainAxisSize.min,
      onPress: onPress,
      child: text,
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _breadcrumbButtonStyle() {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(5),
        ),
        WidgetState.any: BoxDecoration(borderRadius: BorderRadius.circular(5)),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            textStyle: FWidgetStateMap({
              WidgetState.hovered | WidgetState.pressed: const TextStyle(
                color: kWhiteColor,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              WidgetState.any: const TextStyle(
                color: kLightGreyColor,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            }),
          ),
    ),
  );
}

class _LocalCountPill extends StatelessWidget {
  const _LocalCountPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _LocalChildrenStrip extends StatelessWidget {
  const _LocalChildrenStrip({
    required this.folder,
    required this.selectedPath,
    required this.onSelect,
  });

  final LocalChessFolderNode folder;
  final String selectedPath;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        physics: const DesktopScrollPhysics(),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
        itemCount: folder.children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final child = folder.children[i];
          return _LocalChildCard(
            node: child,
            selected: child.path == selectedPath,
            onTap: () => onSelect(child.path),
          );
        },
      ),
    );
  }
}

class _LocalChildCard extends StatelessWidget {
  const _LocalChildCard({
    required this.node,
    required this.selected,
    required this.onTap,
  });

  final LocalChessNode node;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final meta = switch (node) {
      LocalChessFolderNode(:final fileCount, :final gameCount) =>
        '$fileCount files · ${localChessEntryCountLabel(gameCount)}',
      LocalChessFileNode(
        status: LocalChessFileStatus.parsed,
        :final gameCount,
      ) =>
        localChessEntryCountLabel(gameCount),
      LocalChessFileNode(:final message) => message ?? 'recognized only',
      _ => '',
    };
    return SizedBox(
      width: 220,
      child: FButton(
        style: _localChildCardButtonStyle(selected: selected),
        mainAxisSize: MainAxisSize.max,
        onPress: onTap,
        child: Row(
          children: [
            Icon(_iconFor(node), size: 18, color: kPrimaryColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    node.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kLightGreyColor,
                      fontSize: 11,
                      height: 1.25,
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

FBaseButtonStyle Function(FButtonStyle style) _localChildCardButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.55)
                    : kWhiteColor.withValues(alpha: 0.12),
          ),
        ),
        WidgetState.focused: BoxDecoration(
          color: kBlack3Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kPrimaryColor.withValues(alpha: 0.70)),
        ),
        WidgetState.any: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.45)
                    : kDividerColor,
          ),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(padding: const EdgeInsets.all(12)),
    ),
  );
}

enum _LocalGameRowAction { gameInfo, copyPgn, saveToCloud, delete }

class _LocalGamesTable extends HookConsumerWidget {
  const _LocalGamesTable({
    required this.databaseTitle,
    required this.database,
    required this.games,
    required this.databaseGames,
    required this.sort,
    required this.onSortChange,
    required this.onRefresh,
    required this.onSelectPath,
    required this.loadedCount,
    required this.totalCount,
    required this.hasMore,
    required this.isLoadingMore,
    required this.onLoadMore,
  });

  final String databaseTitle;
  final LocalChessFileNode? database;
  final List<LocalChessGame> games;
  final List<LocalChessGame> databaseGames;
  final _LocalGamesSortConfig sort;
  final ValueChanged<_LocalGamesSortConfig> onSortChange;
  final Future<void> Function()? onRefresh;
  final ValueChanged<String> onSelectPath;
  final int loadedCount;
  final int totalCount;
  final bool hasMore;
  final bool isLoadingMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useScrollController();
    final focusNode = useFocusNode(debugLabel: 'local-pgn-games-table');
    final lastScrollLoadRequest = useRef<int?>(null);
    final openableTreeIndex =
        database?.openingTreeIndex?.isUsable == true
            ? database!.openingTreeIndex
            : null;
    final selectedId = useState<String?>(null);
    final selectedIds = useState<Set<String>>(<String>{});
    final selectionAnchor = useState<int?>(null);
    final selectionExtent = useState<int?>(null);
    final visibleIds = useMemoized(
      () => games.map((game) => game.id).toList(growable: false),
      [games],
    );
    final idToIndex = useMemoized(
      () => <String, int>{
        for (var i = 0; i < games.length; i++) games[i].id: i,
      },
      [games],
    );
    final clampedSelectedIds = _clampLocalSelection(
      selectedIds.value,
      visibleIds,
    );
    final effectiveSelectedIds =
        clampedSelectedIds.isNotEmpty
            ? clampedSelectedIds
            : selectedId.value == null
            ? const <String>{}
            : <String>{selectedId.value!};

    List<LocalChessGame> currentSelectedGames() {
      return _localGamesForSelection(
        games: games,
        idToIndex: idToIndex,
        selectedIds: effectiveSelectedIds,
        selectedId: selectedId.value,
      );
    }

    useEffect(() {
      if (games.isEmpty) {
        selectedId.value = null;
        selectedIds.value = <String>{};
        selectionAnchor.value = null;
        selectionExtent.value = null;
      } else if (selectedId.value != null &&
          !visibleIds.contains(selectedId.value)) {
        selectedId.value = null;
        selectedIds.value = clampedSelectedIds;
        selectionAnchor.value = null;
        selectionExtent.value = null;
      } else if (clampedSelectedIds.length != selectedIds.value.length) {
        selectedIds.value = clampedSelectedIds;
      }
      return null;
    }, [games]);

    useEffect(() {
      lastScrollLoadRequest.value = null;
      return null;
    }, [games.length, hasMore, isLoadingMore]);

    useEffect(() {
      void maybeLoadMore() {
        if (!hasMore || isLoadingMore || onLoadMore == null) return;
        if (!controller.hasClients) return;
        final position = controller.position;
        if (!position.hasContentDimensions) return;
        if (position.extentAfter > _kLocalDatabaseScrollLoadMoreThreshold) {
          return;
        }
        if (lastScrollLoadRequest.value == games.length) return;
        lastScrollLoadRequest.value = games.length;
        onLoadMore!();
      }

      controller.addListener(maybeLoadMore);
      WidgetsBinding.instance.addPostFrameCallback((_) => maybeLoadMore());
      return () => controller.removeListener(maybeLoadMore);
    }, [controller, games.length, hasMore, isLoadingMore, onLoadMore]);

    void scrollToIndex(int index) {
      if (!controller.hasClients) return;
      final position = controller.position;
      if (!position.hasViewportDimension) return;
      final viewport = position.viewportDimension;
      final pixels = position.pixels;
      final rowTop = index * _kLocalGameRowHeight;
      final rowBottom = rowTop + _kLocalGameRowHeight;
      double? target;
      if (rowTop < pixels) {
        target = rowTop;
      } else if (rowBottom > pixels + viewport) {
        target = rowBottom - viewport;
      }
      if (target == null) return;
      final clamped = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((clamped - pixels).abs() < 0.5) return;
      controller.animateTo(
        clamped.toDouble(),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }

    void selectIndex(int index, {bool toggle = false, bool range = false}) {
      if (games.isEmpty) return;
      final next = index.clamp(0, games.length - 1).toInt();
      final id = games[next].id;
      if (range) {
        final anchor = selectionAnchor.value ?? next;
        final start = anchor < next ? anchor : next;
        final end = anchor < next ? next : anchor;
        selectedIds.value = {for (var i = start; i <= end; i++) games[i].id};
        selectedId.value = id;
        selectionExtent.value = next;
      } else if (toggle) {
        final updated = Set<String>.of(clampedSelectedIds);
        if (!updated.add(id)) updated.remove(id);
        selectedIds.value = updated;
        selectedId.value = id;
        selectionAnchor.value = next;
        selectionExtent.value = next;
      } else {
        selectedId.value = id;
        selectedIds.value = <String>{};
        selectionAnchor.value = next;
        selectionExtent.value = next;
      }
      scrollToIndex(next);
      focusNode.requestFocus();
    }

    bool moveSelection(int delta, {bool range = false}) {
      if (games.isEmpty) return false;
      final current =
          selectionExtent.value ?? idToIndex[selectedId.value ?? ''] ?? -1;
      final next =
          (current < 0 ? 0 : current + delta)
              .clamp(0, games.length - 1)
              .toInt();
      selectIndex(next, range: range);
      return true;
    }

    bool selectBoundary(int index, {bool range = false}) {
      if (games.isEmpty) return false;
      selectIndex(index, range: range);
      return true;
    }

    bool openSelectedGame() {
      if (games.isEmpty) return false;
      final index = idToIndex[selectedId.value ?? ''] ?? -1;
      final game = games[index < 0 ? 0 : index];
      _openLocalGame(
        ref,
        game,
        sourceLabel: databaseTitle,
        databaseGames: databaseGames,
        localOpeningTreeIndex: openableTreeIndex,
      );
      return true;
    }

    KeyEventResult handleTableKey(FocusNode node, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final pressed = HardwareKeyboard.instance.logicalKeysPressed;
      final hasShortcutModifier =
          pressed.contains(LogicalKeyboardKey.control) ||
          pressed.contains(LogicalKeyboardKey.controlLeft) ||
          pressed.contains(LogicalKeyboardKey.controlRight) ||
          pressed.contains(LogicalKeyboardKey.meta) ||
          pressed.contains(LogicalKeyboardKey.metaLeft) ||
          pressed.contains(LogicalKeyboardKey.metaRight) ||
          pressed.contains(LogicalKeyboardKey.alt) ||
          pressed.contains(LogicalKeyboardKey.altLeft) ||
          pressed.contains(LogicalKeyboardKey.altRight);
      if (hasShortcutModifier) return KeyEventResult.ignored;
      final shift =
          pressed.contains(LogicalKeyboardKey.shift) ||
          pressed.contains(LogicalKeyboardKey.shiftLeft) ||
          pressed.contains(LogicalKeyboardKey.shiftRight);
      final handled = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowDown => moveSelection(1, range: shift),
        LogicalKeyboardKey.arrowUp => moveSelection(-1, range: shift),
        LogicalKeyboardKey.home => selectBoundary(0, range: shift),
        LogicalKeyboardKey.end => selectBoundary(
          games.length - 1,
          range: shift,
        ),
        LogicalKeyboardKey.enter ||
        LogicalKeyboardKey.numpadEnter when !shift => openSelectedGame(),
        _ => false,
      };
      return handled ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    Future<void> copySelectedGames({List<LocalChessGame>? scope}) async {
      final gamesToCopy = scope ?? currentSelectedGames();
      final parts = gamesToCopy
          .map((game) => game.rawPgn.trim())
          .where(
            (pgn) => pgn.isNotEmpty && appendableLocalPgnParts(pgn).isNotEmpty,
          )
          .toList(growable: false);
      if (parts.isEmpty) {
        showDesktopToast(
          context,
          'No selected PGN with moves available to copy.',
          error: true,
        );
        return;
      }
      await Clipboard.setData(ClipboardData(text: '${parts.join('\n\n')}\n'));
      if (!context.mounted) return;
      final skipped = gamesToCopy.length - parts.length;
      showDesktopToast(
        context,
        skipped == 0
            ? 'Copied ${parts.length} ${parts.length == 1 ? 'game' : 'games'} as PGN.'
            : 'Copied ${parts.length} ${parts.length == 1 ? 'game' : 'games'}; $skipped had no PGN moves available.',
      );
    }

    Future<void> saveSelectedGames({List<LocalChessGame>? scope}) async {
      final gamesToSave = scope ?? currentSelectedGames();
      if (gamesToSave.isEmpty) return;
      final hydrated = await compute(_hydrateLocalGamesForSave, gamesToSave);
      if (!context.mounted) return;
      final outcome = await showLibrarySaveToFolderDialog(
        context: context,
        ref: ref,
        games: hydrated,
        sourceLabel: databaseTitle,
        destinationMode: LibrarySaveDestinationMode.cloudOnly,
      );
      if (outcome == null || !outcome.didSave || !context.mounted) return;
      showDesktopToast(context, outcome.toToastMessage());
    }

    Future<void> deleteSelectedGames({List<LocalChessGame>? scope}) async {
      final target = database;
      final gamesToDelete = scope ?? currentSelectedGames();
      if (target == null || gamesToDelete.isEmpty) return;
      final confirmed = await showLocalPgnDeleteGamesConfirmation(
        context,
        count: gamesToDelete.length,
        databaseName: target.name,
      );
      if (!confirmed) return;
      try {
        final removed = await removeLocalPgnGamesFromDatabaseFile(
          repository: ref.read(localChessDatabaseRepositoryProvider),
          filePath: target.path,
          indexesInFile: gamesToDelete.map((game) => game.indexInFile).toSet(),
        );
        if (!context.mounted) return;
        if (onRefresh != null) {
          await onRefresh!();
        } else {
          final notifier = ref.read(localChessLibraryProvider.notifier);
          final refreshed = await notifier.refreshFile(target.path);
          if (!refreshed) {
            await notifier.refresh();
          }
        }
        if (!context.mounted) return;
        ref.read(localChessLibraryProvider.notifier).selectPath(target.path);
        onSelectPath(target.path);
        selectedIds.value = <String>{};
        selectedId.value = null;
        showDesktopToast(
          context,
          'Deleted $removed ${removed == 1 ? 'game' : 'games'} from ${target.name}.',
        );
      } catch (e) {
        if (!context.mounted) return;
        showDesktopToast(
          context,
          'Could not delete from local PGN: $e',
          error: true,
        );
      }
    }

    Future<void> openRowMenu(LocalChessGame game, Offset position) async {
      final rowIndex = idToIndex[game.id] ?? -1;
      if (rowIndex < 0) return;
      final rowScope =
          effectiveSelectedIds.contains(game.id)
              ? currentSelectedGames()
              : <LocalChessGame>[game];
      if (!effectiveSelectedIds.contains(game.id)) {
        selectIndex(rowIndex);
      }
      final action = await showDesktopContextMenu<_LocalGameRowAction>(
        context: context,
        position: position,
        width: 220,
        entries: [
          const DesktopContextMenuItem(
            value: _LocalGameRowAction.gameInfo,
            icon: Icons.info_outline_rounded,
            label: 'Game info',
          ),
          const DesktopContextMenuItem(
            value: _LocalGameRowAction.copyPgn,
            icon: Icons.content_copy_rounded,
            label: 'Copy PGN',
          ),
          const DesktopContextMenuItem(
            value: _LocalGameRowAction.saveToCloud,
            icon: Icons.library_add_outlined,
            label: 'Save To Cloud',
          ),
          const DesktopContextMenuDivider(),
          DesktopContextMenuItem(
            value: _LocalGameRowAction.delete,
            icon: Icons.delete_outline_rounded,
            label: 'Delete game',
            destructive: true,
            enabled: database != null,
          ),
        ],
      );
      if (action == null || !context.mounted) return;
      switch (action) {
        case _LocalGameRowAction.gameInfo:
          unawaited(showLocalGameInfoDialog(context, game));
        case _LocalGameRowAction.copyPgn:
          unawaited(copySelectedGames(scope: rowScope));
        case _LocalGameRowAction.saveToCloud:
          unawaited(saveSelectedGames(scope: rowScope));
        case _LocalGameRowAction.delete:
          unawaited(deleteSelectedGames(scope: rowScope));
      }
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            () => unawaited(copySelectedGames()),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            () => unawaited(copySelectedGames()),
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () {
          selectedIds.value = visibleIds.toSet();
          if (games.isNotEmpty) selectedId.value = games.last.id;
        },
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () {
          selectedIds.value = visibleIds.toSet();
          if (games.isNotEmpty) selectedId.value = games.last.id;
        },
        const SingleActivator(LogicalKeyboardKey.delete):
            () => unawaited(deleteSelectedGames()),
        const SingleActivator(LogicalKeyboardKey.backspace):
            () => unawaited(deleteSelectedGames()),
      },
      child: Focus(
        focusNode: focusNode,
        canRequestFocus: true,
        onKeyEvent: handleTableKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: kBlack2Color,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kDividerColor),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      _LocalGamesHeaderRow(
                        sort: sort,
                        onSortChange: onSortChange,
                      ),
                      const Divider(height: 1, color: kDividerColor),
                      Expanded(
                        child: Scrollbar(
                          controller: controller,
                          thumbVisibility: false,
                          child: ListView.builder(
                            key: const ValueKey('local-games-table-list'),
                            controller: controller,
                            physics: const DesktopScrollPhysics(),
                            itemExtent: _kLocalGameRowHeight,
                            itemCount: games.length,
                            itemBuilder: (context, index) {
                              final game = games[index];
                              return _LocalGamesDataRow(
                                key: ValueKey('local-game-table-${game.id}'),
                                index: index,
                                game: game,
                                selected: effectiveSelectedIds.contains(
                                  game.id,
                                ),
                                onTapDown: (details) {
                                  final keys =
                                      HardwareKeyboard
                                          .instance
                                          .logicalKeysPressed;
                                  selectIndex(
                                    index,
                                    toggle:
                                        keys.contains(
                                          LogicalKeyboardKey.controlLeft,
                                        ) ||
                                        keys.contains(
                                          LogicalKeyboardKey.controlRight,
                                        ) ||
                                        keys.contains(
                                          LogicalKeyboardKey.metaLeft,
                                        ) ||
                                        keys.contains(
                                          LogicalKeyboardKey.metaRight,
                                        ),
                                    range:
                                        keys.contains(
                                          LogicalKeyboardKey.shiftLeft,
                                        ) ||
                                        keys.contains(
                                          LogicalKeyboardKey.shiftRight,
                                        ),
                                  );
                                },
                                onDoubleTap: () {
                                  selectIndex(index);
                                  _openLocalGame(
                                    ref,
                                    game,
                                    sourceLabel: databaseTitle,
                                    databaseGames: databaseGames,
                                    localOpeningTreeIndex: openableTreeIndex,
                                  );
                                },
                                onSecondaryTapUp:
                                    (details) => unawaited(
                                      openRowMenu(game, details.globalPosition),
                                    ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (hasMore || isLoadingMore) ...[
                const SizedBox(height: 10),
                _LocalGamesPaginationFooter(
                  loadedCount: loadedCount,
                  totalCount: totalCount,
                  isLoading: isLoadingMore,
                  onLoadMore: onLoadMore,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

const double _kLocalGameRowHeight = 44;
const int _kLocalDatabaseGameQueryPageSize = 200;
const double _kLocalDatabaseScrollLoadMoreThreshold = 420;
const String _kLocalDatabaseTreeStartingFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

class _LocalDatabasePageWindow {
  const _LocalDatabasePageWindow(this.queryKey, this.pageNumber);

  final String queryKey;
  final int pageNumber;
}

class _LoadedLocalDatabasePages {
  const _LoadedLocalDatabasePages({
    required this.queryKey,
    required this.games,
    required this.totalCount,
    required this.nextPageNumber,
    required this.pageSize,
  });

  const _LoadedLocalDatabasePages.empty()
    : queryKey = '',
      games = const <LocalChessGame>[],
      totalCount = 0,
      nextPageNumber = 0,
      pageSize = _kLocalDatabaseGameQueryPageSize;

  final String queryKey;
  final List<LocalChessGame> games;
  final int totalCount;
  final int nextPageNumber;
  final int pageSize;

  bool get hasRows => games.isNotEmpty;

  bool get hasMore => nextPageNumber * pageSize < totalCount;

  _LoadedLocalDatabasePages merge({
    required String queryKey,
    required LocalChessGameQueryPage page,
  }) {
    if (page.pageNumber == 0 || this.queryKey != queryKey) {
      return _LoadedLocalDatabasePages(
        queryKey: queryKey,
        games: List<LocalChessGame>.unmodifiable(page.games),
        totalCount: page.totalCount,
        nextPageNumber: page.pageNumber + 1,
        pageSize: page.pageSize,
      );
    }
    if (page.pageNumber < nextPageNumber) return this;
    if (page.pageNumber > nextPageNumber) {
      return _LoadedLocalDatabasePages(
        queryKey: queryKey,
        games: List<LocalChessGame>.unmodifiable(page.games),
        totalCount: page.totalCount,
        nextPageNumber: page.pageNumber + 1,
        pageSize: page.pageSize,
      );
    }
    return _LoadedLocalDatabasePages(
      queryKey: queryKey,
      games: List<LocalChessGame>.unmodifiable(<LocalChessGame>[
        ...games,
        ...page.games,
      ]),
      totalCount: page.totalCount,
      nextPageNumber: page.pageNumber + 1,
      pageSize: page.pageSize,
    );
  }
}

_LoadedLocalDatabasePages? _visibleLocalDatabaseRows({
  required String queryKey,
  required _LoadedLocalDatabasePages loaded,
  required LocalChessGameQueryPage? livePage,
}) {
  final hasLoadedRows = loaded.queryKey == queryKey && loaded.hasRows;
  if (livePage == null) return hasLoadedRows ? loaded : null;
  if (livePage.pageNumber == 0 || !hasLoadedRows) {
    return _LoadedLocalDatabasePages(
      queryKey: queryKey,
      games: List<LocalChessGame>.unmodifiable(livePage.games),
      totalCount: livePage.totalCount,
      nextPageNumber: livePage.pageNumber + 1,
      pageSize: livePage.pageSize,
    );
  }
  if (livePage.pageNumber < loaded.nextPageNumber) return loaded;
  if (livePage.pageNumber > loaded.nextPageNumber) {
    return _LoadedLocalDatabasePages(
      queryKey: queryKey,
      games: List<LocalChessGame>.unmodifiable(livePage.games),
      totalCount: livePage.totalCount,
      nextPageNumber: livePage.pageNumber + 1,
      pageSize: livePage.pageSize,
    );
  }
  return _LoadedLocalDatabasePages(
    queryKey: queryKey,
    games: List<LocalChessGame>.unmodifiable(<LocalChessGame>[
      ...loaded.games,
      ...livePage.games,
    ]),
    totalCount: livePage.totalCount,
    nextPageNumber: livePage.pageNumber + 1,
    pageSize: livePage.pageSize,
  );
}

String _localDatabaseCountLabel({
  required int loadedCount,
  required int totalFilteredCount,
  required int databaseEntryCount,
}) {
  final entryLabel = databaseEntryCount == 1 ? 'entry' : 'entries';
  if (loadedCount < totalFilteredCount) {
    return '$loadedCount / $totalFilteredCount loaded';
  }
  return '$totalFilteredCount / $databaseEntryCount $entryLabel';
}

enum _LocalGamesSortKey {
  originalOrder,
  white,
  whiteElo,
  black,
  blackElo,
  result,
  eco,
  opening,
  event,
  date,
}

enum _LocalGamesSortDir { asc, desc }

class _LocalGamesSortConfig {
  const _LocalGamesSortConfig(this.key, this.dir);

  final _LocalGamesSortKey key;
  final _LocalGamesSortDir dir;
}

Future<LocalChessGameQueryPage?> _queryLocalDatabaseGamesPage(
  LocalChessDatabaseRepository repository, {
  required String databasePath,
  required String search,
  required _LocalGamesSortConfig sort,
  LocalChessGameFilter? filter,
  String? playerFideId,
  List<String> playerAliases = const <String>[],
  required int pageNumber,
  required int pageSize,
}) async {
  try {
    return await repository.localDatabaseGamesPage(
      databasePath: databasePath,
      search: search,
      sortBy: _localRepositorySortField(sort.key),
      sortDirection: _localRepositorySortDirection(sort.dir),
      filter: filter,
      playerFideId: playerFideId,
      playerAliases: playerAliases,
      pageNumber: pageNumber,
      pageSize: pageSize,
    );
  } on Object {
    return null;
  }
}

class _LocalGamesPaginationFooter extends StatelessWidget {
  const _LocalGamesPaginationFooter({
    required this.loadedCount,
    required this.totalCount,
    required this.isLoading,
    required this.onLoadMore,
  });

  final int loadedCount;
  final int totalCount;
  final bool isLoading;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$loadedCount of $totalCount loaded',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          FButton(
            style: FButtonStyle.outline(),
            onPress: isLoading ? null : onLoadMore,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isLoading) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 7),
                ] else ...[
                  const Icon(Icons.expand_more_rounded, size: 15),
                  const SizedBox(width: 7),
                ],
                const Text('Load more'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

LocalChessGameSortField _localRepositorySortField(_LocalGamesSortKey key) {
  return switch (key) {
    _LocalGamesSortKey.originalOrder => LocalChessGameSortField.originalOrder,
    _LocalGamesSortKey.white => LocalChessGameSortField.white,
    _LocalGamesSortKey.whiteElo => LocalChessGameSortField.whiteElo,
    _LocalGamesSortKey.black => LocalChessGameSortField.black,
    _LocalGamesSortKey.blackElo => LocalChessGameSortField.blackElo,
    _LocalGamesSortKey.result => LocalChessGameSortField.result,
    _LocalGamesSortKey.eco => LocalChessGameSortField.eco,
    _LocalGamesSortKey.opening => LocalChessGameSortField.opening,
    _LocalGamesSortKey.event => LocalChessGameSortField.event,
    _LocalGamesSortKey.date => LocalChessGameSortField.date,
  };
}

LocalChessGameSortDirection _localRepositorySortDirection(
  _LocalGamesSortDir dir,
) {
  return switch (dir) {
    _LocalGamesSortDir.asc => LocalChessGameSortDirection.asc,
    _LocalGamesSortDir.desc => LocalChessGameSortDirection.desc,
  };
}

void _sortLocalGames(List<LocalChessGame> games, _LocalGamesSortConfig sort) {
  games.sort((a, b) {
    final primary = _compareLocalGames(a, b, sort);
    if (primary != 0) return primary;
    return a.indexInFile.compareTo(b.indexInFile);
  });
}

int _compareLocalGames(
  LocalChessGame a,
  LocalChessGame b,
  _LocalGamesSortConfig sort,
) {
  final amd = a.game.metadata;
  final bmd = b.game.metadata;
  final dir = sort.dir;
  return switch (sort.key) {
    _LocalGamesSortKey.originalOrder => _applyLocalSortDir(
      a.indexInFile.compareTo(b.indexInFile),
      dir,
    ),
    _LocalGamesSortKey.white => _compareLocalText(
      _playerName(amd, 'White'),
      _playerName(bmd, 'White'),
      dir,
    ),
    _LocalGamesSortKey.whiteElo => _compareLocalInt(
      _rating(amd, 'WhiteElo'),
      _rating(bmd, 'WhiteElo'),
      dir,
    ),
    _LocalGamesSortKey.black => _compareLocalText(
      _playerName(amd, 'Black'),
      _playerName(bmd, 'Black'),
      dir,
    ),
    _LocalGamesSortKey.blackElo => _compareLocalInt(
      _rating(amd, 'BlackElo'),
      _rating(bmd, 'BlackElo'),
      dir,
    ),
    _LocalGamesSortKey.result => _compareLocalText(
      _result(amd),
      _result(bmd),
      dir,
    ),
    _LocalGamesSortKey.eco => _compareLocalText(
      _meta(amd, 'ECO'),
      _meta(bmd, 'ECO'),
      dir,
    ),
    _LocalGamesSortKey.opening => _compareLocalText(
      _opening(amd),
      _opening(bmd),
      dir,
    ),
    _LocalGamesSortKey.event => _compareLocalText(
      _event(amd),
      _event(bmd),
      dir,
    ),
    _LocalGamesSortKey.date => _compareLocalText(_date(amd), _date(bmd), dir),
  };
}

int _compareLocalInt(int? a, int? b, _LocalGamesSortDir dir) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return _applyLocalSortDir(a.compareTo(b), dir);
}

int _compareLocalText(String a, String b, _LocalGamesSortDir dir) {
  final left = a.trim();
  final right = b.trim();
  final leftMissing = left.isEmpty || left == '?' || left == '-';
  final rightMissing = right.isEmpty || right == '?' || right == '-';
  if (leftMissing && rightMissing) return 0;
  if (leftMissing) return 1;
  if (rightMissing) return -1;
  return _applyLocalSortDir(
    left.toLowerCase().compareTo(right.toLowerCase()),
    dir,
  );
}

int _applyLocalSortDir(int comparison, _LocalGamesSortDir dir) {
  return dir == _LocalGamesSortDir.asc ? comparison : -comparison;
}

Set<String> _clampLocalSelection(Set<String> selectedIds, List<String> rowIds) {
  if (selectedIds.isEmpty) return const <String>{};
  final visible = rowIds.toSet();
  return selectedIds.where(visible.contains).toSet();
}

List<LocalChessGame> _localGamesForSelection({
  required List<LocalChessGame> games,
  required Map<String, int> idToIndex,
  required Set<String> selectedIds,
  required String? selectedId,
}) {
  if (games.isEmpty) return const <LocalChessGame>[];
  if (selectedIds.isNotEmpty) {
    final selectedIndexes = <int>[];
    for (final id in selectedIds) {
      final index = idToIndex[id];
      if (index != null && index >= 0 && index < games.length) {
        selectedIndexes.add(index);
      }
    }
    selectedIndexes.sort();
    return selectedIndexes.map((index) => games[index]).toList(growable: false);
  }
  final index = idToIndex[selectedId ?? ''];
  if (index == null || index < 0 || index >= games.length) {
    return <LocalChessGame>[games.first];
  }
  return <LocalChessGame>[games[index]];
}

// Shared column geometry for the local database table — the header row and
// every data row must use identical widths/flexes/gaps so columns line up, and
// it matches the cloud/TWIC library tables' row shape.
const double _kLocalColNumber = 44;
const double _kLocalColElo = 56;
const double _kLocalColResult = 56;
const double _kLocalColEco = 62;
const double _kLocalColDate = 88;
const double _kLocalColGap = 12;

class _LocalGamesHeaderRow extends StatelessWidget {
  const _LocalGamesHeaderRow({required this.sort, required this.onSortChange});

  final _LocalGamesSortConfig sort;
  final ValueChanged<_LocalGamesSortConfig> onSortChange;

  @override
  Widget build(BuildContext context) {
    Widget header(
      String label,
      _LocalGamesSortKey key, {
      Alignment alignment = Alignment.centerLeft,
    }) {
      return _LocalHeaderCell(
        label,
        sortKey: key,
        sort: sort,
        alignment: alignment,
        onSortChange: onSortChange,
      );
    }

    return Container(
      color: kBlack3Color.withValues(alpha: 0.4),
      padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
      child: Row(
        children: [
          SizedBox(
            width: _kLocalColNumber,
            child: header(
              '#',
              _LocalGamesSortKey.originalOrder,
              alignment: Alignment.centerRight,
            ),
          ),
          const SizedBox(width: _kLocalColGap),
          Expanded(flex: 5, child: header('WHITE', _LocalGamesSortKey.white)),
          const SizedBox(width: _kLocalColGap),
          SizedBox(
            width: _kLocalColElo,
            child: header(
              'ELO W',
              _LocalGamesSortKey.whiteElo,
              alignment: Alignment.centerRight,
            ),
          ),
          const SizedBox(width: _kLocalColGap),
          SizedBox(
            width: _kLocalColResult,
            child: header(
              'RESULT',
              _LocalGamesSortKey.result,
              alignment: Alignment.center,
            ),
          ),
          const SizedBox(width: _kLocalColGap),
          Expanded(flex: 5, child: header('BLACK', _LocalGamesSortKey.black)),
          const SizedBox(width: _kLocalColGap),
          SizedBox(
            width: _kLocalColElo,
            child: header(
              'ELO B',
              _LocalGamesSortKey.blackElo,
              alignment: Alignment.centerRight,
            ),
          ),
          const SizedBox(width: _kLocalColGap),
          Expanded(flex: 4, child: header('EVENT', _LocalGamesSortKey.event)),
          const SizedBox(width: _kLocalColGap),
          SizedBox(
            width: _kLocalColEco,
            child: header('ECO', _LocalGamesSortKey.eco),
          ),
          const SizedBox(width: _kLocalColGap),
          Expanded(
            flex: 4,
            child: header('OPENING', _LocalGamesSortKey.opening),
          ),
          const SizedBox(width: _kLocalColGap),
          SizedBox(
            width: _kLocalColDate,
            child: header(
              'DATE',
              _LocalGamesSortKey.date,
              alignment: Alignment.centerRight,
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalHeaderCell extends StatelessWidget {
  const _LocalHeaderCell(
    this.label, {
    required this.sortKey,
    required this.sort,
    required this.onSortChange,
    this.alignment = Alignment.centerLeft,
  });

  final String label;
  final _LocalGamesSortKey sortKey;
  final _LocalGamesSortConfig sort;
  final ValueChanged<_LocalGamesSortConfig> onSortChange;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final active = sort.key == sortKey;
    final alignEnd = alignment == Alignment.centerRight;
    final center = alignment == Alignment.center;
    final nextDir =
        active && sort.dir == _LocalGamesSortDir.asc
            ? _LocalGamesSortDir.desc
            : _LocalGamesSortDir.asc;
    final arrow = switch (sort.dir) {
      _LocalGamesSortDir.asc => Icons.arrow_upward_rounded,
      _LocalGamesSortDir.desc => Icons.arrow_downward_rounded,
    };

    return DesktopTooltip(
      message: 'Sort by $label',
      hoverEnterDuration: const Duration(milliseconds: 450),
      child: DesktopTappable(
        hoverColor: kWhiteColor.withValues(alpha: 0.04),
        onPress: () => onSortChange(_LocalGamesSortConfig(sortKey, nextDir)),
        child: Align(
          alignment: alignment,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment:
                alignEnd
                    ? MainAxisAlignment.end
                    : center
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? kPrimaryColor : kLightGreyColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                active ? arrow : Icons.unfold_more_rounded,
                size: active ? 10 : 11,
                color:
                    active
                        ? kPrimaryColor
                        : kWhiteColor.withValues(alpha: 0.35),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalGamesDataRow extends StatefulWidget {
  const _LocalGamesDataRow({
    super.key,
    required this.index,
    required this.game,
    required this.selected,
    required this.onTapDown,
    required this.onDoubleTap,
    required this.onSecondaryTapUp,
  });

  final int index;
  final LocalChessGame game;
  final bool selected;
  final GestureTapDownCallback onTapDown;
  final VoidCallback onDoubleTap;
  final GestureTapUpCallback onSecondaryTapUp;

  @override
  State<_LocalGamesDataRow> createState() => _LocalGamesDataRowState();
}

class _LocalGamesDataRowState extends State<_LocalGamesDataRow>
    with DeferredPointerStateMixin<_LocalGamesDataRow> {
  bool _hovered = false;

  String _ratingText(int? value) =>
      value == null || value <= 0 ? '' : value.toString();

  @override
  Widget build(BuildContext context) {
    final md = widget.game.game.metadata;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
      onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onTapDown,
        onSecondaryTapUp: widget.onSecondaryTapUp,
        onDoubleTap: widget.onDoubleTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: librarySelectedRowDecoration(
            selected: widget.selected,
            hovered: _hovered,
          ),
          padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
          child: Row(
            children: [
              SizedBox(
                width: _kLocalColNumber,
                child: _LocalMonoRight('${widget.game.indexInFile + 1}'),
              ),
              const SizedBox(width: _kLocalColGap),
              Expanded(
                flex: 5,
                child: LocalGamePlayerCell(
                  metadata: md,
                  side: 'White',
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(width: _kLocalColGap),
              SizedBox(
                width: _kLocalColElo,
                child: LibraryTableRatingCell(
                  rating: _ratingText(_rating(md, 'WhiteElo')),
                ),
              ),
              const SizedBox(width: _kLocalColGap),
              SizedBox(
                width: _kLocalColResult,
                child: LibraryTableResultPill(result: _result(md)),
              ),
              const SizedBox(width: _kLocalColGap),
              Expanded(
                flex: 5,
                child: LocalGamePlayerCell(
                  metadata: md,
                  side: 'Black',
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(width: _kLocalColGap),
              SizedBox(
                width: _kLocalColElo,
                child: LibraryTableRatingCell(
                  rating: _ratingText(_rating(md, 'BlackElo')),
                ),
              ),
              const SizedBox(width: _kLocalColGap),
              Expanded(
                flex: 4,
                child: _LocalCellText(_event(md), color: kWhiteColor),
              ),
              const SizedBox(width: _kLocalColGap),
              SizedBox(
                width: _kLocalColEco,
                child: LibraryTableEcoCell(eco: _meta(md, 'ECO')),
              ),
              const SizedBox(width: _kLocalColGap),
              Expanded(
                flex: 4,
                child: _LocalCellText(_opening(md), color: kWhiteColor70),
              ),
              const SizedBox(width: _kLocalColGap),
              SizedBox(
                width: _kLocalColDate,
                child: _LocalMonoRight(_date(md)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Left-aligned single-line text cell (`—` when blank).
class _LocalCellText extends StatelessWidget {
  const _LocalCellText(this.value, {required this.color});

  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final display = value.trim();
    return Text(
      display.isEmpty || display == '?' ? '—' : display,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 12, height: 1.1),
    );
  }
}

/// Right-aligned tabular-figure text cell for the `#`, ELO and date columns.
class _LocalMonoRight extends StatelessWidget {
  const _LocalMonoRight(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final display = value.trim();
    return Text(
      display.isEmpty || display == '?' ? '—' : display,
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kLightGreyColor,
        fontSize: 11,
        height: 1.1,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

String _meta(Map<String, dynamic> md, String key) =>
    (md[key]?.toString().trim() ?? '');

String _playerName(Map<String, dynamic> md, String key) {
  final name = _meta(md, key);
  if (name.isEmpty || name == '?') return key;
  return name;
}

int? _rating(Map<String, dynamic> md, String key) {
  final value = int.tryParse(_meta(md, key));
  return value == null || value <= 0 ? null : value;
}

String _result(Map<String, dynamic> md) {
  final result = _meta(md, 'Result').replaceAll('½', '1/2');
  return result.isEmpty ? '*' : result;
}

String _opening(Map<String, dynamic> md) {
  final opening = _meta(md, 'Opening');
  if (opening.isNotEmpty && opening != '?') return opening;
  return _meta(md, 'Variation');
}

String _event(Map<String, dynamic> md) {
  final event = _meta(md, 'Event');
  return event.isEmpty || event == '?' ? _meta(md, 'Site') : event;
}

String _date(Map<String, dynamic> md) {
  final date = _meta(md, 'Date');
  if (date.isEmpty || date == '?') return '';
  return date;
}

class _LocalNodeEmpty extends StatelessWidget {
  const _LocalNodeEmpty({required this.node});

  final LocalChessNode node;

  @override
  Widget build(BuildContext context) {
    final message = switch (node) {
      LocalChessFolderNode(:final scanError) when scanError != null =>
        'Some files could not be read: $scanError',
      LocalChessFolderNode(:final fileCount) when fileCount == 0 =>
        'This folder has no recognized chess files. Drop or choose a folder '
            'that contains $localChessEmptyFolderFormatsMessage',
      LocalChessFolderNode() =>
        'This folder has recognized chess files, but no playable entries.',
      LocalChessFileNode(:final message) =>
        message ?? 'No playable entries were found in this file.',
      _ => 'No local chess entries were found here.',
    };
    return _LocalEmpty(
      icon: _iconFor(node),
      title: 'No playable entries',
      message: message,
    );
  }
}

class _LocalFolderBrowseState extends StatelessWidget {
  const _LocalFolderBrowseState({required this.folder});

  final LocalChessFolderNode folder;

  @override
  Widget build(BuildContext context) {
    final playableDatabases = folder.playableDatabaseCount;
    if (folder.fileCount == 0 || playableDatabases == 0) {
      return _LocalNodeEmpty(node: folder);
    }

    return _LocalEmpty(
      icon: Icons.account_tree_outlined,
      title: 'Choose a database',
      message:
          'This folder contains $playableDatabases playable '
          '${playableDatabases == 1 ? 'database' : 'databases'}. '
          'Select one from the folder tree or cards above.',
    );
  }
}

class _LocalEmpty extends StatelessWidget {
  const _LocalEmpty({
    required this.icon,
    required this.title,
    required this.message,
    this.onOpenFolder,
    this.onOpenFiles,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onOpenFolder;
  final VoidCallback? onOpenFiles;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kBlack2Color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: kPrimaryColor.withValues(alpha: 0.25),
                  ),
                ),
                child: Icon(icon, size: 28, color: kPrimaryColor),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              if (onOpenFolder != null || onOpenFiles != null) ...[
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (onOpenFolder != null)
                      DesktopToolbarPillButton(
                        label: 'Open folder',
                        icon: Icons.folder_open_outlined,
                        onPress: onOpenFolder,
                        tone: DesktopToolbarPillTone.primary,
                      ),
                    if (onOpenFolder != null && onOpenFiles != null)
                      const SizedBox(width: 8),
                    if (onOpenFiles != null)
                      DesktopToolbarPillButton(
                        label: 'Open files',
                        icon: Icons.file_open_outlined,
                        onPress: onOpenFiles,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalLoading extends StatelessWidget {
  const _LocalLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(kPrimaryColor),
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Scanning local chess files…',
            style: TextStyle(color: kWhiteColor70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// Mirrors the repository's SQL search semantics: every whitespace-separated
// term must match the file name, path, or some PGN header value.
bool _matches(LocalChessGame game, String query) {
  final terms = query.split(RegExp(r'\s+')).where((term) => term.isNotEmpty);
  for (final term in terms) {
    if (!_matchesTerm(game, term)) return false;
  }
  return true;
}

bool _matchesTerm(LocalChessGame game, String term) {
  if (game.fileName.toLowerCase().contains(term)) return true;
  if (game.sourceRelativePath.toLowerCase().contains(term)) return true;
  for (final value in game.game.metadata.values) {
    if (value is String && value.toLowerCase().contains(term)) return true;
  }
  return false;
}

Future<bool> showLocalPgnDeleteGamesConfirmation(
  BuildContext context, {
  required int count,
  required String databaseName,
}) async {
  final confirmed = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Delete local PGN games',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder:
        (ctx, _, _) => FTheme(
          data: FThemes.zinc.dark,
          child: Center(
            child: Container(
              width: 440,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.delete_forever_outlined,
                        color: Color(0xFFEB5757),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Delete $count ${count == 1 ? 'game' : 'games'}?',
                          style: const TextStyle(
                            color: kWhiteColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This rewrites "$databaseName" on this computer and removes the selected PGN ${count == 1 ? 'entry' : 'entries'}. This cannot be undone.',
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DesktopDialogButton(
                        label: 'Cancel',
                        onPress: () => Navigator.of(ctx).pop(false),
                      ),
                      const SizedBox(width: 8),
                      DesktopDialogButton(
                        label: 'Delete',
                        tone: DesktopDialogButtonTone.danger,
                        onPress: () => Navigator.of(ctx).pop(true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
  );
  return confirmed == true;
}

void _openLocalDatabaseTree(
  WidgetRef ref,
  LocalChessFileNode database, {
  required String title,
  required String sourceLabel,
}) {
  final index = database.openingTreeIndex;
  if (index == null || !index.isUsable) return;
  final tabId = openBoardGameTab(
    ref,
    BoardTabGameArgs(
      pgn: '',
      label: title,
      whiteName: '',
      blackName: '',
      fenSeed: _kLocalDatabaseTreeStartingFen,
      initialFen: _kLocalDatabaseTreeStartingFen,
      databaseTitle: sourceLabel,
      localOpeningTreeIndex: _localOpeningTreeHandle(index),
      localOpeningTreeTitle: sourceLabel,
      enableLocalOpeningTreePicker: true,
    ),
    reuseExisting: false,
  );
  ref.read(rightRailActivePageProvider(tabId).notifier).state = 1;
}

void _openLocalGame(
  WidgetRef ref,
  LocalChessGame localGame, {
  required String sourceLabel,
  required List<LocalChessGame> databaseGames,
  PlayerOpeningTreeIndex? localOpeningTreeIndex,
  bool focus = true,
}) {
  openBoardGameTab(
    ref,
    _boardArgsForLocalGame(
      localGame,
      sourceLabel: sourceLabel,
      databaseGames: databaseGames,
      localOpeningTreeIndex:
          localOpeningTreeIndex == null
              ? null
              : _localOpeningTreeHandle(localOpeningTreeIndex),
    ),
    reuseExisting: false,
    focus: focus,
  );
}

PlayerOpeningTreeIndex _localOpeningTreeHandle(PlayerOpeningTreeIndex index) {
  if (index.nodesById.isEmpty &&
      index.nodesByFenKey.isEmpty &&
      index.gamesByFen.isEmpty &&
      index.gameRowsById.isEmpty) {
    return index;
  }
  return PlayerOpeningTreeIndex(
    treeId: index.treeId,
    playerId: index.playerId,
    maxPly: index.maxPly,
    rootNodeId: index.rootNodeId,
    generatedAt: index.generatedAt,
    nodesById: const <int, PlayerOpeningTreeNode>{},
    nodesByFenKey: const <String, PlayerOpeningTreeNode>{},
    gamesByFen: const <String, List<PlayerOpeningTreeGameRef>>{},
    gameRowsById: const <String, Map<String, dynamic>>{},
    persistedPositionCount: index.positionCount,
    persistedGameCount: index.downloadedGameCount,
  );
}

BoardTabGameArgs _boardArgsForLocalGame(
  LocalChessGame localGame, {
  required String sourceLabel,
  required List<LocalChessGame> databaseGames,
  PlayerOpeningTreeIndex? localOpeningTreeIndex,
}) {
  final game = localGame.game;
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  return BoardTabGameArgs(
    pgn: localGame.rawPgn,
    label: localGame.title,
    whiteName: s('White'),
    blackName: s('Black'),
    whiteFederation: localPgnFederation(md, 'White'),
    blackFederation: localPgnFederation(md, 'Black'),
    whiteTitle: s('WhiteTitle'),
    blackTitle: s('BlackTitle'),
    whiteRating: rating('WhiteElo'),
    blackRating: rating('BlackElo'),
    whiteFideId: fideId('WhiteFideId'),
    blackFideId: fideId('BlackFideId'),
    fenSeed: game.startingFen,
    databaseTitle: sourceLabel,
    databaseGames: _summariesFromLocalGames(
      _localBoardContextGames(localGame, databaseGames),
    ),
    localOpeningTreeIndex: localOpeningTreeIndex,
    localOpeningTreeTitle: sourceLabel,
    enableLocalOpeningTreePicker: true,
    gameListSelectedId: localGame.id,
    librarySaveOrigin: BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: localGame.sourcePath,
      sourceIndex: localGame.indexInFile,
      sourceFileGameCount: localGame.fileGameCount,
      title: localGame.title,
    ),
  );
}

const int _kLocalBoardContextRadius = 30;

List<LocalChessGame> _localBoardContextGames(
  LocalChessGame selected,
  List<LocalChessGame> databaseGames,
) {
  if (databaseGames.isEmpty) return <LocalChessGame>[selected];

  final selectedIndex = databaseGames.indexWhere(
    (game) => game.id == selected.id,
  );
  if (selectedIndex < 0) return <LocalChessGame>[selected];

  final start =
      selectedIndex - _kLocalBoardContextRadius < 0
          ? 0
          : selectedIndex - _kLocalBoardContextRadius;
  final end =
      selectedIndex + _kLocalBoardContextRadius + 1 > databaseGames.length
          ? databaseGames.length
          : selectedIndex + _kLocalBoardContextRadius + 1;
  return databaseGames.sublist(start, end);
}

List<TournamentGameSummary> _summariesFromLocalGames(
  List<LocalChessGame> games,
) {
  return [for (final game in games) _summaryFromLocalGame(game)];
}

TournamentGameSummary _summaryFromLocalGame(LocalChessGame localGame) {
  final game = localGame.game;
  final md = game.metadata;
  String s(String key) => (md[key]?.toString() ?? '').trim();
  int rating(String key) => int.tryParse(s(key)) ?? 0;
  int? fideId(String key) {
    final value = rating(key);
    return value > 0 ? value : null;
  }

  final pgn = localGame.rawPgn.trim();
  final lastFen =
      game.mainline.isNotEmpty ? game.mainline.last.fen : game.startingFen;
  return TournamentGameSummary(
    id: localGame.id,
    name: localGame.title,
    whitePlayer: s('White'),
    blackPlayer: s('Black'),
    whiteFederation: localPgnFederation(md, 'White'),
    blackFederation: localPgnFederation(md, 'Black'),
    whiteTitle: s('WhiteTitle'),
    blackTitle: s('BlackTitle'),
    whiteRating: rating('WhiteElo'),
    blackRating: rating('BlackElo'),
    whiteFideId: fideId('WhiteFideId'),
    blackFideId: fideId('BlackFideId'),
    hasPgn: pgn.isNotEmpty,
    pgn: pgn.isEmpty ? null : pgn,
    fen: lastFen,
    roundLabel: s('Round'),
    status: _statusFromResult(s('Result')),
    openingName: s('Opening').isNotEmpty ? s('Opening') : s('ECO'),
    hasStarted: localGame.hasMoves,
  );
}

GameStatus _statusFromResult(String result) {
  switch (result.replaceAll('½', '1/2').trim()) {
    case '1-0':
      return GameStatus.whiteWins;
    case '0-1':
      return GameStatus.blackWins;
    case '1/2-1/2':
      return GameStatus.draw;
    case '*':
      return GameStatus.ongoing;
    default:
      return GameStatus.unknown;
  }
}

IconData _iconFor(LocalChessNode node) {
  return switch (node) {
    LocalChessFolderNode() => Icons.folder_rounded,
    LocalChessFileNode(status: LocalChessFileStatus.parsed) =>
      Icons.description_outlined,
    LocalChessFileNode(status: LocalChessFileStatus.noGames) =>
      Icons.article_outlined,
    LocalChessFileNode(status: LocalChessFileStatus.unsupported) =>
      Icons.lock_outline_rounded,
    LocalChessFileNode(status: LocalChessFileStatus.failed) =>
      Icons.error_outline_rounded,
    _ => Icons.insert_drive_file_outlined,
  };
}

List<ChessGame> _hydrateLocalGamesForSave(List<LocalChessGame> games) {
  final out = <ChessGame>[];
  for (final game in games) {
    try {
      final parsed = ChessGame.fromPgn(game.id, game.rawPgn);
      // The stored header bag may carry backfilled tags (WhiteTitle/WhiteFed)
      // the raw PGN never had; keep them when saving to the library.
      out.add(
        parsed.copyWith(
          metadata: <String, dynamic>{
            ...game.game.metadata,
            ...parsed.metadata,
          },
        ),
      );
    } catch (_) {
      out.add(game.game);
    }
  }
  return out;
}
